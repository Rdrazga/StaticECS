//! # Benchmark Suite for StaticECS
//!
//! Purpose: Performance benchmarks for core ECS operations with statistical
//! analysis, baseline comparison, and detailed throughput metrics.
//!
//! ## Running Benchmarks
//!
//! ```bash
//! # Run all benchmarks
//! zig build bench
//!
//! # Run benchmark tests (lighter, for CI)
//! zig build test -- --test-filter "bench:"
//!
//! # Run with release mode for accurate measurements
//! zig build bench -Doptimize=ReleaseFast
//! ```
//!
//! ## What Each Benchmark Measures
//!
//! | Benchmark | Measures | Expected Range |
//! |-----------|----------|----------------|
//! | spawn | Entity creation throughput | < 10μs/entity |
//! | despawn | Entity destruction throughput | < 10μs/entity |
//! | component_access | getComponent() latency | < 1μs/access |
//! | component_mutation | setComponent() latency | < 1μs/mutation |
//! | hasComponent | Component presence check | < 500ns/check |
//! | isAlive | Entity validity check | < 200ns/check |
//! | query_iteration | Query traversal speed | Varies by entity count |
//! | system_execution | Full system overhead | Varies by complexity |
//!
//! ## Interpreting Results
//!
//! Results include statistical metrics:
//! - **min/max**: Best/worst case latency
//! - **p50**: Median (50th percentile) - typical case
//! - **p90/p99**: Tail latency - worst 10%/1% of cases
//! - **mean**: Average (can be skewed by outliers)
//! - **stddev**: Variation in measurements
//! - **ops/sec**: Throughput (higher is better)
//!
//! Example output:
//! ```
//! spawn: min=1.2μs p50=1.5μs p99=8.2μs ops/sec=650K
//! ```
//!
//! ## Adding New Benchmarks
//!
//! 1. Define test function with `test "bench: my_operation"` naming
//! 2. Use BenchmarkSuite for statistical measurement:
//!    ```zig
//!    test "bench: my_operation" {
//!        var suite = BenchmarkSuite.init(.{
//!            .warmup_iterations = 100,
//!            .measure_iterations = 1000,
//!        });
//!        const result = suite.run("my_op", struct {
//!            fn bench() void {
//!                // Code to benchmark
//!            }
//!        }.bench);
//!        printResult(result);
//!    }
//!    ```
//! 3. Add assertion for expected performance threshold
//!
//! ## Related Modules
//! - `benchmark/mod.zig` - Benchmark infrastructure exports
//! - `benchmark/stats.zig` - Statistical calculations
//! - `benchmark/runner.zig` - Benchmark execution engine
//! - `benchmark/baseline.zig` - Baseline comparison support

const std = @import("std");
const time = std.time;
const testing = std.testing;

// Benchmark infrastructure with statistical analysis
const bench = @import("benchmark/mod.zig");

// Direct imports from within the ecs module (avoids circular dependency with ecs.zig)
const config = @import("config.zig");
const WorldConfig = config.WorldConfig;
const world_mod = @import("world.zig");
const entity = @import("world/entity.zig");

// ============================================================================
// Benchmark Components
// ============================================================================

const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

const Velocity = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    dz: f32 = 0,
};

const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
};

const Transform = struct {
    matrix: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },
};

// ============================================================================
// Benchmark Configuration
// ============================================================================

const BenchConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
            .{ .name = "moving", .components = &.{ Position, Velocity } },
            .{ .name = "living", .components = &.{ Position, Health } },
            .{ .name = "full", .components = &.{ Position, Velocity, Health, Transform } },
        },
    },
    .options = .{
        .max_entities = 65536,
        .enable_debug_asserts = false, // Disable for accurate benchmarks
    },
};

const BenchWorld = world_mod.World(BenchConfig);

// ============================================================================
// Timing Utilities - Using New Infrastructure
// ============================================================================

/// Re-export BenchResult from new infrastructure for external use.
/// The new BenchResult includes statistical percentiles (p50, p90, p99).
const BenchResult = bench.BenchResult;

/// Re-export Stats for direct access to statistical data.
const Stats = bench.Stats;

/// Deprecated: Legacy BenchResult struct - use bench.BenchResult instead.
/// Kept for backward compatibility with existing tests.
const LegacyBenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,

    fn avgNs(self: LegacyBenchResult) u64 {
        if (self.iterations == 0) return 0;
        return self.total_ns / self.iterations;
    }

    fn opsPerSec(self: LegacyBenchResult) u64 {
        if (self.avgNs() == 0) return 0;
        return @divFloor(1_000_000_000, self.avgNs());
    }
};

// ============================================================================
// Benchmark Configuration Constants
// ============================================================================

/// Warm-up iterations before measurement (results discarded).
/// Why: eliminates JIT/cache warm-up variance from measurements.
const WARMUP_ITERATIONS: u32 = 100;

/// Number of measurement samples to collect per benchmark.
/// Bounded by stats.MAX_STACK_SAMPLES for stack-based processing.
const MEASUREMENT_ITERATIONS: u32 = 1000;

// ============================================================================
// Benchmark Tests (run as part of test suite for verification)
// ============================================================================

test "bench: entity spawn throughput" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    const iterations: u64 = 1000;
    var handles: [1000]entity.EntityHandle = undefined;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        handles[i] = try world.spawn("static", .{Position{}});
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_spawn = elapsed / iterations;

    // Cleanup
    for (handles[0..iterations]) |h| {
        try world.despawn(h);
    }

    // Verify reasonable performance (should be < 10us per spawn)
    try testing.expect(ns_per_spawn < 10_000);
}

test "bench: entity despawn throughput" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    const iterations: u64 = 1000;
    var handles: [1000]entity.EntityHandle = undefined;

    // Spawn first
    for (0..iterations) |i| {
        handles[i] = try world.spawn("static", .{Position{}});
    }

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        try world.despawn(handles[i]);
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_despawn = elapsed / iterations;

    // Verify reasonable performance (should be < 10us per despawn)
    try testing.expect(ns_per_despawn < 10_000);
}

test "bench: component access" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    var handles: [100]entity.EntityHandle = undefined;
    for (0..100) |i| {
        handles[i] = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        });
    }

    const iterations: u64 = 10000;
    var sum: f32 = 0;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        const handle = handles[i % 100];
        if (world.getComponent(handle, Position)) |pos| {
            sum += pos.x;
        }
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_access = elapsed / iterations;

    // Prevent optimization of sum
    try testing.expect(sum > 0);

    // Verify reasonable performance (should be < 1us per access)
    try testing.expect(ns_per_access < 1_000);
}

test "bench: component mutation" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    var handles: [100]entity.EntityHandle = undefined;
    for (0..100) |i| {
        handles[i] = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        });
    }

    const iterations: u64 = 10000;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        const handle = handles[i % 100];
        _ = world.setComponent(handle, Position, Position{ .x = @floatFromInt(i), .y = 0, .z = 0 });
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_mutation = elapsed / iterations;

    // Verify reasonable performance (should be < 1us per mutation)
    try testing.expect(ns_per_mutation < 1_000);
}

test "bench: hasComponent check" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    var handles: [100]entity.EntityHandle = undefined;
    for (0..100) |i| {
        handles[i] = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        });
    }

    const iterations: u64 = 10000;
    var has_count: u64 = 0;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        const handle = handles[i % 100];
        if (world.hasComponent(handle, Position)) {
            has_count += 1;
        }
        if (world.hasComponent(handle, Velocity)) {
            has_count += 1;
        }
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_check = elapsed / (iterations * 2);

    // Should have found all
    try testing.expectEqual(@as(u64, iterations * 2), has_count);

    // Verify reasonable performance (should be < 500ns per check)
    try testing.expect(ns_per_check < 500);
}

test "bench: isAlive check" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    var handles: [100]entity.EntityHandle = undefined;
    for (0..100) |i| {
        handles[i] = try world.spawn("static", .{Position{}});
    }

    const iterations: u64 = 10000;
    var alive_count: u64 = 0;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        const handle = handles[i % 100];
        if (world.isAlive(handle)) {
            alive_count += 1;
        }
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_check = elapsed / iterations;

    // Should all be alive
    try testing.expectEqual(@as(u64, iterations), alive_count);

    // Verify reasonable performance (should be < 200ns per check)
    try testing.expect(ns_per_check < 200);
}

test "bench: full entity with large component" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    const iterations: u64 = 500;
    var handles: [500]entity.EntityHandle = undefined;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        handles[i] = try world.spawn("full", .{
            Position{},
            Velocity{},
            Health{},
            Transform{}, // 64 bytes
        });
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_spawn = elapsed / iterations;

    // Cleanup
    for (handles[0..iterations]) |h| {
        try world.despawn(h);
    }

    // Large component spawn should still be < 50us
    try testing.expect(ns_per_spawn < 50_000);
}

// ============================================================================
// Summary Report (can be run standalone)
// ============================================================================

test "bench: print summary" {
    // This test verifies the new benchmark infrastructure works
    // Tests the Stats struct and BenchResult from new infrastructure
    const test_stats = Stats{
        .iterations = 100,
        .total_ns = 10000,
        .min_ns = 50,
        .max_ns = 200,
        .p50_ns = 100,
        .p75_ns = 120,
        .p90_ns = 150,
        .p99_ns = 180,
        .mean_ns = 100.0,
        .stddev_ns = 30.0,
    };

    const result = BenchResult{
        .name = "test",
        .stats = test_stats,
    };

    // Verify stats are accessible
    try testing.expectEqual(@as(u64, 100), result.stats.iterations);
    try testing.expectEqual(@as(u64, 10000), result.stats.total_ns);
    try testing.expectEqual(@as(u64, 50), result.stats.min_ns);
    try testing.expectEqual(@as(u64, 200), result.stats.max_ns);
    try testing.expectEqual(@as(u64, 100), result.stats.p50_ns);

    // Verify throughput calculation
    const ops_per_sec = bench.throughputOpsPerSec(result.stats);
    try testing.expectApproxEqAbs(@as(f64, 10_000_000.0), ops_per_sec, 1.0);
}

test "bench: legacy BenchResult compatibility" {
    // Verify backward compatibility with LegacyBenchResult
    const legacy = LegacyBenchResult{
        .name = "legacy_test",
        .iterations = 1000,
        .total_ns = 100000,
        .min_ns = 80,
        .max_ns = 150,
    };

    try testing.expectEqual(@as(u64, 100), legacy.avgNs());
    try testing.expectEqual(@as(u64, 10_000_000), legacy.opsPerSec());
}

// ============================================================================
// Benchmark Runner Functions (TigerStyle: extracted from main for ≤70 lines)
// ============================================================================

/// Total number of benchmarks produced by all runner functions.
/// Used for static result array sizing - avoids dynamic allocation.
const TOTAL_BENCHMARK_COUNT: usize = 7;

/// Entity pool size for component benchmarks - balances memory vs cache effects.
const ENTITY_POOL_SIZE: usize = 100;

/// Maximum handles for entity spawn/despawn benchmarks.
const MAX_ENTITY_HANDLES: usize = 2000;

/// Prints the benchmark suite header banner.
/// Pure output function - no side effects beyond printing.
fn printHeader() void {
    const print = std.debug.print;

    // TigerStyle: assertions verify function invariants
    std.debug.assert(@sizeOf(BenchResult) > 0); // BenchResult type must be valid
    std.debug.assert(TOTAL_BENCHMARK_COUNT == 7); // Configured for 7 benchmarks
    std.debug.assert(WARMUP_ITERATIONS > 0);
    std.debug.assert(MEASUREMENT_ITERATIONS > 0);
    std.debug.assert(MEASUREMENT_ITERATIONS <= bench.MAX_SAMPLES);

    print("\n", .{});
    print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    print("║               StaticECS Benchmark Suite                          ║\n", .{});
    print("║         Running with warm-up and statistical analysis            ║\n", .{});
    print("╚══════════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});
}

/// Runs entity spawn and despawn benchmarks with warm-up phase.
/// Returns array of 2 results: [spawn, despawn] with full statistics.
/// Why separate: entity lifecycle is fundamental ECS operation, measured in isolation.
fn runEntityBenchmarks(allocator: std.mem.Allocator) [2]BenchResult {
    // TigerStyle: validate configuration constants
    std.debug.assert(MAX_ENTITY_HANDLES > 0);
    std.debug.assert(WARMUP_ITERATIONS + MEASUREMENT_ITERATIONS <= MAX_ENTITY_HANDLES);

    var spawn_samples: [bench.MAX_SAMPLES]u64 = undefined;
    var despawn_samples: [bench.MAX_SAMPLES]u64 = undefined;

    // Run spawn benchmark with warm-up
    {
        // Warm-up phase: spawn/despawn to prime caches
        for (0..WARMUP_ITERATIONS) |_| {
            var world = BenchWorld.init(allocator);
            const h = world.spawn("static", .{Position{}}) catch continue;
            world.despawn(h) catch {};
            world.deinit();
        }

        // Measurement phase: collect individual spawn timings
        for (0..MEASUREMENT_ITERATIONS) |i| {
            var world = BenchWorld.init(allocator);
            defer world.deinit();
            const start = time.Instant.now() catch continue;
            _ = world.spawn("static", .{Position{}}) catch continue;
            const end = time.Instant.now() catch continue;
            spawn_samples[i] = end.since(start);
        }
    }

    // Run despawn benchmark with warm-up
    {
        // Warm-up phase
        for (0..WARMUP_ITERATIONS) |_| {
            var world = BenchWorld.init(allocator);
            const h = world.spawn("static", .{Position{}}) catch continue;
            world.despawn(h) catch {};
            world.deinit();
        }

        // Measurement phase: collect individual despawn timings
        for (0..MEASUREMENT_ITERATIONS) |i| {
            var world = BenchWorld.init(allocator);
            const h = world.spawn("static", .{Position{}}) catch {
                despawn_samples[i] = 0;
                world.deinit();
                continue;
            };
            const start = time.Instant.now() catch {
                despawn_samples[i] = 0;
                world.deinit();
                continue;
            };
            world.despawn(h) catch {};
            const end = time.Instant.now() catch {
                despawn_samples[i] = 0;
                world.deinit();
                continue;
            };
            despawn_samples[i] = end.since(start);
            world.deinit();
        }
    }

    // Calculate statistics using new infrastructure
    const spawn_stats = bench.calculateStats(spawn_samples[0..MEASUREMENT_ITERATIONS]);
    const despawn_stats = bench.calculateStats(despawn_samples[0..MEASUREMENT_ITERATIONS]);

    return .{
        BenchResult{ .name = "entity_spawn", .stats = spawn_stats },
        BenchResult{ .name = "entity_despawn", .stats = despawn_stats },
    };
}

/// Runs component access benchmark with warm-up phase.
/// Measures getComponent() latency with statistical analysis.
fn runComponentAccessBenchmark(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(ENTITY_POOL_SIZE > 0 and ENTITY_POOL_SIZE <= 100);

    var samples: [bench.MAX_SAMPLES]u64 = undefined;
    var world = BenchWorld.init(allocator);
    defer world.deinit();

    // Setup: spawn entity pool
    var handles: [100]entity.EntityHandle = undefined;
    for (0..ENTITY_POOL_SIZE) |i| {
        handles[i] = world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        }) catch break;
    }

    // Warm-up phase
    for (0..WARMUP_ITERATIONS) |i| {
        const h = handles[i % ENTITY_POOL_SIZE];
        if (world.getComponent(h, Position)) |pos| {
            std.mem.doNotOptimizeAway(pos.x);
        }
    }

    // Measurement phase: time each access individually
    for (0..MEASUREMENT_ITERATIONS) |i| {
        const h = handles[i % ENTITY_POOL_SIZE];
        const start = time.Instant.now() catch continue;
        if (world.getComponent(h, Position)) |pos| {
            std.mem.doNotOptimizeAway(pos.x);
        }
        const end = time.Instant.now() catch continue;
        samples[i] = end.since(start);
    }

    return BenchResult{
        .name = "component_access",
        .stats = bench.calculateStats(samples[0..MEASUREMENT_ITERATIONS]),
    };
}

/// Runs component mutation benchmark with warm-up phase.
/// Measures setComponent() latency with statistical analysis.
fn runComponentMutationBenchmark(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(ENTITY_POOL_SIZE > 0 and ENTITY_POOL_SIZE <= 100);

    var samples: [bench.MAX_SAMPLES]u64 = undefined;
    var world = BenchWorld.init(allocator);
    defer world.deinit();

    // Setup: spawn entity pool
    var handles: [100]entity.EntityHandle = undefined;
    for (0..ENTITY_POOL_SIZE) |i| {
        handles[i] = world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        }) catch break;
    }

    // Warm-up phase
    for (0..WARMUP_ITERATIONS) |i| {
        const h = handles[i % ENTITY_POOL_SIZE];
        _ = world.setComponent(h, Position, Position{ .x = @floatFromInt(i), .y = 0, .z = 0 });
    }

    // Measurement phase
    for (0..MEASUREMENT_ITERATIONS) |i| {
        const h = handles[i % ENTITY_POOL_SIZE];
        const start = time.Instant.now() catch continue;
        _ = world.setComponent(h, Position, Position{ .x = @floatFromInt(i), .y = 0, .z = 0 });
        const end = time.Instant.now() catch continue;
        samples[i] = end.since(start);
    }

    return BenchResult{
        .name = "component_mutation",
        .stats = bench.calculateStats(samples[0..MEASUREMENT_ITERATIONS]),
    };
}

/// Runs component access and mutation benchmarks with warm-up phase.
/// Returns array of 2 results: [access, mutation] with full statistics.
fn runComponentBenchmarks(allocator: std.mem.Allocator) [2]BenchResult {
    return .{
        runComponentAccessBenchmark(allocator),
        runComponentMutationBenchmark(allocator),
    };
}

/// Runs hasComponent benchmark with warm-up phase.
fn runHasComponentBenchmark(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(ENTITY_POOL_SIZE > 0);

    var samples: [bench.MAX_SAMPLES]u64 = undefined;
    var world = BenchWorld.init(allocator);
    defer world.deinit();

    var handles: [100]entity.EntityHandle = undefined;
    for (0..ENTITY_POOL_SIZE) |i| {
        handles[i] = world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        }) catch break;
    }

    // Warm-up phase
    for (0..WARMUP_ITERATIONS) |i| {
        const h = handles[i % ENTITY_POOL_SIZE];
        std.mem.doNotOptimizeAway(world.hasComponent(h, Position));
    }

    // Measurement phase
    for (0..MEASUREMENT_ITERATIONS) |i| {
        const h = handles[i % ENTITY_POOL_SIZE];
        const start = time.Instant.now() catch continue;
        std.mem.doNotOptimizeAway(world.hasComponent(h, Position));
        const end = time.Instant.now() catch continue;
        samples[i] = end.since(start);
    }

    return BenchResult{
        .name = "hasComponent_check",
        .stats = bench.calculateStats(samples[0..MEASUREMENT_ITERATIONS]),
    };
}

/// Runs isAlive benchmark with warm-up phase.
fn runIsAliveBenchmark(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(ENTITY_POOL_SIZE > 0);

    var samples: [bench.MAX_SAMPLES]u64 = undefined;
    var world = BenchWorld.init(allocator);
    defer world.deinit();

    var handles: [100]entity.EntityHandle = undefined;
    for (0..ENTITY_POOL_SIZE) |i| {
        handles[i] = world.spawn("static", .{Position{}}) catch break;
    }

    // Warm-up phase
    for (0..WARMUP_ITERATIONS) |i| {
        const h = handles[i % ENTITY_POOL_SIZE];
        std.mem.doNotOptimizeAway(world.isAlive(h));
    }

    // Measurement phase
    for (0..MEASUREMENT_ITERATIONS) |i| {
        const h = handles[i % ENTITY_POOL_SIZE];
        const start = time.Instant.now() catch continue;
        std.mem.doNotOptimizeAway(world.isAlive(h));
        const end = time.Instant.now() catch continue;
        samples[i] = end.since(start);
    }

    return BenchResult{
        .name = "isAlive_check",
        .stats = bench.calculateStats(samples[0..MEASUREMENT_ITERATIONS]),
    };
}

/// Runs query operation benchmarks with warm-up phase.
/// Returns array of 2 results: [hasComponent, isAlive] with full statistics.
fn runQueryBenchmarks(allocator: std.mem.Allocator) [2]BenchResult {
    return .{
        runHasComponentBenchmark(allocator),
        runIsAliveBenchmark(allocator),
    };
}

/// Runs archetype benchmark with full component set (all 4 components).
/// Returns single result for full entity spawn with warm-up and statistics.
/// Why separate: tests worst-case spawn with maximum component count.
fn runArchetypeBenchmarks(allocator: std.mem.Allocator) BenchResult {
    // TigerStyle: validate configuration
    std.debug.assert(BenchConfig.components.types.len == 4); // Full archetype uses all 4

    var samples: [bench.MAX_SAMPLES]u64 = undefined;

    // Warm-up phase: spawn full entities to prime allocators and caches
    for (0..WARMUP_ITERATIONS) |_| {
        var world = BenchWorld.init(allocator);
        _ = world.spawn("full", .{ Position{}, Velocity{}, Health{}, Transform{} }) catch {};
        world.deinit();
    }

    // Measurement phase: time each full entity spawn individually
    for (0..MEASUREMENT_ITERATIONS) |i| {
        var world = BenchWorld.init(allocator);
        defer world.deinit();
        const start = time.Instant.now() catch continue;
        _ = world.spawn("full", .{ Position{}, Velocity{}, Health{}, Transform{} }) catch continue;
        const end = time.Instant.now() catch continue;
        samples[i] = end.since(start);
    }

    return BenchResult{
        .name = "full_entity_spawn",
        .stats = bench.calculateStats(samples[0..MEASUREMENT_ITERATIONS]),
    };
}

/// Prints formatted benchmark results with percentile statistics.
/// Pure output function - takes immutable results slice.
fn printResults(results: []const BenchResult) void {
    const print = std.debug.print;

    // TigerStyle: validate input
    std.debug.assert(results.len > 0);
    std.debug.assert(results.len <= TOTAL_BENCHMARK_COUNT);

    // Print header with percentile columns
    print("┌────────────────────────┬─────────┬─────────┬─────────┬─────────┬─────────┬──────────────┐\n", .{});
    print("│ Benchmark              │ min(ns) │ p50(ns) │ p90(ns) │ p99(ns) │ max(ns) │ ops/sec      │\n", .{});
    print("├────────────────────────┼─────────┼─────────┼─────────┼─────────┼─────────┼──────────────┤\n", .{});

    for (results) |result| {
        const ops_per_sec = bench.throughputOpsPerSec(result.stats);
        print("│ {s:<22} │ {d:>7} │ {d:>7} │ {d:>7} │ {d:>7} │ {d:>7} │ {d:>12.1} │\n", .{
            result.name,
            result.stats.min_ns,
            result.stats.p50_ns,
            result.stats.p90_ns,
            result.stats.p99_ns,
            result.stats.max_ns,
            ops_per_sec,
        });
    }

    print("└────────────────────────┴─────────┴─────────┴─────────┴─────────┴─────────┴──────────────┘\n", .{});
    print("\n", .{});

    // Print additional statistics summary
    printStatsSummary(results);
}

/// Prints additional statistics summary (mean, stddev) for all benchmarks.
fn printStatsSummary(results: []const BenchResult) void {
    const print = std.debug.print;

    print("Additional Statistics:\n", .{});
    print("┌────────────────────────┬───────────────┬───────────────┐\n", .{});
    print("│ Benchmark              │ mean(ns)      │ stddev(ns)    │\n", .{});
    print("├────────────────────────┼───────────────┼───────────────┤\n", .{});

    for (results) |result| {
        print("│ {s:<22} │ {d:>13.1} │ {d:>13.1} │\n", .{
            result.name,
            result.stats.mean_ns,
            result.stats.stddev_ns,
        });
    }

    print("└────────────────────────┴───────────────┴───────────────┘\n", .{});
    print("\n", .{});
}

// ============================================================================
// Executable Entry Point (for `zig build benchmark`)
// ============================================================================

/// Main entry point for benchmark executable.
/// TigerStyle: orchestrator-only function - delegates to pure helpers.
/// Runs in ReleaseFast mode via `zig build benchmark`.
pub fn main() !void {
    // TigerStyle: validate benchmark configuration at startup
    std.debug.assert(TOTAL_BENCHMARK_COUNT == 7); // Expected benchmark count
    std.debug.assert(BenchConfig.components.types.len == 4); // Position, Velocity, Health, Transform
    std.debug.assert(WARMUP_ITERATIONS > 0);
    std.debug.assert(MEASUREMENT_ITERATIONS > 0);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Print header banner
    printHeader();

    // Collect results from all benchmark categories
    var results: [TOTAL_BENCHMARK_COUNT]BenchResult = undefined;
    var idx: usize = 0;

    // Entity lifecycle benchmarks (spawn/despawn)
    const entity_results = runEntityBenchmarks(allocator);
    results[idx] = entity_results[0];
    idx += 1;
    results[idx] = entity_results[1];
    idx += 1;

    // Component operation benchmarks (access/mutation)
    const component_results = runComponentBenchmarks(allocator);
    results[idx] = component_results[0];
    idx += 1;
    results[idx] = component_results[1];
    idx += 1;

    // Query operation benchmarks (hasComponent/isAlive)
    const query_results = runQueryBenchmarks(allocator);
    results[idx] = query_results[0];
    idx += 1;
    results[idx] = query_results[1];
    idx += 1;

    // Archetype benchmark (full entity with all components)
    results[idx] = runArchetypeBenchmarks(allocator);
    idx += 1;

    // TigerStyle: verify all benchmarks were collected
    std.debug.assert(idx == TOTAL_BENCHMARK_COUNT);

    // Print formatted results table with percentile statistics
    printResults(results[0..idx]);
}
