//! Query Specification and Iterators
//!
//! This module provides compile-time query definitions and runtime iterators
//! for efficiently accessing entities matching specific component patterns.

const std = @import("std");
const entity = @import("entity.zig");
const EntityId = entity.EntityId;
const EntityHandle = entity.EntityHandle;
const archetype_table = @import("archetype_table.zig");

/// Query specification defining which components to match.
/// - read_types: Required read-only components
/// - write_types: Required mutable components
/// - exclude_types: Components that must NOT be present
/// - optional_types: Components that MAY be present (returns ?*const T)
pub fn QuerySpec(
    comptime read_types: []const type,
    comptime write_types: []const type,
    comptime exclude_types: []const type,
    comptime optional_types: []const type,
) type {
    return struct {
        pub const read_components = read_types;
        pub const write_components = write_types;
        pub const exclude_components = exclude_types;
        pub const optional_components = optional_types;

        /// Count unique required components (read + write without duplicates)
        const unique_count = blk: {
            var count: usize = read_types.len;
            for (write_types) |t| {
                var duplicate = false;
                for (read_types) |rt| {
                    if (rt == t) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) count += 1;
            }
            break :blk count;
        };

        /// All required component types this query accesses (read or write).
        pub const all_components: [unique_count]type = blk: {
            var result: [unique_count]type = undefined;
            var i: usize = 0;
            for (read_types) |t| {
                result[i] = t;
                i += 1;
            }
            for (write_types) |t| {
                // Avoid duplicates if same type in both read and write
                var duplicate = false;
                for (read_types) |rt| {
                    if (rt == t) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    result[i] = t;
                    i += 1;
                }
            }
            break :blk result;
        };

        /// Check if an archetype's component set matches this query.
        /// Requires all read/write components, rejects excluded components.
        /// Optional components do not affect matching.
        pub fn matchesArchetype(comptime arch_components: []const type) bool {
            // Check all required components are present
            inline for (all_components) |required| {
                var found = false;
                inline for (arch_components) |arch_comp| {
                    if (arch_comp == required) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }

            // Check no excluded components are present
            inline for (exclude_components) |excluded| {
                inline for (arch_components) |arch_comp| {
                    if (arch_comp == excluded) {
                        return false;
                    }
                }
            }

            return true;
        }

        /// Check if an archetype has a specific optional component.
        pub fn archetypeHasOptional(comptime arch_components: []const type, comptime T: type) bool {
            inline for (arch_components) |arch_comp| {
                if (arch_comp == T) return true;
            }
            return false;
        }
    };
}

/// Result type for query iteration, containing pointers to components.
pub fn QueryResult(comptime Spec: type) type {
    return struct {
        const Self = @This();

        entity_id: EntityId,

        /// Read-only component pointers (required) - stored as tuple
        read: ReadPointers,

        /// Mutable component pointers (required) - stored as tuple
        write: WritePointers,

        /// Optional component pointers (may be null if not present in archetype) - stored as tuple
        optional: OptionalPointers,

        /// Find index of type T in types array at comptime
        fn findTypeIndex(comptime types: []const type, comptime T: type) comptime_int {
            for (types, 0..) |t, i| {
                if (t == T) return i;
            }
            @compileError("Type " ++ @typeName(T) ++ " not found in query components");
        }

        /// Tuple of const pointers to read components
        const ReadPointers = if (Spec.read_components.len == 0)
            struct {}
        else
            @Tuple(blk: {
                var ptr_types: [Spec.read_components.len]type = undefined;
                for (Spec.read_components, 0..) |T, i| {
                    ptr_types[i] = *const T;
                }
                break :blk &ptr_types;
            });

        /// Tuple of mutable pointers to write components
        const WritePointers = if (Spec.write_components.len == 0)
            struct {}
        else
            @Tuple(blk: {
                var ptr_types: [Spec.write_components.len]type = undefined;
                for (Spec.write_components, 0..) |T, i| {
                    ptr_types[i] = *T;
                }
                break :blk &ptr_types;
            });

        /// Tuple of optional const pointers to optional components
        const OptionalPointers = if (Spec.optional_components.len == 0)
            struct {}
        else
            @Tuple(blk: {
                var ptr_types: [Spec.optional_components.len]type = undefined;
                for (Spec.optional_components, 0..) |T, i| {
                    ptr_types[i] = ?*const T;
                }
                break :blk &ptr_types;
            });

        /// Get a read-only component pointer by type.
        pub fn getRead(self: *const Self, comptime T: type) *const T {
            const idx = comptime findTypeIndex(Spec.read_components, T);
            return self.read[idx];
        }

        /// Get a mutable component pointer by type.
        pub fn getWrite(self: *Self, comptime T: type) *T {
            const idx = comptime findTypeIndex(Spec.write_components, T);
            return self.write[idx];
        }

        /// Get an optional component pointer by type. Returns null if component not present.
        pub fn getOptional(self: *const Self, comptime T: type) ?*const T {
            const idx = comptime findTypeIndex(Spec.optional_components, T);
            return self.optional[idx];
        }

        /// Check if an optional component is present.
        pub fn hasOptional(self: *const Self, comptime T: type) bool {
            return self.getOptional(T) != null;
        }

        /// Set a read pointer at comptime index (used by iterators)
        pub fn setReadPtr(self: *Self, comptime idx: usize, ptr: anytype) void {
            if (Spec.read_components.len > 0) {
                self.read[idx] = ptr;
            }
        }

        /// Set a write pointer at comptime index (used by iterators)
        pub fn setWritePtr(self: *Self, comptime idx: usize, ptr: anytype) void {
            if (Spec.write_components.len > 0) {
                self.write[idx] = ptr;
            }
        }

        /// Set an optional pointer at comptime index (used by iterators)
        pub fn setOptionalPtr(self: *Self, comptime idx: usize, ptr: anytype) void {
            if (Spec.optional_components.len > 0) {
                self.optional[idx] = ptr;
            }
        }
    };
}

/// Iterator over a single archetype table for a query.
pub fn ArchetypeQueryIterator(comptime Spec: type, comptime Table: type) type {
    return struct {
        const Self = @This();
        const Result = QueryResult(Spec);

        table: *Table,
        current_row: u32,

        /// Comptime-computed: which optional components are present in this archetype
        const archetype_components = Table.component_types;

        pub fn init(table: *Table) Self {
            return .{
                .table = table,
                .current_row = 0,
            };
        }

        pub fn next(self: *Self) ?Result {
            if (self.current_row >= self.table.len()) {
                return null;
            }

            var result: Result = undefined;

            // Get entity ID - invariant: valid rows always have entity IDs
            result.entity_id = self.table.getEntityId(self.current_row) orelse unreachable;

            // Get read component pointers using tuple indexing
            // Invariant: query only iterates archetypes containing required components
            inline for (Spec.read_components, 0..) |T, i| {
                const ptr = self.table.getComponentConst(T, self.current_row);
                result.read[i] = ptr orelse unreachable;
            }

            // Get write component pointers using tuple indexing
            // Invariant: query only iterates archetypes containing required components
            inline for (Spec.write_components, 0..) |T, i| {
                const ptr = self.table.getComponent(T, self.current_row);
                result.write[i] = ptr orelse unreachable;
            }

            // Get optional component pointers (null if not in this archetype)
            inline for (Spec.optional_components, 0..) |T, i| {
                if (Spec.archetypeHasOptional(archetype_components, T)) {
                    result.optional[i] = self.table.getComponentConst(T, self.current_row);
                } else {
                    result.optional[i] = null;
                }
            }

            self.current_row += 1;
            return result;
        }

        /// Reset the iterator to the beginning.
        pub fn reset(self: *Self) void {
            self.current_row = 0;
        }

        /// Get remaining count.
        pub fn remaining(self: *const Self) usize {
            const total = self.table.len();
            if (self.current_row >= total) return 0;
            return total - self.current_row;
        }
    };
}

/// Multi-archetype query iterator that iterates over all matching archetypes.
pub fn MultiArchetypeQueryIterator(
    comptime Spec: type,
    comptime archetype_tables: []const type,
    comptime matching_indices: []const usize,
) type {
    return struct {
        const Self = @This();
        const Result = QueryResult(Spec);

        /// Pointers to all archetype tables
        tables: TablePointers,
        current_archetype: usize,
        current_row: u32,

        /// Tuple of pointers to matching archetype tables
        const TablePointers = if (matching_indices.len == 0)
            struct {}
        else
            @Tuple(blk: {
                var ptr_types: [matching_indices.len]type = undefined;
                for (matching_indices, 0..) |arch_idx, i| {
                    ptr_types[i] = *archetype_tables[arch_idx];
                }
                break :blk &ptr_types;
            });

        /// Comptime-computed: which optional components are available per archetype
        const OptionalAvailability = blk: {
            var availability: [matching_indices.len][Spec.optional_components.len]bool = undefined;
            for (matching_indices, 0..) |arch_idx, i| {
                const arch_components = archetype_tables[arch_idx].component_types;
                for (Spec.optional_components, 0..) |opt_type, j| {
                    availability[i][j] = Spec.archetypeHasOptional(arch_components, opt_type);
                }
            }
            break :blk availability;
        };

        pub fn next(self: *Self) ?Result {
            while (self.current_archetype < matching_indices.len) {
                // Inline switch over archetype index for type-safe table access
                inline for (0..matching_indices.len) |i| {
                    if (self.current_archetype == i) {
                        const table_ptr = self.tables[i];
                        const table_len = table_ptr.len();

                        if (self.current_row < table_len) {
                            var result: Result = undefined;
                            result.entity_id = table_ptr.getEntityId(self.current_row).?;

                            // Get required component pointers using tuple indexing
                            inline for (Spec.read_components, 0..) |T, ri| {
                                result.read[ri] = table_ptr.getComponentConst(T, self.current_row).?;
                            }
                            inline for (Spec.write_components, 0..) |T, wi| {
                                result.write[wi] = table_ptr.getComponent(T, self.current_row).?;
                            }

                            // Get optional component pointers using tuple indexing
                            inline for (Spec.optional_components, 0..) |T, j| {
                                if (OptionalAvailability[i][j]) {
                                    result.optional[j] = table_ptr.getComponentConst(T, self.current_row);
                                } else {
                                    result.optional[j] = null;
                                }
                            }

                            self.current_row += 1;
                            return result;
                        }
                    }
                }

                // Move to next archetype
                self.current_archetype += 1;
                self.current_row = 0;
            }

            return null;
        }

        pub fn reset(self: *Self) void {
            self.current_archetype = 0;
            self.current_row = 0;
        }
    };
}

/// Simple query builder for creating QuerySpec types.
/// Usage:
///   Query(.{ .read = &.{Position}, .write = &.{Velocity} })
///   Query(.{ .read = &.{Position}, .optional = &.{Velocity} }) // Velocity may be null
pub fn Query(comptime opts: struct {
    read: []const type = &.{},
    write: []const type = &.{},
    exclude: []const type = &.{},
    optional: []const type = &.{},
}) type {
    return QuerySpec(opts.read, opts.write, opts.exclude, opts.optional);
}

// ============================================================================
// Tests
// ============================================================================

test "QuerySpec matching" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Static = struct {};

    const Q = Query(.{
        .read = &.{Position},
        .write = &.{Velocity},
        .exclude = &.{Static},
    });

    // Should match archetype with Position and Velocity
    try std.testing.expect(Q.matchesArchetype(&.{ Position, Velocity }));

    // Should not match without Velocity
    try std.testing.expect(!Q.matchesArchetype(&.{Position}));

    // Should not match with Static (excluded)
    try std.testing.expect(!Q.matchesArchetype(&.{ Position, Velocity, Static }));

    // Should match with extra components (not excluded)
    const Extra = struct {};
    try std.testing.expect(Q.matchesArchetype(&.{ Position, Velocity, Extra }));
}

test "QuerySpec read-only" {
    const Position = struct { x: f32, y: f32 };

    const Q = Query(.{
        .read = &.{Position},
    });

    try std.testing.expect(Q.matchesArchetype(&.{Position}));
    try std.testing.expectEqual(@as(usize, 1), Q.all_components.len);
}

test "QuerySpec with optional components" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { hp: i32 };

    // Query requires Position, optionally wants Velocity
    const Q = Query(.{
        .read = &.{Position},
        .optional = &.{Velocity},
    });

    // Should match archetype with just Position
    try std.testing.expect(Q.matchesArchetype(&.{Position}));

    // Should also match archetype with Position AND Velocity
    try std.testing.expect(Q.matchesArchetype(&.{ Position, Velocity }));

    // Should match archetype with Position, Velocity, and Health
    try std.testing.expect(Q.matchesArchetype(&.{ Position, Velocity, Health }));

    // Should NOT match archetype without Position (required)
    try std.testing.expect(!Q.matchesArchetype(&.{Velocity}));

    // Verify optional components are tracked
    try std.testing.expectEqual(@as(usize, 1), Q.optional_components.len);
}

test "ArchetypeQueryIterator" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const Table = archetype_table.ArchetypeTable(&.{ Position, Velocity });
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    // Add some entities
    _ = try table.addEntity(EntityId.init(0, 0), .{
        Position{ .x = 1.0, .y = 2.0 },
        Velocity{ .dx = 0.1, .dy = 0.2 },
    });
    _ = try table.addEntity(EntityId.init(1, 0), .{
        Position{ .x = 3.0, .y = 4.0 },
        Velocity{ .dx = 0.3, .dy = 0.4 },
    });

    const Q = Query(.{
        .read = &.{Position},
        .write = &.{Velocity},
    });

    const Iterator = ArchetypeQueryIterator(Q, Table);
    var iter = Iterator.init(&table);

    // First entity
    const r1 = iter.next().?;
    try std.testing.expectEqual(@as(u20, 0), r1.entity_id.index);
    try std.testing.expectEqual(@as(f32, 1.0), r1.getRead(Position).x);

    // Second entity
    const r2 = iter.next().?;
    try std.testing.expectEqual(@as(u20, 1), r2.entity_id.index);
    try std.testing.expectEqual(@as(f32, 3.0), r2.getRead(Position).x);

    // No more
    try std.testing.expectEqual(@as(?QueryResult(Q), null), iter.next());
}

test "ArchetypeQueryIterator with optional - present" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    // Table HAS both Position and Velocity
    const Table = archetype_table.ArchetypeTable(&.{ Position, Velocity });
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    _ = try table.addEntity(EntityId.init(0, 0), .{
        Position{ .x = 1.0, .y = 2.0 },
        Velocity{ .dx = 0.5, .dy = 0.5 },
    });

    // Query with optional Velocity
    const Q = Query(.{
        .read = &.{Position},
        .optional = &.{Velocity},
    });

    const Iterator = ArchetypeQueryIterator(Q, Table);
    var iter = Iterator.init(&table);

    const result = iter.next().?;
    try std.testing.expectEqual(@as(f32, 1.0), result.getRead(Position).x);

    // Optional Velocity should be present
    const opt_vel = result.getOptional(Velocity);
    try std.testing.expect(opt_vel != null);
    try std.testing.expectEqual(@as(f32, 0.5), opt_vel.?.dx);
    try std.testing.expect(result.hasOptional(Velocity));
}

test "ArchetypeQueryIterator with optional - absent" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    // Table only has Position, NOT Velocity
    const Table = archetype_table.ArchetypeTable(&.{Position});
    var table = Table.init(std.testing.allocator, "test");
    defer table.deinit();

    _ = try table.addEntity(EntityId.init(0, 0), .{
        Position{ .x = 1.0, .y = 2.0 },
    });

    // Query with optional Velocity
    const Q = Query(.{
        .read = &.{Position},
        .optional = &.{Velocity},
    });

    const Iterator = ArchetypeQueryIterator(Q, Table);
    var iter = Iterator.init(&table);

    const result = iter.next().?;
    try std.testing.expectEqual(@as(f32, 1.0), result.getRead(Position).x);

    // Optional Velocity should be null (not in this archetype)
    try std.testing.expect(result.getOptional(Velocity) == null);
    try std.testing.expect(!result.hasOptional(Velocity));
}
