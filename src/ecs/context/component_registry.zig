//! Component Registry - Runtime Type Dispatch for Deferred Commands
//!
//! This module provides compile-time generated dispatch tables for mapping
//! component type IDs (hashes) to typed setter functions. This enables
//! deferred set_component commands to work with type-erased data.
//!
//! Tiger Style: All bounds come from config - component count determines table size.

const std = @import("std");

const command_types = @import("command_types.zig");
const componentTypeId = command_types.componentTypeId;

const entity_mod = @import("../world/entity.zig");
const EntityHandle = entity_mod.EntityHandle;

// ============================================================================
// Setter Function Signature
// ============================================================================

/// SetterFn signature for component setters.
/// Returns true if component was set, false if entity dead or component not found.
pub const SetterFn = *const fn (*anyopaque, EntityHandle, [*]const u8, usize) bool;

// ============================================================================
// Component Registry Generator
// ============================================================================

/// Generate a component registry type for dispatching deferred setComponent operations.
/// The registry maps component_id (u32 hash) to typed setter functions.
///
/// Parameters:
///   - cfg: WorldConfig containing component type information
///   - WorldType: The World type to operate on
///
/// Tiger Style: Component count from config determines table size.
pub fn ComponentRegistry(comptime cfg: anytype, comptime WorldType: type) type {
    const component_types = cfg.components.types;
    const component_count = component_types.len;

    // Generate sorted (id, index) pairs at comptime for binary search
    const IdIndexPair = struct {
        id: u32,
        index: usize,
    };

    const sorted_pairs = blk: {
        var pairs: [component_count]IdIndexPair = undefined;

        // Build pairs
        for (component_types, 0..) |T, i| {
            pairs[i] = .{
                .id = componentTypeId(T),
                .index = i,
            };
        }

        // Sort by id (simple insertion sort - small array at comptime)
        for (1..component_count) |i| {
            const key = pairs[i];
            var j: usize = i;
            while (j > 0 and pairs[j - 1].id > key.id) : (j -= 1) {
                pairs[j] = pairs[j - 1];
            }
            pairs[j] = key;
        }

        break :blk pairs;
    };

    // Extract sorted IDs for binary search
    const sorted_ids = blk: {
        var ids: [component_count]u32 = undefined;
        for (sorted_pairs, 0..) |pair, i| {
            ids[i] = pair.id;
        }
        break :blk ids;
    };

    return struct {
        // Generate typed setter for a specific component type index
        fn MakeSetterForTypeIndex(comptime type_index: usize) type {
            return struct {
                fn setter(world_ptr: *anyopaque, handle: EntityHandle, data: [*]const u8, size: usize) bool {
                    const world: *WorldType = @ptrCast(@alignCast(world_ptr));
                    const T = component_types[type_index];

                    // Validate size matches expected
                    if (size != @sizeOf(T)) {
                        // Size mismatch - data corruption would occur
                        if (@import("builtin").mode == .Debug) {
                            std.debug.print(
                                "set_component: size mismatch for {s} (expected {}, got {})\n",
                                .{ @typeName(T), @sizeOf(T), size },
                            );
                        }
                        return false;
                    }

                    // Copy bytes to aligned storage
                    var value: T = undefined;
                    @memcpy(std.mem.asBytes(&value), data[0..size]);

                    // Use World's setComponent
                    return world.setComponent(handle, T, value);
                }
            };
        }

        // Pre-build setter functions array at comptime (sorted order matches sorted_ids)
        const setter_fns = blk: {
            var fns: [component_count]SetterFn = undefined;
            for (sorted_pairs, 0..) |pair, i| {
                fns[i] = MakeSetterForTypeIndex(pair.index).setter;
            }
            break :blk fns;
        };

        const Self = @This();
        /// Number of registered component types.
        pub const count = component_count;

        /// Sorted component IDs for binary search.
        pub const component_ids = sorted_ids;

        /// Lookup a setter function by component_id hash.
        /// Returns null if component_id is not registered.
        pub fn lookup(component_id: u32) ?SetterFn {
            // Binary search for component_id
            const index = binarySearch(component_id) orelse return null;

            // Return pre-built setter function from table
            return setter_fns[index];
        }

        /// Binary search for component_id in sorted array.
        fn binarySearch(target: u32) ?usize {
            if (component_count == 0) return null;

            var left: usize = 0;
            var right: usize = component_count;

            while (left < right) {
                const mid = left + (right - left) / 2;
                const mid_val = sorted_ids[mid];

                if (mid_val == target) {
                    return mid;
                } else if (mid_val < target) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }

            return null;
        }

        /// Execute a set_component command using the registry.
        /// Returns true if component was set, false otherwise.
        pub fn executeSetComponent(
            world: *WorldType,
            handle: EntityHandle,
            component_id: u32,
            data: [*]const u8,
            size: usize,
        ) bool {
            const setter = lookup(component_id) orelse {
                // Unknown component_id - type was removed or changed
                if (@import("builtin").mode == .Debug) {
                    std.debug.print("set_component: unknown component_id {}\n", .{component_id});
                }
                return false;
            };

            // Cast world pointer to anyopaque for type-erased setter function
            return setter(@ptrCast(world), handle, data, size);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ComponentRegistry lookup and execute" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { value: u32 };

    // Mock minimal config
    const MockConfig = struct {
        pub const components = struct {
            pub const types = &[_]type{ Position, Velocity, Health };
        };
        pub const archetypes = struct {
            pub const archetypes = &[_]struct {
                name: [:0]const u8,
                components: []const type,
            }{
                .{ .name = "pos_vel", .components = &[_]type{ Position, Velocity } },
            };
        };
    };

    // Mock World type with setComponent
    const MockWorld = struct {
        position_set: bool = false,
        velocity_set: bool = false,
        health_set: bool = false,
        last_pos: Position = .{ .x = 0, .y = 0 },

        pub fn setComponent(self: *@This(), handle: EntityHandle, comptime T: type, value: T) bool {
            _ = handle;
            if (T == Position) {
                self.position_set = true;
                self.last_pos = value;
                return true;
            } else if (T == Velocity) {
                self.velocity_set = true;
                return true;
            } else if (T == Health) {
                self.health_set = true;
                return true;
            }
            return false;
        }
    };

    const Registry = ComponentRegistry(MockConfig, MockWorld);

    // Test count
    try std.testing.expectEqual(@as(usize, 3), Registry.count);

    // Test lookup finds registered types
    try std.testing.expect(Registry.lookup(componentTypeId(Position)) != null);
    try std.testing.expect(Registry.lookup(componentTypeId(Velocity)) != null);
    try std.testing.expect(Registry.lookup(componentTypeId(Health)) != null);

    // Test lookup returns null for unknown type
    const UnknownType = struct { unknown: bool };
    try std.testing.expect(Registry.lookup(componentTypeId(UnknownType)) == null);

    // Test execute
    var world = MockWorld{};
    const handle = EntityHandle.fromId(entity_mod.EntityId.init(0, 0));

    // Set Position via registry
    const pos = Position{ .x = 10.0, .y = 20.0 };
    const pos_bytes = std.mem.asBytes(&pos);
    const success = Registry.executeSetComponent(
        &world,
        handle,
        componentTypeId(Position),
        pos_bytes.ptr,
        @sizeOf(Position),
    );

    try std.testing.expect(success);
    try std.testing.expect(world.position_set);
    try std.testing.expectEqual(@as(f32, 10.0), world.last_pos.x);
    try std.testing.expectEqual(@as(f32, 20.0), world.last_pos.y);
}

test "ComponentRegistry binary search" {
    const A = struct { a: u8 };
    const B = struct { b: u16 };
    const C = struct { c: u32 };

    const MockConfig = struct {
        pub const components = struct {
            pub const types = &[_]type{ A, B, C };
        };
    };

    const MockWorld = struct {
        pub fn setComponent(_: *@This(), _: EntityHandle, comptime _: type, _: anytype) bool {
            return true;
        }
    };

    const Registry = ComponentRegistry(MockConfig, MockWorld);

    // All registered types should be found
    try std.testing.expect(Registry.lookup(componentTypeId(A)) != null);
    try std.testing.expect(Registry.lookup(componentTypeId(B)) != null);
    try std.testing.expect(Registry.lookup(componentTypeId(C)) != null);

    // IDs are sorted, verify binary search works
    for (Registry.component_ids, 0..) |id, i| {
        if (i > 0) {
            try std.testing.expect(Registry.component_ids[i - 1] < id);
        }
    }
}

test "ComponentRegistry size validation" {
    const SmallComponent = struct { x: u8 };

    const MockConfig = struct {
        pub const components = struct {
            pub const types = &[_]type{SmallComponent};
        };
    };

    const MockWorld = struct {
        set_called: bool = false,

        pub fn setComponent(self: *@This(), _: EntityHandle, comptime _: type, _: anytype) bool {
            self.set_called = true;
            return true;
        }
    };

    const Registry = ComponentRegistry(MockConfig, MockWorld);
    var world = MockWorld{};
    const handle = EntityHandle.fromId(entity_mod.EntityId.init(0, 0));

    // Wrong size should fail
    var wrong_data: [100]u8 = undefined;
    const wrong_result = Registry.executeSetComponent(
        &world,
        handle,
        componentTypeId(SmallComponent),
        &wrong_data,
        100, // Wrong size
    );

    try std.testing.expect(!wrong_result);
    try std.testing.expect(!world.set_called);

    // Correct size should succeed
    const correct = SmallComponent{ .x = 42 };
    const correct_bytes = std.mem.asBytes(&correct);
    const correct_result = Registry.executeSetComponent(
        &world,
        handle,
        componentTypeId(SmallComponent),
        correct_bytes.ptr,
        @sizeOf(SmallComponent),
    );

    try std.testing.expect(correct_result);
    try std.testing.expect(world.set_called);
}
