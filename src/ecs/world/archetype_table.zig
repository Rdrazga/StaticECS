//! Dense Archetype Storage
//!
//! This module implements Structure-of-Arrays (SoA) storage for entities
//! with a fixed component set. Each archetype has a table that stores
//! component data in dense, cache-friendly arrays.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const entity = @import("entity.zig");
const EntityId = entity.EntityId;
const EntityHandle = entity.EntityHandle;

/// Error types for archetype operations.
pub const ArchetypeError = error{
    /// The archetype table has reached capacity.
    CapacityExhausted,
    /// Entity not found in this archetype.
    EntityNotFound,
    /// Component type not in this archetype.
    ComponentNotFound,
    /// Out of memory during allocation.
    OutOfMemory,
};

/// Generate an archetype table type for a specific set of component types.
/// This uses comptime to create a specialized SoA storage layout.
pub fn ArchetypeTable(comptime types: []const type) type {
    return struct {
        const Self = @This();

        /// The component types stored in this archetype.
        pub const component_types = types;

        /// Number of component types in this archetype.
        pub const component_count = types.len;

        /// Allocator used for all dynamic arrays.
        allocator: Allocator,

        /// Entity IDs stored in this archetype (parallel to component arrays).
        entity_ids: std.ArrayList(EntityId),

        /// Component storage arrays - one ArrayList per component type.
        /// Stored as aligned byte arrays to support generic access.
        component_storage: ComponentStorage,

        /// Archetype name for debugging.
        name: []const u8,

        /// Type for storing component arrays as a tuple of ArrayLists.
        const ComponentStorage = if (component_count == 0)
            struct {}
        else
            @Tuple(blk: {
                var arr: [component_count]type = undefined;
                for (component_types, 0..) |T, i| {
                    arr[i] = std.ArrayList(T);
                }
                break :blk &arr;
            });

        /// Initialize an empty archetype table.
        pub fn init(allocator: Allocator, name: []const u8) Self {
            var storage: ComponentStorage = undefined;
            inline for (0..component_count) |i| {
                storage[i] = .empty;
            }

            return .{
                .allocator = allocator,
                .entity_ids = .empty,
                .component_storage = storage,
                .name = name,
            };
        }

        /// Initialize an archetype table with pre-allocated capacity.
        /// Tiger Style: Use this for fixed allocation patterns.
        pub fn initWithCapacity(allocator: Allocator, name: []const u8, initial_capacity: u32) !Self {
            var self = init(allocator, name);

            if (initial_capacity > 0) {
                // Pre-allocate entity_ids array
                try self.entity_ids.ensureTotalCapacity(allocator, initial_capacity);

                // Pre-allocate all component arrays using tuple indexing
                inline for (0..component_count) |i| {
                    try self.component_storage[i].ensureTotalCapacity(allocator, initial_capacity);
                }
            }

            return self;
        }

        /// Returns the current capacity of the archetype table.
        pub fn capacity(self: *const Self) usize {
            return self.entity_ids.capacity;
        }

        /// Deinitialize and free all storage.
        pub fn deinit(self: *Self) void {
            self.entity_ids.deinit(self.allocator);
            inline for (0..component_count) |i| {
                self.component_storage[i].deinit(self.allocator);
            }
        }

        /// Get the number of entities in this archetype.
        pub fn len(self: *const Self) usize {
            return self.entity_ids.items.len;
        }

        /// Check if the archetype is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        /// Add an entity with its component values.
        /// Returns the row index where the entity was stored.
        pub fn addEntity(self: *Self, entity_id: EntityId, components: anytype) !u32 {
            const Components = @TypeOf(components);
            const row = self.entity_ids.items.len;

            // Ensure capacity for all arrays
            try self.entity_ids.append(self.allocator, entity_id);
            errdefer _ = self.entity_ids.pop();

            // Add each component value using tuple indexing
            inline for (0..component_count) |i| {
                const T = component_types[i];
                const array = &self.component_storage[i];

                // Find matching field in components tuple/struct
                const value = inline for (std.meta.fields(Components)) |field| {
                    if (field.type == T) {
                        break @field(components, field.name);
                    }
                } else {
                    // Component not provided - use default
                    if (@hasDecl(T, "default")) {
                        break T.default;
                    } else {
                        break std.mem.zeroes(T);
                    }
                };

                try array.append(self.allocator, value);
            }

            return @intCast(row);
        }

        /// Remove an entity by row index. Uses swap-remove for O(1) performance.
        /// Returns the entity ID that was moved into this slot (if any).
        pub fn removeEntityByRow(self: *Self, row: u32) ?EntityId {
            if (row >= self.entity_ids.items.len) return null;

            // Swap-remove the entity ID
            _ = self.entity_ids.swapRemove(row);

            // Swap-remove all component arrays using tuple indexing
            inline for (0..component_count) |i| {
                _ = self.component_storage[i].swapRemove(row);
            }

            // Return the entity that was moved into this slot
            if (row < self.entity_ids.items.len) {
                return self.entity_ids.items[row];
            }
            return null;
        }

        /// Get a pointer to a component for an entity at a given row.
        pub fn getComponent(self: *Self, comptime T: type, row: u32) ?*T {
            inline for (0..component_count) |i| {
                if (component_types[i] == T) {
                    if (row < self.component_storage[i].items.len) {
                        return &self.component_storage[i].items[row];
                    }
                    return null;
                }
            }
            return null;
        }

        /// Get a const pointer to a component for an entity at a given row.
        pub fn getComponentConst(self: *const Self, comptime T: type, row: u32) ?*const T {
            inline for (0..component_count) |i| {
                if (component_types[i] == T) {
                    if (row < self.component_storage[i].items.len) {
                        return &self.component_storage[i].items[row];
                    }
                    return null;
                }
            }
            return null;
        }

        /// Set a component value for an entity at a given row.
        pub fn setComponent(self: *Self, comptime T: type, row: u32, value: T) bool {
            if (self.getComponent(T, row)) |ptr| {
                ptr.* = value;
                return true;
            }
            return false;
        }

        /// Check if this archetype contains a component type.
        pub fn hasComponent(comptime T: type) bool {
            inline for (component_types) |ct| {
                if (ct == T) return true;
            }
            return false;
        }

        /// Get the entity ID at a given row.
        pub fn getEntityId(self: *const Self, row: u32) ?EntityId {
            if (row < self.entity_ids.items.len) {
                return self.entity_ids.items[row];
            }
            return null;
        }

        /// Find the row index for a given entity ID.
        pub fn findEntity(self: *const Self, entity_id: EntityId) ?u32 {
            for (self.entity_ids.items, 0..) |id, row| {
                if (id.toU32() == entity_id.toU32()) {
                    return @intCast(row);
                }
            }
            return null;
        }

        /// Get a slice of all component values for iteration.
        pub fn getComponentSlice(self: *Self, comptime T: type) ?[]T {
            inline for (0..component_count) |i| {
                if (component_types[i] == T) {
                    return self.component_storage[i].items;
                }
            }
            return null;
        }

        /// Get a const slice of all component values for iteration.
        pub fn getComponentSliceConst(self: *const Self, comptime T: type) ?[]const T {
            inline for (0..component_count) |i| {
                if (component_types[i] == T) {
                    return self.component_storage[i].items;
                }
            }
            return null;
        }

        /// Get a slice of all entity IDs.
        pub fn getEntitySlice(self: *const Self) []const EntityId {
            return self.entity_ids.items;
        }

        /// Reserve capacity for a number of entities.
        pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
            try self.entity_ids.ensureTotalCapacity(new_capacity);
            inline for (0..component_count) |i| {
                try self.component_storage[i].ensureTotalCapacity(new_capacity);
            }
        }

        /// Clear all entities but retain allocated memory.
        pub fn clear(self: *Self) void {
            self.entity_ids.clearRetainingCapacity();
            inline for (0..component_count) |i| {
                self.component_storage[i].clearRetainingCapacity();
            }
        }
    };
}

/// Archetype index manager for multi-archetype worlds.
/// Maps component type sets to archetype indices.
pub fn ArchetypeIndex(comptime archetypes: []const []const type) type {
    return struct {
        const Self = @This();
        pub const archetype_count = archetypes.len;

        /// Get the archetype index for a component type set.
        /// Returns null if no matching archetype exists.
        pub fn findArchetype(comptime components: []const type) ?u16 {
            inline for (archetypes, 0..) |arch_components, i| {
                if (componentSetsEqual(components, arch_components)) {
                    return @intCast(i);
                }
            }
            return null;
        }

        /// Check if two component sets are equal (order-independent).
        fn componentSetsEqual(comptime a: []const type, comptime b: []const type) bool {
            if (a.len != b.len) return false;
            inline for (a) |ta| {
                var found = false;
                inline for (b) |tb| {
                    if (ta == tb) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ArchetypeTable basic operations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const Table = ArchetypeTable(&.{ Position, Velocity });
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 0), table.len());
    try std.testing.expect(table.isEmpty());

    // Add entity
    const e1 = EntityId.init(0, 0);
    const row = try table.addEntity(e1, .{
        Position{ .x = 1.0, .y = 2.0 },
        Velocity{ .dx = 0.5, .dy = -0.5 },
    });

    try std.testing.expectEqual(@as(u32, 0), row);
    try std.testing.expectEqual(@as(usize, 1), table.len());

    // Get components
    const pos = table.getComponent(Position, 0).?;
    try std.testing.expectEqual(@as(f32, 1.0), pos.x);
    try std.testing.expectEqual(@as(f32, 2.0), pos.y);

    const vel = table.getComponent(Velocity, 0).?;
    try std.testing.expectEqual(@as(f32, 0.5), vel.dx);

    // Modify component
    pos.x = 10.0;
    try std.testing.expectEqual(@as(f32, 10.0), table.getComponent(Position, 0).?.x);
}

test "ArchetypeTable swap remove" {
    const Value = struct { v: u32 };
    const Table = ArchetypeTable(&.{Value});
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    // Add 3 entities
    const e1 = EntityId.init(0, 0);
    const e2 = EntityId.init(1, 0);
    const e3 = EntityId.init(2, 0);

    _ = try table.addEntity(e1, .{Value{ .v = 100 }});
    _ = try table.addEntity(e2, .{Value{ .v = 200 }});
    _ = try table.addEntity(e3, .{Value{ .v = 300 }});

    try std.testing.expectEqual(@as(usize, 3), table.len());

    // Remove middle entity (row 1)
    const moved = table.removeEntityByRow(1);

    // e3 should have been moved to row 1
    try std.testing.expectEqual(e3.toU32(), moved.?.toU32());
    try std.testing.expectEqual(@as(usize, 2), table.len());

    // Row 1 should now have e3's value
    try std.testing.expectEqual(@as(u32, 300), table.getComponent(Value, 1).?.v);
}

test "ArchetypeTable hasComponent" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    const Table = ArchetypeTable(&.{ A, B });

    try std.testing.expect(Table.hasComponent(A));
    try std.testing.expect(Table.hasComponent(B));
    try std.testing.expect(!Table.hasComponent(C));
}

test "ArchetypeIndex findArchetype" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    const Index = ArchetypeIndex(&.{
        &.{A},
        &.{ A, B },
        &.{ A, B, C },
    });

    try std.testing.expectEqual(@as(?u16, 0), Index.findArchetype(&.{A}));
    try std.testing.expectEqual(@as(?u16, 1), Index.findArchetype(&.{ A, B }));
    try std.testing.expectEqual(@as(?u16, 1), Index.findArchetype(&.{ B, A })); // Order independent
    try std.testing.expectEqual(@as(?u16, null), Index.findArchetype(&.{C}));
}
