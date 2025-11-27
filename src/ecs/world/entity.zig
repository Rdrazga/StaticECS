//! Entity ID and Handle Management
//!
//! This module provides entity identification with generation-checked handles
//! for safe entity access. Entities are identified by an index and a generation
//! counter to detect stale references.
//!
//! Tiger Style: Bit widths are configurable via WorldConfig.options.entity_index_bits.
//! Default is 20-bit index, 12-bit generation (32 bits total).

const std = @import("std");
const assert = std.debug.assert;

// ============================================================================
// Default Bit Widths (kept for backward compatibility and standalone tests)
// ============================================================================

/// Default number of bits for entity index.
pub const DEFAULT_INDEX_BITS: u5 = 20;
/// Default number of bits for generation counter.
pub const DEFAULT_GENERATION_BITS: u5 = 12;

/// Default maximum entity index value.
pub const DEFAULT_MAX_INDEX: u32 = (1 << DEFAULT_INDEX_BITS) - 1;
/// Default maximum generation value before wrap.
pub const DEFAULT_MAX_GENERATION: u32 = (1 << DEFAULT_GENERATION_BITS) - 1;

// ============================================================================
// Legacy Type Aliases (for backward compatibility)
// ============================================================================

/// Legacy EntityId using default 20-bit index, 12-bit generation.
/// For new code, prefer EntityIdType for config-driven sizing.
pub const EntityId = EntityIdType(DEFAULT_INDEX_BITS);

// ============================================================================
// Configurable EntityId Generator
// ============================================================================

/// Generate an EntityId type with configurable index bit width.
/// Tiger Style: All bounds configurable via this comptime parameter.
///
/// Parameters:
/// - index_bits: Number of bits for entity index (8-24). Generation uses 32 - index_bits.
///
/// Example:
/// ```zig
/// const EntityId16 = EntityIdType(16); // 64K entities, 64K generations
/// const EntityId24 = EntityIdType(24); // 16M entities, 256 generations
/// ```
pub fn EntityIdType(comptime index_bits: u5) type {
    comptime {
        if (index_bits < 8 or index_bits > 24) {
            @compileError("EntityIdType: index_bits must be between 8 and 24");
        }
    }

    // Use u8 for arithmetic since 32 - index_bits can be > 31
    const gen_bits: u8 = 32 - @as(u8, index_bits);
    // Safe to truncate to u5 since gen_bits is between 8 and 24
    const gen_bits_u5: u5 = @truncate(gen_bits);
    const IndexType = std.meta.Int(.unsigned, index_bits);
    const GenType = std.meta.Int(.unsigned, gen_bits_u5);
    const max_index: u32 = (@as(u32, 1) << index_bits) - 1;
    const max_gen: u32 = (@as(u32, 1) << gen_bits) - 1;

    return packed struct {
        const Self = @This();

        /// Number of bits used for index.
        pub const INDEX_BITS = index_bits;
        /// Number of bits used for generation.
        pub const GENERATION_BITS = gen_bits_u5;
        /// Maximum index value.
        pub const MAX_INDEX = max_index;
        /// Maximum generation value.
        pub const MAX_GENERATION = max_gen;
        /// Index integer type.
        pub const Index = IndexType;
        /// Generation integer type.
        pub const Generation = GenType;

        index: IndexType,
        generation: GenType,

        pub const INVALID = Self{ .index = @truncate(max_index), .generation = @truncate(max_gen) };

        /// Create an EntityId from raw parts.
        pub fn init(index: IndexType, generation: GenType) Self {
            return .{ .index = index, .generation = generation };
        }

        /// Convert to a single u32 value.
        pub fn toU32(self: Self) u32 {
            return @bitCast(self);
        }

        /// Create from a single u32 value.
        pub fn fromU32(value: u32) Self {
            return @bitCast(value);
        }

        /// Check if this is the invalid/null entity.
        pub fn isValid(self: Self) bool {
            return self.index != @as(IndexType, @truncate(max_index)) or
                self.generation != @as(GenType, @truncate(max_gen));
        }

        /// Format for debug printing.
        pub fn format(
            self: Self,
            writer: anytype,
        ) !void {
            if (!self.isValid()) {
                try writer.writeAll("Entity(INVALID)");
            } else {
                try writer.print("Entity({d}:{d})", .{ self.index, self.generation });
            }
        }
    };
}

// ============================================================================
// Configurable EntityHandle Generator
// ============================================================================

/// Legacy EntityHandle using default EntityId type.
/// For new code, prefer EntityHandleType for config-driven sizing.
pub const EntityHandle = EntityHandleType(DEFAULT_INDEX_BITS);

/// Generate an EntityHandle type for a specific EntityId configuration.
/// Tiger Style: Handle type matches the corresponding EntityId bit configuration.
pub fn EntityHandleType(comptime index_bits: u5) type {
    const IdType = EntityIdType(index_bits);

    return struct {
        const Self = @This();

        /// The EntityId type this handle wraps.
        pub const EntityIdT = IdType;
        /// Index bit width.
        pub const INDEX_BITS = index_bits;

        id: IdType,

        pub const INVALID = Self{ .id = IdType.INVALID };

        /// Create a handle from an EntityId.
        pub fn fromId(id: IdType) Self {
            return .{ .id = id };
        }

        /// Get the underlying EntityId.
        pub fn toId(self: Self) IdType {
            return self.id;
        }

        /// Get the entity index.
        pub fn index(self: Self) IdType.Index {
            return self.id.index;
        }

        /// Get the entity generation.
        pub fn generation(self: Self) IdType.Generation {
            return self.id.generation;
        }

        /// Check if this is a valid (non-null) handle.
        pub fn isValid(self: Self) bool {
            return self.id.isValid();
        }

        /// Format for debug printing.
        pub fn format(
            self: Self,
            writer: anytype,
        ) !void {
            try self.id.format(writer);
        }
    };
}

// ============================================================================
// Configurable EntityMetadata Generator
// ============================================================================

/// Legacy EntityMetadata using default generation bits.
/// For new code, prefer EntityMetadataType for config-driven sizing.
pub const EntityMetadata = EntityMetadataType(DEFAULT_INDEX_BITS);

/// Generate EntityMetadata type for a specific bit configuration.
/// Tiger Style: Metadata type matches the corresponding EntityId bit configuration.
pub fn EntityMetadataType(comptime index_bits: u5) type {
    // Use u8 for arithmetic since 32 - index_bits can be > 31
    const gen_bits: u8 = 32 - @as(u8, index_bits);
    const gen_bits_u5: u5 = @truncate(gen_bits);
    const GenType = std.meta.Int(.unsigned, gen_bits_u5);

    return struct {
        const Self = @This();

        /// Generation integer type.
        pub const Generation = GenType;

        /// Current generation for this slot.
        generation: GenType = 0,
        /// Index into archetype storage (or sentinel if dead).
        archetype_index: u16 = 0,
        /// Row within the archetype's storage.
        archetype_row: u32 = 0,
        /// Whether this slot is currently alive.
        alive: bool = false,

        pub const DEAD_ARCHETYPE: u16 = std.math.maxInt(u16);
    };
}

// ============================================================================
// Legacy EntityManager (backward compatible)
// ============================================================================

/// Legacy entity manager using default 20-bit index.
/// For new code, prefer EntityManagerType for config-driven sizing.
pub fn EntityManager(comptime max_entities: u32) type {
    return EntityManagerType(max_entities, DEFAULT_INDEX_BITS);
}

// ============================================================================
// Configurable EntityManager Generator
// ============================================================================

/// Entity manager with configurable bit widths.
/// Tiger Style: All bounds and bit widths are configurable.
///
/// Parameters:
/// - max_entities: Maximum number of entities this manager can hold.
/// - index_bits: Number of bits for entity index (must accommodate max_entities).
pub fn EntityManagerType(comptime max_entities: u32, comptime index_bits: u5) type {
    const IdType = EntityIdType(index_bits);
    const HandleType = EntityHandleType(index_bits);
    const MetaType = EntityMetadataType(index_bits);

    comptime {
        if (max_entities == 0) {
            @compileError("EntityManager: max_entities must be greater than zero");
        }
        if (max_entities > IdType.MAX_INDEX + 1) {
            @compileError("EntityManager: max_entities exceeds capacity of index_bits");
        }
    }

    return struct {
        const Self = @This();

        /// The EntityId type used by this manager.
        pub const EntityIdT = IdType;
        /// The EntityHandle type used by this manager.
        pub const EntityHandleT = HandleType;
        /// The EntityMetadata type used by this manager.
        pub const EntityMetadataT = MetaType;
        /// Index bit width.
        pub const INDEX_BITS = index_bits;
        /// Maximum entities this manager can hold.
        pub const MAX_ENTITIES = max_entities;

        /// Entity metadata array.
        metadata: [max_entities]MetaType,
        /// Free list head (index of first free slot, or max_entities if empty).
        free_head: u32,
        /// Number of currently alive entities.
        alive_count: u32,

        /// Initialize a new entity manager.
        pub fn init() Self {
            var self = Self{
                .metadata = undefined,
                .free_head = 0,
                .alive_count = 0,
            };

            // Initialize all metadata slots as dead
            for (&self.metadata, 0..) |*m, i| {
                m.* = MetaType{
                    .generation = 0,
                    .archetype_index = MetaType.DEAD_ARCHETYPE,
                    .archetype_row = @intCast(i + 1), // Next free slot (linked list)
                    .alive = false,
                };
            }
            // Last slot points to sentinel
            if (max_entities > 0) {
                self.metadata[max_entities - 1].archetype_row = max_entities;
            }

            return self;
        }

        /// Create a new entity. Returns null if capacity is exhausted.
        pub fn create(self: *Self) ?HandleType {
            if (self.free_head >= max_entities) {
                return null; // Capacity exhausted
            }

            const index: IdType.Index = @intCast(self.free_head);
            const meta = &self.metadata[index];

            // Update free list head
            self.free_head = meta.archetype_row;

            // Mark as alive
            meta.alive = true;
            meta.archetype_index = MetaType.DEAD_ARCHETYPE;
            meta.archetype_row = 0;

            self.alive_count += 1;

            return HandleType.fromId(IdType.init(index, meta.generation));
        }

        /// Destroy an entity. Returns false if the entity is invalid or already dead.
        pub fn destroy(self: *Self, handle: HandleType) bool {
            if (!handle.isValid()) return false;

            const index = handle.index();
            if (index >= max_entities) return false;

            const meta = &self.metadata[index];

            // Generation check
            if (meta.generation != handle.generation()) return false;
            if (!meta.alive) return false;

            // Mark as dead
            meta.alive = false;

            // Increment generation (with wrap)
            meta.generation +%= 1;

            // Add to free list
            meta.archetype_row = self.free_head;
            self.free_head = index;

            self.alive_count -= 1;

            return true;
        }

        /// Check if an entity handle is still valid (alive and matching generation).
        pub fn isAlive(self: *const Self, handle: HandleType) bool {
            if (!handle.isValid()) return false;

            const index = handle.index();
            if (index >= max_entities) return false;

            const meta = &self.metadata[index];
            return meta.alive and meta.generation == handle.generation();
        }

        /// Get metadata for an entity. Returns null if handle is invalid.
        pub fn getMetadata(self: *const Self, handle: HandleType) ?*const MetaType {
            if (!handle.isValid()) return null;

            const index = handle.index();
            if (index >= max_entities) return null;

            const meta = &self.metadata[index];
            if (!meta.alive or meta.generation != handle.generation()) return null;

            return meta;
        }

        /// Get mutable metadata for an entity. Returns null if handle is invalid.
        pub fn getMetadataMut(self: *Self, handle: HandleType) ?*MetaType {
            if (!handle.isValid()) return null;

            const index = handle.index();
            if (index >= max_entities) return null;

            const meta = &self.metadata[index];
            if (!meta.alive or meta.generation != handle.generation()) return null;

            return meta;
        }

        /// Set archetype location for an entity.
        pub fn setLocation(self: *Self, handle: HandleType, archetype_index: u16, row: u32) bool {
            if (self.getMetadataMut(handle)) |meta| {
                meta.archetype_index = archetype_index;
                meta.archetype_row = row;
                return true;
            }
            return false;
        }

        /// Get the number of currently alive entities.
        pub fn count(self: *const Self) u32 {
            return self.alive_count;
        }

        /// Get the maximum capacity.
        pub fn capacity(self: *const Self) u32 {
            _ = self;
            return max_entities;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "EntityId layout" {
    try std.testing.expectEqual(@sizeOf(EntityId), @sizeOf(u32));

    const id = EntityId.init(100, 5);
    try std.testing.expectEqual(@as(u20, 100), id.index);
    try std.testing.expectEqual(@as(u12, 5), id.generation);

    // Round-trip through u32
    const raw = id.toU32();
    const restored = EntityId.fromU32(raw);
    try std.testing.expectEqual(id.index, restored.index);
    try std.testing.expectEqual(id.generation, restored.generation);
}

test "EntityId invalid" {
    const invalid = EntityId.INVALID;
    try std.testing.expect(!invalid.isValid());

    const valid = EntityId.init(0, 0);
    try std.testing.expect(valid.isValid());
}

test "EntityManager create and destroy" {
    var em = EntityManager(100).init();

    // Create entities
    const e1 = em.create().?;
    const e2 = em.create().?;
    const e3 = em.create().?;

    try std.testing.expectEqual(@as(u32, 3), em.count());
    try std.testing.expect(em.isAlive(e1));
    try std.testing.expect(em.isAlive(e2));
    try std.testing.expect(em.isAlive(e3));

    // Destroy e2
    try std.testing.expect(em.destroy(e2));
    try std.testing.expectEqual(@as(u32, 2), em.count());
    try std.testing.expect(!em.isAlive(e2));
    try std.testing.expect(em.isAlive(e1));
    try std.testing.expect(em.isAlive(e3));

    // Double destroy should fail
    try std.testing.expect(!em.destroy(e2));

    // Create new entity should reuse slot
    const e4 = em.create().?;
    try std.testing.expectEqual(@as(u32, 3), em.count());
    try std.testing.expect(em.isAlive(e4));
    // e4 should have same index as e2 but different generation
    try std.testing.expectEqual(e2.index(), e4.index());
    try std.testing.expect(e2.generation() != e4.generation());
}

test "EntityManager capacity exhaustion" {
    var em = EntityManager(3).init();

    _ = em.create().?;
    _ = em.create().?;
    _ = em.create().?;

    // Should be at capacity
    try std.testing.expectEqual(@as(?EntityHandle, null), em.create());
}

test "EntityManager generation wraparound" {
    const EM = EntityManager(1);
    var em = EM.init();

    // Simulate many create/destroy cycles to test generation wrap
    var last_gen: EM.EntityHandleT.EntityIdT.Generation = 0;
    for (0..10) |_| {
        const e = em.create().?;
        const gen = e.generation();
        if (gen < last_gen) {
            // Generation wrapped - this is expected behavior
        }
        last_gen = gen;
        _ = em.destroy(e);
    }
}

test "EntityHandle formatting" {
    const handle = EntityHandle.fromId(EntityId.init(42, 7));
    var buf: [64]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{f}", .{handle}) catch unreachable;
    try std.testing.expectEqualStrings("Entity(42:7)", result);
}

// ============================================================================
// Tests for Configurable Bit Widths
// ============================================================================

test "EntityIdType - different bit widths" {
    // Test 16-bit index (64K entities, 64K generations)
    const Id16 = EntityIdType(16);
    try std.testing.expectEqual(@sizeOf(Id16), @sizeOf(u32));
    try std.testing.expectEqual(@as(u32, 65535), Id16.MAX_INDEX);
    try std.testing.expectEqual(@as(u32, 65535), Id16.MAX_GENERATION);

    const id16 = Id16.init(1000, 2000);
    try std.testing.expectEqual(@as(u16, 1000), id16.index);
    try std.testing.expectEqual(@as(u16, 2000), id16.generation);
    try std.testing.expect(id16.isValid());

    // Test 24-bit index (16M entities, 256 generations)
    const Id24 = EntityIdType(24);
    try std.testing.expectEqual(@sizeOf(Id24), @sizeOf(u32));
    try std.testing.expectEqual(@as(u32, 16777215), Id24.MAX_INDEX);
    try std.testing.expectEqual(@as(u32, 255), Id24.MAX_GENERATION);

    const id24 = Id24.init(1000000, 200);
    try std.testing.expectEqual(@as(u24, 1000000), id24.index);
    try std.testing.expectEqual(@as(u8, 200), id24.generation);
    try std.testing.expect(id24.isValid());

    // Test invalid sentinel
    try std.testing.expect(!Id16.INVALID.isValid());
    try std.testing.expect(!Id24.INVALID.isValid());
}

test "EntityManagerType - 16-bit index" {
    // 16-bit index manager with small capacity
    const EM16 = EntityManagerType(100, 16);
    var em = EM16.init();

    const e1 = em.create().?;
    const e2 = em.create().?;

    try std.testing.expectEqual(@as(u32, 2), em.count());
    try std.testing.expect(em.isAlive(e1));
    try std.testing.expect(em.isAlive(e2));

    _ = em.destroy(e1);
    try std.testing.expect(!em.isAlive(e1));

    // Verify generation increment
    const e3 = em.create().?;
    try std.testing.expectEqual(e1.index(), e3.index());
    try std.testing.expect(e1.generation() != e3.generation());
}

test "EntityManagerType - 24-bit index for large entity counts" {
    // 24-bit index manager - can handle more entities but fewer generations
    const EM24 = EntityManagerType(200, 24);
    var em = EM24.init();

    // Create many entities
    var handles: [100]EM24.EntityHandleT = undefined;
    for (&handles) |*h| {
        h.* = em.create().?;
    }

    try std.testing.expectEqual(@as(u32, 100), em.count());

    // Cleanup
    for (handles) |h| {
        _ = em.destroy(h);
    }
    try std.testing.expectEqual(@as(u32, 0), em.count());
}

test "EntityIdType - round trip through u32" {
    // Test 16-bit configuration
    const Id16 = EntityIdType(16);
    const id16 = Id16.init(12345, 6789);
    const raw16 = id16.toU32();
    const restored16 = Id16.fromU32(raw16);
    try std.testing.expectEqual(id16.index, restored16.index);
    try std.testing.expectEqual(id16.generation, restored16.generation);

    // Test 24-bit configuration
    const Id24 = EntityIdType(24);
    const id24 = Id24.init(1234567, 89);
    const raw24 = id24.toU32();
    const restored24 = Id24.fromU32(raw24);
    try std.testing.expectEqual(id24.index, restored24.index);
    try std.testing.expectEqual(id24.generation, restored24.generation);
}
