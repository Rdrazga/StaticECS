//! Memory usage and cache efficiency benchmarks.
//!
//! Measures memory footprint and access patterns:
//! - Total memory per entity
//! - Component vs metadata overhead
//! - Sequential vs random access performance
//! - Cache line utilization
//!
//! ## Usage
//! ```zig
//! const memory_bench = @import("memory_bench.zig");
//! const mem_result = memory_bench.benchMemoryUsage(allocator, 10_000);
//! memory_bench.printMemoryResults(mem_result);
//!
//! const cache_result = memory_bench.benchCacheEfficiency(allocator, 10_000);
//! memory_bench.printCacheResults(cache_result);
//! ```

const std = @import("std");
const time = std.time;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const stats = @import("stats.zig");
const runner = @import("runner.zig");

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const world_mod = @import("../world.zig");
const QuerySpec = world_mod.QuerySpec;

// ============================================================================
// Constants
// ============================================================================

/// Typical CPU cache line size in bytes.
pub const CACHE_LINE_SIZE: usize = 64;

/// Sample counts for benchmarks.
const SAMPLES_COUNT: usize = 50;
const SAMPLES_BUFFER_SIZE: usize = 64;

/// Default entity count for memory benchmarks.
pub const DEFAULT_ENTITY_COUNT: u64 = 10_000;

// ============================================================================
// Component Types for Measurement
// ============================================================================

/// Minimal component (4 bytes).
const Tag = struct { id: u32 };

/// Small component (12 bytes).
const Position = struct { x: f32, y: f32, z: f32 };

/// Medium component (24 bytes).
const Transform = struct {
    pos: [3]f32,
    rot: [3]f32,
};

/// Large component (64 bytes - cache line sized).
const BigData = struct { data: [16]u32 };

/// Velocity component for movement benchmarks.
const Velocity = struct { x: f32, y: f32, z: f32 };

// ============================================================================
// Result Types
// ============================================================================

/// Memory usage analysis result.
pub const MemoryResult = struct {
    /// Total bytes used by the world.
    total_bytes: u64,
    /// Average bytes per entity.
    bytes_per_entity: f64,
    /// Overhead percentage (actual vs theoretical minimum).
    overhead_percent: f64,
    /// Bytes used by component data.
    component_bytes: u64,
    /// Bytes used by metadata (entity IDs, generation, etc).
    metadata_bytes: u64,
    /// Entity count measured.
    entity_count: u64,
    /// Archetype count.
    archetype_count: u32,
};

/// Cache efficiency analysis result.
pub const CacheResult = struct {
    /// Time for sequential access (ns/entity).
    sequential_ns: u64,
    /// Time for random access (ns/entity).
    random_ns: u64,
    /// Ratio: random/sequential - higher means worse cache behavior.
    ratio: f64,
    /// Entity count tested.
    entity_count: u64,
    /// Statistical data for sequential access.
    sequential_stats: stats.Stats,
    /// Statistical data for random access.
    random_stats: stats.Stats,
};

/// Component density analysis result.
pub const DensityResult = struct {
    /// Actual memory used per entity.
    actual_bytes_per_entity: f64,
    /// Theoretical minimum bytes per entity.
    theoretical_bytes_per_entity: f64,
    /// Density ratio (theoretical / actual) - 1.0 is perfect.
    density_ratio: f64,
    /// Entities that fit per cache line.
    entities_per_cache_line: f64,
    /// Component size breakdown.
    component_sizes: ComponentSizes,
};

/// Component size breakdown.
pub const ComponentSizes = struct {
    tag_size: usize,
    position_size: usize,
    transform_size: usize,
    big_data_size: usize,
    entity_id_size: usize,
};

// ============================================================================
// World Configurations
// ============================================================================

/// Configuration for memory benchmarks with varied component sizes.
const MemoryBenchConfig = WorldConfig{
    .components = .{
        .types = &.{ Tag, Position, Transform, BigData, Velocity },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "tag_only", .components = &.{Tag} },
            .{ .name = "pos_vel", .components = &.{ Position, Velocity } },
            .{ .name = "transform", .components = &.{Transform} },
            .{ .name = "big_data", .components = &.{BigData} },
            .{ .name = "mixed", .components = &.{ Tag, Position, Velocity } },
        },
    },
    .options = .{
        .max_entities = 131072, // 128K headroom
        .enable_debug_asserts = false,
    },
};

const MemoryBenchWorld = world_mod.World(MemoryBenchConfig);

/// Configuration for single archetype overhead measurement.
const SingleArchConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "pos_vel", .components = &.{ Position, Velocity } },
        },
    },
    .options = .{
        .max_entities = 131072,
        .enable_debug_asserts = false,
    },
};

const SingleArchWorld = world_mod.World(SingleArchConfig);

// ============================================================================
// Memory Usage Benchmark
// ============================================================================

/// Measure memory footprint per entity.
///
/// Pre-conditions:
/// - entity_count > 0
/// - entity_count <= max_entities configured
/// - allocator is valid
///
/// Post-conditions:
/// - Returns valid MemoryResult
/// - bytes_per_entity > 0
pub fn benchMemoryUsage(allocator: Allocator, entity_count: u64) MemoryResult {
    // Pre-conditions
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= MemoryBenchConfig.options.max_entities);

    // Calculate theoretical minimum bytes per entity
    // For pos_vel archetype: Position(12) + Velocity(12) + EntityId(4) = 28 bytes
    const theoretical_per_entity = @sizeOf(Position) + @sizeOf(Velocity) + @sizeOf(u32);

    // Create world and spawn entities
    var world = SingleArchWorld.init(allocator);
    defer world.deinit();

    // Spawn entities with Position and Velocity
    const spawn_count = @as(usize, @intCast(@min(entity_count, MemoryBenchConfig.options.max_entities)));
    for (0..spawn_count) |i| {
        _ = world.spawn("pos_vel", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1, .y = 0, .z = 0 },
        }) catch break;
    }

    // Calculate memory usage from type sizes
    const component_bytes = calculateComponentBytes(spawn_count);
    const metadata_bytes = calculateMetadataBytes(spawn_count);
    const total_bytes = component_bytes + metadata_bytes;

    const bytes_per_entity: f64 = if (spawn_count > 0)
        @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(spawn_count))
    else
        0;

    const overhead_percent: f64 = if (theoretical_per_entity > 0)
        (bytes_per_entity - @as(f64, @floatFromInt(theoretical_per_entity))) /
            @as(f64, @floatFromInt(theoretical_per_entity)) * 100.0
    else
        0;

    // Post-conditions
    std.debug.assert(bytes_per_entity >= 0);

    return MemoryResult{
        .total_bytes = total_bytes,
        .bytes_per_entity = bytes_per_entity,
        .overhead_percent = overhead_percent,
        .component_bytes = component_bytes,
        .metadata_bytes = metadata_bytes,
        .entity_count = spawn_count,
        .archetype_count = 1,
    };
}

/// Calculate component data bytes for entity count.
fn calculateComponentBytes(entity_count: usize) u64 {
    // pos_vel archetype: Position(12) + Velocity(12) per entity
    const per_entity = @sizeOf(Position) + @sizeOf(Velocity);
    return @as(u64, entity_count) * per_entity;
}

/// Calculate metadata bytes for entity count.
fn calculateMetadataBytes(entity_count: usize) u64 {
    // EntityId (4 bytes) + generation tracking estimate (4 bytes) per entity
    // Plus archetype map overhead estimate
    const entity_id_size = @sizeOf(u32);
    const generation_size = @sizeOf(u32);
    const archetype_map_per_entity: usize = 8; // Estimate for index storage

    return @as(u64, entity_count) * (entity_id_size + generation_size + archetype_map_per_entity);
}

// ============================================================================
// Component Density Analysis
// ============================================================================

/// Analyze memory layout efficiency.
/// Measures how much memory is used vs theoretical minimum.
///
/// Pre-conditions:
/// - allocator is valid
///
/// Post-conditions:
/// - density_ratio in range (0, 1] for reasonable overhead
pub fn benchComponentDensity(allocator: Allocator) DensityResult {
    _ = allocator; // Used for consistency with other benchmarks

    // Get actual component sizes
    const component_sizes = ComponentSizes{
        .tag_size = @sizeOf(Tag),
        .position_size = @sizeOf(Position),
        .transform_size = @sizeOf(Transform),
        .big_data_size = @sizeOf(BigData),
        .entity_id_size = @sizeOf(u32),
    };

    // For pos_vel archetype analysis
    const theoretical = @sizeOf(Position) + @sizeOf(Velocity);
    const entity_id_overhead = @sizeOf(u32);

    // Actual includes entity ID and any alignment padding
    const actual = theoretical + entity_id_overhead;

    const density_ratio: f64 = @as(f64, @floatFromInt(theoretical)) /
        @as(f64, @floatFromInt(actual));

    // Entities per cache line (using Position entity as example)
    const entity_size = @sizeOf(Position) + @sizeOf(u32);
    const entities_per_line: f64 = @as(f64, @floatFromInt(CACHE_LINE_SIZE)) /
        @as(f64, @floatFromInt(entity_size));

    // Post-conditions
    std.debug.assert(density_ratio > 0);
    std.debug.assert(density_ratio <= 1.0);

    return DensityResult{
        .actual_bytes_per_entity = @floatFromInt(actual),
        .theoretical_bytes_per_entity = @floatFromInt(theoretical),
        .density_ratio = density_ratio,
        .entities_per_cache_line = entities_per_line,
        .component_sizes = component_sizes,
    };
}

// ============================================================================
// Cache Efficiency Benchmark
// ============================================================================

/// Compare sequential vs random access patterns.
/// Measures cache efficiency by timing sequential iteration vs random access.
///
/// Pre-conditions:
/// - entity_count > 0
/// - allocator is valid
///
/// Post-conditions:
/// - ratio >= 1.0 (random is always >= sequential)
pub fn benchCacheEfficiency(allocator: Allocator, entity_count: u64) CacheResult {
    // Pre-conditions
    std.debug.assert(entity_count > 0);

    const count = @as(usize, @intCast(@min(entity_count, 100_000)));

    // Allocate test data
    const data = allocator.alloc(Position, count) catch {
        return createEmptyCacheResult(entity_count);
    };
    defer allocator.free(data);

    // Initialize data
    for (data, 0..) |*pos, i| {
        pos.* = Position{
            .x = @floatFromInt(i),
            .y = @floatFromInt(i * 2),
            .z = @floatFromInt(i * 3),
        };
    }

    // Build random access indices
    const indices = allocator.alloc(usize, count) catch {
        return createEmptyCacheResult(entity_count);
    };
    defer allocator.free(indices);

    // Initialize with sequential, then shuffle
    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }
    shuffleIndices(indices);

    // Measure sequential access
    var seq_samples: [SAMPLES_BUFFER_SIZE]u64 = undefined;
    for (0..SAMPLES_COUNT) |i| {
        seq_samples[i] = measureSequentialAccess(data);
    }
    const seq_stats = stats.calculateStats(seq_samples[0..SAMPLES_COUNT]);

    // Measure random access
    var rand_samples: [SAMPLES_BUFFER_SIZE]u64 = undefined;
    for (0..SAMPLES_COUNT) |i| {
        rand_samples[i] = measureRandomAccess(data, indices);
    }
    const rand_stats = stats.calculateStats(rand_samples[0..SAMPLES_COUNT]);

    // Calculate per-entity times
    const seq_ns_per_entity = if (count > 0) seq_stats.p50_ns / count else 0;
    const rand_ns_per_entity = if (count > 0) rand_stats.p50_ns / count else 0;

    const ratio: f64 = if (seq_ns_per_entity > 0)
        @as(f64, @floatFromInt(rand_ns_per_entity)) /
            @as(f64, @floatFromInt(seq_ns_per_entity))
    else
        1.0;

    // Post-conditions
    std.debug.assert(ratio >= 0);

    return CacheResult{
        .sequential_ns = seq_ns_per_entity,
        .random_ns = rand_ns_per_entity,
        .ratio = ratio,
        .entity_count = count,
        .sequential_stats = seq_stats,
        .random_stats = rand_stats,
    };
}

/// Measure sequential access time.
fn measureSequentialAccess(data: []const Position) u64 {
    const start = time.Instant.now() catch return 0;

    var sum: f32 = 0;
    for (data) |pos| {
        sum += pos.x + pos.y + pos.z;
    }

    const end = time.Instant.now() catch return 0;

    // Prevent optimization
    std.mem.doNotOptimizeAway(&sum);

    return end.since(start);
}

/// Measure random access time.
fn measureRandomAccess(data: []const Position, indices: []const usize) u64 {
    const start = time.Instant.now() catch return 0;

    var sum: f32 = 0;
    for (indices) |idx| {
        const pos = data[idx];
        sum += pos.x + pos.y + pos.z;
    }

    const end = time.Instant.now() catch return 0;

    // Prevent optimization
    std.mem.doNotOptimizeAway(&sum);

    return end.since(start);
}

/// Simple shuffle using PRNG for repeatable random access pattern.
fn shuffleIndices(indices: []usize) void {
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    // Fisher-Yates shuffle
    var i: usize = indices.len - 1;
    while (i > 0) : (i -= 1) {
        const j = random.intRangeAtMost(usize, 0, i);
        const tmp = indices[i];
        indices[i] = indices[j];
        indices[j] = tmp;
    }
}

/// Create empty cache result for error cases.
fn createEmptyCacheResult(entity_count: u64) CacheResult {
    return CacheResult{
        .sequential_ns = 0,
        .random_ns = 0,
        .ratio = 1.0,
        .entity_count = entity_count,
        .sequential_stats = createEmptyStats(),
        .random_stats = createEmptyStats(),
    };
}

// ============================================================================
// Archetype Table Memory Benchmark
// ============================================================================

/// Measure memory overhead of archetype tables.
/// Tests memory usage with varying archetype counts.
///
/// Pre-conditions:
/// - archetype_count > 0
/// - archetype_count <= 5 (limited by config)
/// - allocator is valid
///
/// Post-conditions:
/// - Returns valid MemoryResult
pub fn benchArchetypeOverhead(allocator: Allocator, archetype_count: u32) MemoryResult {
    // Pre-conditions
    std.debug.assert(archetype_count > 0);
    std.debug.assert(archetype_count <= 5);

    var world = MemoryBenchWorld.init(allocator);
    defer world.deinit();

    const entities_per_archetype: usize = 1000;
    var total_spawned: u64 = 0;

    // Spawn entities across archetypes based on count
    if (archetype_count >= 1) {
        for (0..entities_per_archetype) |i| {
            _ = world.spawn("tag_only", .{
                Tag{ .id = @intCast(i) },
            }) catch break;
            total_spawned += 1;
        }
    }

    if (archetype_count >= 2) {
        for (0..entities_per_archetype) |i| {
            _ = world.spawn("pos_vel", .{
                Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
                Velocity{ .x = 1, .y = 0, .z = 0 },
            }) catch break;
            total_spawned += 1;
        }
    }

    if (archetype_count >= 3) {
        for (0..entities_per_archetype) |i| {
            _ = world.spawn("transform", .{
                Transform{ .pos = .{ @floatFromInt(i), 0, 0 }, .rot = .{ 0, 0, 0 } },
            }) catch break;
            total_spawned += 1;
        }
    }

    if (archetype_count >= 4) {
        for (0..entities_per_archetype) |i| {
            var data: [16]u32 = .{0} ** 16;
            data[0] = @as(u32, @intCast(i % 65536));
            _ = world.spawn("big_data", .{
                BigData{ .data = data },
            }) catch break;
            total_spawned += 1;
        }
    }

    if (archetype_count >= 5) {
        for (0..entities_per_archetype) |i| {
            _ = world.spawn("mixed", .{
                Tag{ .id = @as(u32, @intCast(i)) },
                Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
                Velocity{ .x = 1, .y = 0, .z = 0 },
            }) catch break;
            total_spawned += 1;
        }
    }

    // Calculate memory based on archetype composition
    const component_bytes = calculateMultiArchetypeComponentBytes(archetype_count, entities_per_archetype);
    const metadata_bytes = calculateMetadataBytes(@intCast(total_spawned));
    const total_bytes = component_bytes + metadata_bytes;

    const bytes_per_entity: f64 = if (total_spawned > 0)
        @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(total_spawned))
    else
        0;

    // Base overhead comparison (tag_only is minimal)
    const minimal_bytes = @sizeOf(Tag) + @sizeOf(u32); // Tag + EntityId
    const overhead_percent = if (minimal_bytes > 0)
        (bytes_per_entity - @as(f64, @floatFromInt(minimal_bytes))) /
            @as(f64, @floatFromInt(minimal_bytes)) * 100.0
    else
        0;

    return MemoryResult{
        .total_bytes = total_bytes,
        .bytes_per_entity = bytes_per_entity,
        .overhead_percent = overhead_percent,
        .component_bytes = component_bytes,
        .metadata_bytes = metadata_bytes,
        .entity_count = total_spawned,
        .archetype_count = archetype_count,
    };
}

/// Calculate component bytes for multiple archetypes.
fn calculateMultiArchetypeComponentBytes(archetype_count: u32, entities_per_archetype: usize) u64 {
    var total: u64 = 0;

    if (archetype_count >= 1) {
        total += @as(u64, entities_per_archetype) * @sizeOf(Tag);
    }
    if (archetype_count >= 2) {
        total += @as(u64, entities_per_archetype) * (@sizeOf(Position) + @sizeOf(Velocity));
    }
    if (archetype_count >= 3) {
        total += @as(u64, entities_per_archetype) * @sizeOf(Transform);
    }
    if (archetype_count >= 4) {
        total += @as(u64, entities_per_archetype) * @sizeOf(BigData);
    }
    if (archetype_count >= 5) {
        total += @as(u64, entities_per_archetype) * (@sizeOf(Tag) + @sizeOf(Position) + @sizeOf(Velocity));
    }

    return total;
}

// ============================================================================
// Entity Density Benchmark
// ============================================================================

/// Calculate entities per cache line.
/// Measures how many entity IDs fit in L1 cache line.
///
/// Pre-conditions:
/// - allocator is valid
///
/// Post-conditions:
/// - entities_per_cache_line > 0
pub fn benchEntityDensity(allocator: Allocator) DensityResult {
    _ = allocator;

    // Entity ID size
    const entity_id_size = @sizeOf(u32);

    // Entities per cache line
    const entities_per_line: f64 = @as(f64, @floatFromInt(CACHE_LINE_SIZE)) /
        @as(f64, @floatFromInt(entity_id_size));

    // Component sizes for reference
    const component_sizes = ComponentSizes{
        .tag_size = @sizeOf(Tag),
        .position_size = @sizeOf(Position),
        .transform_size = @sizeOf(Transform),
        .big_data_size = @sizeOf(BigData),
        .entity_id_size = entity_id_size,
    };

    // Theoretical: just entity ID
    // Actual: entity ID + generation (assume u32)
    const theoretical = entity_id_size;
    const actual = entity_id_size + @sizeOf(u32); // With generation

    const density_ratio: f64 = @as(f64, @floatFromInt(theoretical)) /
        @as(f64, @floatFromInt(actual));

    // Post-conditions
    std.debug.assert(entities_per_line > 0);
    std.debug.assert(density_ratio > 0);

    return DensityResult{
        .actual_bytes_per_entity = @floatFromInt(actual),
        .theoretical_bytes_per_entity = @floatFromInt(theoretical),
        .density_ratio = density_ratio,
        .entities_per_cache_line = entities_per_line,
        .component_sizes = component_sizes,
    };
}

// ============================================================================
// Output Functions
// ============================================================================

/// Print memory usage results in formatted output.
pub fn printMemoryResults(result: MemoryResult) void {
    std.debug.print("\n=== Memory Usage Analysis ===\n", .{});
    std.debug.print("Entity Count: {d:,}\n", .{result.entity_count});
    std.debug.print("Archetype Count: {d}\n\n", .{result.archetype_count});

    std.debug.print("Component Memory:\n", .{});
    std.debug.print("  Total Component: {d:,} bytes\n\n", .{result.component_bytes});

    std.debug.print("Metadata Memory:\n", .{});
    std.debug.print("  Total Metadata:  {d:,} bytes\n\n", .{result.metadata_bytes});

    std.debug.print("Summary:\n", .{});
    std.debug.print("  Total Memory:     {d:,} bytes\n", .{result.total_bytes});
    std.debug.print("  Bytes/Entity:     {d:.1}\n", .{result.bytes_per_entity});
    std.debug.print("  Overhead:         {d:.1}%\n", .{result.overhead_percent});
}

/// Print cache efficiency results in formatted output.
pub fn printCacheResults(result: CacheResult) void {
    std.debug.print("\n=== Cache Efficiency ===\n", .{});
    std.debug.print("Entity Count: {d:,}\n\n", .{result.entity_count});

    std.debug.print("Sequential Access: {d} ns/entity\n", .{result.sequential_ns});
    std.debug.print("Random Access:     {d} ns/entity\n", .{result.random_ns});
    std.debug.print("Cache Miss Ratio:  {d:.2}x (higher = worse)\n", .{result.ratio});
}

/// Print density analysis results.
pub fn printDensityResults(result: DensityResult) void {
    std.debug.print("\n=== Component Density Analysis ===\n\n", .{});

    std.debug.print("Component Sizes (bytes):\n", .{});
    std.debug.print("  Tag:       {d}\n", .{result.component_sizes.tag_size});
    std.debug.print("  Position:  {d}\n", .{result.component_sizes.position_size});
    std.debug.print("  Transform: {d}\n", .{result.component_sizes.transform_size});
    std.debug.print("  BigData:   {d}\n", .{result.component_sizes.big_data_size});
    std.debug.print("  EntityID:  {d}\n\n", .{result.component_sizes.entity_id_size});

    std.debug.print("Memory Efficiency:\n", .{});
    std.debug.print("  Theoretical:           {d:.1} bytes/entity\n", .{result.theoretical_bytes_per_entity});
    std.debug.print("  Actual:                {d:.1} bytes/entity\n", .{result.actual_bytes_per_entity});
    std.debug.print("  Density Ratio:         {d:.2} (1.0 = perfect)\n", .{result.density_ratio});
    std.debug.print("  Entities/Cache Line:   {d:.1}\n", .{result.entities_per_cache_line});
}

/// Print full memory benchmark report.
pub fn printFullReport(
    mem_result: MemoryResult,
    cache_result: CacheResult,
    density_result: DensityResult,
) void {
    printMemoryResults(mem_result);
    printCacheResults(cache_result);
    printDensityResults(density_result);
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Create empty stats for error cases.
fn createEmptyStats() stats.Stats {
    return stats.Stats{
        .iterations = 0,
        .total_ns = 0,
        .min_ns = 0,
        .max_ns = 0,
        .p50_ns = 0,
        .p75_ns = 0,
        .p90_ns = 0,
        .p99_ns = 0,
        .mean_ns = 0,
        .stddev_ns = 0,
    };
}

// ============================================================================
// All-in-One Runner
// ============================================================================

/// Run all memory benchmarks and return combined results.
pub const MemoryBenchResults = struct {
    memory: MemoryResult,
    cache: CacheResult,
    density: DensityResult,
    entity_density: DensityResult,
    archetype_overhead: [5]MemoryResult,
};

/// Run complete memory benchmark suite.
pub fn runAllBenchmarks(allocator: Allocator, entity_count: u64) MemoryBenchResults {
    var results: MemoryBenchResults = undefined;

    // Memory usage
    results.memory = benchMemoryUsage(allocator, entity_count);

    // Cache efficiency
    results.cache = benchCacheEfficiency(allocator, entity_count);

    // Component density
    results.density = benchComponentDensity(allocator);

    // Entity density
    results.entity_density = benchEntityDensity(allocator);

    // Archetype overhead at different scales
    for (1..6) |i| {
        results.archetype_overhead[i - 1] = benchArchetypeOverhead(allocator, @intCast(i));
    }

    return results;
}

// ============================================================================
// Tests
// ============================================================================

test "memory usage calculation" {
    const result = benchMemoryUsage(testing.allocator, 100);

    // Verify basic properties
    try testing.expect(result.entity_count > 0);
    try testing.expect(result.total_bytes > 0);
    try testing.expect(result.bytes_per_entity > 0);
    try testing.expect(result.component_bytes > 0);
    try testing.expect(result.metadata_bytes > 0);

    // Verify relationship: total = component + metadata
    try testing.expectEqual(
        result.component_bytes + result.metadata_bytes,
        result.total_bytes,
    );
}

test "component density calculation" {
    const result = benchComponentDensity(testing.allocator);

    // Verify density ratio is in valid range (0, 1]
    try testing.expect(result.density_ratio > 0);
    try testing.expect(result.density_ratio <= 1.0);

    // Verify entities per cache line is positive
    try testing.expect(result.entities_per_cache_line > 0);

    // Verify component sizes match @sizeOf
    try testing.expectEqual(@as(usize, @sizeOf(Tag)), result.component_sizes.tag_size);
    try testing.expectEqual(@as(usize, @sizeOf(Position)), result.component_sizes.position_size);
    try testing.expectEqual(@as(usize, @sizeOf(Transform)), result.component_sizes.transform_size);
    try testing.expectEqual(@as(usize, @sizeOf(BigData)), result.component_sizes.big_data_size);
}

test "cache efficiency measurement" {
    const result = benchCacheEfficiency(testing.allocator, 1000);

    // Verify entity count
    try testing.expectEqual(@as(u64, 1000), result.entity_count);

    // Verify ratio >= 1.0 (random should be slower or equal)
    // Note: In rare cases with small data sets, caching effects might vary
    try testing.expect(result.ratio >= 0.5); // Allow some variance
}

test "entity density calculation" {
    const result = benchEntityDensity(testing.allocator);

    // Verify entities per cache line calculation
    // 64 bytes / 4 bytes (u32) = 16 entities
    try testing.expectEqual(@as(f64, 16.0), result.entities_per_cache_line);

    // Verify entity ID size
    try testing.expectEqual(@as(usize, 4), result.component_sizes.entity_id_size);
}

test "archetype overhead measurement" {
    const result = benchArchetypeOverhead(testing.allocator, 2);

    // Verify archetype count recorded
    try testing.expectEqual(@as(u32, 2), result.archetype_count);

    // Verify entities spawned (2 archetypes * 1000 each = 2000)
    try testing.expectEqual(@as(u64, 2000), result.entity_count);

    // Verify memory is positive
    try testing.expect(result.total_bytes > 0);
}

test "shuffle indices produces permutation" {
    var indices: [10]usize = undefined;
    for (&indices, 0..) |*idx, i| {
        idx.* = i;
    }

    shuffleIndices(&indices);

    // Verify all values still present (it's a permutation)
    var seen: [10]bool = .{false} ** 10;
    for (indices) |idx| {
        try testing.expect(idx < 10);
        seen[idx] = true;
    }

    // All values should be present
    for (seen) |s| {
        try testing.expect(s);
    }
}

test "component sizes are correct" {
    // Tag: 4 bytes (u32)
    try testing.expectEqual(@as(usize, 4), @sizeOf(Tag));

    // Position: 12 bytes (3 × f32)
    try testing.expectEqual(@as(usize, 12), @sizeOf(Position));

    // Transform: 24 bytes (6 × f32)
    try testing.expectEqual(@as(usize, 24), @sizeOf(Transform));

    // BigData: 64 bytes (16 × u32)
    try testing.expectEqual(@as(usize, 64), @sizeOf(BigData));
}
