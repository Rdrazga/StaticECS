//! Benchmark runner with warm-up phase support.
//!
//! Executes benchmarks with configurable warm-up and measurement iterations.
//! Uses statistical analysis from stats.zig for result processing.
//!
//! ## Usage
//! ```zig
//! const runner = @import("runner.zig");
//! var suite = runner.BenchmarkSuite.init(.{
//!     .warmup_iterations = 100,
//!     .measurement_iterations = 1000,
//! });
//! const result = suite.runBenchmark("my_bench", myBenchFn);
//! runner.printResult(result);
//! ```

const std = @import("std");
const stats = @import("stats.zig");

/// Maximum samples that can be collected per benchmark run.
/// Matches stats.MAX_STACK_SAMPLES for compatibility.
pub const MAX_SAMPLES: usize = stats.MAX_STACK_SAMPLES;

// ============================================================================
// Configuration
// ============================================================================

/// Configuration for benchmark suite initialization.
pub const Config = struct {
    /// Number of warm-up iterations (results discarded).
    warmup_iterations: u32 = 100,

    /// Number of measurement iterations (results collected).
    measurement_iterations: u32 = 1000,

    /// Entity count tiers for scaling benchmarks.
    entity_tiers: []const u64 = &.{ 1_000, 10_000, 100_000 },

    /// Thread counts for parallel benchmarks.
    thread_counts: []const u32 = &.{ 1, 2, 4, 8 },

    /// Optional setup callback executed before each benchmark.
    setup_fn: ?*const fn () void = null,

    /// Optional teardown callback executed after each benchmark.
    teardown_fn: ?*const fn () void = null,
};

// ============================================================================
// Benchmark Result
// ============================================================================

/// Result of a benchmark run containing statistics and metadata.
pub const BenchResult = struct {
    /// Name identifier for the benchmark.
    name: []const u8,

    /// Computed statistics from measurement samples.
    stats: stats.Stats,

    /// Number of entities processed (for throughput calculations).
    entity_count: u64 = 0,

    /// Calculates entities processed per second.
    ///
    /// Pre-conditions:
    /// - stats.total_ns > 0 for meaningful results
    /// - entity_count > 0 for meaningful results
    ///
    /// Returns: entities/second as f64, or 0 if not applicable.
    pub fn entitiesPerSecond(self: BenchResult) f64 {
        // Pre-conditions
        std.debug.assert(self.stats.iterations > 0);

        if (self.entity_count == 0) return 0;
        if (self.stats.total_ns == 0) return 0;

        const ns_per_sec: f64 = 1_000_000_000.0;
        const total_time_sec = @as(f64, @floatFromInt(self.stats.total_ns)) / ns_per_sec;
        const total_entities = @as(f64, @floatFromInt(self.entity_count)) *
            @as(f64, @floatFromInt(self.stats.iterations));
        const result = total_entities / total_time_sec;

        // Post-condition
        std.debug.assert(result >= 0);

        return result;
    }
};

// ============================================================================
// Benchmark Suite
// ============================================================================

/// Benchmark runner with configurable warm-up and measurement phases.
pub const BenchmarkSuite = struct {
    /// Number of warm-up iterations (results discarded).
    warmup_iterations: u32,

    /// Number of measurement iterations (collected for statistics).
    measurement_iterations: u32,

    /// Entity count tiers for scaling benchmarks.
    entity_tiers: []const u64,

    /// Thread counts for parallel benchmarks.
    thread_counts: []const u32,

    /// Optional setup callback.
    setup_fn: ?*const fn () void,

    /// Optional teardown callback.
    teardown_fn: ?*const fn () void,

    /// Type for benchmark functions.
    pub const BenchFn = *const fn () u64;

    /// Initializes a benchmark suite from configuration.
    ///
    /// Pre-conditions:
    /// - config.warmup_iterations > 0
    /// - config.measurement_iterations > 0
    /// - config.measurement_iterations <= MAX_SAMPLES
    ///
    /// Post-conditions:
    /// - Returned suite has valid iteration counts.
    pub fn init(config: Config) BenchmarkSuite {
        // Pre-conditions
        std.debug.assert(config.warmup_iterations > 0);
        std.debug.assert(config.measurement_iterations > 0);
        std.debug.assert(config.measurement_iterations <= MAX_SAMPLES);

        const suite = BenchmarkSuite{
            .warmup_iterations = config.warmup_iterations,
            .measurement_iterations = config.measurement_iterations,
            .entity_tiers = config.entity_tiers,
            .thread_counts = config.thread_counts,
            .setup_fn = config.setup_fn,
            .teardown_fn = config.teardown_fn,
        };

        // Post-conditions
        std.debug.assert(suite.warmup_iterations > 0);
        std.debug.assert(suite.measurement_iterations > 0);

        return suite;
    }

    /// Runs a benchmark with warm-up and measurement phases.
    ///
    /// Phase 1: Execute warm-up iterations (results discarded).
    /// Phase 2: Execute measurement iterations (results collected).
    /// Phase 3: Calculate and return statistics.
    ///
    /// Pre-conditions:
    /// - self.warmup_iterations > 0
    /// - self.measurement_iterations > 0
    ///
    /// Post-conditions:
    /// - result.stats.iterations == sample_count
    pub fn runBenchmark(
        self: *BenchmarkSuite,
        name: []const u8,
        bench_fn: BenchFn,
    ) BenchResult {
        // Pre-conditions
        std.debug.assert(self.warmup_iterations > 0);
        std.debug.assert(self.measurement_iterations > 0);

        // Execute optional setup
        if (self.setup_fn) |setup| {
            setup();
        }

        // Phase 1: Warm-up iterations (discard results)
        for (0..self.warmup_iterations) |_| {
            _ = bench_fn();
        }

        // Phase 2: Measurement iterations (collect samples)
        var samples: [MAX_SAMPLES]u64 = undefined;
        const sample_count = @min(self.measurement_iterations, MAX_SAMPLES);

        for (0..sample_count) |i| {
            samples[i] = bench_fn();
        }

        // Execute optional teardown
        if (self.teardown_fn) |teardown| {
            teardown();
        }

        // Phase 3: Calculate statistics
        const bench_stats = stats.calculateStats(samples[0..sample_count]);

        // Post-condition
        std.debug.assert(bench_stats.iterations == sample_count);

        return BenchResult{
            .name = name,
            .stats = bench_stats,
        };
    }
};

// ============================================================================
// Output Functions
// ============================================================================

/// Prints a single benchmark result in a formatted line.
///
/// Format: name | min | p50 | p90 | p99 | max | ops/sec
///
/// Pre-conditions:
/// - result.stats.iterations > 0
pub fn printResult(result: BenchResult) void {
    // Pre-conditions
    std.debug.assert(result.stats.iterations > 0);
    std.debug.assert(result.name.len > 0);

    const ops_per_sec = stats.throughputOpsPerSec(result.stats);

    std.debug.print("{s:.<30} min:{d:>8}ns p50:{d:>8}ns p90:{d:>8}ns p99:{d:>8}ns max:{d:>8}ns | {d:.2} ops/sec\n", .{
        result.name,
        result.stats.min_ns,
        result.stats.p50_ns,
        result.stats.p90_ns,
        result.stats.p99_ns,
        result.stats.max_ns,
        ops_per_sec,
    });
}

/// Prints a formatted report of multiple benchmark results.
///
/// Pre-conditions:
/// - results.len > 0 for meaningful output
pub fn printReport(results: []const BenchResult) void {
    // Pre-conditions (allow empty for edge case)
    std.debug.assert(results.len < 10000); // Reasonable bound

    std.debug.print("\n=== Benchmark Results ===\n\n", .{});

    for (results) |result| {
        printResult(result);
    }

    std.debug.print("\n", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "Config defaults are valid" {
    const config = Config{};

    // Verify defaults match expected values
    try std.testing.expectEqual(@as(u32, 100), config.warmup_iterations);
    try std.testing.expectEqual(@as(u32, 1000), config.measurement_iterations);
    try std.testing.expect(config.entity_tiers.len == 3);
    try std.testing.expect(config.thread_counts.len == 4);
    try std.testing.expect(config.setup_fn == null);
    try std.testing.expect(config.teardown_fn == null);
}

test "BenchmarkSuite init with defaults" {
    const suite = BenchmarkSuite.init(.{});

    try std.testing.expectEqual(@as(u32, 100), suite.warmup_iterations);
    try std.testing.expectEqual(@as(u32, 1000), suite.measurement_iterations);
    try std.testing.expect(suite.entity_tiers.len == 3);
    try std.testing.expect(suite.thread_counts.len == 4);
}

test "BenchmarkSuite init with custom config" {
    const suite = BenchmarkSuite.init(.{
        .warmup_iterations = 50,
        .measurement_iterations = 500,
        .entity_tiers = &.{ 100, 1000 },
        .thread_counts = &.{ 1, 2 },
    });

    try std.testing.expectEqual(@as(u32, 50), suite.warmup_iterations);
    try std.testing.expectEqual(@as(u32, 500), suite.measurement_iterations);
    try std.testing.expectEqual(@as(usize, 2), suite.entity_tiers.len);
    try std.testing.expectEqual(@as(usize, 2), suite.thread_counts.len);
}

/// Counter for tracking warm-up execution in tests.
var test_warmup_counter: u32 = 0;
var test_measurement_counter: u32 = 0;

fn testBenchFn() u64 {
    if (test_warmup_counter < 10) {
        test_warmup_counter += 1;
    } else {
        test_measurement_counter += 1;
    }
    return 1000; // Fixed timing for predictable tests
}

test "warm-up phase executes" {
    // Reset counters
    test_warmup_counter = 0;
    test_measurement_counter = 0;

    var suite = BenchmarkSuite.init(.{
        .warmup_iterations = 10,
        .measurement_iterations = 20,
    });

    _ = suite.runBenchmark("test_warmup", testBenchFn);

    // Warm-up should have executed 10 times
    try std.testing.expectEqual(@as(u32, 10), test_warmup_counter);
    // Measurement should have executed 20 times
    try std.testing.expectEqual(@as(u32, 20), test_measurement_counter);
}

test "measurement phase collects samples" {
    var suite = BenchmarkSuite.init(.{
        .warmup_iterations = 5,
        .measurement_iterations = 100,
    });

    const result = suite.runBenchmark("test_samples", struct {
        fn bench() u64 {
            return 500;
        }
    }.bench);

    // Should have collected 100 samples
    try std.testing.expectEqual(@as(u64, 100), result.stats.iterations);
    // All samples were 500ns, so min/max/p50 should all be 500
    try std.testing.expectEqual(@as(u64, 500), result.stats.min_ns);
    try std.testing.expectEqual(@as(u64, 500), result.stats.max_ns);
    try std.testing.expectEqual(@as(u64, 500), result.stats.p50_ns);
}

var test_setup_called: bool = false;
var test_teardown_called: bool = false;

fn testSetup() void {
    test_setup_called = true;
}

fn testTeardown() void {
    test_teardown_called = true;
}

test "setup and teardown callbacks execute" {
    test_setup_called = false;
    test_teardown_called = false;

    var suite = BenchmarkSuite.init(.{
        .warmup_iterations = 1,
        .measurement_iterations = 1,
        .setup_fn = testSetup,
        .teardown_fn = testTeardown,
    });

    _ = suite.runBenchmark("callback_test", struct {
        fn bench() u64 {
            return 100;
        }
    }.bench);

    try std.testing.expect(test_setup_called);
    try std.testing.expect(test_teardown_called);
}

test "BenchResult entitiesPerSecond calculation" {
    // 1000 iterations, 1 second total, 100 entities per iteration
    const result = BenchResult{
        .name = "entity_test",
        .stats = stats.Stats{
            .iterations = 1000,
            .total_ns = 1_000_000_000, // 1 second
            .min_ns = 900_000,
            .max_ns = 1_100_000,
            .p50_ns = 1_000_000,
            .p75_ns = 1_050_000,
            .p90_ns = 1_080_000,
            .p99_ns = 1_095_000,
            .mean_ns = 1_000_000,
            .stddev_ns = 50_000,
        },
        .entity_count = 100,
    };

    // 100 entities * 1000 iterations / 1 second = 100,000 entities/sec
    const eps = result.entitiesPerSecond();
    try std.testing.expectApproxEqAbs(@as(f64, 100_000.0), eps, 0.001);
}

test "BenchResult entitiesPerSecond handles zero" {
    const result = BenchResult{
        .name = "zero_test",
        .stats = stats.Stats{
            .iterations = 100,
            .total_ns = 1_000_000,
            .min_ns = 9_000,
            .max_ns = 11_000,
            .p50_ns = 10_000,
            .p75_ns = 10_500,
            .p90_ns = 10_800,
            .p99_ns = 10_950,
            .mean_ns = 10_000,
            .stddev_ns = 500,
        },
        .entity_count = 0,
    };

    // Zero entities should return 0
    try std.testing.expectEqual(@as(f64, 0), result.entitiesPerSecond());
}

test "result name stored correctly" {
    var suite = BenchmarkSuite.init(.{
        .warmup_iterations = 1,
        .measurement_iterations = 1,
    });

    const result = suite.runBenchmark("my_benchmark_name", struct {
        fn bench() u64 {
            return 42;
        }
    }.bench);

    try std.testing.expectEqualStrings("my_benchmark_name", result.name);
}
