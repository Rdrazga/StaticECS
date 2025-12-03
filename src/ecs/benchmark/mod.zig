//! # Benchmark Infrastructure
//!
//! Purpose: Statistical analysis utilities and benchmark runners for measuring
//! ECS performance with proper warm-up, outlier handling, and percentile reporting.
//!
//! ## Key Types
//! - `Stats` - Statistical summary (min, max, mean, percentiles, stddev)
//! - `BenchmarkSuite` - Benchmark runner with configurable warm-up
//! - `BenchResult` - Combined name + statistics result
//! - `Baseline` - Baseline storage for regression detection
//!
//! ## Modules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `stats.zig` | Statistical calculations (percentiles, stddev, throughput) |
//! | `runner.zig` | Benchmark execution with warm-up phase |
//! | `baseline.zig` | Baseline file I/O and comparison |
//! | `query_bench.zig` | Query iteration benchmarks |
//! | `system_bench.zig` | System execution benchmarks |
//! | `scale_bench.zig` | Scaling behavior (entity count) |
//! | `threaded_bench.zig` | Multi-threaded benchmarks |
//! | `memory_bench.zig` | Memory usage and cache efficiency |
//!
//! ## Quick Start
//!
//! ```zig
//! const bench = @import("benchmark/mod.zig");
//!
//! // Option 1: Use BenchmarkSuite (recommended)
//! var suite = bench.BenchmarkSuite.init(.{
//!     .warmup_iterations = 100,
//!     .measure_iterations = 1000,
//! });
//! const result = suite.run("my_operation", myBenchFn);
//! bench.printResult(result);
//!
//! // Option 2: Manual stats calculation
//! var samples: [1000]u64 = undefined;
//! for (&samples) |*s| {
//!     const start = std.time.nanoTimestamp();
//!     myOperation();
//!     s.* = std.time.nanoTimestamp() - start;
//! }
//! const stats = bench.calculateStats(&samples);
//! ```
//!
//! ## Baseline Comparison
//!
//! ```zig
//! // Load previous baseline
//! const baseline = try bench.loadBaseline(allocator, "baselines/v1.json");
//!
//! // Compare current results
//! const comparison = bench.compareBaseline(baseline, current_results, .{
//!     .regression_threshold = 0.10,  // 10% slower = regression
//!     .improvement_threshold = 0.05, // 5% faster = improvement
//! });
//!
//! if (comparison.regressions.len > 0) {
//!     // Report regressions in CI
//! }
//! ```
//!
//! ## Thread Safety
//! - Stats calculations are thread-safe (pure functions)
//! - BenchmarkSuite is NOT thread-safe (single-threaded runner)
//! - Baseline I/O uses standard file operations

pub const stats = @import("stats.zig");
pub const runner = @import("runner.zig");
pub const query_bench = @import("query_bench.zig");
pub const system_bench = @import("system_bench.zig");
pub const scale_bench = @import("scale_bench.zig");
pub const threaded_bench = @import("threaded_bench.zig");
pub const memory_bench = @import("memory_bench.zig");
pub const baseline = @import("baseline.zig");

// Re-export commonly used types for convenience
pub const Stats = stats.Stats;
pub const MAX_STACK_SAMPLES = stats.MAX_STACK_SAMPLES;

// Re-export runner types for convenience
pub const BenchmarkSuite = runner.BenchmarkSuite;
pub const BenchResult = runner.BenchResult;
pub const Config = runner.Config;
pub const MAX_SAMPLES = runner.MAX_SAMPLES;

// Re-export core stats functions
pub const calculateStats = stats.calculateStats;
pub const percentile = stats.percentile;
pub const mean = stats.mean;
pub const standardDeviation = stats.standardDeviation;
pub const throughputOpsPerSec = stats.throughputOpsPerSec;
pub const throughputMBps = stats.throughputMBps;

// Re-export runner functions
pub const printResult = runner.printResult;
pub const printReport = runner.printReport;

// Re-export baseline types for convenience
pub const Baseline = baseline.Baseline;
pub const BaselineEntry = baseline.BaselineEntry;
pub const ComparisonResult = baseline.ComparisonResult;
pub const CompareOptions = baseline.CompareOptions;
pub const RegressionEntry = baseline.RegressionEntry;
pub const ImprovementEntry = baseline.ImprovementEntry;
pub const StableEntry = baseline.StableEntry;

// Re-export baseline functions
pub const compareBaseline = baseline.compare;
pub const calculateChange = baseline.calculateChange;
pub const parseBaseline = baseline.parse;
pub const formatBaseline = baseline.format;
pub const loadBaseline = baseline.load;
pub const saveBaseline = baseline.save;

// Re-export threaded_bench types for convenience
pub const THREAD_COUNTS = threaded_bench.THREAD_COUNTS;
pub const ThreadScalingResults = threaded_bench.ThreadScalingResults;
pub const BackendComparisonResult = threaded_bench.BackendComparisonResult;

// Re-export threaded_bench functions
pub const benchThreadScaling = threaded_bench.benchThreadScaling;
pub const benchBackendComparison = threaded_bench.benchBackendComparison;
pub const benchParallelSystems = threaded_bench.benchParallelSystems;
pub const benchContention = threaded_bench.benchContention;
pub const calculateEfficiency = threaded_bench.calculateEfficiency;
pub const printThreadScalingResults = threaded_bench.printThreadScalingResults;
pub const printBackendComparison = threaded_bench.printBackendComparison;

// Re-export memory_bench types for convenience
pub const MemoryResult = memory_bench.MemoryResult;
pub const CacheResult = memory_bench.CacheResult;
pub const DensityResult = memory_bench.DensityResult;
pub const ComponentSizes = memory_bench.ComponentSizes;
pub const MemoryBenchResults = memory_bench.MemoryBenchResults;
pub const CACHE_LINE_SIZE = memory_bench.CACHE_LINE_SIZE;

// Re-export memory_bench functions
pub const benchMemoryUsage = memory_bench.benchMemoryUsage;
pub const benchComponentDensity = memory_bench.benchComponentDensity;
pub const benchCacheEfficiency = memory_bench.benchCacheEfficiency;
pub const benchArchetypeOverhead = memory_bench.benchArchetypeOverhead;
pub const benchEntityDensity = memory_bench.benchEntityDensity;
pub const printMemoryResults = memory_bench.printMemoryResults;
pub const printCacheResults = memory_bench.printCacheResults;
pub const printDensityResults = memory_bench.printDensityResults;
pub const runAllMemoryBenchmarks = memory_bench.runAllBenchmarks;

test {
    // Run all submodule tests
    _ = stats;
    _ = runner;
    _ = query_bench;
    _ = scale_bench;
    _ = threaded_bench;
    _ = memory_bench;
    _ = baseline;
    // Note: system_bench requires FrameExecutor which has pre-existing issues
    // _ = system_bench;
}
