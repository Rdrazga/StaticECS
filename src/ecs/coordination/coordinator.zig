//! World Coordinator
//!
//! Manages multiple ECS worlds in a pipeline configuration.
//! Each world can process entities at different pipeline stages simultaneously,
//! with entity transfers handled through lock-free queues.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
//! │   World 0   │ ──► │   World 1   │ ──► │   World 2   │
//! │   (Accept)  │     │    (I/O)    │     │  (Compute)  │
//! └─────────────┘     └─────────────┘     └─────────────┘
//!       │                   ▲                   │
//!       └───────────────────┴───────────────────┘
//!              Lock-free Transfer Queues
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const Coordinator = ecs.WorldCoordinator(config, 3);
//! var coord = try Coordinator.init(allocator);
//! defer coord.deinit();
//!
//! // Run coordination loop
//! while (running) {
//!     try coord.tick(delta_time);
//! }
//! ```
//!
//! Tiger Style: All bounds from config. Zero allocations after init.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;

const lock_free_queue = @import("lock_free_queue.zig");
const LockFreeQueue = lock_free_queue.LockFreeQueue;

const transfer_mod = @import("transfer.zig");
const EntityTransfer = transfer_mod.EntityTransfer;
const TransferMarker = transfer_mod.TransferMarker;

// ============================================================================
// Coordinator Statistics
// ============================================================================

/// Statistics tracked by the coordinator
pub const CoordinatorStats = struct {
    /// Total ticks executed
    ticks: u64 = 0,
    /// Transfers sent per world (indexed by source world)
    transfers_sent: [MAX_WORLDS]u64 = [_]u64{0} ** MAX_WORLDS,
    /// Transfers received per world (indexed by target world)
    transfers_received: [MAX_WORLDS]u64 = [_]u64{0} ** MAX_WORLDS,
    /// Queue full events per world pair
    queue_full_count: u64 = 0,
    /// Time spent in tick (nanoseconds)
    total_tick_time_ns: u64 = 0,

    const MAX_WORLDS = 8;

    pub fn reset(self: *CoordinatorStats) void {
        self.* = .{};
    }
};

// ============================================================================
// World Coordinator
// ============================================================================

/// Coordinates multiple ECS worlds with the same configuration.
///
/// This coordinator manages worlds that share the same component schema
/// but have different roles in a pipeline. For heterogeneous world configs,
/// use separate coordinators or a custom orchestration layer.
///
/// Tiger Style: Fixed world count at comptime. Lock-free transfer queues.
pub fn WorldCoordinator(comptime cfg: WorldConfig, comptime world_count: u8) type {
    comptime {
        if (world_count < 1) {
            @compileError("WorldCoordinator requires at least 1 world");
        }
        if (world_count > 8) {
            @compileError("WorldCoordinator supports at most 8 worlds");
        }
    }

    const Transfer = EntityTransfer(cfg);
    const queue_capacity = cfg.coordination.transfer_queue.capacity;
    const TransferQueue = LockFreeQueue(Transfer, queue_capacity);

    return struct {
        const Self = @This();

        /// Number of worlds managed
        pub const num_worlds = world_count;

        /// Transfer queues: queues[src][dst] = queue from src to dst
        /// Diagonal (src == dst) is unused
        queues: [world_count][world_count]TransferQueue,

        /// Running state
        running: Atomic(bool),

        /// Statistics
        stats: CoordinatorStats,

        /// Allocator for cleanup
        allocator: Allocator,

        /// Initialize the coordinator.
        pub fn init(allocator: Allocator) Self {
            var self = Self{
                .queues = undefined,
                .running = Atomic(bool).init(false),
                .stats = .{},
                .allocator = allocator,
            };

            // Initialize all transfer queues
            for (0..world_count) |src| {
                for (0..world_count) |dst| {
                    self.queues[src][dst] = TransferQueue.init();
                }
            }

            return self;
        }

        /// Clean up coordinator resources.
        pub fn deinit(self: *Self) void {
            self.stop();
        }

        /// Start the coordinator (marks as running).
        pub fn start(self: *Self) void {
            self.running.store(true, .release);
        }

        /// Stop the coordinator.
        pub fn stop(self: *Self) void {
            self.running.store(false, .release);
        }

        /// Check if coordinator is running.
        pub fn isRunning(self: *const Self) bool {
            return self.running.load(.acquire);
        }

        /// Queue an entity transfer from source to target world.
        /// Returns false if queue is full (back-pressure).
        pub fn queueTransfer(
            self: *Self,
            source_world: u8,
            target_world: u8,
            transfer: Transfer,
        ) bool {
            if (source_world >= world_count or target_world >= world_count) {
                return false;
            }
            if (source_world == target_world) {
                return false; // Can't transfer to self
            }

            const queue = &self.queues[source_world][target_world];
            if (queue.push(transfer)) {
                self.stats.transfers_sent[source_world] += 1;
                return true;
            } else {
                self.stats.queue_full_count += 1;
                return false;
            }
        }

        /// Pop a pending transfer for a specific world.
        /// Checks all queues targeting this world.
        pub fn popTransferFor(self: *Self, target_world: u8) ?Transfer {
            if (target_world >= world_count) return null;

            // Check all source queues for this target
            for (0..world_count) |src| {
                if (src == target_world) continue;

                const queue = &self.queues[src][target_world];
                if (queue.pop()) |transfer| {
                    self.stats.transfers_received[target_world] += 1;
                    return transfer;
                }
            }

            return null;
        }

        /// Pop multiple transfers for a world (batch operation).
        pub fn popTransferBatchFor(self: *Self, target_world: u8, out: []Transfer) usize {
            if (target_world >= world_count) return 0;

            var count: usize = 0;

            // Check all source queues for this target
            for (0..world_count) |src| {
                if (src == target_world) continue;
                if (count >= out.len) break;

                const queue = &self.queues[src][target_world];
                const remaining = out.len - count;
                const batch_count = queue.popBatch(out[count..][0..remaining]);
                self.stats.transfers_received[target_world] += batch_count;
                count += batch_count;
            }

            return count;
        }

        /// Get pending transfer count for a world.
        pub fn pendingTransfersFor(self: *const Self, target_world: u8) usize {
            if (target_world >= world_count) return 0;

            var total: usize = 0;
            for (0..world_count) |src| {
                if (src == target_world) continue;
                total += self.queues[src][target_world].len();
            }
            return total;
        }

        /// Get total pending transfers across all queues.
        pub fn totalPendingTransfers(self: *const Self) usize {
            var total: usize = 0;
            for (0..world_count) |src| {
                for (0..world_count) |dst| {
                    if (src != dst) {
                        total += self.queues[src][dst].len();
                    }
                }
            }
            return total;
        }

        /// Get the transfer queue between two worlds (for direct access).
        pub fn getQueue(self: *Self, source: u8, target: u8) ?*TransferQueue {
            if (source >= world_count or target >= world_count) return null;
            if (source == target) return null;
            return &self.queues[source][target];
        }

        /// Get coordinator statistics.
        pub fn getStats(self: *const Self) CoordinatorStats {
            return self.stats;
        }

        /// Reset coordinator statistics.
        pub fn resetStats(self: *Self) void {
            self.stats.reset();
        }

        /// Tick counter increment (for external tracking).
        pub fn recordTick(self: *Self) void {
            self.stats.ticks += 1;
        }

        /// Create a transfer packet initialized for source→target.
        pub fn createTransfer(source: u8, target: u8) Transfer {
            return Transfer.init(source, target);
        }
    };
}

// ============================================================================
// Helper: Single World Pipeline
// ============================================================================

/// Configuration helper for creating a standard 3-world pipeline.
/// Returns configs for accept, io, and compute worlds.
pub fn createPipelineConfigs(comptime base_cfg: WorldConfig) struct {
    accept: WorldConfig,
    io: WorldConfig,
    compute: WorldConfig,
} {
    const accept_cfg = blk: {
        var cfg = base_cfg;
        cfg.coordination = .{
            .role = .accept,
            .world_id = 0,
            .routing = .{ .default_target = 1 },
        };
        break :blk cfg;
    };

    const io_cfg = blk: {
        var cfg = base_cfg;
        cfg.coordination = .{
            .role = .io,
            .world_id = 1,
            .routing = .{ .default_target = 2 },
        };
        break :blk cfg;
    };

    const compute_cfg = blk: {
        var cfg = base_cfg;
        cfg.coordination = .{
            .role = .compute,
            .world_id = 2,
            .routing = .{ .default_target = 1 }, // Back to IO for writing
        };
        break :blk cfg;
    };

    return .{
        .accept = accept_cfg,
        .io = io_cfg,
        .compute = compute_cfg,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "WorldCoordinator initialization" {
    const Pos = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Pos} },
        .coordination = .{
            .role = .standalone,
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 3);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    try std.testing.expectEqual(@as(u8, 3), Coordinator.num_worlds);
    try std.testing.expect(!coord.isRunning());
}

test "WorldCoordinator start/stop" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    try std.testing.expect(!coord.isRunning());

    coord.start();
    try std.testing.expect(coord.isRunning());

    coord.stop();
    try std.testing.expect(!coord.isRunning());
}

test "WorldCoordinator queueTransfer" {
    const Data = struct { value: i32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Data} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 3);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Create a transfer from world 0 to world 1
    var transfer = Coordinator.createTransfer(0, 1);
    try std.testing.expect(transfer.packComponent(Data, .{ .value = 42 }));

    // Queue it
    try std.testing.expect(coord.queueTransfer(0, 1, transfer));
    try std.testing.expectEqual(@as(usize, 1), coord.pendingTransfersFor(1));

    // Pop it
    const received = coord.popTransferFor(1).?;
    try std.testing.expectEqual(@as(u8, 0), received.source_world);
    try std.testing.expectEqual(@as(u8, 1), received.target_world);

    const data = received.unpackComponent(Data).?;
    try std.testing.expectEqual(@as(i32, 42), data.value);
}

test "WorldCoordinator batch transfer" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Queue multiple transfers
    for (0..5) |_| {
        const transfer = Coordinator.createTransfer(0, 1);
        try std.testing.expect(coord.queueTransfer(0, 1, transfer));
    }

    try std.testing.expectEqual(@as(usize, 5), coord.pendingTransfersFor(1));
    try std.testing.expectEqual(@as(usize, 5), coord.totalPendingTransfers());

    // Batch pop
    const Transfer = EntityTransfer(cfg);
    var out: [10]Transfer = undefined;
    const count = coord.popTransferBatchFor(1, &out);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqual(@as(usize, 0), coord.pendingTransfersFor(1));
}

test "WorldCoordinator invalid transfers" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    const transfer = Coordinator.createTransfer(0, 1);

    // Invalid: self transfer
    try std.testing.expect(!coord.queueTransfer(0, 0, transfer));

    // Invalid: out of bounds
    try std.testing.expect(!coord.queueTransfer(5, 1, transfer));
    try std.testing.expect(!coord.queueTransfer(0, 5, transfer));
}

test "WorldCoordinator statistics" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Queue and pop transfers
    const transfer = Coordinator.createTransfer(0, 1);
    _ = coord.queueTransfer(0, 1, transfer);
    _ = coord.popTransferFor(1);

    const stats = coord.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.transfers_sent[0]);
    try std.testing.expectEqual(@as(u64, 1), stats.transfers_received[1]);

    coord.resetStats();
    const reset_stats = coord.getStats();
    try std.testing.expectEqual(@as(u64, 0), reset_stats.transfers_sent[0]);
}

test "WorldCoordinator getQueue" {
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Valid queue
    const queue = coord.getQueue(0, 1);
    try std.testing.expect(queue != null);

    // Invalid: self queue
    try std.testing.expectEqual(@as(?*@TypeOf(coord.queues[0][0]), null), coord.getQueue(0, 0));

    // Invalid: out of bounds
    try std.testing.expectEqual(@as(?*@TypeOf(coord.queues[0][0]), null), coord.getQueue(5, 1));
}

test "createPipelineConfigs" {
    const base = WorldConfig{
        .components = .{ .types = &.{} },
    };

    const pipeline = createPipelineConfigs(base);

    try std.testing.expectEqual(config_mod.WorldRole.accept, pipeline.accept.coordination.role);
    try std.testing.expectEqual(@as(u8, 0), pipeline.accept.coordination.world_id);
    try std.testing.expectEqual(@as(?u8, 1), pipeline.accept.coordination.routing.default_target);

    try std.testing.expectEqual(config_mod.WorldRole.io, pipeline.io.coordination.role);
    try std.testing.expectEqual(@as(u8, 1), pipeline.io.coordination.world_id);

    try std.testing.expectEqual(config_mod.WorldRole.compute, pipeline.compute.coordination.role);
    try std.testing.expectEqual(@as(u8, 2), pipeline.compute.coordination.world_id);
}
