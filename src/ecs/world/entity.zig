//! Entity ID and Handle Management
//!
//! This module provides entity identification with generation-checked handles
//! for safe entity access. Entities are identified by an index and a generation
//! counter to detect stale references.
//!
//! Tiger Style: Bit widths are configurable via WorldConfig.options.entity_index_bits.
//! Default is 20-bit index, 12-bit generation (32 bits total).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const policy_types = @import("../config/policy_types.zig");
const GenerationPolicy = policy_types.GenerationPolicy;
const GenerationWrapAction = policy_types.GenerationWrapAction;

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
// Generation Statistics (EN-1: Wrap-around tracking)
// ============================================================================

/// Statistics for generation lifecycle tracking.
/// Tracks wrap-around events (epoch), high-water marks, and warnings.
/// Tiger Style: Observable metrics for monitoring long-running applications.
pub const GenerationStats = struct {
    /// Number of times any slot's generation has wrapped (epoch count).
    /// Each increment means one slot went from MAX_GENERATION back to 0.
    /// u8 allows 256 epochs before this counter wraps.
    epoch_count: u8 = 0,

    /// Highest generation value seen across all slots.
    /// Useful for estimating how close to wrap-around the system is.
    max_generation_seen: u32 = 0,

    /// Number of slots that have triggered the warning threshold.
    /// Indicates how many slots are approaching wrap-around.
    slots_at_warn_threshold: u32 = 0,

    /// Total number of generation increments performed.
    /// Useful for understanding entity churn rate.
    total_increments: u64 = 0,

    /// Reset all statistics to zero.
    pub fn reset(self: *GenerationStats) void {
        self.* = GenerationStats{};
    }
};

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

/// Entity manager with custom generation policy.
/// For new code that needs generation wrap-around tracking.
pub fn EntityManagerWithPolicy(comptime max_entities: u32, comptime gen_policy: GenerationPolicy) type {
    return EntityManagerTypeWithPolicy(max_entities, DEFAULT_INDEX_BITS, gen_policy);
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
    // Default policy: debug_panic for safety-first development
    return EntityManagerTypeWithPolicy(max_entities, index_bits, GenerationPolicy{});
}

/// Entity manager with configurable bit widths and generation policy.
/// Tiger Style: All bounds, bit widths, and policies are configurable.
///
/// Parameters:
/// - max_entities: Maximum number of entities this manager can hold.
/// - index_bits: Number of bits for entity index (must accommodate max_entities).
/// - gen_policy: Policy for handling generation overflow and tracking.
pub fn EntityManagerTypeWithPolicy(
    comptime max_entities: u32,
    comptime index_bits: u5,
    comptime gen_policy: GenerationPolicy,
) type {
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

    // Compute warning threshold at compile time
    const warn_threshold_value: u32 = gen_policy.computeWarnThreshold(IdType.MAX_GENERATION);

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
        /// Generation policy for this manager.
        pub const GEN_POLICY = gen_policy;
        /// Warning threshold (generation value at which warnings trigger).
        pub const WARN_THRESHOLD = warn_threshold_value;

        /// Entity metadata array.
        metadata: [max_entities]MetaType,
        /// Free list head (index of first free slot, or max_entities if empty).
        free_head: u32,
        /// Number of currently alive entities.
        alive_count: u32,
        /// Generation statistics (EN-1: wrap-around tracking).
        /// Only updated when gen_policy.enable_stats is true.
        stats: GenerationStats,

        /// Initialize a new entity manager.
        ///
        /// ## EN-2: Runtime Initialization Rationale
        /// The metadata array is initialized at runtime rather than comptime because:
        /// 1. **Free-list linkage**: Each slot's `archetype_row` field is set to `i + 1`
        ///    to form a linked free-list, requiring per-slot index-based computation.
        /// 2. **Compilation time**: Comptime initialization of potentially large arrays
        ///    (up to 1M+ entities) would significantly slow compilation.
        /// 3. **Single execution**: This init runs once per EntityManager lifetime,
        ///    making runtime cost negligible compared to comptime benefits.
        ///
        /// Tiger Style: Runtime init is acceptable here as it's bounded O(max_entities)
        /// and occurs only during initialization, not in hot paths.
        pub fn init() Self {
            var self = Self{
                .metadata = undefined,
                .free_head = 0,
                .alive_count = 0,
                .stats = GenerationStats{},
            };

            // Initialize all metadata slots as dead, linking them into a free-list
            // where each slot's archetype_row points to the next free slot.
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
        ///
        /// TigerStyle: Assertions verify pool state, generation safety, and
        /// free list integrity. Fail-fast on invariant violations.
        pub fn create(self: *Self) ?HandleType {
            // Pre-condition: Entity pool not exhausted (early return path)
            if (self.free_head >= max_entities) {
                return null; // Capacity exhausted
            }

            // Pre-condition assertion: free_head must point to a valid slot
            // Why: Corrupted free_head would cause out-of-bounds access
            assert(self.free_head < max_entities);

            const index: IdType.Index = @intCast(self.free_head);
            const meta = &self.metadata[index];

            // Pre-condition assertion: Slot must be dead before allocation
            // Why: Allocating an alive slot indicates free list corruption
            assert(!meta.alive);

            // Pre-condition assertion: Generation overflow check (policy-aware)
            // Why: For non-wrapping policies, slot at MAX_GENERATION indicates error
            // since debug_panic should have fired in destroy(). For silent_wrap,
            // MAX_GENERATION is valid and will wrap to 0 on next destroy.
            if (comptime gen_policy.on_wrap != .silent_wrap) {
                assert(meta.generation < IdType.MAX_GENERATION);
            }

            // Capture next free before modifying for invariant check
            const next_free = meta.archetype_row;

            // Invariant assertion: Free list integrity - next pointer valid
            // Why: Free list linkage must point to valid slot or sentinel (max_entities)
            assert(next_free <= max_entities);

            // Update free list head
            self.free_head = next_free;

            // Mark as alive
            meta.alive = true;
            meta.archetype_index = MetaType.DEAD_ARCHETYPE;
            meta.archetype_row = 0;

            self.alive_count += 1;

            const handle = HandleType.fromId(IdType.init(index, meta.generation));

            // Post-condition assertion: Returned entity ID is valid
            // Why: Invalid handle would indicate corrupted construction
            assert(handle.isValid());

            // Post-condition assertion: Entity slot properly initialized
            // Why: Slot must be alive after successful creation
            assert(meta.alive);
            assert(meta.archetype_index == MetaType.DEAD_ARCHETYPE);

            return handle;
        }

        /// Destroy an entity. Returns false if the entity is invalid or already dead.
        /// Implements EN-1 (generation wrap-around tracking) and EN-3 (near-overflow assertion).
        ///
        /// TigerStyle: Central control flow delegates to pure helpers for generation
        /// policy handling and slot cleanup. Assertions verify entity validity.
        pub fn destroy(self: *Self, handle: HandleType) bool {
            // Validate handle format
            if (!handle.isValid()) return false;

            const index = handle.index();
            if (index >= max_entities) return false;

            const meta = &self.metadata[index];

            // Assertion: generation must match (detects stale handles)
            assert(meta.generation == handle.generation() or !meta.alive);

            // Generation check - stale handle detection
            if (meta.generation != handle.generation()) return false;
            if (!meta.alive) return false;

            // Assertion: entity must be alive before destruction
            assert(meta.alive);

            // Mark as dead before any policy handling
            meta.alive = false;

            // Delegate generation policy handling (warnings, wrap-around)
            const current_gen: u32 = @intCast(meta.generation);
            const new_gen = handleGenerationPolicy(self, index, current_gen);

            // Assertion: generation must increment (or wrap correctly)
            const expected_wrapped = (current_gen == IdType.MAX_GENERATION);
            const actual_wrapped = @as(u32, @intCast(new_gen)) < current_gen;
            assert(expected_wrapped == actual_wrapped);

            meta.generation = new_gen;

            // Update generation statistics
            updateGenerationStats(self, new_gen);

            // Recycle the entity slot into free list
            cleanupEntitySlot(self, meta, index);

            return true;
        }

        /// Handle generation policy: warnings for near-overflow, wrap-around actions.
        /// Pure function for generation increment policy (EN-1, EN-3).
        ///
        /// Why: Centralizes wrap-around detection and policy actions, keeping
        /// destroy() focused on control flow. Returns the new generation value.
        fn handleGenerationPolicy(self: *Self, index: IdType.Index, current_gen: u32) MetaType.Generation {
            const max_gen = IdType.MAX_GENERATION;

            // EN-3: Check for near-overflow warning threshold
            if (current_gen >= WARN_THRESHOLD and current_gen < max_gen) {
                if (builtin.mode == .Debug) {
                    std.debug.print(
                        "Warning: Entity slot {d} generation near overflow ({d}/{d})\n",
                        .{ index, current_gen, max_gen },
                    );
                }
                // Track first crossing of warning threshold
                if (gen_policy.enable_stats and current_gen == WARN_THRESHOLD) {
                    self.stats.slots_at_warn_threshold +|= 1;
                }
            }

            // Compute new generation with wrapping arithmetic
            const old_gen: MetaType.Generation = @intCast(current_gen);
            const new_gen = old_gen +% 1;
            const wrapped = @as(u32, @intCast(new_gen)) < current_gen;

            // EN-1: Handle wrap-around per policy
            if (wrapped) {
                handleWrapAction(self, index);
            }

            // Assertion: new generation is valid
            assert(@as(u32, @intCast(new_gen)) <= max_gen);

            return new_gen;
        }

        /// Handle wrap-around action per configured policy.
        /// Why: Isolates policy-specific actions for wrap events.
        fn handleWrapAction(self: *Self, index: IdType.Index) void {
            switch (gen_policy.on_wrap) {
                .silent_wrap => {},
                .log_and_wrap => {
                    std.debug.print(
                        "Warning: Entity generation wrapped for slot {d} (epoch: {d})\n",
                        .{ index, self.stats.epoch_count +| 1 },
                    );
                },
                .debug_panic => {
                    if (builtin.mode == .Debug) {
                        @panic("Entity generation overflow - slot has wrapped around");
                    }
                    std.debug.print("Warning: Entity generation wrapped for slot {d}\n", .{index});
                },
                .always_panic => {
                    @panic("Entity generation overflow - slot has wrapped around");
                },
            }
            // Update epoch count (EN-1 tracking)
            if (gen_policy.enable_stats) {
                self.stats.epoch_count +|= 1;
            }
        }

        /// Update generation statistics after increment.
        /// Why: Keeps stats update logic separate from main control flow.
        fn updateGenerationStats(self: *Self, new_gen: MetaType.Generation) void {
            if (gen_policy.enable_stats) {
                self.stats.total_increments +|= 1;
                const new_gen_u32: u32 = @intCast(new_gen);
                if (new_gen_u32 > self.stats.max_generation_seen) {
                    self.stats.max_generation_seen = new_gen_u32;
                }
            }
        }

        /// Cleanup entity slot: add to free list and update alive count.
        /// Pure function for slot recycling.
        ///
        /// Why: Isolates free-list management from main destruction logic.
        /// Assertion verifies slot is properly dead before recycling.
        fn cleanupEntitySlot(self: *Self, meta: *MetaType, index: IdType.Index) void {
            // Assertion: slot must be dead before recycling
            assert(!meta.alive);

            // Link into free list (archetype_row used as next-pointer for dead slots)
            meta.archetype_row = self.free_head;
            self.free_head = index;

            // Assertion: alive count must be positive before decrement
            assert(self.alive_count > 0);
            self.alive_count -= 1;
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

        /// Get generation statistics snapshot.
        /// Returns null if stats tracking is disabled.
        pub fn getStats(self: *const Self) ?GenerationStats {
            if (!gen_policy.enable_stats) return null;
            return self.stats;
        }

        /// Reset generation statistics.
        /// No-op if stats tracking is disabled.
        pub fn resetStats(self: *Self) void {
            if (gen_policy.enable_stats) {
                self.stats.reset();
            }
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

// ============================================================================
// Tests for Generation Overflow Detection (EN-1, EN-3)
// ============================================================================

test "GenerationStats - initial values" {
    const stats = GenerationStats{};
    try std.testing.expectEqual(@as(u8, 0), stats.epoch_count);
    try std.testing.expectEqual(@as(u32, 0), stats.max_generation_seen);
    try std.testing.expectEqual(@as(u32, 0), stats.slots_at_warn_threshold);
    try std.testing.expectEqual(@as(u64, 0), stats.total_increments);
}

test "GenerationStats - reset" {
    var stats = GenerationStats{
        .epoch_count = 5,
        .max_generation_seen = 100,
        .slots_at_warn_threshold = 3,
        .total_increments = 1000,
    };
    stats.reset();
    try std.testing.expectEqual(@as(u8, 0), stats.epoch_count);
    try std.testing.expectEqual(@as(u32, 0), stats.max_generation_seen);
}

test "GenerationPolicy - warn threshold computation" {
    const policy = GenerationPolicy{
        .warn_threshold = 0.9,
    };

    // Test with max_gen = 100
    const threshold100 = policy.computeWarnThreshold(100);
    try std.testing.expectEqual(@as(u32, 90), threshold100);

    // Test with max_gen = 4095 (default 12-bit)
    const threshold4095 = policy.computeWarnThreshold(4095);
    try std.testing.expectEqual(@as(u32, 3685), threshold4095); // 0.9 * 4095 = 3685.5

    // Test edge cases
    const policy_disable = GenerationPolicy{ .warn_threshold = 1.0 };
    try std.testing.expectEqual(@as(u32, 255), policy_disable.computeWarnThreshold(255));

    const policy_zero = GenerationPolicy{ .warn_threshold = 0.0 };
    try std.testing.expectEqual(@as(u32, 0), policy_zero.computeWarnThreshold(255));
}

test "EntityManager with policy - stats tracking enabled" {
    // Use silent_wrap to avoid panic in tests
    const policy = GenerationPolicy{
        .on_wrap = .silent_wrap,
        .warn_threshold = 0.9,
        .enable_stats = true,
    };
    const EM = EntityManagerTypeWithPolicy(10, DEFAULT_INDEX_BITS, policy);
    var em = EM.init();

    // Initial stats should be empty
    const initial_stats = em.getStats().?;
    try std.testing.expectEqual(@as(u8, 0), initial_stats.epoch_count);
    try std.testing.expectEqual(@as(u64, 0), initial_stats.total_increments);

    // Create and destroy should increment stats
    const e1 = em.create().?;
    _ = em.destroy(e1);

    const stats_after = em.getStats().?;
    try std.testing.expectEqual(@as(u64, 1), stats_after.total_increments);
    try std.testing.expectEqual(@as(u32, 1), stats_after.max_generation_seen);
}

test "EntityManager with policy - stats tracking disabled" {
    const policy = GenerationPolicy{
        .on_wrap = .silent_wrap,
        .enable_stats = false,
    };
    const EM = EntityManagerTypeWithPolicy(10, DEFAULT_INDEX_BITS, policy);
    var em = EM.init();

    // Stats should return null when disabled
    try std.testing.expectEqual(@as(?GenerationStats, null), em.getStats());
}

test "EntityManager with policy - generation wrap with silent_wrap" {
    // Use 8-bit generation (max 255) with 24-bit index for fast wrap testing
    const policy = GenerationPolicy{
        .on_wrap = .silent_wrap,
        .warn_threshold = 0.9,
        .enable_stats = true,
    };
    const EM = EntityManagerTypeWithPolicy(1, 24, policy);
    var em = EM.init();

    // Max generation for 24-bit index is 255 (8-bit generation)
    // Cycle through enough times to trigger wrap
    const max_gen = EM.EntityIdT.MAX_GENERATION;
    try std.testing.expectEqual(@as(u32, 255), max_gen);

    // Create/destroy entity until we wrap
    for (0..257) |_| {
        const e = em.create().?;
        _ = em.destroy(e);
    }

    // Should have wrapped at least once
    const stats = em.getStats().?;
    try std.testing.expect(stats.epoch_count >= 1);
}

test "EntityManager with policy - epoch count accuracy" {
    // Use 8-bit generation for fast wrap testing
    const policy = GenerationPolicy{
        .on_wrap = .silent_wrap,
        .warn_threshold = 1.0, // Disable warnings to avoid spam
        .enable_stats = true,
    };
    const EM = EntityManagerTypeWithPolicy(1, 24, policy);
    var em = EM.init();

    // 256 destroys should cause exactly 1 wrap (gen 0->255, then 255->0)
    for (0..256) |_| {
        const e = em.create().?;
        _ = em.destroy(e);
    }

    const stats = em.getStats().?;
    try std.testing.expectEqual(@as(u8, 1), stats.epoch_count);
    try std.testing.expectEqual(@as(u64, 256), stats.total_increments);

    // Another 256 destroys = another wrap
    for (0..256) |_| {
        const e = em.create().?;
        _ = em.destroy(e);
    }

    const stats2 = em.getStats().?;
    try std.testing.expectEqual(@as(u8, 2), stats2.epoch_count);
    try std.testing.expectEqual(@as(u64, 512), stats2.total_increments);
}

test "EntityManager with policy - resetStats" {
    const policy = GenerationPolicy{
        .on_wrap = .silent_wrap,
        .enable_stats = true,
    };
    const EM = EntityManagerTypeWithPolicy(10, DEFAULT_INDEX_BITS, policy);
    var em = EM.init();

    // Generate some stats
    const e1 = em.create().?;
    _ = em.destroy(e1);
    const e2 = em.create().?;
    _ = em.destroy(e2);

    try std.testing.expectEqual(@as(u64, 2), em.getStats().?.total_increments);

    // Reset and verify
    em.resetStats();
    const stats_after = em.getStats().?;
    try std.testing.expectEqual(@as(u64, 0), stats_after.total_increments);
    try std.testing.expectEqual(@as(u8, 0), stats_after.epoch_count);
}

test "EntityManagerWithPolicy - convenience wrapper" {
    const policy = GenerationPolicy{
        .on_wrap = .log_and_wrap,
        .enable_stats = true,
    };
    const EM = EntityManagerWithPolicy(100, policy);
    var em = EM.init();

    const e1 = em.create().?;
    try std.testing.expect(em.isAlive(e1));
    _ = em.destroy(e1);
    try std.testing.expect(!em.isAlive(e1));

    // Verify policy was applied
    try std.testing.expectEqual(GenerationWrapAction.log_and_wrap, EM.GEN_POLICY.on_wrap);
}

test "EntityManager default policy - has stats enabled" {
    // Default EntityManager should still have stats enabled
    const EM = EntityManager(100);
    var em = EM.init();

    // Create and destroy
    const e1 = em.create().?;
    _ = em.destroy(e1);

    // Should be able to get stats with default policy
    const stats = em.getStats();
    try std.testing.expect(stats != null);
    try std.testing.expectEqual(@as(u64, 1), stats.?.total_increments);
}
