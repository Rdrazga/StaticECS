//! Command Buffer - Deferred Operation Collection
//!
//! This module provides command buffers for collecting deferred operations
//! during system execution. Commands are executed at the end of each stage/phase
//! to avoid iterator invalidation.
//!
//! Tiger Style: All bounds come from config - max_commands and max_component_data_size.

const std = @import("std");

const command_types = @import("command_types.zig");
pub const CommandType = command_types.CommandType;
pub const SpawnCommandType = command_types.SpawnCommandType;
pub const SetComponentCommandType = command_types.SetComponentCommandType;
pub const CustomCommand = command_types.CustomCommand;
pub const DEFAULT_MAX_COMPONENT_DATA_SIZE = command_types.DEFAULT_MAX_COMPONENT_DATA_SIZE;
const componentTypeId = command_types.componentTypeId;

const entity_mod = @import("../world/entity.zig");
const EntityHandle = entity_mod.EntityHandle;
const EntityId = entity_mod.EntityId;

// ============================================================================
// Command Buffer
// ============================================================================

/// Command buffer for collecting deferred operations during system execution.
/// Commands are executed at the end of each stage/phase to avoid iterator invalidation.
/// Tiger Style: All bounds come from config - max_commands and max_component_data_size.
pub fn CommandBufferType(comptime max_commands: usize, comptime max_data_size: u32) type {
    const CmdType = CommandType(max_data_size);
    const SpawnCmd = SpawnCommandType(max_data_size);
    const SetComponentCmd = SetComponentCommandType(max_data_size);

    return struct {
        const Self = @This();

        /// Type of commands stored in this buffer.
        pub const CommandT = CmdType;
        /// Maximum commands this buffer can hold.
        pub const max_command_count = max_commands;
        /// Maximum inline data size for commands.
        pub const max_component_data = max_data_size;

        commands: [max_commands]CmdType = undefined,
        count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn clear(self: *Self) void {
            self.count = 0;
        }

        /// Queue a despawn command.
        pub fn despawn(self: *Self, handle: EntityHandle) bool {
            if (self.count >= max_commands) return false;
            self.commands[self.count] = .{ .despawn = handle };
            self.count += 1;
            return true;
        }

        /// Queue a spawn command for a specific archetype.
        pub fn spawnInArchetype(self: *Self, archetype_index: u16) bool {
            if (self.count >= max_commands) return false;
            self.commands[self.count] = .{
                .spawn = SpawnCmd{
                    .archetype_index = archetype_index,
                },
            };
            self.count += 1;
            return true;
        }

        /// Queue a custom command.
        pub fn custom(self: *Self, id: u32, data: ?*anyopaque) bool {
            if (self.count >= max_commands) return false;
            self.commands[self.count] = .{
                .custom = .{
                    .id = id,
                    .data = data,
                },
            };
            self.count += 1;
            return true;
        }

        /// Queue a deferred component set operation (stores component data inline).
        pub fn setComponent(self: *Self, handle: EntityHandle, comptime T: type, value: T) bool {
            if (@sizeOf(T) > max_data_size) {
                @compileError("Component type exceeds max_component_data_size from config");
            }

            if (self.count >= max_commands) return false;

            var cmd = SetComponentCmd{
                .entity = handle,
                .component_id = componentTypeId(T),
                .data = undefined,
                .size = @sizeOf(T),
            };
            // Copy component data into the fixed-size buffer
            const value_bytes = std.mem.asBytes(&value);
            @memcpy(cmd.data[0..@sizeOf(T)], value_bytes);

            self.commands[self.count] = CmdType{ .set_component = cmd };
            self.count += 1;
            return true;
        }

        /// Get all queued commands.
        pub fn getCommands(self: *const Self) []const CmdType {
            return self.commands[0..self.count];
        }

        /// Check if buffer is full.
        pub fn isFull(self: *const Self) bool {
            return self.count >= max_commands;
        }

        /// Check if buffer has commands.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }
    };
}

/// Legacy CommandBuffer with default component data size.
/// Tiger Style: Prefer CommandBufferType for explicit config-based sizing.
pub fn CommandBuffer(comptime max_commands: usize) type {
    return CommandBufferType(max_commands, DEFAULT_MAX_COMPONENT_DATA_SIZE);
}

// ============================================================================
// Tests
// ============================================================================

test "CommandBuffer basic operations" {
    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    try std.testing.expect(buf.isEmpty());
    try std.testing.expect(!buf.isFull());

    const handle = EntityHandle.fromId(EntityId.init(42, 7));
    try std.testing.expect(buf.despawn(handle));
    try std.testing.expect(!buf.isEmpty());

    try std.testing.expect(buf.spawnInArchetype(0));
    try std.testing.expect(buf.custom(99, null));

    try std.testing.expectEqual(@as(usize, 3), buf.count);

    const cmds = buf.getCommands();
    try std.testing.expectEqual(@as(usize, 3), cmds.len);

    const Command = command_types.Command;
    try std.testing.expectEqual(Command.despawn, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(Command.spawn, std.meta.activeTag(cmds[1]));
    try std.testing.expectEqual(Command.custom, std.meta.activeTag(cmds[2]));

    buf.clear();
    try std.testing.expect(buf.isEmpty());
}

test "CommandBuffer overflow protection" {
    const CmdBuf = CommandBuffer(2);
    var buf = CmdBuf.init();

    const handle = EntityHandle.fromId(EntityId.init(1, 0));
    try std.testing.expect(buf.despawn(handle));
    try std.testing.expect(buf.despawn(handle));
    try std.testing.expect(!buf.despawn(handle)); // Should fail - full
    try std.testing.expect(buf.isFull());
}

test "CommandBuffer setComponent" {
    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    const TestComponent = struct { x: i32, y: i32 };
    const handle = EntityHandle.fromId(EntityId.init(5, 1));

    try std.testing.expect(buf.setComponent(handle, TestComponent, .{ .x = 10, .y = 20 }));
    try std.testing.expectEqual(@as(usize, 1), buf.count);

    const cmds = buf.getCommands();
    const Command = command_types.Command;
    try std.testing.expectEqual(Command.set_component, std.meta.activeTag(cmds[0]));

    const set_cmd = cmds[0].set_component;
    try std.testing.expectEqual(handle.id.toU32(), set_cmd.entity.id.toU32());
    try std.testing.expectEqual(@as(usize, @sizeOf(TestComponent)), set_cmd.size);
}
