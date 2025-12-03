//! Multi-threaded benchmark utilities.
//!
//! Tests parallel execution and thread scaling:
//! - Backend comparison (work_stealing vs blocking)
//! - Thread count scaling efficiency
//! - Parallel system execution
//! - Contention detection
//!
//! ## Usage
//! ```zig
//! const threaded = @import("threaded_bench.zig");
//! const results = threaded.runThreadScaling(allocator, 10_000);
//! threaded.printThreadScalingResults(&results);
//! ```

const std = @import("std");
const time = std.time;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const stats = @import("stats.zig");
const runner = @import("runner.zig");
const BenchResult = runner.BenchResult;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const ExecutionModel = config_mod.ExecutionModel;
const WorkStealingConfig = config_mod.WorkStealingConfig;

const world_mod = @import("../world.zig");
const QuerySpec = world_mod.QuerySpec;

// ============================================================================
// Thread Count Constants
// ============================================================================

/// Thread counts for scaling tests.
/// Tests 1, 2, 4, 8 threads to measure scaling efficiency.
pub const THREAD_COUNTS = [_]u8{ 1, 2, 4, 8 };

/// Maximum thread count supported (must match array size).
pub const MAX_THREAD_COUNT: u8 = 8;

/// Sample configuration for threaded benchmarks.
const SAMPLES_SMALL: usize = 50;
const SAMPLES_LARGE: usize = 10;
const SAMPLES_BUFFER_SIZE: usize = 64;

/// Default entity count for threaded benchmarks.
pub const DEFAULT_ENTITY_COUNT: u64 = 10_000;

// ============================================================================
// Component Types
// ============================================================================

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { vx: f32, vy: f32, vz: f32 };
const Health = struct { current: f32, max: f32 };

/// Cache line size for padding to prevent false sharing.
const CACHE_LINE_SIZE: usize = 64;

// ============================================================================
// Thread Scaling Result Types
// ============================================================================

/// Result for a single thread count measurement.
pub const ThreadResult = struct {
    thread_count: u8,
    time_ns: u64,
    speedup: f64,
    efficiency: f64,
};

/// Complete thread scaling results (one per THREAD_COUNTS entry).
pub const ThreadScalingResults = struct {
    results: [THREAD_COUNTS.len]ThreadResult,
    entity_count: u64,
    single_thread_time_ns: u64,
};

/// Backend comparison result.
pub const BackendComparisonResult = struct {
    blocking_time_ns: u64,
    work_stealing_time_ns: u64,
    speedup: f64,
    entity_count: u64,
    thread_count: u8,
};

/// Contention benchmark result.
pub const ContentionResult = struct {
    stats: stats.Stats,
    entity_count: u64,
    suspected_false_sharing: bool,
    variance_ratio: f64,
};

// ============================================================================
// Parallel Workload Simulation
// ============================================================================

/// Simulated work data for parallel benchmarks.
/// Padded to cache line to prevent false sharing in thread tests.
const WorkItem = struct {
    data: [CACHE_LINE_SIZE - @sizeOf(u64)]u8 align(CACHE_LINE_SIZE),
    value: u64,

    pub fn init() WorkItem {
        return .{
            .data = undefined,
            .value = 0,
        };
    }
};

/// Simulates CPU-bound work (position+velocity update pattern).
/// This represents a typical ECS system workload.
fn simulateWork(items: []WorkItem, start: usize, end: usize) void {
    // Pre-conditions
    std.debug.assert(end <= items.len);
    std.debug.assert(start <= end);

    // Simulate position += velocity * dt physics update
    const dt: f32 = 0.016;
    for (items[start..end]) |*item| {
        // Compute-bound work similar to ECS system
        var sum: f32 = 0;
        for (&item.data) |*b| {
            sum += @as(f32, @floatFromInt(b.*)) * dt;
            b.* = @truncate(@as(u32, @intFromFloat(@abs(sum) * 255)) % 256);
        }
        item.value +%= 1;
    }
}

/// Thread worker context for parallel execution.
const WorkerContext = struct {
    items: []WorkItem,
    start: usize,
    end: usize,
    completion_signal: *std.atomic.Value(u32),
};

/// Worker thread function.
fn workerThread(ctx: WorkerContext) void {
    simulateWork(ctx.items, ctx.start, ctx.end);
    _ = ctx.completion_signal.fetchAdd(1, .release);
}

// ============================================================================
// Thread Scaling Benchmark
// ============================================================================

/// Benchmark thread scaling (1, 2, 4, 8 threads).
/// Measures how well the workload scales with additional threads.
///
/// Pre-conditions:
/// - entity_count > 0
/// - allocator is valid
///
/// Post-conditions:
/// - Returns scaling results for all thread counts
/// - efficiency is in range [0, N] where N is thread count (>1 = superlinear, rare)
pub fn benchThreadScaling(allocator: Allocator, entity_count: u64) ThreadScalingResults {
    std.debug.assert(entity_count > 0);

    var output = ThreadScalingResults{
        .results = undefined,
        .entity_count = entity_count,
        .single_thread_time_ns = 0,
    };

    // Run benchmark for each thread count
    for (THREAD_COUNTS, 0..) |thread_count, i| {
        const time_ns = measureParallelExecution(allocator, entity_count, thread_count);
        output.results[i] = .{
            .thread_count = thread_count,
            .time_ns = time_ns,
            .speedup = 0,
            .efficiency = 0,
        };
    }

    // Calculate metrics based on single-thread baseline
    output.single_thread_time_ns = output.results[0].time_ns;
    for (&output.results) |*result| {
        if (result.time_ns > 0) {
            result.speedup = @as(f64, @floatFromInt(output.single_thread_time_ns)) /
                @as(f64, @floatFromInt(result.time_ns));
            result.efficiency = calculateEfficiency(
                output.single_thread_time_ns,
                result.time_ns,
                result.thread_count,
            );
        }
    }

    return output;
}

/// Measures parallel execution time with specified thread count.
fn measureParallelExecution(allocator: Allocator, entity_count: u64, thread_count: u8) u64 {
    std.debug.assert(thread_count > 0);
    std.debug.assert(thread_count <= MAX_THREAD_COUNT);

    const count = @as(usize, @intCast(@min(entity_count, 1_000_000)));

    // Allocate work items
    const items = allocator.alloc(WorkItem, count) catch return 0;
    defer allocator.free(items);

    // Initialize items
    for (items) |*item| {
        item.* = WorkItem.init();
    }

    // Run multiple samples and take median
    var samples: [SAMPLES_SMALL]u64 = undefined;

    for (0..SAMPLES_SMALL) |sample_idx| {
        const start = time.Instant.now() catch return 0;

        if (thread_count == 1) {
            // Single-threaded baseline
            simulateWork(items, 0, count);
        } else {
            // Multi-threaded execution
            runParallel(items, thread_count);
        }

        const end = time.Instant.now() catch return 0;
        samples[sample_idx] = end.since(start);
    }

    // Return median (p50)
    const bench_stats = stats.calculateStats(&samples);
    return bench_stats.p50_ns;
}

/// Run work in parallel across threads.
fn runParallel(items: []WorkItem, thread_count: u8) void {
    const count = items.len;
    const items_per_thread = count / thread_count;

    var completion = std.atomic.Value(u32).init(0);
    var threads: [MAX_THREAD_COUNT]?Thread = .{null} ** MAX_THREAD_COUNT;

    // Spawn worker threads (except last one runs on main thread)
    for (0..thread_count - 1) |i| {
        const start = i * items_per_thread;
        const end = start + items_per_thread;

        const ctx = WorkerContext{
            .items = items,
            .start = start,
            .end = end,
            .completion_signal = &completion,
        };

        threads[i] = Thread.spawn(.{}, workerThread, .{ctx}) catch null;
    }

    // Main thread handles last chunk (including remainder)
    const main_start = (thread_count - 1) * items_per_thread;
    simulateWork(items, main_start, count);
    _ = completion.fetchAdd(1, .release);

    // Wait for all worker threads
    while (completion.load(.acquire) < thread_count) {
        Thread.yield() catch {};
    }

    // Join all threads
    for (&threads) |*t| {
        if (t.*) |thread| {
            thread.join();
            t.* = null;
        }
    }
}

// ============================================================================
// Efficiency Calculation
// ============================================================================

/// Calculate scaling efficiency: how close to linear scaling.
/// Perfect linear scaling = 1.0 (100% efficiency).
/// Values > 1.0 indicate superlinear scaling (rare, usually cache effects).
/// Values < 1.0 indicate overhead from parallelization.
///
/// Pre-conditions:
/// - single_thread_time > 0
/// - multi_time > 0
/// - threads > 0
///
/// Post-conditions:
/// - Result >= 0
/// - Result == 1.0 means perfect linear scaling
pub fn calculateEfficiency(single_thread_time: u64, multi_time: u64, threads: u8) f64 {
    // Pre-conditions
    std.debug.assert(threads > 0);

    if (single_thread_time == 0 or multi_time == 0) return 0;

    const ideal = @as(f64, @floatFromInt(single_thread_time)) / @as(f64, @floatFromInt(threads));
    const actual = @as(f64, @floatFromInt(multi_time));
    const result = ideal / actual;

    // Post-conditions
    std.debug.assert(result >= 0);

    return result;
}

// ============================================================================
// Backend Comparison Benchmark
// ============================================================================

/// Compare performance of work_stealing vs blocking backend.
/// Note: This currently simulates the comparison since work_stealing
/// backend may not be fully integrated into World.tick().
///
/// Pre-conditions:
/// - entity_count > 0
/// - allocator is valid
///
/// Returns struct with timing for both backends and speedup factor.
pub fn benchBackendComparison(
    allocator: Allocator,
    entity_count: u64,
) BackendComparisonResult {
    std.debug.assert(entity_count > 0);

    // Default thread count for comparison
    const thread_count: u8 = 4;

    // Measure blocking (single-threaded) execution
    const blocking_time = measureParallelExecution(allocator, entity_count, 1);

    // Measure work-stealing style (multi-threaded) execution
    const ws_time = measureParallelExecution(allocator, entity_count, thread_count);

    const speedup: f64 = if (ws_time > 0)
        @as(f64, @floatFromInt(blocking_time)) / @as(f64, @floatFromInt(ws_time))
    else
        0;

    return .{
        .blocking_time_ns = blocking_time,
        .work_stealing_time_ns = ws_time,
        .speedup = speedup,
        .entity_count = entity_count,
        .thread_count = thread_count,
    };
}

// ============================================================================
// Parallel Systems Benchmark
// ============================================================================

/// Benchmark systems that can run in parallel.
/// Simulates N independent systems with no data conflicts.
///
/// Pre-conditions:
/// - system_count > 0
/// - system_count <= 16
/// - allocator is valid
///
/// Returns: BenchResult with parallel execution statistics.
pub fn benchParallelSystems(allocator: Allocator, system_count: u8) BenchResult {
    std.debug.assert(system_count > 0);
    std.debug.assert(system_count <= 16);

    const entities_per_system: usize = 1000;
    const total_entities = @as(usize, system_count) * entities_per_system;

    // Allocate work items (one region per "system")
    const items = allocator.alloc(WorkItem, total_entities) catch {
        return createEmptyResult("parallel_systems");
    };
    defer allocator.free(items);

    // Initialize
    for (items) |*item| {
        item.* = WorkItem.init();
    }

    var samples: [SAMPLES_SMALL]u64 = undefined;

    // Run multiple samples
    for (0..SAMPLES_SMALL) |sample_idx| {
        const start = time.Instant.now() catch continue;

        // Run "systems" in parallel (each system processes its region)
        runParallel(items, system_count);

        const end = time.Instant.now() catch continue;
        samples[sample_idx] = end.since(start);
    }

    const bench_stats = stats.calculateStats(&samples);

    return .{
        .name = "parallel_systems",
        .stats = bench_stats,
        .entity_count = total_entities,
    };
}

// ============================================================================
// Contention / False Sharing Detection
// ============================================================================

/// Adjacent data for false sharing test (NOT cache-line aligned).
const ContentionItem = struct {
    value: u64,
};

/// Benchmark to detect false sharing overhead.
/// Adjacent memory writes from multiple threads can cause false sharing
/// when data shares cache lines. High p99 variance suggests false sharing.
///
/// Pre-conditions:
/// - entity_count > 0
/// - allocator is valid
///
/// Returns: ContentionResult with variance analysis and false sharing detection.
pub fn benchContention(allocator: Allocator, entity_count: u64) ContentionResult {
    std.debug.assert(entity_count > 0);

    const count = @as(usize, @intCast(@min(entity_count, 100_000)));

    // Allocate tightly-packed items (intentionally NOT cache-aligned)
    const items = allocator.alloc(ContentionItem, count) catch {
        return createEmptyContentionResult(entity_count);
    };
    defer allocator.free(items);

    // Initialize
    for (items) |*item| {
        item.value = 0;
    }

    var samples: [SAMPLES_SMALL]u64 = undefined;
    const thread_count: u8 = 4;

    // Run contention benchmark
    for (0..SAMPLES_SMALL) |sample_idx| {
        const start = time.Instant.now() catch continue;

        runContentionTest(items, thread_count);

        const end = time.Instant.now() catch continue;
        samples[sample_idx] = end.since(start);
    }

    const bench_stats = stats.calculateStats(&samples);

    // Calculate variance ratio (p99/p50) - high ratio suggests contention
    const variance_ratio: f64 = if (bench_stats.p50_ns > 0)
        @as(f64, @floatFromInt(bench_stats.p99_ns)) / @as(f64, @floatFromInt(bench_stats.p50_ns))
    else
        1.0;

    // False sharing suspected if variance ratio > 2.0 (p99 is 2x p50)
    const suspected = variance_ratio > 2.0;

    return .{
        .stats = bench_stats,
        .entity_count = entity_count,
        .suspected_false_sharing = suspected,
        .variance_ratio = variance_ratio,
    };
}

/// Run contention test with parallel writes to adjacent memory.
fn runContentionTest(items: []ContentionItem, thread_count: u8) void {
    const count = items.len;
    const items_per_thread = count / thread_count;

    var threads: [MAX_THREAD_COUNT]?Thread = .{null} ** MAX_THREAD_COUNT;

    // Spawn threads that write to adjacent memory regions
    for (0..thread_count - 1) |i| {
        const start_idx = i * items_per_thread;
        const end_idx = start_idx + items_per_thread;
        const slice = items[start_idx..end_idx];

        threads[i] = Thread.spawn(.{}, contentionWorker, .{slice}) catch null;
    }

    // Main thread handles last chunk
    const main_start = (thread_count - 1) * items_per_thread;
    contentionWorker(items[main_start..]);

    // Join threads
    for (&threads) |*t| {
        if (t.*) |thread| {
            thread.join();
            t.* = null;
        }
    }
}

/// Worker that writes to adjacent memory locations.
fn contentionWorker(items: []ContentionItem) void {
    for (items, 0..) |*item, i| {
        // Multiple writes to exercise cache coherency
        item.value = i;
        item.value +%= 1;
        item.value *%= 2;
    }
}

// ============================================================================
// Output Functions
// ============================================================================

/// Print thread scaling results in tabular format.
pub fn printThreadScalingResults(results: *const ThreadScalingResults) void {
    std.debug.print("\n=== Thread Scaling Results ({d} entities) ===\n", .{results.entity_count});
    std.debug.print("Threads | Time (ns)    | Speedup | Efficiency\n", .{});
    std.debug.print("--------|--------------|---------|----------\n", .{});

    for (results.results) |r| {
        std.debug.print("   {d:>2}   | {d:>12} | {d:>6.2}x | {d:>7.1}%\n", .{
            r.thread_count,
            r.time_ns,
            r.speedup,
            r.efficiency * 100,
        });
    }
    std.debug.print("\n", .{});
}

/// Print backend comparison results.
pub fn printBackendComparison(result: *const BackendComparisonResult) void {
    std.debug.print("\n=== Backend Comparison ({d} threads, {d} entities) ===\n", .{
        result.thread_count,
        result.entity_count,
    });
    std.debug.print("  Blocking:      {d:>12} ns\n", .{result.blocking_time_ns});
    std.debug.print("  Work-Stealing: {d:>12} ns\n", .{result.work_stealing_time_ns});
    std.debug.print("  Speedup:       {d:>12.2}x\n", .{result.speedup});
    std.debug.print("\n", .{});
}

/// Print contention detection results.
pub fn printContentionResults(result: *const ContentionResult) void {
    std.debug.print("\n=== Contention Analysis ({d} entities) ===\n", .{result.entity_count});
    std.debug.print("  p50:            {d:>12} ns\n", .{result.stats.p50_ns});
    std.debug.print("  p99:            {d:>12} ns\n", .{result.stats.p99_ns});
    std.debug.print("  Variance ratio: {d:>12.2}x\n", .{result.variance_ratio});

    if (result.suspected_false_sharing) {
        std.debug.print("  WARNING: High variance suggests false sharing!\n", .{});
    } else {
        std.debug.print("  Status: No significant false sharing detected.\n", .{});
    }
    std.debug.print("\n", .{});
}

// ============================================================================
// Runner Integration
// ============================================================================

/// Run all threaded benchmarks and return results.
/// Intended for integration with the main benchmark runner.
pub fn runAll(allocator: Allocator) [4]BenchResult {
    var results: [4]BenchResult = undefined;

    // Thread scaling (4-thread test)
    const scaling = benchThreadScaling(allocator, DEFAULT_ENTITY_COUNT);
    results[0] = .{
        .name = "thread_scaling_4",
        .stats = createStatsFromScaling(&scaling, 2), // Index 2 = 4 threads
        .entity_count = scaling.entity_count,
    };

    // Backend comparison
    const backend_cmp = benchBackendComparison(allocator, DEFAULT_ENTITY_COUNT);
    results[1] = .{
        .name = "backend_comparison",
        .stats = createStatsFromBackend(&backend_cmp),
        .entity_count = backend_cmp.entity_count,
    };

    // Parallel systems
    results[2] = benchParallelSystems(allocator, 4);

    // Contention detection
    const contention = benchContention(allocator, DEFAULT_ENTITY_COUNT);
    results[3] = .{
        .name = "contention_detection",
        .stats = contention.stats,
        .entity_count = contention.entity_count,
    };

    return results;
}

// ============================================================================
// Helper Functions
// ============================================================================

fn createEmptyResult(name: []const u8) BenchResult {
    return .{
        .name = name,
        .stats = stats.Stats{
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
        },
        .entity_count = 0,
    };
}

fn createEmptyContentionResult(entity_count: u64) ContentionResult {
    return .{
        .stats = stats.Stats{
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
        },
        .entity_count = entity_count,
        .suspected_false_sharing = false,
        .variance_ratio = 1.0,
    };
}

fn createStatsFromScaling(scaling: *const ThreadScalingResults, idx: usize) stats.Stats {
    const r = scaling.results[idx];
    return stats.Stats{
        .iterations = SAMPLES_SMALL,
        .total_ns = r.time_ns * SAMPLES_SMALL,
        .min_ns = r.time_ns,
        .max_ns = r.time_ns,
        .p50_ns = r.time_ns,
        .p75_ns = r.time_ns,
        .p90_ns = r.time_ns,
        .p99_ns = r.time_ns,
        .mean_ns = @floatFromInt(r.time_ns),
        .stddev_ns = 0,
    };
}

fn createStatsFromBackend(cmp: *const BackendComparisonResult) stats.Stats {
    return stats.Stats{
        .iterations = SAMPLES_SMALL,
        .total_ns = cmp.work_stealing_time_ns * SAMPLES_SMALL,
        .min_ns = cmp.work_stealing_time_ns,
        .max_ns = cmp.blocking_time_ns,
        .p50_ns = cmp.work_stealing_time_ns,
        .p75_ns = cmp.work_stealing_time_ns,
        .p90_ns = cmp.blocking_time_ns,
        .p99_ns = cmp.blocking_time_ns,
        .mean_ns = @floatFromInt(cmp.work_stealing_time_ns),
        .stddev_ns = 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "efficiency calculation - perfect linear" {
    // Perfect scaling: 1 thread takes 1000ns, 2 threads take 500ns
    const eff = calculateEfficiency(1000, 500, 2);
    try testing.expectApproxEqAbs(@as(f64, 1.0), eff, 0.001);
}

test "efficiency calculation - 50% efficiency" {
    // 50% scaling: 1 thread takes 1000ns, 2 threads take 1000ns
    const eff = calculateEfficiency(1000, 1000, 2);
    try testing.expectApproxEqAbs(@as(f64, 0.5), eff, 0.001);
}

test "efficiency calculation - handles edge cases" {
    // Zero multi_time returns 0 (avoid division by zero)
    try testing.expectEqual(@as(f64, 0), calculateEfficiency(1000, 0, 2));

    // Zero single_thread_time returns 0
    try testing.expectEqual(@as(f64, 0), calculateEfficiency(0, 1000, 2));
}

test "thread scaling results structure" {
    // Verify THREAD_COUNTS matches expected values
    try testing.expectEqual(@as(u8, 1), THREAD_COUNTS[0]);
    try testing.expectEqual(@as(u8, 2), THREAD_COUNTS[1]);
    try testing.expectEqual(@as(u8, 4), THREAD_COUNTS[2]);
    try testing.expectEqual(@as(u8, 8), THREAD_COUNTS[3]);
}

test "work item alignment" {
    // Verify WorkItem is properly aligned to prevent false sharing
    try testing.expectEqual(@as(usize, CACHE_LINE_SIZE), @alignOf(WorkItem));
}

test "contention item is NOT aligned" {
    // ContentionItem should be small to test false sharing
    try testing.expect(@sizeOf(ContentionItem) < CACHE_LINE_SIZE);
}

test "thread scaling benchmark runs" {
    // Run with minimal entity count to verify it executes
    const results = benchThreadScaling(testing.allocator, 100);

    // All results should have measurements
    for (results.results) |r| {
        try testing.expect(r.thread_count > 0);
    }

    // Single-thread baseline should be recorded
    try testing.expect(results.single_thread_time_ns > 0);
}

test "backend comparison benchmark runs" {
    const result = benchBackendComparison(testing.allocator, 100);

    try testing.expect(result.blocking_time_ns > 0);
    try testing.expect(result.work_stealing_time_ns > 0);
    try testing.expect(result.speedup > 0);
}

test "parallel systems benchmark runs" {
    const result = benchParallelSystems(testing.allocator, 4);

    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.entity_count > 0);
}

test "contention benchmark runs" {
    const result = benchContention(testing.allocator, 100);

    try testing.expect(result.stats.iterations > 0);
    try testing.expect(result.variance_ratio >= 1.0);
}
