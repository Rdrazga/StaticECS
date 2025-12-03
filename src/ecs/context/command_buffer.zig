//! # Command Buffer
//!
//! Purpose: Collect deferred entity operations during system execution.
//! Commands are batched and executed at stage boundaries to prevent
//! iterator invalidation and enable safe concurrent system execution.
//!
//! ## Key Types
//! - `CommandBufferType` - Generic command buffer with configurable capacity
//! - `CommandType` - Union of all command variants (spawn, despawn, etc.)
//! - `SpawnCommandType` - Deferred entity spawn with component data
//! - `AddComponentCommand` - Add component to existing entity
//! - `RemoveComponentCommand` - Remove component from entity
//!
//! ## Why Deferred Commands?
//!
//! During system execution, directly modifying entities would:
//! 1. Invalidate active iterators (undefined behavior)
//! 2. Race with parallel systems accessing the same data
//! 3. Make rollback on error impossible
//!
//! Command buffers solve this by:
//! - Collecting operations during system execution
//! - Applying them atomically at safe boundaries
//! - Enabling parallel systems to "write" without conflicts
//!
//! ## Usage
//! ```zig
//! fn combatSystem(ctx: *SystemContext) !void {
//!     var query = ctx.world.query(.{ .include = &.{Health} });
//!     while (query.next()) |result| {
//!         const health = result.get(Health);
//!         if (health.current <= 0) {
//!             // Don't despawn here - would invalidate iterator!
//!             // Instead, queue for later:
//!             _ = ctx.commands.despawn(result.entity);
//!         }
//!     }
//!     // Commands applied after system returns
//! }
//! ```
//!
//! ## Command Types
//! | Command | Description |
//! |---------|-------------|
//! | `spawn` | Create new entity with components |
//! | `despawn` | Destroy entity |
//! | `setComponent` | Update existing component |
//! | `addComponent` | Add component, change archetype |
//! | `removeComponent` | Remove component, change archetype |
//! | `custom` | User-defined deferred operation |
//!
//! ## Thread Safety
//! - Each system gets its own command buffer (no sharing)
//! - Buffers are flushed sequentially at stage end
//! - `ConcurrentCommandBuffers` provides per-thread isolation for parallel systems
//!
//! ## Related Modules
//! - `command_types.zig` - Command type definitions
//! - `concurrent_commands.zig` - Thread-safe buffer pool
//! - `../scheduler/scheduler_runtime.zig` - Command execution
//!
//! Tiger Style: All bounds come from config - max_commands and max_component_data_size.

const std = @import("std");

const command_types = @import("command_types.zig");
pub const CommandType = command_types.CommandType;
pub const SpawnCommandType = command_types.SpawnCommandType;
pub const SetComponentCommandType = command_types.SetComponentCommandType;
pub const AddComponentCommandType = command_types.AddComponentCommandType;
pub const RemoveComponentCommand = command_types.RemoveComponentCommand;
pub const CustomCommand = command_types.CustomCommand;
pub const DEFAULT_MAX_COMPONENT_DATA_SIZE = command_types.DEFAULT_MAX_COMPONENT_DATA_SIZE;
pub const componentTypeId = command_types.componentTypeId;

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
    const AddComponentCmd = AddComponentCommandType(max_data_size);

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

        /// Queue a spawn command for a specific archetype (without component data).
        /// Tiger Style: Prefer spawnWithData() for spawns with component values.
        pub fn spawnInArchetype(self: *Self, archetype_index: u16) bool {
            if (self.count >= max_commands) return false;
            self.commands[self.count] = .{
                .spawn = SpawnCmd{
                    .archetype_index = archetype_index,
                    .data_size = 0, // No component data
                },
            };
            self.count += 1;
            return true;
        }

        /// Queue a spawn command with component data for a specific archetype.
        /// Components are packed in declaration order using the archetype table's layout.
        /// Tiger Style: Use this for deferred spawns with component values.
        ///
        /// Parameters:
        ///   - archetype_index: Index of the target archetype (from world.archIndex())
        ///   - ArchTable: The ArchetypeTable type for the target archetype
        ///   - components: Tuple/struct of component values to set
        ///
        /// Returns: true if command was queued, false if buffer is full
        pub fn spawnWithData(
            self: *Self,
            archetype_index: u16,
            comptime ArchTable: type,
            components: anytype,
        ) bool {
            if (self.count >= max_commands) return false;

            const packed_size = ArchTable.packedComponentSize();

            // Validate at compile time that component data fits
            if (packed_size > max_data_size) {
                @compileError("Component data exceeds max_component_data_size from config");
            }

            var cmd = SpawnCmd{
                .archetype_index = archetype_index,
                .data_size = packed_size,
            };

            // Pack component data into command buffer
            _ = ArchTable.packComponents(components, &cmd.data);

            self.commands[self.count] = .{ .spawn = cmd };
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
        /// Tiger Style: Entity must already have this component; use addComponent for new components.
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

        /// Queue a deferred add component operation (stores component data inline).
        /// Tiger Style: Adds a new component to an entity, possibly triggering archetype migration.
        ///
        /// ## Migration Note
        /// Adding a component to an entity requires moving it to a different archetype
        /// that includes the new component. This is handled during flush by the world's
        /// archetype management logic.
        ///
        /// ## Parameters
        /// - `handle`: The entity to add the component to
        /// - `T`: The component type (comptime)
        /// - `value`: The component value to add
        ///
        /// ## Returns
        /// `true` if command was queued, `false` if buffer is full.
        ///
        /// ## TODO: Implementation Status
        /// The command is queued but archetype migration in flush is NOT yet implemented.
        /// Current behavior: Command stored but migration logic in world is needed.
        pub fn addComponent(self: *Self, handle: EntityHandle, comptime T: type, value: T) bool {
            if (@sizeOf(T) > max_data_size) {
                @compileError("Component type exceeds max_component_data_size from config");
            }

            if (self.count >= max_commands) return false;

            var cmd = AddComponentCmd{
                .entity = handle,
                .component_type = componentTypeId(T),
                .data = undefined,
                .size = @sizeOf(T),
            };
            // Copy component data into the fixed-size buffer
            const value_bytes = std.mem.asBytes(&value);
            @memcpy(cmd.data[0..@sizeOf(T)], value_bytes);

            self.commands[self.count] = CmdType{ .add_component = cmd };
            self.count += 1;
            return true;
        }

        /// Queue a deferred remove component operation.
        /// Tiger Style: Removes a component from an entity, possibly triggering archetype migration.
        ///
        /// ## Migration Note
        /// Removing a component from an entity requires moving it to a different archetype
        /// that excludes the component. The component data is dropped during migration.
        ///
        /// ## Parameters
        /// - `handle`: The entity to remove the component from
        /// - `T`: The component type to remove (comptime)
        ///
        /// ## Returns
        /// `true` if command was queued, `false` if buffer is full.
        ///
        /// ## TODO: Implementation Status
        /// The command is queued but archetype migration in flush is NOT yet implemented.
        /// Current behavior: Command stored but migration logic in world is needed.
        pub fn removeComponent(self: *Self, handle: EntityHandle, comptime T: type) bool {
            if (self.count >= max_commands) return false;

            self.commands[self.count] = CmdType{
                .remove_component = RemoveComponentCommand{
                    .entity = handle,
                    .component_type = componentTypeId(T),
                },
            };
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

test "CommandBuffer spawnWithData" {
    const archetype_table = @import("../world/archetype_table.zig");
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const TestTable = archetype_table.ArchetypeTable(&.{ Position, Velocity }, .dynamic, 0);

    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    // Queue a spawn with component data
    const result = buf.spawnWithData(0, TestTable, .{
        Position{ .x = 1.5, .y = 2.5 },
        Velocity{ .dx = 0.1, .dy = -0.1 },
    });
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(usize, 1), buf.count);

    const cmds = buf.getCommands();
    const Command = command_types.Command;
    try std.testing.expectEqual(Command.spawn, std.meta.activeTag(cmds[0]));

    const spawn_cmd = cmds[0].spawn;
    try std.testing.expectEqual(@as(u16, 0), spawn_cmd.archetype_index);
    try std.testing.expectEqual(TestTable.packedComponentSize(), spawn_cmd.data_size);

    // Verify data is packed correctly by copying bytes to aligned storage
    var pos: Position = undefined;
    @memcpy(std.mem.asBytes(&pos), spawn_cmd.data[0..@sizeOf(Position)]);
    try std.testing.expectEqual(@as(f32, 1.5), pos.x);
    try std.testing.expectEqual(@as(f32, 2.5), pos.y);

    const vel_offset = TestTable.componentOffset(1);
    var vel: Velocity = undefined;
    @memcpy(std.mem.asBytes(&vel), spawn_cmd.data[vel_offset .. vel_offset + @sizeOf(Velocity)]);
    try std.testing.expectEqual(@as(f32, 0.1), vel.dx);
    try std.testing.expectEqual(@as(f32, -0.1), vel.dy);
}

test "CommandBuffer spawnInArchetype sets data_size to zero" {
    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    try std.testing.expect(buf.spawnInArchetype(5));

    const cmds = buf.getCommands();
    const spawn_cmd = cmds[0].spawn;
    try std.testing.expectEqual(@as(u16, 5), spawn_cmd.archetype_index);
    try std.testing.expectEqual(@as(usize, 0), spawn_cmd.data_size);
}

test "CommandBuffer addComponent queues command with data" {
    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    const Health = struct { hp: i32, max_hp: i32 };
    const handle = EntityHandle.fromId(EntityId.init(42, 3));

    // Queue an add component command
    try std.testing.expect(buf.addComponent(handle, Health, .{ .hp = 100, .max_hp = 150 }));
    try std.testing.expectEqual(@as(usize, 1), buf.count);

    const cmds = buf.getCommands();
    const Command = command_types.Command;
    try std.testing.expectEqual(Command.add_component, std.meta.activeTag(cmds[0]));

    const add_cmd = cmds[0].add_component;
    try std.testing.expectEqual(handle.id.toU32(), add_cmd.entity.id.toU32());
    try std.testing.expectEqual(@as(usize, @sizeOf(Health)), add_cmd.size);
    try std.testing.expectEqual(componentTypeId(Health), add_cmd.component_type);

    // Verify data is stored correctly
    var health: Health = undefined;
    @memcpy(std.mem.asBytes(&health), add_cmd.data[0..@sizeOf(Health)]);
    try std.testing.expectEqual(@as(i32, 100), health.hp);
    try std.testing.expectEqual(@as(i32, 150), health.max_hp);
}

test "CommandBuffer removeComponent queues command" {
    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    const Tag = struct { id: u32 };
    const handle = EntityHandle.fromId(EntityId.init(99, 7));

    // Queue a remove component command
    try std.testing.expect(buf.removeComponent(handle, Tag));
    try std.testing.expectEqual(@as(usize, 1), buf.count);

    const cmds = buf.getCommands();
    const Command = command_types.Command;
    try std.testing.expectEqual(Command.remove_component, std.meta.activeTag(cmds[0]));

    const remove_cmd = cmds[0].remove_component;
    try std.testing.expectEqual(handle.id.toU32(), remove_cmd.entity.id.toU32());
    try std.testing.expectEqual(componentTypeId(Tag), remove_cmd.component_type);
}

test "CommandBuffer addComponent overflow protection" {
    const CmdBuf = CommandBuffer(1);
    var buf = CmdBuf.init();

    const Component = struct { value: f32 };
    const handle = EntityHandle.fromId(EntityId.init(1, 0));

    try std.testing.expect(buf.addComponent(handle, Component, .{ .value = 1.0 }));
    try std.testing.expect(!buf.addComponent(handle, Component, .{ .value = 2.0 })); // Should fail - full
    try std.testing.expect(buf.isFull());
}

test "CommandBuffer removeComponent overflow protection" {
    const CmdBuf = CommandBuffer(1);
    var buf = CmdBuf.init();

    const Component = struct { value: f32 };
    const handle = EntityHandle.fromId(EntityId.init(1, 0));

    try std.testing.expect(buf.removeComponent(handle, Component));
    try std.testing.expect(!buf.removeComponent(handle, Component)); // Should fail - full
    try std.testing.expect(buf.isFull());
}

test "CommandBuffer mixed add/remove commands" {
    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const handle1 = EntityHandle.fromId(EntityId.init(1, 0));
    const handle2 = EntityHandle.fromId(EntityId.init(2, 0));

    // Queue a mix of commands
    try std.testing.expect(buf.addComponent(handle1, Position, .{ .x = 10.0, .y = 20.0 }));
    try std.testing.expect(buf.removeComponent(handle2, Velocity));
    try std.testing.expect(buf.addComponent(handle2, Position, .{ .x = 30.0, .y = 40.0 }));
    try std.testing.expect(buf.despawn(handle1));

    try std.testing.expectEqual(@as(usize, 4), buf.count);

    const cmds = buf.getCommands();
    const Command = command_types.Command;

    try std.testing.expectEqual(Command.add_component, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(Command.remove_component, std.meta.activeTag(cmds[1]));
    try std.testing.expectEqual(Command.add_component, std.meta.activeTag(cmds[2]));
    try std.testing.expectEqual(Command.despawn, std.meta.activeTag(cmds[3]));
}
