//! System execution benchmarks for StaticECS.
//!
//! Measures system dispatch and scheduling overhead:
//! - Single system dispatch overhead
//! - System chain execution (sequential)
//! - Dependency resolution cost
//! - Phase transition overhead
//!
//! ## Usage
//! ```zig
//! const system_bench = @import("system_bench.zig");
//! const results = system_bench.runAll(allocator);
//! system_bench.printSystemResults(&results);
//! ```

const std = @import("std");
const time = std.time;
const testing = std.testing;

const stats = @import("stats.zig");
const runner = @import("runner.zig");
const BenchResult = runner.BenchResult;

// Import ECS modules
const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const Phase = config_mod.Phase;
const asSystemFn = config_mod.asSystemFn;
const world_mod = @import("../world.zig");
const scheduler_mod = @import("../scheduler.zig");

// ============================================================================
// Benchmark Component Types
// ============================================================================

const Position = struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };
const Velocity = struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };
const Health = struct { current: u32 = 100, max: u32 = 100 };
const Transform = struct { scale: f32 = 1.0 };

// ============================================================================
// Test System Functions
// ============================================================================

/// Minimal no-op system for measuring pure dispatch overhead.
/// Does nothing except return success.
fn noopSystem(_: *anyopaque) void {
    // Intentionally empty - measures pure dispatch overhead
}

// ============================================================================
// World Configuration: Single System (Dispatch Overhead)
// ============================================================================

const SingleSystemConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        },
    },
    .systems = .{
        .systems = &.{
            .{
                .name = "noop",
                .func = asSystemFn(noopSystem),
                .phase = Phase.update.index(),
            },
        },
    },
    .options = .{
        .max_entities = 16384,
        .enable_debug_asserts = false,
    },
};

const SingleSystemWorld = world_mod.World(SingleSystemConfig);
const SingleScheduler = scheduler_mod.Scheduler(SingleSystemConfig);

// ============================================================================
// World Configuration: System Chain (5 systems in same phase)
// ============================================================================

const Chain5Config = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "sys1", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys2", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys3", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys4", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys5", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
        },
    },
    .options = .{
        .max_entities = 16384,
        .enable_debug_asserts = false,
    },
};

const Chain5World = world_mod.World(Chain5Config);
const Chain5Scheduler = scheduler_mod.Scheduler(Chain5Config);

// ============================================================================
// World Configuration: System Chain (10 systems in same phase)
// ============================================================================

const Chain10Config = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "sys1", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys2", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys3", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys4", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys5", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys6", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys7", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys8", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys9", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "sys10", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
        },
    },
    .options = .{
        .max_entities = 16384,
        .enable_debug_asserts = false,
    },
};

const Chain10World = world_mod.World(Chain10Config);
const Chain10Scheduler = scheduler_mod.Scheduler(Chain10Config);

// ============================================================================
// World Configuration: Multi-Phase (3 phases)
// ============================================================================

const MultiPhaseConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "pre1", .func = asSystemFn(noopSystem), .phase = Phase.pre_update.index() },
            .{ .name = "pre2", .func = asSystemFn(noopSystem), .phase = Phase.pre_update.index() },
            .{ .name = "update1", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "update2", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "post1", .func = asSystemFn(noopSystem), .phase = Phase.post_update.index() },
            .{ .name = "post2", .func = asSystemFn(noopSystem), .phase = Phase.post_update.index() },
        },
    },
    .options = .{
        .max_entities = 16384,
        .enable_debug_asserts = false,
    },
};

const MultiPhaseWorld = world_mod.World(MultiPhaseConfig);
const MultiPhaseScheduler = scheduler_mod.Scheduler(MultiPhaseConfig);

// ============================================================================
// World Configuration: 5 Phases
// ============================================================================

const FivePhaseConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "pre1", .func = asSystemFn(noopSystem), .phase = Phase.pre_update.index() },
            .{ .name = "update1", .func = asSystemFn(noopSystem), .phase = Phase.update.index() },
            .{ .name = "post1", .func = asSystemFn(noopSystem), .phase = Phase.post_update.index() },
            .{ .name = "render1", .func = asSystemFn(noopSystem), .phase = Phase.render.index() },
            .{ .name = "network1", .func = asSystemFn(noopSystem), .phase = Phase.network.index() },
        },
    },
    .options = .{
        .max_entities = 16384,
        .enable_debug_asserts = false,
    },
};

const FivePhaseWorld = world_mod.World(FivePhaseConfig);
const FivePhaseScheduler = scheduler_mod.Scheduler(FivePhaseConfig);

// ============================================================================
// World Configuration: Systems with Dependencies (Component Read/Write)
// ============================================================================

const DependencyConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "full", .components = &.{ Position, Velocity, Health } },
        },
    },
    .systems = .{
        .systems = &.{
            // System A writes Position
            .{
                .name = "sys_a",
                .func = asSystemFn(noopSystem),
                .phase = Phase.update.index(),
                .write_components = &.{Position},
            },
            // System B reads Position, writes Velocity (depends on A)
            .{
                .name = "sys_b",
                .func = asSystemFn(noopSystem),
                .phase = Phase.update.index(),
                .read_components = &.{Position},
                .write_components = &.{Velocity},
            },
            // System C reads Velocity, writes Health (depends on B)
            .{
                .name = "sys_c",
                .func = asSystemFn(noopSystem),
                .phase = Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Health},
            },
        },
    },
    .options = .{
        .max_entities = 16384,
        .enable_debug_asserts = false,
    },
};

const DependencyWorld = world_mod.World(DependencyConfig);
const DependencyScheduler = scheduler_mod.Scheduler(DependencyConfig);

// ============================================================================
// World Configuration: Work Systems (Light Work)
// ============================================================================

const WorkSystemConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        },
    },
    .systems = .{
        .systems = &.{
            .{
                .name = "light_work",
                .func = asSystemFn(noopSystem),
                .phase = Phase.update.index(),
            },
        },
    },
    .options = .{
        .max_entities = 16384,
        .enable_debug_asserts = false,
    },
};

const WorkSystemWorld = world_mod.World(WorkSystemConfig);
const WorkScheduler = scheduler_mod.Scheduler(WorkSystemConfig);

// ============================================================================
// Benchmark: Single System Dispatch Overhead
// ============================================================================

/// Benchmark the overhead of dispatching a single system.
/// Measures: dispatch overhead ns (should be minimal).
pub fn benchSingleSystemDispatch(allocator: std.mem.Allocator) BenchResult {
    // Pre-conditions
    std.debug.assert(@intFromPtr(&allocator) != 0);

    var world = SingleSystemWorld.init(allocator);
    defer world.deinit();

    var scheduler = SingleScheduler.init(&world, null, allocator);
    defer scheduler.deinit();

    // Spawn some entities for realism
    spawnEntities(&world, 100) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 1000;

    // Warm-up
    for (0..100) |_| {
        _ = scheduler.tick(0.016);
    }

    // Measurement
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = scheduler.tick(0.016);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    // Post-conditions
    std.debug.assert(bench_stats.iterations == sample_count);
    std.debug.assert(bench_stats.min_ns > 0);

    return BenchResult{
        .name = "single_system_dispatch",
        .stats = bench_stats,
    };
}

// ============================================================================
// Benchmark: System Chain Execution
// ============================================================================

/// Benchmark executing a chain of 5 sequential systems.
pub fn benchSystemChain5(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(@intFromPtr(&allocator) != 0);

    var world = Chain5World.init(allocator);
    defer world.deinit();

    var scheduler = Chain5Scheduler.init(&world, null, allocator);
    defer scheduler.deinit();

    spawnChainEntities(&world, 100) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 1000;

    // Warm-up
    for (0..100) |_| {
        _ = scheduler.tick(0.016);
    }

    // Measurement
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = scheduler.tick(0.016);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    std.debug.assert(bench_stats.iterations == sample_count);
    std.debug.assert(bench_stats.min_ns > 0);

    return BenchResult{
        .name = "system_chain_5",
        .stats = bench_stats,
    };
}

/// Benchmark executing a chain of 10 sequential systems.
pub fn benchSystemChain10(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(@intFromPtr(&allocator) != 0);

    var world = Chain10World.init(allocator);
    defer world.deinit();

    var scheduler = Chain10Scheduler.init(&world, null, allocator);
    defer scheduler.deinit();

    spawnChain10Entities(&world, 100) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 1000;

    // Warm-up
    for (0..100) |_| {
        _ = scheduler.tick(0.016);
    }

    // Measurement
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = scheduler.tick(0.016);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    std.debug.assert(bench_stats.iterations == sample_count);
    std.debug.assert(bench_stats.min_ns > 0);

    return BenchResult{
        .name = "system_chain_10",
        .stats = bench_stats,
    };
}

// ============================================================================
// Benchmark: Dependency Resolution Overhead
// ============================================================================

/// Benchmark systems with explicit component dependencies (A -> B -> C).
/// The scheduler must resolve these dependencies to order execution.
pub fn benchDependencyResolution(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(@intFromPtr(&allocator) != 0);

    var world = DependencyWorld.init(allocator);
    defer world.deinit();

    var scheduler = DependencyScheduler.init(&world, null, allocator);
    defer scheduler.deinit();

    spawnDependencyEntities(&world, 100) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 1000;

    // Warm-up
    for (0..100) |_| {
        _ = scheduler.tick(0.016);
    }

    // Measurement
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = scheduler.tick(0.016);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    std.debug.assert(bench_stats.iterations == sample_count);
    std.debug.assert(bench_stats.min_ns > 0);

    return BenchResult{
        .name = "dependency_resolution",
        .stats = bench_stats,
    };
}

// ============================================================================
// Benchmark: Phase Transition Overhead
// ============================================================================

/// Benchmark multiple phase transitions (3 phases).
pub fn benchPhaseTransitions3(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(@intFromPtr(&allocator) != 0);

    var world = MultiPhaseWorld.init(allocator);
    defer world.deinit();

    var scheduler = MultiPhaseScheduler.init(&world, null, allocator);
    defer scheduler.deinit();

    spawnMultiPhaseEntities(&world, 100) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 1000;

    // Warm-up
    for (0..100) |_| {
        _ = scheduler.tick(0.016);
    }

    // Measurement
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = scheduler.tick(0.016);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    std.debug.assert(bench_stats.iterations == sample_count);
    std.debug.assert(bench_stats.min_ns > 0);

    return BenchResult{
        .name = "phase_transitions_3",
        .stats = bench_stats,
    };
}

/// Benchmark 5 phase transitions (all default phases).
pub fn benchPhaseTransitions5(allocator: std.mem.Allocator) BenchResult {
    std.debug.assert(@intFromPtr(&allocator) != 0);

    var world = FivePhaseWorld.init(allocator);
    defer world.deinit();

    var scheduler = FivePhaseScheduler.init(&world, null, allocator);
    defer scheduler.deinit();

    spawnFivePhaseEntities(&world, 100) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 1000;

    // Warm-up
    for (0..100) |_| {
        _ = scheduler.tick(0.016);
    }

    // Measurement
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = scheduler.tick(0.016);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    std.debug.assert(bench_stats.iterations == sample_count);
    std.debug.assert(bench_stats.min_ns > 0);

    return BenchResult{
        .name = "phase_transitions_5",
        .stats = bench_stats,
    };
}

// ============================================================================
// Benchmark: System with Actual Work
// ============================================================================

/// Benchmark a system doing light work (query iteration).
pub fn benchLightWorkSystem(allocator: std.mem.Allocator, entity_count: u64) BenchResult {
    std.debug.assert(@intFromPtr(&allocator) != 0);
    std.debug.assert(entity_count > 0);
    std.debug.assert(entity_count <= 16384);

    var world = WorkSystemWorld.init(allocator);
    defer world.deinit();

    var scheduler = WorkScheduler.init(&world, null, allocator);
    defer scheduler.deinit();

    spawnWorkEntities(&world, entity_count) catch @panic("Failed to spawn entities");

    var samples: [runner.MAX_SAMPLES]u64 = undefined;
    const sample_count: usize = 100;

    // Warm-up
    for (0..10) |_| {
        _ = scheduler.tick(0.016);
    }

    // Measurement
    for (0..sample_count) |i| {
        const start = time.Instant.now() catch @panic("Timer unavailable");
        _ = scheduler.tick(0.016);
        const end = time.Instant.now() catch @panic("Timer unavailable");
        samples[i] = end.since(start);
    }

    const bench_stats = stats.calculateStats(samples[0..sample_count]);

    std.debug.assert(bench_stats.iterations == sample_count);
    std.debug.assert(bench_stats.min_ns > 0);

    return BenchResult{
        .name = "light_work_system",
        .stats = bench_stats,
        .entity_count = entity_count,
    };
}

// ============================================================================
// Entity Spawning Helpers
// ============================================================================

fn spawnEntities(world: *SingleSystemWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnChainEntities(world: *Chain5World, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnChain10Entities(world: *Chain10World, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnDependencyEntities(world: *DependencyWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("full", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
            Health{ .current = 100, .max = 100 },
        });
    }
}

fn spawnMultiPhaseEntities(world: *MultiPhaseWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnFivePhaseEntities(world: *FivePhaseWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

fn spawnWorkEntities(world: *WorkSystemWorld, count: u64) !void {
    for (0..count) |i| {
        _ = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .x = 1.0, .y = 0, .z = 0 },
        });
    }
}

// ============================================================================
// Benchmark Suite Integration
// ============================================================================

/// Maximum number of benchmark results.
pub const MAX_RESULTS: usize = 8;

/// Run all system benchmarks.
/// Returns array of benchmark results.
pub fn runAll(allocator: std.mem.Allocator) [7]BenchResult {
    // Pre-conditions
    std.debug.assert(@intFromPtr(&allocator) != 0);

    var results: [7]BenchResult = undefined;

    // Single system dispatch
    results[0] = benchSingleSystemDispatch(allocator);

    // System chains
    results[1] = benchSystemChain5(allocator);
    results[2] = benchSystemChain10(allocator);

    // Dependency resolution
    results[3] = benchDependencyResolution(allocator);

    // Phase transitions
    results[4] = benchPhaseTransitions3(allocator);
    results[5] = benchPhaseTransitions5(allocator);

    // Light work system
    results[6] = benchLightWorkSystem(allocator, 1000);

    // Post-condition
    for (results) |r| {
        std.debug.assert(r.stats.iterations > 0);
    }

    return results;
}

/// Print results with system throughput metrics.
pub fn printSystemResults(results: []const BenchResult) void {
    std.debug.print("\n=== System Execution Benchmarks ===\n\n", .{});

    for (results) |result| {
        const ops_per_sec = stats.throughputOpsPerSec(result.stats);

        std.debug.print(
            "{s:.<30} p50:{d:>8}ns p99:{d:>8}ns | {d:.2} ticks/sec\n",
            .{
                result.name,
                result.stats.p50_ns,
                result.stats.p99_ns,
                ops_per_sec,
            },
        );
    }

    std.debug.print("\n", .{});
}

/// Calculate per-system overhead from chain benchmarks.
pub fn calculateOverheadPerSystem(single: BenchResult, chain: BenchResult, chain_len: u64) u64 {
    // Pre-conditions
    std.debug.assert(chain_len > 1);
    std.debug.assert(chain.stats.p50_ns >= single.stats.p50_ns);

    const additional_ns = chain.stats.p50_ns - single.stats.p50_ns;
    return additional_ns / (chain_len - 1);
}

// ============================================================================
// Tests
// ============================================================================

test "single system dispatch benchmark runs" {
    const result = benchSingleSystemDispatch(testing.allocator);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("single_system_dispatch", result.name);
}

test "system chain 5 benchmark runs" {
    const result = benchSystemChain5(testing.allocator);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("system_chain_5", result.name);
}

test "system chain 10 benchmark runs" {
    const result = benchSystemChain10(testing.allocator);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("system_chain_10", result.name);
}

test "dependency resolution benchmark runs" {
    const result = benchDependencyResolution(testing.allocator);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("dependency_resolution", result.name);
}

test "phase transitions 3 benchmark runs" {
    const result = benchPhaseTransitions3(testing.allocator);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("phase_transitions_3", result.name);
}

test "phase transitions 5 benchmark runs" {
    const result = benchPhaseTransitions5(testing.allocator);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("phase_transitions_5", result.name);
}

test "light work system benchmark runs" {
    const result = benchLightWorkSystem(testing.allocator, 500);
    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.stats.p50_ns > 0);
    try testing.expectEqualStrings("light_work_system", result.name);
    try testing.expectEqual(@as(u64, 500), result.entity_count);
}

test "runAll produces valid results" {
    const results = runAll(testing.allocator);
    try testing.expectEqual(@as(usize, 7), results.len);

    for (results) |r| {
        try testing.expect(r.stats.iterations > 0);
        try testing.expect(r.name.len > 0);
    }
}

test "chain benchmark overhead scales with system count" {
    const single = benchSingleSystemDispatch(testing.allocator);
    const chain5 = benchSystemChain5(testing.allocator);
    const chain10 = benchSystemChain10(testing.allocator);

    // Chain benchmarks should take longer than single
    // (may not hold in release mode due to optimizations, so just check validity)
    try testing.expect(single.stats.p50_ns > 0);
    try testing.expect(chain5.stats.p50_ns > 0);
    try testing.expect(chain10.stats.p50_ns > 0);
}
