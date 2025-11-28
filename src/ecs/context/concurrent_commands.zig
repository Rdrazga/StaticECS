//! Concurrent Command Buffers - Thread-Safe Parallel Command Collection
//!
//! This module provides per-system command buffers for concurrent execution.
//! When systems run in parallel, each system gets its own command buffer to
//! avoid data races. After the stage completes, all per-system buffers are
//! merged into the main buffer in deterministic order.
//!
//! Tiger Style: Buffer sizes derived from config, divided by max systems.

const std = @import("std");

const command_buffer = @import("command_buffer.zig");
const CommandBufferType = command_buffer.CommandBufferType;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;

const entity_mod = @import("../world/entity.zig");
const EntityHandle = entity_mod.EntityHandle;
const EntityId = entity_mod.EntityId;

// ============================================================================
// Concurrent Command Buffers
// ============================================================================

/// Per-system command buffers for concurrent execution.
///
/// When systems run in parallel (concurrent_threadpool mode), each system
/// gets its own command buffer to avoid data races. After the stage completes,
/// all per-system buffers are merged into the main buffer in deterministic order.
///
/// Tiger Style: Buffer sizes derived from config, divided by max systems.
pub fn ConcurrentCommandBuffers(
    comptime max_systems: usize,
    comptime total_max_commands: usize,
    comptime max_data_size: u32,
) type {
    // Each system gets an equal share of the total command budget
    const commands_per_system = total_max_commands / max_systems;
    const PerSystemBuffer = CommandBufferType(commands_per_system, max_data_size);

    return struct {
        const Self = @This();

        /// Type of per-system buffer.
        pub const BufferType = PerSystemBuffer;
        /// Commands each system can hold.
        pub const commands_per_buffer = commands_per_system;
        /// Maximum number of concurrent systems.
        pub const max_concurrent_systems = max_systems;

        /// Per-system command buffers.
        buffers: [max_systems]PerSystemBuffer = .{PerSystemBuffer.init()} ** max_systems,

        /// Number of systems actively using buffers.
        active_count: u16 = 0,

        /// Initialize concurrent command buffers.
        pub fn init() Self {
            return .{};
        }

        /// Get the command buffer for a specific system index.
        ///
        /// Tiger Style: System index must be < max_systems.
        /// Precondition: system_index < max_concurrent_systems
        pub fn getForSystem(self: *Self, system_index: u16) *PerSystemBuffer {
            std.debug.assert(system_index < max_systems);
            if (system_index >= self.active_count) {
                self.active_count = system_index + 1;
            }
            return &self.buffers[system_index];
        }

        /// Merge all active per-system buffers into a target buffer.
        ///
        /// Commands are merged in system index order for deterministic results.
        /// After merge, all per-system buffers are cleared.
        ///
        /// Returns the number of commands merged, or 0 if target would overflow.
        pub fn mergeInto(self: *Self, target: anytype) usize {
            var merged_count: usize = 0;

            for (0..self.active_count) |i| {
                const src = &self.buffers[i];
                for (src.getCommands()) |cmd| {
                    // Check if target can accept more commands
                    if (target.count >= @TypeOf(target.*).max_command_count) {
                        // Target is full, stop merging
                        self.clearAll();
                        return merged_count;
                    }

                    // Copy command to target
                    target.commands[target.count] = convertCommand(cmd);
                    target.count += 1;
                    merged_count += 1;
                }
                src.clear();
            }

            self.active_count = 0;
            return merged_count;
        }

        /// Clear all per-system buffers.
        pub fn clearAll(self: *Self) void {
            for (0..self.active_count) |i| {
                self.buffers[i].clear();
            }
            self.active_count = 0;
        }

        /// Get total commands across all active buffers.
        pub fn totalCommands(self: *const Self) usize {
            var total: usize = 0;
            for (0..self.active_count) |i| {
                total += self.buffers[i].count;
            }
            return total;
        }

        /// Check if any buffer is approaching capacity.
        pub fn anyNearCapacity(self: *const Self, threshold: usize) bool {
            for (0..self.active_count) |i| {
                if (self.buffers[i].count >= threshold) {
                    return true;
                }
            }
            return false;
        }

        /// Convert command between buffer types (handles different max_data_size).
        fn convertCommand(cmd: PerSystemBuffer.CommandT) @TypeOf(cmd) {
            // Same type, just return as-is
            return cmd;
        }
    };
}

/// Create ConcurrentCommandBuffers type from WorldConfig.
///
/// Usage:
/// ```zig
/// const ConcBufs = ConcurrentCommandBuffersFromConfig(my_config);
/// var concurrent = ConcBufs.init();
/// ```
pub fn ConcurrentCommandBuffersFromConfig(comptime cfg: WorldConfig) type {
    return ConcurrentCommandBuffers(
        cfg.options.max_systems_per_stage,
        cfg.options.max_commands_per_frame,
        cfg.options.max_component_data_size,
    );
}

// ============================================================================
// Tests
// ============================================================================

test "ConcurrentCommandBuffers basic operations" {
    const ConcurrentBufs = ConcurrentCommandBuffers(4, 40, 64);
    var bufs = ConcurrentBufs.init();

    // Get first two buffers - buffers start empty
    const buf0 = bufs.getForSystem(0);
    const buf1 = bufs.getForSystem(1);
    try std.testing.expectEqual(@as(usize, 0), buf0.count);
    try std.testing.expectEqual(@as(usize, 0), buf1.count);

    // Add commands to different buffers
    const handle0 = EntityHandle.fromId(EntityId.init(1, 0));
    const handle1 = EntityHandle.fromId(EntityId.init(2, 0));

    try std.testing.expect(buf0.despawn(handle0));
    try std.testing.expect(buf1.despawn(handle1));

    try std.testing.expectEqual(@as(usize, 1), buf0.count);
    try std.testing.expectEqual(@as(usize, 1), buf1.count);

    // Clear all
    bufs.clearAll();
    try std.testing.expectEqual(@as(usize, 0), bufs.getForSystem(0).count);
    try std.testing.expectEqual(@as(usize, 0), bufs.getForSystem(1).count);
}

test "ConcurrentCommandBuffers merge operations" {
    // Use matching data sizes (64 bytes) between concurrent and target buffers
    const ConcurrentBufs = ConcurrentCommandBuffers(3, 30, 64);
    const SingleBuf = CommandBufferType(30, 64);

    var concurrent = ConcurrentBufs.init();
    var target = SingleBuf.init();

    // Add commands to each concurrent buffer
    const handle0 = EntityHandle.fromId(EntityId.init(10, 0));
    const handle1 = EntityHandle.fromId(EntityId.init(20, 0));
    const handle2 = EntityHandle.fromId(EntityId.init(30, 0));

    const buf0 = concurrent.getForSystem(0);
    const buf1 = concurrent.getForSystem(1);
    const buf2 = concurrent.getForSystem(2);

    _ = buf0.despawn(handle0);
    _ = buf0.spawnInArchetype(0);
    _ = buf1.despawn(handle1);
    _ = buf2.despawn(handle2);
    _ = buf2.custom(99, null);

    // Total: 5 commands across 3 buffers
    try std.testing.expectEqual(@as(usize, 2), concurrent.getForSystem(0).count);
    try std.testing.expectEqual(@as(usize, 1), concurrent.getForSystem(1).count);
    try std.testing.expectEqual(@as(usize, 2), concurrent.getForSystem(2).count);

    // Merge into target
    const merge_count = concurrent.mergeInto(&target);
    try std.testing.expectEqual(@as(usize, 5), merge_count);
    try std.testing.expectEqual(@as(usize, 5), target.count);

    // Verify command order (deterministic by system index)
    // Note: Use SingleBuf.CommandT enum for type-safe tag comparison
    const CmdTag = @typeInfo(SingleBuf.CommandT).@"union".tag_type.?;
    const cmds = target.getCommands();
    try std.testing.expectEqual(CmdTag.despawn, std.meta.activeTag(cmds[0])); // from buf 0
    try std.testing.expectEqual(CmdTag.spawn, std.meta.activeTag(cmds[1])); // from buf 0
    try std.testing.expectEqual(CmdTag.despawn, std.meta.activeTag(cmds[2])); // from buf 1
    try std.testing.expectEqual(CmdTag.despawn, std.meta.activeTag(cmds[3])); // from buf 2
    try std.testing.expectEqual(CmdTag.custom, std.meta.activeTag(cmds[4])); // from buf 2

    // Merge clears concurrent buffers
    try std.testing.expectEqual(@as(usize, 0), concurrent.getForSystem(0).count);
    try std.testing.expectEqual(@as(usize, 0), concurrent.getForSystem(1).count);
    try std.testing.expectEqual(@as(usize, 0), concurrent.getForSystem(2).count);
}
