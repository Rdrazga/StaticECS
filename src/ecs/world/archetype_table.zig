//! # Archetype Table
//!
//! Purpose: Structure-of-Arrays (SoA) storage for entities sharing a component set.
//! Provides cache-friendly, dense storage optimized for iteration performance.
//!
//! ## Key Types
//! - `ArchetypeTable` - Generic table type parameterized by component types
//! - `ArchetypeError` - Error types (CapacityExhausted, EntityNotFound, etc.)
//!
//! ## Memory Layout
//! ```
//! Archetype "dynamic" (Position, Velocity):
//!
//! entity_ids:  [ E0 | E1 | E2 | E3 | ... ]   // Dense entity array
//! positions:   [ P0 | P1 | P2 | P3 | ... ]   // Component array 1
//! velocities:  [ V0 | V1 | V2 | V3 | ... ]   // Component array 2
//!
//! Row 0: E0 has P0, V0
//! Row 1: E1 has P1, V1
//! ...
//! ```
//!
//! ## Usage
//! ```zig
//! const Table = ArchetypeTable(&.{Position, Velocity}, .fixed, 1000);
//! var table = Table.init(allocator, "dynamic");
//! defer table.deinit();
//!
//! // Add entity with components
//! const row = try table.addEntity(entity_id, .{
//!     Position{ .x = 0, .y = 0, .z = 0 },
//!     Velocity{ .x = 1, .y = 0, .z = 0 },
//! });
//!
//! // Access components by row
//! const pos = table.getComponent(Position, row);
//! pos.x += vel.x * dt;
//! ```
//!
//! ## Capacity Modes (Tiger Style)
//! | Mode | Behavior | Allocation | Tiger Style |
//! |------|----------|------------|-------------|
//! | `.fixed` | Pre-allocated, fail on overflow | Init only | ✅ Compliant |
//! | `.dynamic` | ArrayList growth | Runtime | ⚠️ Not recommended |
//!
//! ## Performance Characteristics
//! - O(1) component access by row index
//! - O(n) entity lookup (linear scan)
//! - Cache-friendly iteration (sequential memory access)
//! - Swap-remove for O(1) entity deletion
//!
//! ## Thread Safety
//! - NOT thread-safe for concurrent modification
//! - Safe for concurrent read-only access
//! - Use command buffers for deferred modifications in parallel systems
//!
//! ## Related Modules
//! - `entity.zig` - Entity ID and handle types
//! - `query.zig` - Query iteration over archetype tables
//! - `../world.zig` - World manages multiple archetype tables

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const entity = @import("entity.zig");
const EntityId = entity.EntityId;
const EntityHandle = entity.EntityHandle;

const config_mod = @import("../config.zig");
const CapacityMode = config_mod.CapacityMode;

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
///
/// Parameters:
/// - `types`: Component types stored in this archetype
/// - `capacity_mode`: Storage allocation strategy (.fixed or .dynamic)
/// - `max_capacity`: Maximum entities when using .fixed mode (ignored for .dynamic)
pub fn ArchetypeTable(
    comptime types: []const type,
    comptime capacity_mode: CapacityMode,
    comptime max_capacity: u32,
) type {
    return struct {
        const Self = @This();

        /// The component types stored in this archetype.
        pub const component_types = types;

        /// Number of component types in this archetype.
        pub const component_count = types.len;

        /// The capacity mode for this archetype table.
        pub const mode = capacity_mode;

        /// Maximum capacity (only meaningful for fixed mode).
        pub const fixed_capacity = max_capacity;

        /// Allocator used for arrays.
        allocator: Allocator,

        /// Entity IDs stored in this archetype (parallel to component arrays).
        entity_ids: EntityStorage,

        /// Component storage arrays - one per component type.
        component_storage: ComponentStorage,

        /// Current entity count (for fixed mode).
        /// In dynamic mode, this equals entity_ids.items.len.
        count: u32,

        /// Archetype name for debugging.
        name: []const u8,

        /// Entity storage type depends on capacity mode.
        const EntityStorage = switch (capacity_mode) {
            .fixed => []EntityId, // Slice backed by allocated array
            .dynamic => std.ArrayList(EntityId),
        };

        /// Component storage type - tuple of arrays or ArrayLists.
        const ComponentStorage = if (component_count == 0)
            struct {}
        else switch (capacity_mode) {
            .fixed => @Tuple(blk: {
                var arr: [component_count]type = undefined;
                for (component_types, 0..) |T, i| {
                    arr[i] = []T; // Slice type
                }
                break :blk &arr;
            }),
            .dynamic => @Tuple(blk: {
                var arr: [component_count]type = undefined;
                for (component_types, 0..) |T, i| {
                    arr[i] = std.ArrayList(T);
                }
                break :blk &arr;
            }),
        };

        /// Initialize an empty archetype table.
        /// For fixed mode, this allocates the full capacity upfront.
        pub fn init(allocator: Allocator, name: []const u8) Self {
            return switch (capacity_mode) {
                .fixed => initFixed(allocator, name),
                .dynamic => initDynamic(allocator, name),
            };
        }

        /// Initialize fixed-capacity storage (allocates full capacity).
        fn initFixed(allocator: Allocator, name: []const u8) Self {
            // Allocate entity array
            const entity_mem = allocator.alloc(EntityId, max_capacity) catch
                @panic("Failed to allocate fixed archetype storage - out of memory");

            // Allocate component arrays
            var comp_storage: ComponentStorage = undefined;
            inline for (0..component_count) |i| {
                const T = component_types[i];
                comp_storage[i] = allocator.alloc(T, max_capacity) catch
                    @panic("Failed to allocate fixed component storage - out of memory");
            }

            return .{
                .allocator = allocator,
                .entity_ids = entity_mem,
                .component_storage = comp_storage,
                .count = 0,
                .name = name,
            };
        }

        /// Initialize dynamic-capacity storage (empty ArrayLists).
        fn initDynamic(allocator: Allocator, name: []const u8) Self {
            var storage: ComponentStorage = undefined;
            inline for (0..component_count) |i| {
                storage[i] = .empty;
            }

            return .{
                .allocator = allocator,
                .entity_ids = .empty,
                .component_storage = storage,
                .count = 0,
                .name = name,
            };
        }

        // ==================================================================
        // AT-4: Invariant Assertions (Tiger_Style: Exhaustive validation)
        // ==================================================================

        /// Debug-only assertion that validates critical invariants:
        /// 1. All component arrays have the same length as entity_ids
        /// 2. count field matches actual storage length
        ///
        /// Tiger Style: Exhaustive assertions to catch bugs early.
        /// Called after mutations in debug builds only.
        fn assertInvariants(self: *const Self) void {
            // Only run checks in Debug mode (skip in ReleaseSafe/ReleaseFast/ReleaseSmall)
            if (builtin.mode != .Debug) return;

            const entity_len = switch (capacity_mode) {
                .fixed => self.count,
                .dynamic => @as(u32, @intCast(self.entity_ids.items.len)),
            };

            // Verify count matches entity_ids length
            assert(self.count == entity_len);

            // Verify all component arrays match entity_ids length
            if (component_count > 0) {
                inline for (0..component_count) |i| {
                    const comp_len: u32 = switch (capacity_mode) {
                        .fixed => self.count, // Fixed mode uses count, arrays are pre-allocated
                        .dynamic => @intCast(self.component_storage[i].items.len),
                    };
                    assert(comp_len == entity_len);
                }
            }
        }

        /// Initialize an archetype table with pre-allocated capacity.
        /// For fixed mode, this is equivalent to init() (already pre-allocated).
        /// For dynamic mode, this reserves capacity upfront.
        /// Tiger Style: Use this for predictable allocation patterns.
        pub fn initWithCapacity(allocator: Allocator, name: []const u8, initial_capacity: u32) !Self {
            switch (capacity_mode) {
                .fixed => {
                    // Fixed mode always uses max_capacity, initial_capacity is informational
                    return init(allocator, name);
                },
                .dynamic => {
                    var self = initDynamic(allocator, name);

                    if (initial_capacity > 0) {
                        // Pre-allocate entity_ids array
                        try self.entity_ids.ensureTotalCapacity(allocator, initial_capacity);

                        // Pre-allocate all component arrays
                        inline for (0..component_count) |i| {
                            try self.component_storage[i].ensureTotalCapacity(allocator, initial_capacity);
                        }
                    }

                    return self;
                },
            }
        }

        /// Returns the current capacity of the archetype table.
        pub fn capacity(self: *const Self) u32 {
            return switch (capacity_mode) {
                .fixed => fixed_capacity,
                .dynamic => @intCast(self.entity_ids.capacity),
            };
        }

        /// Deinitialize and free all storage.
        pub fn deinit(self: *Self) void {
            switch (capacity_mode) {
                .fixed => {
                    self.allocator.free(self.entity_ids);
                    inline for (0..component_count) |i| {
                        self.allocator.free(self.component_storage[i]);
                    }
                },
                .dynamic => {
                    self.entity_ids.deinit(self.allocator);
                    inline for (0..component_count) |i| {
                        self.component_storage[i].deinit(self.allocator);
                    }
                },
            }
        }

        /// Get the number of entities in this archetype.
        pub fn len(self: *const Self) u32 {
            return self.count;
        }

        /// Check if the archetype is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Check if the archetype is at capacity (fixed mode only returns true at limit).
        pub fn isFull(self: *const Self) bool {
            return switch (capacity_mode) {
                .fixed => self.count >= fixed_capacity,
                .dynamic => false, // Dynamic mode is never "full"
            };
        }

        // ==================================================================
        // AT-5: addEntity Helper Functions (Tiger_Style: ≤70 lines per fn)
        // ==================================================================

        /// Resolve component value from a components struct/tuple.
        /// Returns either the matching field value, T.default, or zero-initialized.
        /// Tiger Style: Pure compile-time helper for component value resolution.
        fn resolveComponentValue(comptime T: type, comptime Components: type, components: Components) T {
            // Why: Centralize component resolution logic to avoid duplication
            // How: Compile-time field matching with fallback to defaults
            return inline for (std.meta.fields(Components)) |field| {
                if (field.type == T) break @field(components, field.name);
            } else if (@hasDecl(T, "default")) T.default else std.mem.zeroes(T);
        }

        /// Store components for an entity in fixed capacity mode.
        /// Tiger Style: Pure helper with bounded storage, no dynamic allocation.
        /// Pre-condition: row < fixed_capacity (caller verified via error return)
        fn storeEntityFixed(self: *Self, row: u32, entity_id: EntityId, comptime Components: type, components: Components) void {
            // Assert pre-condition: row is within bounds (defensive, caller checked)
            assert(row < fixed_capacity);

            self.entity_ids[row] = entity_id;
            inline for (0..component_count) |i| {
                self.component_storage[i][row] = resolveComponentValue(component_types[i], Components, components);
            }

            // Assert post-condition: entity ID was stored correctly
            assert(self.entity_ids[row] == entity_id);
        }

        /// Store components for an entity in dynamic capacity mode.
        /// Tiger Style: Growable storage with optional max_capacity bound.
        /// Pre-condition: max_capacity == 0 OR count < max_capacity (caller verified)
        fn storeEntityDynamic(self: *Self, entity_id: EntityId, comptime Components: type, components: Components) !void {
            // Assert pre-condition: capacity limit honored if configured
            assert(max_capacity == 0 or self.count < max_capacity);

            try self.entity_ids.append(self.allocator, entity_id);
            errdefer _ = self.entity_ids.pop();

            inline for (0..component_count) |i| {
                try self.component_storage[i].append(
                    self.allocator,
                    resolveComponentValue(component_types[i], Components, components),
                );
            }

            // Assert post-condition: entity appended to end of storage
            assert(self.entity_ids.items[self.entity_ids.items.len - 1] == entity_id);
        }

        /// Add an entity with its component values.
        /// Returns the row index where the entity was stored.
        /// In fixed mode, returns error.CapacityExhausted if full.
        /// AT-3: Also validates against max_capacity in dynamic mode if configured.
        pub fn addEntity(self: *Self, entity_id: EntityId, components: anytype) !u32 {
            const Components = @TypeOf(components);
            const row = self.count;

            // Assert pre-condition: count is consistent with storage state
            assert(row == switch (capacity_mode) {
                .fixed => self.count,
                .dynamic => @as(u32, @intCast(self.entity_ids.items.len)),
            });

            switch (capacity_mode) {
                .fixed => {
                    // Tiger_Style: Check capacity before any mutation
                    if (row >= fixed_capacity) return ArchetypeError.CapacityExhausted;
                    self.storeEntityFixed(row, entity_id, Components, components);
                },
                .dynamic => {
                    // AT-3: Validate against max_capacity if configured (non-zero)
                    if (max_capacity > 0 and row >= max_capacity) return ArchetypeError.CapacityExhausted;
                    try self.storeEntityDynamic(entity_id, Components, components);
                },
            }

            self.count += 1;

            // Assert post-condition: count incremented correctly
            assert(self.count == row + 1);

            self.assertInvariants(); // AT-4: Verify invariants after mutation
            return row;
        }

        /// Remove an entity by row index. Uses swap-remove for O(1) performance.
        /// Returns the entity ID that was moved into this slot (if any).
        pub fn removeEntityByRow(self: *Self, row: u32) ?EntityId {
            if (row >= self.count) return null;

            const last_row = self.count - 1;
            var moved_entity: ?EntityId = null;

            switch (capacity_mode) {
                .fixed => {
                    // Swap with last element (if not already last)
                    if (row != last_row) {
                        self.entity_ids[row] = self.entity_ids[last_row];
                        inline for (0..component_count) |i| {
                            self.component_storage[i][row] = self.component_storage[i][last_row];
                        }
                    }

                    self.count -= 1;

                    // Return the entity that was moved into this slot
                    if (row < self.count) {
                        moved_entity = self.entity_ids[row];
                    }
                },
                .dynamic => {
                    // Swap-remove the entity ID
                    _ = self.entity_ids.swapRemove(row);

                    // Swap-remove all component arrays
                    inline for (0..component_count) |i| {
                        _ = self.component_storage[i].swapRemove(row);
                    }

                    self.count -= 1;

                    // Return the entity that was moved into this slot
                    if (row < self.count) {
                        moved_entity = self.entity_ids.items[row];
                    }
                },
            }

            self.assertInvariants(); // AT-4: Verify invariants after mutation
            return moved_entity;
        }

        /// Get a pointer to a component for an entity at a given row.
        pub fn getComponent(self: *Self, comptime T: type, row: u32) ?*T {
            if (row >= self.count) return null;

            inline for (0..component_count) |i| {
                if (component_types[i] == T) {
                    return switch (capacity_mode) {
                        .fixed => &self.component_storage[i][row],
                        .dynamic => &self.component_storage[i].items[row],
                    };
                }
            }
            return null;
        }

        /// Get a const pointer to a component for an entity at a given row.
        pub fn getComponentConst(self: *const Self, comptime T: type, row: u32) ?*const T {
            if (row >= self.count) return null;

            inline for (0..component_count) |i| {
                if (component_types[i] == T) {
                    return switch (capacity_mode) {
                        .fixed => &self.component_storage[i][row],
                        .dynamic => &self.component_storage[i].items[row],
                    };
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
            if (row >= self.count) return null;

            return switch (capacity_mode) {
                .fixed => self.entity_ids[row],
                .dynamic => self.entity_ids.items[row],
            };
        }

        /// Find the row index for a given entity ID.
        ///
        /// ## AT-2: O(n) Linear Search Warning
        /// **IMPORTANT**: This function uses O(n) linear search through all entities.
        /// It is intended ONLY for:
        /// - Debug assertions and invariant verification
        /// - Testing and validation
        /// - Rare, non-performance-critical lookups
        ///
        /// **DO NOT** use in hot paths or performance-critical code.
        /// For efficient entity-to-row mapping, use EntityManager metadata
        /// which provides O(1) lookup via `archetype_row` field.
        ///
        /// Tiger Style: Document performance characteristics explicitly.
        pub fn findEntity(self: *const Self, entity_id: EntityId) ?u32 {
            const entities = switch (capacity_mode) {
                .fixed => self.entity_ids[0..self.count],
                .dynamic => self.entity_ids.items,
            };

            for (entities, 0..) |id, row| {
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
                    return switch (capacity_mode) {
                        .fixed => self.component_storage[i][0..self.count],
                        .dynamic => self.component_storage[i].items,
                    };
                }
            }
            return null;
        }

        /// Get a const slice of all component values for iteration.
        pub fn getComponentSliceConst(self: *const Self, comptime T: type) ?[]const T {
            inline for (0..component_count) |i| {
                if (component_types[i] == T) {
                    return switch (capacity_mode) {
                        .fixed => self.component_storage[i][0..self.count],
                        .dynamic => self.component_storage[i].items,
                    };
                }
            }
            return null;
        }

        /// Get a slice of all entity IDs.
        pub fn getEntitySlice(self: *const Self) []const EntityId {
            return switch (capacity_mode) {
                .fixed => self.entity_ids[0..self.count],
                .dynamic => self.entity_ids.items,
            };
        }

        /// Reserve capacity for a number of entities.
        /// In fixed mode, this is a no-op (capacity is fixed at compile time).
        /// Returns error if new_capacity exceeds fixed_capacity in fixed mode.
        pub fn ensureCapacity(self: *Self, new_capacity: u32) !void {
            switch (capacity_mode) {
                .fixed => {
                    if (new_capacity > fixed_capacity) {
                        return ArchetypeError.CapacityExhausted;
                    }
                    // Already have fixed capacity, nothing to do
                },
                .dynamic => {
                    try self.entity_ids.ensureTotalCapacity(self.allocator, new_capacity);
                    inline for (0..component_count) |i| {
                        try self.component_storage[i].ensureTotalCapacity(self.allocator, new_capacity);
                    }
                },
            }
        }

        /// Clear all entities but retain allocated memory.
        pub fn clear(self: *Self) void {
            switch (capacity_mode) {
                .fixed => {
                    self.count = 0;
                    // Memory is retained, just reset count
                },
                .dynamic => {
                    self.entity_ids.clearRetainingCapacity();
                    inline for (0..component_count) |i| {
                        self.component_storage[i].clearRetainingCapacity();
                    }
                    self.count = 0;
                },
            }
        }

        // ==================================================================
        // Byte-based operations for deferred spawn commands
        // ==================================================================

        /// Calculate total packed size of all components.
        /// Components are packed in declaration order without padding.
        pub fn packedComponentSize() comptime_int {
            var size: usize = 0;
            inline for (component_types) |T| {
                size += @sizeOf(T);
            }
            return size;
        }

        /// Get the byte offset of a component in packed data.
        /// Components are packed sequentially in declaration order.
        pub fn componentOffset(comptime component_idx: usize) comptime_int {
            var offset: usize = 0;
            inline for (0..component_idx) |i| {
                offset += @sizeOf(component_types[i]);
            }
            return offset;
        }

        /// Add an entity with component data from packed bytes.
        /// Returns the row index where the entity was stored.
        /// Tiger Style: Bytes must match packedComponentSize() exactly.
        /// In fixed mode, returns error.CapacityExhausted if full.
        /// AT-3: Also validates against max_capacity in dynamic mode if configured.
        pub fn addEntityFromBytes(self: *Self, entity_id: EntityId, data: []const u8) !u32 {
            const expected_size = packedComponentSize();
            std.debug.assert(data.len == expected_size); // Precondition: data size matches

            const row = self.count;

            switch (capacity_mode) {
                .fixed => {
                    // Tiger_Style: Check capacity before any mutation
                    if (row >= fixed_capacity) {
                        return ArchetypeError.CapacityExhausted;
                    }

                    // Store entity ID
                    self.entity_ids[row] = entity_id;

                    // Unpack and store each component from bytes
                    inline for (0..component_count) |i| {
                        const T = component_types[i];
                        const offset = componentOffset(i);

                        // Copy bytes to aligned storage to handle unaligned source
                        var value: T = undefined;
                        @memcpy(std.mem.asBytes(&value), data[offset .. offset + @sizeOf(T)]);

                        self.component_storage[i][row] = value;
                    }

                    self.count += 1;
                    self.assertInvariants(); // AT-4: Verify invariants after mutation
                    return row;
                },
                .dynamic => {
                    // AT-3: Validate against max_capacity if configured (non-zero)
                    // Tiger Style: Bounded growth even in dynamic mode when limit specified
                    if (max_capacity > 0 and row >= max_capacity) {
                        return ArchetypeError.CapacityExhausted;
                    }

                    // Reserve space for entity
                    try self.entity_ids.append(self.allocator, entity_id);
                    errdefer _ = self.entity_ids.pop();

                    // Unpack and add each component from bytes
                    inline for (0..component_count) |i| {
                        const T = component_types[i];
                        const offset = componentOffset(i);
                        const array = &self.component_storage[i];

                        // Copy bytes to aligned storage to handle unaligned source
                        var value: T = undefined;
                        @memcpy(std.mem.asBytes(&value), data[offset .. offset + @sizeOf(T)]);

                        try array.append(self.allocator, value);
                    }

                    self.count += 1;
                    self.assertInvariants(); // AT-4: Verify invariants after mutation
                    return row;
                },
            }
        }

        /// Pack component values into a byte buffer.
        /// Returns the number of bytes written.
        /// Tiger Style: Buffer must be at least packedComponentSize() bytes.
        pub fn packComponents(components: anytype, buffer: []u8) usize {
            const Components = @TypeOf(components);
            const expected_size = packedComponentSize();
            std.debug.assert(buffer.len >= expected_size);

            inline for (0..component_count) |i| {
                const T = component_types[i];
                const offset = componentOffset(i);

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

                // Copy component bytes into buffer
                const value_bytes = std.mem.asBytes(&value);
                @memcpy(buffer[offset .. offset + @sizeOf(T)], value_bytes);
            }

            return expected_size;
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

test "ArchetypeTable dynamic mode basic operations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    // Use dynamic mode for backward compatibility testing
    const Table = ArchetypeTable(&.{ Position, Velocity }, .dynamic, 0);
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    try std.testing.expectEqual(@as(u32, 0), table.len());
    try std.testing.expect(table.isEmpty());

    // Add entity
    const e1 = EntityId.init(0, 0);
    const row = try table.addEntity(e1, .{
        Position{ .x = 1.0, .y = 2.0 },
        Velocity{ .dx = 0.5, .dy = -0.5 },
    });

    try std.testing.expectEqual(@as(u32, 0), row);
    try std.testing.expectEqual(@as(u32, 1), table.len());

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

test "ArchetypeTable fixed mode basic operations" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    // Use fixed mode with capacity of 100
    const Table = ArchetypeTable(&.{ Position, Velocity }, .fixed, 100);
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    try std.testing.expectEqual(@as(u32, 0), table.len());
    try std.testing.expect(table.isEmpty());
    try std.testing.expectEqual(@as(u32, 100), table.capacity());

    // Add entity
    const e1 = EntityId.init(0, 0);
    const row = try table.addEntity(e1, .{
        Position{ .x = 1.0, .y = 2.0 },
        Velocity{ .dx = 0.5, .dy = -0.5 },
    });

    try std.testing.expectEqual(@as(u32, 0), row);
    try std.testing.expectEqual(@as(u32, 1), table.len());

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

test "ArchetypeTable fixed mode capacity exhaustion" {
    const Value = struct { v: u32 };

    // Use fixed mode with very small capacity
    const Table = ArchetypeTable(&.{Value}, .fixed, 3);
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    // Fill to capacity
    const e1 = EntityId.init(0, 0);
    const e2 = EntityId.init(1, 0);
    const e3 = EntityId.init(2, 0);

    _ = try table.addEntity(e1, .{Value{ .v = 100 }});
    _ = try table.addEntity(e2, .{Value{ .v = 200 }});
    _ = try table.addEntity(e3, .{Value{ .v = 300 }});

    try std.testing.expectEqual(@as(u32, 3), table.len());
    try std.testing.expect(table.isFull());

    // Next add should fail with CapacityExhausted
    const e4 = EntityId.init(3, 0);
    const result = table.addEntity(e4, .{Value{ .v = 400 }});
    try std.testing.expectError(ArchetypeError.CapacityExhausted, result);

    // Count should remain unchanged
    try std.testing.expectEqual(@as(u32, 3), table.len());
}

test "ArchetypeTable dynamic mode swap remove" {
    const Value = struct { v: u32 };
    const Table = ArchetypeTable(&.{Value}, .dynamic, 0);
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    // Add 3 entities
    const e1 = EntityId.init(0, 0);
    const e2 = EntityId.init(1, 0);
    const e3 = EntityId.init(2, 0);

    _ = try table.addEntity(e1, .{Value{ .v = 100 }});
    _ = try table.addEntity(e2, .{Value{ .v = 200 }});
    _ = try table.addEntity(e3, .{Value{ .v = 300 }});

    try std.testing.expectEqual(@as(u32, 3), table.len());

    // Remove middle entity (row 1)
    const moved = table.removeEntityByRow(1);

    // e3 should have been moved to row 1
    try std.testing.expectEqual(e3.toU32(), moved.?.toU32());
    try std.testing.expectEqual(@as(u32, 2), table.len());

    // Row 1 should now have e3's value
    try std.testing.expectEqual(@as(u32, 300), table.getComponent(Value, 1).?.v);
}

test "ArchetypeTable fixed mode swap remove" {
    const Value = struct { v: u32 };
    const Table = ArchetypeTable(&.{Value}, .fixed, 10);
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    // Add 3 entities
    const e1 = EntityId.init(0, 0);
    const e2 = EntityId.init(1, 0);
    const e3 = EntityId.init(2, 0);

    _ = try table.addEntity(e1, .{Value{ .v = 100 }});
    _ = try table.addEntity(e2, .{Value{ .v = 200 }});
    _ = try table.addEntity(e3, .{Value{ .v = 300 }});

    try std.testing.expectEqual(@as(u32, 3), table.len());

    // Remove middle entity (row 1)
    const moved = table.removeEntityByRow(1);

    // e3 should have been moved to row 1
    try std.testing.expectEqual(e3.toU32(), moved.?.toU32());
    try std.testing.expectEqual(@as(u32, 2), table.len());

    // Row 1 should now have e3's value
    try std.testing.expectEqual(@as(u32, 300), table.getComponent(Value, 1).?.v);

    // Can now add another entity (freed slot)
    const e4 = EntityId.init(3, 0);
    _ = try table.addEntity(e4, .{Value{ .v = 400 }});
    try std.testing.expectEqual(@as(u32, 3), table.len());
}

test "ArchetypeTable hasComponent" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    const Table = ArchetypeTable(&.{ A, B }, .fixed, 10);

    try std.testing.expect(Table.hasComponent(A));
    try std.testing.expect(Table.hasComponent(B));
    try std.testing.expect(!Table.hasComponent(C));
}

test "ArchetypeTable packComponents and addEntityFromBytes dynamic" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const Table = ArchetypeTable(&.{ Position, Velocity }, .dynamic, 0);
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    // Test packing
    const packed_size = Table.packedComponentSize();
    try std.testing.expectEqual(@as(usize, @sizeOf(Position) + @sizeOf(Velocity)), packed_size);

    var buffer: [256]u8 = undefined;
    const written = Table.packComponents(.{
        Position{ .x = 1.5, .y = 2.5 },
        Velocity{ .dx = 0.1, .dy = -0.1 },
    }, &buffer);
    try std.testing.expectEqual(packed_size, written);

    // Test adding entity from bytes
    const e1 = EntityId.init(0, 0);
    const row = try table.addEntityFromBytes(e1, buffer[0..packed_size]);
    try std.testing.expectEqual(@as(u32, 0), row);
    try std.testing.expectEqual(@as(u32, 1), table.len());

    // Verify component values
    const pos = table.getComponent(Position, 0).?;
    try std.testing.expectEqual(@as(f32, 1.5), pos.x);
    try std.testing.expectEqual(@as(f32, 2.5), pos.y);

    const vel = table.getComponent(Velocity, 0).?;
    try std.testing.expectEqual(@as(f32, 0.1), vel.dx);
    try std.testing.expectEqual(@as(f32, -0.1), vel.dy);
}

test "ArchetypeTable packComponents and addEntityFromBytes fixed" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const Table = ArchetypeTable(&.{ Position, Velocity }, .fixed, 10);
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    // Test packing
    const packed_size = Table.packedComponentSize();

    var buffer: [256]u8 = undefined;
    _ = Table.packComponents(.{
        Position{ .x = 1.5, .y = 2.5 },
        Velocity{ .dx = 0.1, .dy = -0.1 },
    }, &buffer);

    // Test adding entity from bytes
    const e1 = EntityId.init(0, 0);
    const row = try table.addEntityFromBytes(e1, buffer[0..packed_size]);
    try std.testing.expectEqual(@as(u32, 0), row);
    try std.testing.expectEqual(@as(u32, 1), table.len());

    // Verify component values
    const pos = table.getComponent(Position, 0).?;
    try std.testing.expectEqual(@as(f32, 1.5), pos.x);
    try std.testing.expectEqual(@as(f32, 2.5), pos.y);
}

test "ArchetypeTable componentOffset" {
    const A = struct { a: u32 };
    const B = struct { b: u64 };
    const C = struct { c: u16 };

    const Table = ArchetypeTable(&.{ A, B, C }, .fixed, 10);

    // Verify offsets match expected layout
    try std.testing.expectEqual(@as(usize, 0), Table.componentOffset(0)); // A at 0
    try std.testing.expectEqual(@as(usize, @sizeOf(A)), Table.componentOffset(1)); // B after A
    try std.testing.expectEqual(@as(usize, @sizeOf(A) + @sizeOf(B)), Table.componentOffset(2)); // C after B
}

test "ArchetypeTable clear preserves capacity" {
    const Value = struct { v: u32 };

    // Fixed mode
    const FixedTable = ArchetypeTable(&.{Value}, .fixed, 10);
    var fixed_table = FixedTable.init(std.testing.allocator, "test");
    defer fixed_table.deinit();

    _ = try fixed_table.addEntity(EntityId.init(0, 0), .{Value{ .v = 1 }});
    _ = try fixed_table.addEntity(EntityId.init(1, 0), .{Value{ .v = 2 }});
    try std.testing.expectEqual(@as(u32, 2), fixed_table.len());

    fixed_table.clear();
    try std.testing.expectEqual(@as(u32, 0), fixed_table.len());
    try std.testing.expectEqual(@as(u32, 10), fixed_table.capacity()); // Capacity unchanged

    // Can add again
    _ = try fixed_table.addEntity(EntityId.init(2, 0), .{Value{ .v = 3 }});
    try std.testing.expectEqual(@as(u32, 1), fixed_table.len());
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
