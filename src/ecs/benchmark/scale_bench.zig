//! Large-scale entity benchmarks.
//!
//! Tests performance across cache hierarchy levels:
//! - L1: 1K entities (hot path, fits in L1 cache)
//! - L2: 10K entities (typical game scenario, L2 cache)
//! - L3: 100K entities (large simulation, L3 cache pressure)
//! - RAM: 1M entities (stress test, main memory bandwidth)
//!
//! ## Usage
//! ```zig
//! const scale_bench = @import("scale_bench.zig");
//! const results = scale_bench.runScaleComparison(allocator);
//! scale_bench.printScaleComparison(&results);
//! ```

const std = @import("std");
const time = std.time;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const stats = @import("stats.zig");
const runner = @import("runner.zig");
const BenchResult = runner.BenchResult;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const world_mod = @import("../world.zig");
const QuerySpec = world_mod.QuerySpec;

// ============================================================================
// Scale Constants
// ============================================================================

/// Entity count tiers for testing different memory hierarchy levels.
/// Each tier represents a different cache/memory pressure point:
/// - 1K: L1 cache hotpath benchmark
/// - 10K: L2 cache typical game scenario
/// - 100K: L3 cache large simulation
/// - 1M: Main memory stress test
pub const ENTITY_TIERS = [_]u64{
    1_000, // L1 cache - hot path
    10_000, // L2 cache - typical game scenario
    100_000, // L3 cache - large simulation
    1_000_000, // Main memory - stress test
};

/// Maximum results: 4 tiers × 3 benchmarks (spawn, query, access) = 12
pub const MAX_SCALE_RESULTS: usize = 16;

/// Sample counts for benchmarks (reduced for large entity counts)
const SAMPLES_SMALL: usize = 100; // For 1K-10K entities
const SAMPLES_LARGE: usize = 20; // For 100K-1M entities (too slow otherwise)

/// Maximum samples buffer size (must be >= SAMPLES_SMALL)
const SAMPLES_BUFFER_SIZE: usize = 128;

// ============================================================================
// Benchmark Component Types
// ============================================================================

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };

// ============================================================================
// World Configurations for Each Scale Tier
// ============================================================================

/// Configuration for 1K entity tests (L1 cache tier).
const SmallScaleConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "pos_vel", .components = &.{ Position, Velocity } },
        },
    },
    .options = .{
        .max_entities = 2_048, // Headroom for 1K test
        .enable_debug_asserts = false,
    },
};

/// Configuration for 10K entity tests (L2 cache tier).
const MediumScaleConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "pos_vel", .components = &.{ Position, Velocity } },
        },
    },
    .options = .{
        .max_entities = 16_384, // Headroom for 10K test
        .enable_debug_asserts = false,
    },
};

/// Configuration for 100K entity tests (L3 cache tier).
const LargeScaleConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "pos_vel", .components = &.{ Position, Velocity } },
        },
    },
    .options = .{
        .max_entities = 131_072, // 128K headroom for 100K test
        .enable_debug_asserts = false,
    },
};

/// Configuration for 1M entity tests (main memory stress).
/// Note: entity_index_bits=20 (default) allows up to 2^20 - 1 = 1,048,575 entities.
const HugeScaleConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "pos_vel", .components = &.{ Position, Velocity } },
        },
    },
    .options = .{
        .max_entities = 1_048_575, // Max for 20-bit entity index (2^20 - 1)
        .enable_debug_asserts = false,
    },
};

// World type aliases
const SmallWorld = world_mod.World(SmallScaleConfig);
const MediumWorld = world_mod.World(MediumScaleConfig);
const LargeWorld = world_mod.World(LargeScaleConfig);
const HugeWorld = world_mod.World(HugeScaleConfig);

// ============================================================================
// Spawn Benchmark
// ============================================================================

/// Benchmark spawning entities at scale.
/// Measures time to spawn entity_count entities with Position+Velocity.
///
/// Pre-conditions:
/// - entity_count > 0
/// - entity_count is one of ENTITY_TIERS
/// - allocator is valid
///
/// Returns: BenchResult with spawn timing statistics
pub fn benchSpawnAtScale(allocator: Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= 1_000_000);

    const sample_count = getSampleCount(entity_count);
    std.debug.assert(sample_count <= SAMPLES_BUFFER_SIZE);

    var samples: [SAMPLES_BUFFER_SIZE]u64 = undefined;

    // Run multiple spawn trials
    for (0..sample_count) |i| {
        samples[i] = measureSpawnTime(allocator, entity_count);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    return BenchResult{
        .name = getSpawnName(entity_count),
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

/// Measures time to spawn entities and cleanup.
fn measureSpawnTime(allocator: Allocator, entity_count: u64) u64 {
    const start = time.Instant.now() catch @panic("Timer unavailable");

    if (entity_count <= 1_000) {
        var world = SmallWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesSmall(&world, entity_count) catch @panic("Spawn failed");
    } else if (entity_count <= 10_000) {
        var world = MediumWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesMedium(&world, entity_count) catch @panic("Spawn failed");
    } else if (entity_count <= 100_000) {
        var world = LargeWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesLarge(&world, entity_count) catch @panic("Spawn failed");
    } else {
        var world = HugeWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesHuge(&world, entity_count) catch @panic("Spawn failed");
    }

    const end = time.Instant.now() catch @panic("Timer unavailable");
    return end.since(start);
}

// ============================================================================
// Query Iteration Benchmark
// ============================================================================

/// Benchmark query iteration at scale.
/// Measures full iteration time over all entities.
///
/// Pre-conditions:
/// - entity_count > 0
/// - entity_count is one of ENTITY_TIERS
///
/// Returns: BenchResult showing cache hierarchy effects
pub fn benchQueryAtScale(allocator: Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= 1_000_000);

    const sample_count = getSampleCount(entity_count);
    std.debug.assert(sample_count <= SAMPLES_BUFFER_SIZE);

    var samples: [SAMPLES_BUFFER_SIZE]u64 = undefined;

    // Select appropriate world type and run
    if (entity_count <= 1_000) {
        var world = SmallWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesSmall(&world, entity_count) catch @panic("Spawn failed");
        measureQueryIterations(&world, &samples, sample_count);
    } else if (entity_count <= 10_000) {
        var world = MediumWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesMedium(&world, entity_count) catch @panic("Spawn failed");
        measureQueryIterations(&world, &samples, sample_count);
    } else if (entity_count <= 100_000) {
        var world = LargeWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesLarge(&world, entity_count) catch @panic("Spawn failed");
        measureQueryIterations(&world, &samples, sample_count);
    } else {
        var world = HugeWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesHuge(&world, entity_count) catch @panic("Spawn failed");
        measureQueryIterations(&world, &samples, sample_count);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    return BenchResult{
        .name = getQueryName(entity_count),
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

/// Measures query iteration time using any World type with pos_vel archetype.
fn measureQueryIterations(world: anytype, samples: *[SAMPLES_BUFFER_SIZE]u64, count: usize) void {
    const Spec = QuerySpec(&.{ Position, Velocity }, &.{}, &.{}, &.{});

    // Warmup iterations
    for (0..5) |_| {
        var iter = world.query(Spec);
        while (iter.next()) |_| {}
    }

    // Measurement iterations
    for (0..count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");

        var iter = world.query(Spec);
        var sum: f32 = 0;
        while (iter.next()) |result| {
            const pos = result.read[0];
            const vel = result.read[1];
            sum += pos.x + vel.x;
        }

        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);

        // Prevent optimization
        std.mem.doNotOptimizeAway(&sum);
    }
}

// ============================================================================
// Component Access Benchmark
// ============================================================================

/// Benchmark component read/write access at scale.
/// Uses update pattern: vel.x += pos.x * dt
///
/// Pre-conditions:
/// - entity_count > 0
/// - entity_count <= 1_000_000
///
/// Returns: BenchResult with access pattern statistics
pub fn benchComponentAccessAtScale(allocator: Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= 1_000_000);

    const sample_count = getSampleCount(entity_count);
    std.debug.assert(sample_count <= SAMPLES_BUFFER_SIZE);

    var samples: [SAMPLES_BUFFER_SIZE]u64 = undefined;

    // Select appropriate world type and run
    if (entity_count <= 1_000) {
        var world = SmallWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesSmall(&world, entity_count) catch @panic("Spawn failed");
        measureAccessIterations(&world, &samples, sample_count);
    } else if (entity_count <= 10_000) {
        var world = MediumWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesMedium(&world, entity_count) catch @panic("Spawn failed");
        measureAccessIterations(&world, &samples, sample_count);
    } else if (entity_count <= 100_000) {
        var world = LargeWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesLarge(&world, entity_count) catch @panic("Spawn failed");
        measureAccessIterations(&world, &samples, sample_count);
    } else {
        var world = HugeWorld.init(allocator);
        defer world.deinit();
        spawnEntitiesHuge(&world, entity_count) catch @panic("Spawn failed");
        measureAccessIterations(&world, &samples, sample_count);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    return BenchResult{
        .name = getAccessName(entity_count),
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

/// Measures component read+write access time.
fn measureAccessIterations(world: anytype, samples: *[SAMPLES_BUFFER_SIZE]u64, count: usize) void {
    const Spec = QuerySpec(&.{Position}, &.{Velocity}, &.{}, &.{});
    const dt: f32 = 0.016; // ~60fps

    // Warmup
    for (0..3) |_| {
        var iter = world.query(Spec);
        while (iter.next()) |result| {
            const pos = result.read[0];
            var vel = result.write[0];
            vel.x += pos.x * dt;
        }
    }

    // Measurement
    for (0..count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");

        var iter = world.query(Spec);
        while (iter.next()) |result| {
            const pos = result.read[0];
            var vel = result.write[0];
            vel.x += pos.x * dt;
            vel.y += pos.y * dt;
            vel.z += pos.z * dt;
        }

        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }
}

// ============================================================================
// Scale Comparison Runner
// ============================================================================

/// Result storage for scale comparison.
pub const ScaleComparisonResults = struct {
    results: [MAX_SCALE_RESULTS]BenchResult,
    count: usize,
};

/// Run all benchmarks at each tier for comparison.
/// Returns array of results for all tier × benchmark combinations.
///
/// Pre-conditions:
/// - allocator is valid
///
/// Post-conditions:
/// - Returns results for each tier run successfully
pub fn runScaleComparison(allocator: Allocator) ScaleComparisonResults {
    var output = ScaleComparisonResults{
        .results = undefined,
        .count = 0,
    };

    for (ENTITY_TIERS) |tier| {
        // Spawn benchmark
        output.results[output.count] = benchSpawnAtScale(allocator, tier);
        output.count += 1;

        // Query benchmark
        output.results[output.count] = benchQueryAtScale(allocator, tier);
        output.count += 1;

        // Access benchmark
        output.results[output.count] = benchComponentAccessAtScale(allocator, tier);
        output.count += 1;
    }

    std.debug.assert(output.count <= MAX_SCALE_RESULTS);
    return output;
}

/// Prints scale comparison results in formatted output.
pub fn printScaleComparison(comparison: *const ScaleComparisonResults) void {
    std.debug.print("\n=== Scale Comparison ===\n", .{});

    var idx: usize = 0;
    for (ENTITY_TIERS) |tier| {
        const tier_str = getTierLabel(tier);
        std.debug.print("\nTier: {s} entities\n", .{tier_str});

        if (idx < comparison.count) {
            const spawn = comparison.results[idx];
            const eps_spawn = spawn.entitiesPerSecond();
            std.debug.print("  spawn:  {d:.0} entities/sec (p50: {d}ns)\n", .{ eps_spawn, spawn.stats.p50_ns });
            idx += 1;
        }

        if (idx < comparison.count) {
            const query = comparison.results[idx];
            const eps_query = query.entitiesPerSecond();
            std.debug.print("  query:  {d:.0} entities/sec (p50: {d}ns)\n", .{ eps_query, query.stats.p50_ns });
            idx += 1;
        }

        if (idx < comparison.count) {
            const access = comparison.results[idx];
            const eps_access = access.entitiesPerSecond();
            std.debug.print("  access: {d:.0} ops/sec (p50: {d}ns)\n", .{ eps_access, access.stats.p50_ns });
            idx += 1;
        }

        // Print expected degradation note for larger tiers
        if (tier >= 100_000) {
            std.debug.print("  (expect cache miss impact at this scale)\n", .{});
        }
    }

    std.debug.print("\n", .{});
}

// ============================================================================
// Spawn Helpers (TigerStyle: ≤70 lines each)
// ============================================================================

fn spawnEntitiesSmall(world: *SmallWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("pos_vel", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnEntitiesMedium(world: *MediumWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("pos_vel", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnEntitiesLarge(world: *LargeWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("pos_vel", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnEntitiesHuge(world: *HugeWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("pos_vel", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Returns sample count based on entity tier (fewer samples for large tests).
fn getSampleCount(entity_count: u64) usize {
    return if (entity_count >= 100_000) SAMPLES_LARGE else SAMPLES_SMALL;
}

/// Returns benchmark name for spawn at given tier.
fn getSpawnName(entity_count: u64) []const u8 {
    return switch (entity_count) {
        1_000 => "spawn_1K",
        10_000 => "spawn_10K",
        100_000 => "spawn_100K",
        1_000_000 => "spawn_1M",
        else => "spawn_custom",
    };
}

/// Returns benchmark name for query at given tier.
fn getQueryName(entity_count: u64) []const u8 {
    return switch (entity_count) {
        1_000 => "query_1K",
        10_000 => "query_10K",
        100_000 => "query_100K",
        1_000_000 => "query_1M",
        else => "query_custom",
    };
}

/// Returns benchmark name for access at given tier.
fn getAccessName(entity_count: u64) []const u8 {
    return switch (entity_count) {
        1_000 => "access_1K",
        10_000 => "access_10K",
        100_000 => "access_100K",
        1_000_000 => "access_1M",
        else => "access_custom",
    };
}

/// Returns human-readable tier label.
fn getTierLabel(tier: u64) []const u8 {
    return switch (tier) {
        1_000 => "1K",
        10_000 => "10K",
        100_000 => "100K",
        1_000_000 => "1M",
        else => "custom",
    };
}

// ============================================================================
// Tests (use smaller scales for speed, avoid large world instantiation)
// ============================================================================

test "ENTITY_TIERS has expected values" {
    try testing.expectEqual(@as(u64, 1_000), ENTITY_TIERS[0]);
    try testing.expectEqual(@as(u64, 10_000), ENTITY_TIERS[1]);
    try testing.expectEqual(@as(u64, 100_000), ENTITY_TIERS[2]);
    try testing.expectEqual(@as(u64, 1_000_000), ENTITY_TIERS[3]);
}

test "sample count selection" {
    try testing.expectEqual(@as(usize, SAMPLES_SMALL), getSampleCount(1_000));
    try testing.expectEqual(@as(usize, SAMPLES_SMALL), getSampleCount(10_000));
    try testing.expectEqual(@as(usize, SAMPLES_LARGE), getSampleCount(100_000));
    try testing.expectEqual(@as(usize, SAMPLES_LARGE), getSampleCount(1_000_000));
}

test "tier label generation" {
    try testing.expectEqualStrings("1K", getTierLabel(1_000));
    try testing.expectEqualStrings("10K", getTierLabel(10_000));
    try testing.expectEqualStrings("100K", getTierLabel(100_000));
    try testing.expectEqualStrings("1M", getTierLabel(1_000_000));
}

test "name generation functions" {
    try testing.expectEqualStrings("spawn_1K", getSpawnName(1_000));
    try testing.expectEqualStrings("query_10K", getQueryName(10_000));
    try testing.expectEqualStrings("access_100K", getAccessName(100_000));
    try testing.expectEqualStrings("spawn_1M", getSpawnName(1_000_000));
}

test "SmallWorld spawn and query" {
    // Test with small world to verify basic functionality
    // without instantiating large world types
    var world = SmallWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn a few entities
    for (0..10) |i| {
        _ = world.spawn("pos_vel", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        }) catch @panic("spawn failed");
    }

    // Verify query iteration
    const Spec = QuerySpec(&.{ Position, Velocity }, &.{}, &.{}, &.{});
    var iter = world.query(Spec);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 10), count);
}

test "MediumWorld basic functionality" {
    var world = MediumWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn 100 entities
    for (0..100) |i| {
        _ = world.spawn("pos_vel", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        }) catch @panic("spawn failed");
    }

    // Verify entity count via query
    const Spec = QuerySpec(&.{Position}, &.{}, &.{}, &.{});
    var iter = world.query(Spec);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 100), count);
}
