//! # World Coordinator
//!
//! Purpose: Manages multiple ECS worlds in a pipeline configuration for
//! horizontal scaling. Enables parallel processing across pipeline stages.
//!
//! ## Key Types
//! - `WorldCoordinator` - Central coordinator managing N worlds
//! - `Seqlock` - Sequence lock for atomic statistics snapshots
//! - `CoordinatorStats` - Metrics snapshot type
//! - `AtomicStats` - Lock-free updateable statistics
//!
//! ## Architecture
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
//! ```zig
//! const Coordinator = WorldCoordinator(cfg, 3);  // 3 worlds
//! var coord = try Coordinator.init(allocator);
//! defer coord.deinit();
//!
//! // Queue entity transfer between worlds
//! const transfer = coord.createTransfer(entity, target_world);
//! _ = coord.queueTransfer(source_world, target_world, transfer);
//!
//! // Process transfers and tick all worlds
//! try coord.tick(delta_time);
//!
//! // Monitor coordination health
//! const stats = coord.getStats();
//! if (stats.queue_full_count > 0) {
//!     log.warn("Transfer backpressure detected");
//! }
//! ```
//!
//! ## Threading Model
//! - Each world can run on a dedicated thread
//! - Transfer queues are lock-free (MPMC or SPSC based on config)
//! - Statistics use seqlock for consistent snapshots
//! - Queue full events are tracked atomically
//!
//! ## Backpressure
//! - `queueTransfer()` returns `false` when queue is full
//! - `queue_full_count` metric tracks rejected transfers
//! - Caller decides retry/drop policy
//!
//! ## Related Modules
//! - `lock_free_queue.zig` - Transfer queue implementation
//! - `transfer.zig` - Entity transfer serialization
//! - `../world.zig` - Individual world implementation
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
// Seqlock for Atomic Snapshots
// ============================================================================

/// Sequence lock for atomic snapshot reads.
/// Even version = stable, odd version = write in progress.
///
/// Writers increment version before AND after updating protected data.
/// Readers spin if version is odd (write in progress) or changed during read.
///
/// Tiger Style: Wait-free writes, lock-free reads. Bounded retry with spinLoopHint.
pub const Seqlock = struct {
    version: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Maximum retry attempts for snapshot reads before returning null.
    /// Under normal conditions, retries should be 0-2.
    pub const MAX_RETRIES: u32 = 100;

    /// Begin a write operation (increments version to odd).
    /// Must be paired with endWrite().
    pub fn beginWrite(self: *Seqlock) void {
        _ = self.version.fetchAdd(1, .release);
    }

    /// End a write operation (increments version to even).
    /// Must be called after beginWrite().
    pub fn endWrite(self: *Seqlock) void {
        _ = self.version.fetchAdd(1, .release);
    }

    /// Read the current version for snapshot validation.
    pub fn readVersion(self: *const Seqlock) u32 {
        return self.version.load(.acquire);
    }

    /// Check if a snapshot taken at start_version is still valid.
    /// Valid if: started on even (no write in progress) AND hasn't changed.
    pub fn validateSnapshot(self: *const Seqlock, start_version: u32) bool {
        const end_version = self.version.load(.acquire);
        return (start_version & 1) == 0 and start_version == end_version;
    }

    /// Check if version indicates a write is in progress.
    pub fn isWriteInProgress(version: u32) bool {
        return (version & 1) != 0;
    }
};

// ============================================================================
// Coordinator Statistics
// ============================================================================

/// Non-atomic snapshot of coordinator statistics (returned by getStats).
/// Use this for reading/displaying stats outside the coordinator.
pub const CoordinatorStatsSnapshot = struct {
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
};

/// Atomic statistics tracked by the coordinator.
/// All fields are atomic to ensure thread-safe concurrent updates.
///
/// Uses a seqlock for atomic snapshot reads:
/// - Individual counter updates use fetchAdd for lock-free writes
/// - Batch writes (like reset) use beginWrite/endWrite for atomicity
/// - Readers use getAtomicSnapshot() for consistent multi-field reads
///
/// Tiger Style: Using monotonic ordering for pure statistics, seqlock for snapshot consistency.
pub const CoordinatorStats = struct {
    /// Seqlock for atomic snapshot reads
    seqlock: Seqlock = .{},

    /// Total ticks executed
    ticks: Atomic(u64),
    /// Transfers sent per world (indexed by source world)
    transfers_sent: [MAX_WORLDS]Atomic(u64),
    /// Transfers received per world (indexed by target world)
    transfers_received: [MAX_WORLDS]Atomic(u64),
    /// Queue full events per world pair
    queue_full_count: Atomic(u64),
    /// Time spent in tick (nanoseconds)
    total_tick_time_ns: Atomic(u64),

    const MAX_WORLDS = 8;

    /// Initialize all atomic counters to zero.
    pub fn init() CoordinatorStats {
        return .{
            .seqlock = .{},
            .ticks = Atomic(u64).init(0),
            .transfers_sent = [_]Atomic(u64){Atomic(u64).init(0)} ** MAX_WORLDS,
            .transfers_received = [_]Atomic(u64){Atomic(u64).init(0)} ** MAX_WORLDS,
            .queue_full_count = Atomic(u64).init(0),
            .total_tick_time_ns = Atomic(u64).init(0),
        };
    }

    /// Begin a write operation - call before updating multiple fields atomically.
    /// Must be paired with endWrite().
    pub fn beginWrite(self: *CoordinatorStats) void {
        self.seqlock.beginWrite();
    }

    /// End a write operation - call after updating multiple fields atomically.
    /// Must be called after beginWrite().
    pub fn endWrite(self: *CoordinatorStats) void {
        self.seqlock.endWrite();
    }

    /// Reset all counters to zero atomically.
    /// Uses seqlock to ensure readers see consistent state.
    pub fn reset(self: *CoordinatorStats) void {
        self.seqlock.beginWrite();
        defer self.seqlock.endWrite();

        self.ticks.store(0, .monotonic);
        for (&self.transfers_sent) |*counter| {
            counter.store(0, .monotonic);
        }
        for (&self.transfers_received) |*counter| {
            counter.store(0, .monotonic);
        }
        self.queue_full_count.store(0, .monotonic);
        self.total_tick_time_ns.store(0, .monotonic);
    }

    /// Increment a single statistic without seqlock overhead.
    /// Use for individual counter updates in hot paths.
    /// For batch updates, use beginWrite/endWrite.
    pub fn incrementTicks(self: *CoordinatorStats) void {
        self.seqlock.beginWrite();
        _ = self.ticks.fetchAdd(1, .monotonic);
        self.seqlock.endWrite();
    }

    /// Add time to tick statistics with seqlock protection.
    pub fn addTickTime(self: *CoordinatorStats, delta_ns: u64) void {
        self.seqlock.beginWrite();
        _ = self.total_tick_time_ns.fetchAdd(delta_ns, .monotonic);
        self.seqlock.endWrite();
    }

    /// Increment transfer sent counter with seqlock protection.
    pub fn incrementTransfersSent(self: *CoordinatorStats, world: usize) void {
        if (world >= MAX_WORLDS) return;
        self.seqlock.beginWrite();
        _ = self.transfers_sent[world].fetchAdd(1, .monotonic);
        self.seqlock.endWrite();
    }

    /// Increment transfer received counter with seqlock protection.
    pub fn incrementTransfersReceived(self: *CoordinatorStats, world: usize, count: u64) void {
        if (world >= MAX_WORLDS) return;
        self.seqlock.beginWrite();
        _ = self.transfers_received[world].fetchAdd(count, .monotonic);
        self.seqlock.endWrite();
    }

    /// Increment queue full counter with seqlock protection.
    pub fn incrementQueueFull(self: *CoordinatorStats) void {
        self.seqlock.beginWrite();
        _ = self.queue_full_count.fetchAdd(1, .monotonic);
        self.seqlock.endWrite();
    }

    /// Create a non-atomic snapshot of current statistics (legacy API).
    /// WARNING: This can return inconsistent data if read during a write.
    /// Use getAtomicSnapshot() for consistent reads.
    /// Uses monotonic ordering since stats are for observation only.
    pub fn snapshot(self: *const CoordinatorStats) CoordinatorStatsSnapshot {
        var snap = CoordinatorStatsSnapshot{};
        snap.ticks = self.ticks.load(.monotonic);
        for (0..MAX_WORLDS) |i| {
            snap.transfers_sent[i] = self.transfers_sent[i].load(.monotonic);
            snap.transfers_received[i] = self.transfers_received[i].load(.monotonic);
        }
        snap.queue_full_count = self.queue_full_count.load(.monotonic);
        snap.total_tick_time_ns = self.total_tick_time_ns.load(.monotonic);
        return snap;
    }

    /// Read a consistent snapshot of statistics using seqlock.
    /// Returns null if unable to get consistent read after max_retries.
    ///
    /// This is safe to call concurrently with write operations.
    /// Under normal conditions (short write hold times), this should
    /// succeed immediately with 0-2 retries.
    pub fn getAtomicSnapshot(self: *const CoordinatorStats) ?CoordinatorStatsSnapshot {
        var retries: u32 = 0;

        while (retries < Seqlock.MAX_RETRIES) : (retries += 1) {
            const start_version = self.seqlock.readVersion();

            // Skip if write in progress (odd version)
            if (Seqlock.isWriteInProgress(start_version)) {
                std.atomic.spinLoopHint();
                continue;
            }

            // Read all fields
            var snap = CoordinatorStatsSnapshot{};
            snap.ticks = self.ticks.load(.monotonic);
            for (0..MAX_WORLDS) |i| {
                snap.transfers_sent[i] = self.transfers_sent[i].load(.monotonic);
                snap.transfers_received[i] = self.transfers_received[i].load(.monotonic);
            }
            snap.queue_full_count = self.queue_full_count.load(.monotonic);
            snap.total_tick_time_ns = self.total_tick_time_ns.load(.monotonic);

            // Validate snapshot is consistent (version unchanged)
            if (self.seqlock.validateSnapshot(start_version)) {
                return snap;
            }

            std.atomic.spinLoopHint();
        }

        return null; // Failed to get consistent snapshot
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
                .stats = CoordinatorStats.init(),
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
                self.stats.incrementTransfersSent(source_world);
                return true;
            } else {
                self.stats.incrementQueueFull();
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
                    self.stats.incrementTransfersReceived(target_world, 1);
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
                self.stats.incrementTransfersReceived(target_world, batch_count);
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

        /// Get coordinator statistics as a non-atomic snapshot.
        pub fn getStats(self: *const Self) CoordinatorStatsSnapshot {
            return self.stats.snapshot();
        }

        /// Reset coordinator statistics.
        pub fn resetStats(self: *Self) void {
            self.stats.reset();
        }

        /// Tick counter increment (for external tracking).
        pub fn recordTick(self: *Self) void {
            self.stats.incrementTicks();
        }

        /// Get atomic statistics snapshot (consistent multi-field read).
        /// Returns null if unable to get consistent read (very rare).
        pub fn getAtomicStats(self: *const Self) ?CoordinatorStatsSnapshot {
            return self.stats.getAtomicSnapshot();
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

// ============================================================================
// Extended Coordinator Tests (Task: Add Coordination Module Tests)
// ============================================================================

test "WorldCoordinator: multi-world initialization and lifecycle" {
    // Test coordinator creates proper queue matrix for multi-world setup.
    const TestComp = struct { value: i32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .coordination = .{
            .role = .standalone,
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    // Create coordinator for 3 worlds
    const Coordinator = WorldCoordinator(cfg, 3);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Verify initialization (no crash)
    try std.testing.expectEqual(@as(u8, 3), Coordinator.num_worlds);

    // Check initial stats (all zeros)
    const initial_stats = coord.getStats();
    try std.testing.expectEqual(@as(u64, 0), initial_stats.ticks);
    try std.testing.expectEqual(@as(u64, 0), initial_stats.queue_full_count);
    for (0..8) |i| {
        try std.testing.expectEqual(@as(u64, 0), initial_stats.transfers_sent[i]);
        try std.testing.expectEqual(@as(u64, 0), initial_stats.transfers_received[i]);
    }

    // Call start() - should set running state
    try std.testing.expect(!coord.isRunning());
    coord.start();
    try std.testing.expect(coord.isRunning());

    // Call stop() - should clear running state
    coord.stop();
    try std.testing.expect(!coord.isRunning());
}

test "WorldCoordinator: tick recording and stats accumulation" {
    // Test tick recording and statistics accumulation.
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Record multiple ticks
    coord.recordTick();
    coord.recordTick();
    coord.recordTick();

    try std.testing.expectEqual(@as(u64, 3), coord.getStats().ticks);

    // Stats should persist across multiple operations
    const transfer = Coordinator.createTransfer(0, 1);
    _ = coord.queueTransfer(0, 1, transfer);
    _ = coord.queueTransfer(0, 1, transfer);

    try std.testing.expectEqual(@as(u64, 2), coord.getStats().transfers_sent[0]);
    try std.testing.expectEqual(@as(u64, 3), coord.getStats().ticks);

    // Reset should clear all stats
    coord.resetStats();
    try std.testing.expectEqual(@as(u64, 0), coord.getStats().ticks);
    try std.testing.expectEqual(@as(u64, 0), coord.getStats().transfers_sent[0]);
}

test "WorldCoordinator: queue full back-pressure" {
    // Test that queue correctly reports full and tracks queue_full_count.
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 4 }, // Small capacity for testing
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Fill the queue
    for (0..4) |_| {
        const transfer = Coordinator.createTransfer(0, 1);
        try std.testing.expect(coord.queueTransfer(0, 1, transfer));
    }

    // Next push should fail and increment queue_full_count
    const extra_transfer = Coordinator.createTransfer(0, 1);
    try std.testing.expect(!coord.queueTransfer(0, 1, extra_transfer));
    try std.testing.expectEqual(@as(u64, 1), coord.getStats().queue_full_count);

    // Pop one and verify transfer succeeds again
    _ = coord.popTransferFor(1);
    try std.testing.expect(coord.queueTransfer(0, 1, extra_transfer));
}

test "WorldCoordinator: bidirectional transfers" {
    // Test transfers in both directions between worlds.
    const Data = struct { id: u32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Data} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 3);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // World 0 -> World 1
    var t01 = Coordinator.createTransfer(0, 1);
    _ = t01.packComponent(Data, .{ .id = 100 });
    try std.testing.expect(coord.queueTransfer(0, 1, t01));

    // World 1 -> World 0 (reverse direction)
    var t10 = Coordinator.createTransfer(1, 0);
    _ = t10.packComponent(Data, .{ .id = 200 });
    try std.testing.expect(coord.queueTransfer(1, 0, t10));

    // World 1 -> World 2
    var t12 = Coordinator.createTransfer(1, 2);
    _ = t12.packComponent(Data, .{ .id = 300 });
    try std.testing.expect(coord.queueTransfer(1, 2, t12));

    // Verify pending counts
    try std.testing.expectEqual(@as(usize, 1), coord.pendingTransfersFor(0));
    try std.testing.expectEqual(@as(usize, 1), coord.pendingTransfersFor(1));
    try std.testing.expectEqual(@as(usize, 1), coord.pendingTransfersFor(2));
    try std.testing.expectEqual(@as(usize, 3), coord.totalPendingTransfers());

    // Pop and verify data integrity
    const recv0 = coord.popTransferFor(0).?;
    try std.testing.expectEqual(@as(u32, 200), recv0.unpackComponent(Data).?.id);

    const recv1 = coord.popTransferFor(1).?;
    try std.testing.expectEqual(@as(u32, 100), recv1.unpackComponent(Data).?.id);

    const recv2 = coord.popTransferFor(2).?;
    try std.testing.expectEqual(@as(u32, 300), recv2.unpackComponent(Data).?.id);
}

// ============================================================================
// Seqlock Tests (Task: Atomic Statistics Snapshot H1)
// ============================================================================

test "Seqlock: basic version counting" {
    // Test that begin/end write properly updates version.
    var lock = Seqlock{};

    // Initial version is 0 (even = stable)
    try std.testing.expectEqual(@as(u32, 0), lock.readVersion());
    try std.testing.expect(!Seqlock.isWriteInProgress(lock.readVersion()));

    // Begin write: version becomes 1 (odd = write in progress)
    lock.beginWrite();
    try std.testing.expectEqual(@as(u32, 1), lock.readVersion());
    try std.testing.expect(Seqlock.isWriteInProgress(lock.readVersion()));

    // End write: version becomes 2 (even = stable)
    lock.endWrite();
    try std.testing.expectEqual(@as(u32, 2), lock.readVersion());
    try std.testing.expect(!Seqlock.isWriteInProgress(lock.readVersion()));

    // Multiple write cycles increment correctly
    lock.beginWrite();
    lock.endWrite();
    try std.testing.expectEqual(@as(u32, 4), lock.readVersion());

    lock.beginWrite();
    lock.endWrite();
    try std.testing.expectEqual(@as(u32, 6), lock.readVersion());
}

test "Seqlock: validateSnapshot success case" {
    // Test that validateSnapshot succeeds when version unchanged.
    var lock = Seqlock{};

    const start_version = lock.readVersion();
    try std.testing.expect(lock.validateSnapshot(start_version));

    // Still valid if no writes occurred
    try std.testing.expect(lock.validateSnapshot(start_version));
}

test "Seqlock: validateSnapshot fails on odd version" {
    // Test that validateSnapshot fails if started during write.
    var lock = Seqlock{};

    lock.beginWrite();
    const odd_version = lock.readVersion();
    // Odd version should fail validation
    try std.testing.expect(!lock.validateSnapshot(odd_version));
    lock.endWrite();
}

test "Seqlock: validateSnapshot fails on version change" {
    // Test that validateSnapshot fails if version changed.
    var lock = Seqlock{};

    const start_version = lock.readVersion();
    try std.testing.expectEqual(@as(u32, 0), start_version);

    // Simulate a write cycle
    lock.beginWrite();
    lock.endWrite();

    // Version is now 2, so validating version 0 should fail
    try std.testing.expect(!lock.validateSnapshot(start_version));
}

test "CoordinatorStats: atomic snapshot succeeds single-threaded" {
    // In single-threaded case, atomic snapshot should always succeed.
    var stats = CoordinatorStats.init();

    // Initial state: all zeros
    const snapshot = stats.getAtomicSnapshot().?;
    try std.testing.expectEqual(@as(u64, 0), snapshot.ticks);
    try std.testing.expectEqual(@as(u64, 0), snapshot.queue_full_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.total_tick_time_ns);
    for (0..8) |i| {
        try std.testing.expectEqual(@as(u64, 0), snapshot.transfers_sent[i]);
        try std.testing.expectEqual(@as(u64, 0), snapshot.transfers_received[i]);
    }

    // Update some stats
    stats.incrementTicks();
    stats.incrementTicks();
    stats.incrementTransfersSent(0);
    stats.incrementTransfersReceived(1, 5);
    stats.incrementQueueFull();
    stats.addTickTime(1000);

    // Atomic snapshot should reflect all updates
    const updated = stats.getAtomicSnapshot().?;
    try std.testing.expectEqual(@as(u64, 2), updated.ticks);
    try std.testing.expectEqual(@as(u64, 1), updated.transfers_sent[0]);
    try std.testing.expectEqual(@as(u64, 5), updated.transfers_received[1]);
    try std.testing.expectEqual(@as(u64, 1), updated.queue_full_count);
    try std.testing.expectEqual(@as(u64, 1000), updated.total_tick_time_ns);
}

test "CoordinatorStats: reset uses seqlock" {
    // Test that reset properly uses seqlock protection.
    var stats = CoordinatorStats.init();

    // Add some values
    stats.incrementTicks();
    stats.incrementTransfersSent(0);
    stats.incrementQueueFull();

    // Reset should clear all values atomically
    stats.reset();

    // Atomic snapshot should see all zeros
    const snapshot = stats.getAtomicSnapshot().?;
    try std.testing.expectEqual(@as(u64, 0), snapshot.ticks);
    try std.testing.expectEqual(@as(u64, 0), snapshot.transfers_sent[0]);
    try std.testing.expectEqual(@as(u64, 0), snapshot.queue_full_count);
}

test "CoordinatorStats: legacy snapshot still works" {
    // Test that non-atomic snapshot API still works for compatibility.
    var stats = CoordinatorStats.init();

    stats.incrementTicks();
    stats.incrementTransfersSent(2);

    // Legacy snapshot should return values (though not atomically)
    const snap = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.ticks);
    try std.testing.expectEqual(@as(u64, 1), snap.transfers_sent[2]);
}

test "WorldCoordinator: getAtomicStats returns consistent snapshot" {
    // Test the coordinator-level atomic stats getter.
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Initial atomic stats should be all zeros
    const initial = coord.getAtomicStats().?;
    try std.testing.expectEqual(@as(u64, 0), initial.ticks);
    try std.testing.expectEqual(@as(u64, 0), initial.transfers_sent[0]);

    // Update stats through coordinator operations
    coord.recordTick();
    const transfer = Coordinator.createTransfer(0, 1);
    _ = coord.queueTransfer(0, 1, transfer);
    _ = coord.popTransferFor(1);

    // Atomic stats should reflect all changes
    const updated = coord.getAtomicStats().?;
    try std.testing.expectEqual(@as(u64, 1), updated.ticks);
    try std.testing.expectEqual(@as(u64, 1), updated.transfers_sent[0]);
    try std.testing.expectEqual(@as(u64, 1), updated.transfers_received[1]);
}

test "WorldCoordinator: atomic vs legacy stats comparison" {
    // Both getStats (legacy) and getAtomicStats should return same values in single-threaded case.
    const cfg = WorldConfig{
        .components = .{ .types = &.{} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    const Coordinator = WorldCoordinator(cfg, 2);
    var coord = Coordinator.init(std.testing.allocator);
    defer coord.deinit();

    // Perform some operations
    for (0..5) |_| {
        coord.recordTick();
        const transfer = Coordinator.createTransfer(0, 1);
        _ = coord.queueTransfer(0, 1, transfer);
    }

    // Both methods should return identical values
    const legacy = coord.getStats();
    const atomic = coord.getAtomicStats().?;

    try std.testing.expectEqual(legacy.ticks, atomic.ticks);
    try std.testing.expectEqual(legacy.transfers_sent[0], atomic.transfers_sent[0]);
    try std.testing.expectEqual(legacy.queue_full_count, atomic.queue_full_count);
}
