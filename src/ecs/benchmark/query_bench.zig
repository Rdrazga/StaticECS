//! Query iteration benchmarks for StaticECS.
//!
//! Measures query performance across different scenarios:
//! - Single vs multi-component access
//! - Filtered queries (With/Without)
//! - Sparse vs dense archetype distributions
//!
//! ## Usage
//! ```zig
//! const query_bench = @import("query_bench.zig");
//! var suite = BenchmarkSuite.init(.{});
//! const results = query_bench.runAll(&suite);
//! runner.printReport(results);
//! ```

const std = @import("std");
const time = std.time;
const testing = std.testing;

const stats = @import("stats.zig");
const runner = @import("runner.zig");
const BenchmarkSuite = runner.BenchmarkSuite;
const BenchResult = runner.BenchResult;
const Config = runner.Config;

// Import ECS modules
const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const world_mod = @import("../world.zig");
const QuerySpec = world_mod.QuerySpec;

// ============================================================================
// Benchmark Component Types
// ============================================================================

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };
const Health = struct { current: u32, max: u32 };
const Damage = struct { amount: u32 };
const Enemy = struct { threat_level: u8 };
const Armor = struct { value: u32 };
const Speed = struct { value: f32 };
const Range = struct { min: f32, max: f32 };

// ============================================================================
// World Configuration for Query Benchmarks
// ============================================================================

/// World config for single/multi-component query benchmarks.
const QueryBenchConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Damage, Enemy, Armor, Speed, Range },
    },
    .archetypes = .{
        .archetypes = &.{
            // Single component (also used for exclusion test - entities without Enemy)
            .{ .name = "pos_only", .components = &.{Position} },
            // Two components
            .{ .name = "pos_vel", .components = &.{ Position, Velocity } },
            // Four components
            .{ .name = "pos_vel_health_dmg", .components = &.{ Position, Velocity, Health, Damage } },
            // Eight components (full)
            .{ .name = "full", .components = &.{ Position, Velocity, Health, Damage, Enemy, Armor, Speed, Range } },
            // With enemy marker (for exclusion tests)
            .{ .name = "pos_enemy", .components = &.{ Position, Enemy } },
        },
    },
    .options = .{
        .max_entities = 131072, // 128k for headroom
        .enable_debug_asserts = false, // Disable for benchmarks
    },
};

const QueryBenchWorld = world_mod.World(QueryBenchConfig);

/// World config for sparse archetype benchmarks (many archetypes).
const SparseBenchConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Damage },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "arch_0", .components = &.{Position} },
            .{ .name = "arch_1", .components = &.{ Position, Velocity } },
            .{ .name = "arch_2", .components = &.{ Position, Health } },
            .{ .name = "arch_3", .components = &.{ Position, Damage } },
            .{ .name = "arch_4", .components = &.{ Position, Velocity, Health } },
            .{ .name = "arch_5", .components = &.{ Position, Velocity, Damage } },
            .{ .name = "arch_6", .components = &.{ Position, Health, Damage } },
            .{ .name = "arch_7", .components = &.{ Position, Velocity, Health, Damage } },
        },
    },
    .options = .{
        .max_entities = 131072,
        .enable_debug_asserts = false,
    },
};

const SparseBenchWorld = world_mod.World(SparseBenchConfig);

// ============================================================================
// Single Component Query Benchmark
// ============================================================================

/// Benchmark iterating entities with single component (Position).
/// Measures baseline query iteration performance.
///
/// Pre-conditions:
/// - entity_count <= world max_entities
/// - entity_count > 0
///
/// Post-conditions:
/// - Returns valid BenchResult with timing data
/// - All spawned entities are cleaned up
pub fn benchSingleComponentQuery(allocator: std.mem.Allocator, entity_count: u64) BenchResult {
    // Pre-conditions
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= QueryBenchConfig.options.max_entities);

    var world = QueryBenchWorld.init(allocator);
    defer world.deinit();

    // Setup: spawn entities with Position
    spawnPositionEntities(&world, entity_count) catch @panic("Failed to spawn entities");

    // Measurement phase
    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 100;

    // Warm-up iterations
    for (0..10) |_| {
        _ = iterateSingleComponent(&world);
    }

    // Measure iterations
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = iterateSingleComponent(&world);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    // Post-conditions
    std.debug.assert(bench_stats.iterations == sample_count);

    return BenchResult{
        .name = "query_single_component",
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

/// Iterate single component query, returning sum for anti-optimization.
fn iterateSingleComponent(world: *QueryBenchWorld) f32 {
    const Spec = QuerySpec(&.{Position}, &.{}, &.{}, &.{});
    var iter = world.query(Spec);
    var sum: f32 = 0;

    while (iter.next()) |result| {
        const pos = result.read[0];
        sum += pos.x + pos.y + pos.z;
    }

    return sum;
}

// ============================================================================
// Multi-Component Query Benchmarks
// ============================================================================

/// Benchmark iterating entities with 2 components (Position, Velocity).
pub fn benchTwoComponentQuery(allocator: std.mem.Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= QueryBenchConfig.options.max_entities);

    var world = QueryBenchWorld.init(allocator);
    defer world.deinit();

    // Spawn entities with Position + Velocity
    spawnTwoComponentEntities(&world, entity_count) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 100;

    // Warm-up
    for (0..10) |_| {
        _ = iterateTwoComponents(&world);
    }

    // Measure
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = iterateTwoComponents(&world);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);
    std.debug.assert(bench_stats.iterations == sample_count);

    return BenchResult{
        .name = "query_2_components",
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

fn iterateTwoComponents(world: *QueryBenchWorld) f32 {
    const Spec = QuerySpec(&.{ Position, Velocity }, &.{}, &.{}, &.{});
    var iter = world.query(Spec);
    var sum: f32 = 0;

    while (iter.next()) |result| {
        const pos = result.read[0];
        const vel = result.read[1];
        sum += pos.x + vel.x;
    }

    return sum;
}

/// Benchmark iterating entities with 4 components.
pub fn benchFourComponentQuery(allocator: std.mem.Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= QueryBenchConfig.options.max_entities);

    var world = QueryBenchWorld.init(allocator);
    defer world.deinit();

    spawnFourComponentEntities(&world, entity_count) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 100;

    for (0..10) |_| {
        _ = iterateFourComponents(&world);
    }

    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = iterateFourComponents(&world);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);
    std.debug.assert(bench_stats.iterations == sample_count);

    return BenchResult{
        .name = "query_4_components",
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

fn iterateFourComponents(world: *QueryBenchWorld) f32 {
    const Spec = QuerySpec(&.{ Position, Velocity, Health, Damage }, &.{}, &.{}, &.{});
    var iter = world.query(Spec);
    var sum: f32 = 0;

    while (iter.next()) |result| {
        const pos = result.read[0];
        const vel = result.read[1];
        const health = result.read[2];
        const dmg = result.read[3];
        sum += pos.x + vel.x + @as(f32, @floatFromInt(health.current)) + @as(f32, @floatFromInt(dmg.amount));
    }

    return sum;
}

/// Benchmark iterating entities with 8 components (full archetype).
pub fn benchEightComponentQuery(allocator: std.mem.Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= QueryBenchConfig.options.max_entities);

    var world = QueryBenchWorld.init(allocator);
    defer world.deinit();

    spawnEightComponentEntities(&world, entity_count) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 100;

    for (0..10) |_| {
        _ = iterateEightComponents(&world);
    }

    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = iterateEightComponents(&world);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);
    std.debug.assert(bench_stats.iterations == sample_count);

    return BenchResult{
        .name = "query_8_components",
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

fn iterateEightComponents(world: *QueryBenchWorld) f32 {
    const Spec = QuerySpec(
        &.{ Position, Velocity, Health, Damage, Enemy, Armor, Speed, Range },
        &.{},
        &.{},
        &.{},
    );
    var iter = world.query(Spec);
    var sum: f32 = 0;

    while (iter.next()) |result| {
        sum += result.read[0].x; // Position
        sum += result.read[1].x; // Velocity
        sum += @as(f32, @floatFromInt(result.read[2].current)); // Health
        sum += @as(f32, @floatFromInt(result.read[3].amount)); // Damage
        sum += @as(f32, @floatFromInt(result.read[4].threat_level)); // Enemy
        sum += @as(f32, @floatFromInt(result.read[5].value)); // Armor
        sum += result.read[6].value; // Speed
        sum += result.read[7].min; // Range
    }

    return sum;
}

// ============================================================================
// Query with Exclusion Filter Benchmark
// ============================================================================

/// Benchmark query with Without() filter.
/// Setup: 50% entities with Enemy, 50% without.
/// Measures filter overhead compared to simple query.
pub fn benchQueryWithExclusion(allocator: std.mem.Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= QueryBenchConfig.options.max_entities);

    var world = QueryBenchWorld.init(allocator);
    defer world.deinit();

    // Spawn 50% with Enemy, 50% without
    spawnMixedEnemyEntities(&world, entity_count) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 100;

    for (0..10) |_| {
        _ = iterateWithExclusion(&world);
    }

    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = iterateWithExclusion(&world);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);
    std.debug.assert(bench_stats.iterations == sample_count);

    return BenchResult{
        .name = "query_with_exclusion",
        .stats = bench_stats,
        .entity_count = entity_count / 2, // Only half match the filter
    };
}

fn iterateWithExclusion(world: *QueryBenchWorld) f32 {
    // Query Position but exclude Enemy
    const Spec = QuerySpec(&.{Position}, &.{}, &.{Enemy}, &.{});
    var iter = world.query(Spec);
    var sum: f32 = 0;

    while (iter.next()) |result| {
        const pos = result.read[0];
        sum += pos.x + pos.y + pos.z;
    }

    return sum;
}

// ============================================================================
// Sparse vs Dense Archetype Benchmarks
// ============================================================================

/// Benchmark query on dense archetype (all entities in one table).
/// Best-case iteration speed - single contiguous memory access.
pub fn benchDenseArchetypeQuery(allocator: std.mem.Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= QueryBenchConfig.options.max_entities);

    var world = QueryBenchWorld.init(allocator);
    defer world.deinit();

    // All entities in single archetype
    spawnPositionEntities(&world, entity_count) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 100;

    for (0..10) |_| {
        _ = iterateSingleComponent(&world);
    }

    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = iterateSingleComponent(&world);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);
    std.debug.assert(bench_stats.iterations == sample_count);

    return BenchResult{
        .name = "query_dense_archetype",
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

/// Benchmark query on sparse archetypes (entities spread across many tables).
/// Measures archetype traversal overhead.
pub fn benchSparseArchetypeQuery(allocator: std.mem.Allocator, entity_count: u64) BenchResult {
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= SparseBenchConfig.options.max_entities);

    var world = SparseBenchWorld.init(allocator);
    defer world.deinit();

    // Spread entities across multiple archetypes
    spawnSparseEntities(&world, entity_count) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 100;

    for (0..10) |_| {
        _ = iterateSparseQuery(&world);
    }

    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = iterateSparseQuery(&world);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);
    std.debug.assert(bench_stats.iterations == sample_count);

    return BenchResult{
        .name = "query_sparse_archetype",
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

fn iterateSparseQuery(world: *SparseBenchWorld) f32 {
    // Query Position which exists in all sparse archetypes
    const Spec = QuerySpec(&.{Position}, &.{}, &.{}, &.{});
    var iter = world.query(Spec);
    var sum: f32 = 0;

    while (iter.next()) |result| {
        const pos = result.read[0];
        sum += pos.x + pos.y + pos.z;
    }

    return sum;
}

// ============================================================================
// Entity Spawning Helpers (TigerStyle: ≤70 lines each)
// ============================================================================

fn spawnPositionEntities(world: *QueryBenchWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("pos_only", .{Position{
            .x = @floatFromInt(i),
            .y = @floatFromInt(i * 2),
            .z = @floatFromInt(i * 3),
        }});
    }
}

fn spawnTwoComponentEntities(world: *QueryBenchWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("pos_vel", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnFourComponentEntities(world: *QueryBenchWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("pos_vel_health_dmg", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
            Health{ .current = 100, .max = 100 },
            Damage{ .amount = 10 },
        });
    }
}

fn spawnEightComponentEntities(world: *QueryBenchWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("full", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
            Health{ .current = 100, .max = 100 },
            Damage{ .amount = 10 },
            Enemy{ .threat_level = 5 },
            Armor{ .value = 50 },
            Speed{ .value = 2.5 },
            Range{ .min = 0, .max = 100 },
        });
    }
}

fn spawnMixedEnemyEntities(world: *QueryBenchWorld, count: u64) !void {
    const half = count / 2;
    // Spawn half with Enemy component
    for (0..half) |i| {
        _ = try world.spawn("pos_enemy", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Enemy{ .threat_level = 1 },
        });
    }
    // Spawn half without Enemy component (uses pos_only archetype)
    for (0..half) |i| {
        _ = try world.spawn("pos_only", .{Position{
            .x = @floatFromInt(i + half),
            .y = 0,
            .z = 0,
        }});
    }
}

fn spawnSparseEntities(world: *SparseBenchWorld, count: u64) !void {
    const per_archetype = count / 8;
    const remainder = count % 8;

    // Distribute entities across all 8 archetypes
    for (0..per_archetype) |i| {
        _ = try world.spawn("arch_0", .{Position{ .x = @floatFromInt(i), .y = 0, .z = 0 }});
    }
    for (0..per_archetype) |i| {
        _ = try world.spawn("arch_1", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1, .y = 0, .z = 0 },
        });
    }
    for (0..per_archetype) |i| {
        _ = try world.spawn("arch_2", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Health{ .current = 100, .max = 100 },
        });
    }
    for (0..per_archetype) |i| {
        _ = try world.spawn("arch_3", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Damage{ .amount = 10 },
        });
    }
    for (0..per_archetype) |i| {
        _ = try world.spawn("arch_4", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1, .y = 0, .z = 0 },
            Health{ .current = 100, .max = 100 },
        });
    }
    for (0..per_archetype) |i| {
        _ = try world.spawn("arch_5", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1, .y = 0, .z = 0 },
            Damage{ .amount = 10 },
        });
    }
    for (0..per_archetype) |i| {
        _ = try world.spawn("arch_6", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Health{ .current = 100, .max = 100 },
            Damage{ .amount = 10 },
        });
    }
    for (0..per_archetype + remainder) |i| {
        _ = try world.spawn("arch_7", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1, .y = 0, .z = 0 },
            Health{ .current = 100, .max = 100 },
            Damage{ .amount = 10 },
        });
    }
}

// ============================================================================
// Benchmark Suite Integration
// ============================================================================

/// Maximum number of benchmark results.
pub const MAX_RESULTS: usize = 10;

/// Run all query benchmarks with default entity count (10,000).
/// Returns slice of benchmark results.
pub fn runAll(allocator: std.mem.Allocator) [7]BenchResult {
    return runAllWithCount(allocator, 10_000);
}

/// Run all query benchmarks with specified entity count.
pub fn runAllWithCount(allocator: std.mem.Allocator, entity_count: u64) [7]BenchResult {
    // Pre-conditions
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= 100_000);

    var results: [7]BenchResult = undefined;

    // Single component query
    results[0] = benchSingleComponentQuery(allocator, entity_count);

    // Multi-component queries
    results[1] = benchTwoComponentQuery(allocator, entity_count);
    results[2] = benchFourComponentQuery(allocator, entity_count);
    results[3] = benchEightComponentQuery(allocator, entity_count);

    // Filtered query
    results[4] = benchQueryWithExclusion(allocator, entity_count);

    // Dense vs sparse
    results[5] = benchDenseArchetypeQuery(allocator, entity_count);
    results[6] = benchSparseArchetypeQuery(allocator, entity_count);

    // Post-condition
    for (results) |r| {
        std.debug.assert(r.stats.iterations > 0);
    }

    return results;
}

/// Print results with entity throughput metrics.
pub fn printQueryResults(results: []const BenchResult) void {
    std.debug.print("\n=== Query Iteration Benchmarks ===\n\n", .{});

    for (results) |result| {
        const entities_per_sec = result.entitiesPerSecond();
        const ns_per_entity = if (result.entity_count > 0 and result.stats.p50_ns > 0)
            @as(f64, @floatFromInt(result.stats.p50_ns)) / @as(f64, @floatFromInt(result.entity_count))
        else
            0;

        std.debug.print(
            "{s:.<30} p50:{d:>8}ns p99:{d:>8}ns | {d:.2} entities/sec ({d:.2} ns/entity)\n",
            .{
                result.name,
                result.stats.p50_ns,
                result.stats.p99_ns,
                entities_per_sec,
                ns_per_entity,
            },
        );
    }

    std.debug.print("\n", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "single component query benchmark runs" {
    const result = benchSingleComponentQuery(testing.allocator, 1000);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("query_single_component", result.name);
}

test "two component query benchmark runs" {
    const result = benchTwoComponentQuery(testing.allocator, 1000);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("query_2_components", result.name);
}

test "four component query benchmark runs" {
    const result = benchFourComponentQuery(testing.allocator, 1000);
    try testing.expect(result.stats.iterations > 0);
    try testing.expectEqualStrings("query_4_components", result.name);
}

test "eight component query benchmark runs" {
    const result = benchEightComponentQuery(testing.allocator, 500);
    try testing.expect(result.stats.iterations > 0);
    try testing.expectEqualStrings("query_8_components", result.name);
}

test "exclusion query benchmark runs" {
    const result = benchQueryWithExclusion(testing.allocator, 1000);
    try testing.expect(result.stats.iterations > 0);
    try testing.expectEqualStrings("query_with_exclusion", result.name);
    // Should have processed half the entities (those without Enemy)
    try testing.expectEqual(@as(u64, 500), result.entity_count);
}

test "dense archetype query benchmark runs" {
    const result = benchDenseArchetypeQuery(testing.allocator, 1000);
    try testing.expect(result.stats.iterations > 0);
    try testing.expectEqualStrings("query_dense_archetype", result.name);
}

test "sparse archetype query benchmark runs" {
    const result = benchSparseArchetypeQuery(testing.allocator, 800);
    try testing.expect(result.stats.iterations > 0);
    try testing.expectEqualStrings("query_sparse_archetype", result.name);
}

test "runAll produces valid results" {
    const results = runAllWithCount(testing.allocator, 500);
    try testing.expectEqual(@as(usize, 7), results.len);

    for (results) |r| {
        try testing.expect(r.stats.iterations > 0);
        try testing.expect(r.name.len > 0);
    }
}
