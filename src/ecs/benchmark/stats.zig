//! Statistical analysis utilities for benchmark measurements.
//!
//! Provides percentile calculations, standard deviation, and throughput metrics.
//! Follows TigerStyle: pure functions with comprehensive assertions.
//!
//! ## Usage
//! ```zig
//! const stats = @import("stats.zig");
//! const samples = [_]u64{ 100, 200, 150, 180, 120 };
//! const result = stats.calculateStats(&samples);
//! std.debug.print("p50: {d} ns, stddev: {d:.2}\n", .{ result.p50_ns, result.stddev_ns });
//! ```

const std = @import("std");
const math = std.math;
const mem = std.mem;
const testing = std.testing;

/// Statistical measures computed from timing samples.
/// All timing values are in nanoseconds (ns).
pub const Stats = struct {
    iterations: u64,
    total_ns: u64,

    // Statistical measures
    min_ns: u64,
    max_ns: u64,
    p50_ns: u64, // median
    p75_ns: u64,
    p90_ns: u64,
    p99_ns: u64,
    mean_ns: f64,
    stddev_ns: f64,

    // Optional metadata (can be set after calculation)
    entities_processed: u64 = 0,
    bytes_processed: u64 = 0,
};

/// Maximum sample size that can be processed without allocator.
/// Uses stack buffer for efficiency - exceeding this requires external sort.
pub const MAX_STACK_SAMPLES: usize = 8192;

// ============================================================================
// Core Statistical Functions
// ============================================================================

/// Calculates comprehensive statistics from timing samples.
/// Sorts a copy of the samples for percentile calculations.
///
/// Pre-conditions:
/// - samples.len > 0
/// - samples.len <= MAX_STACK_SAMPLES (for stack-based sorting)
///
/// Post-conditions:
/// - stats.min_ns <= stats.mean_ns <= stats.max_ns (approximately)
/// - stats.min_ns <= stats.p50_ns <= stats.max_ns
pub fn calculateStats(samples: []const u64) Stats {
    // Pre-conditions
    std.debug.assert(samples.len > 0);
    std.debug.assert(samples.len <= MAX_STACK_SAMPLES);

    // Copy to stack buffer for sorting (preserves original)
    var sorted_buf: [MAX_STACK_SAMPLES]u64 = undefined;
    const sorted = sorted_buf[0..samples.len];
    @memcpy(sorted, samples);

    // Sort for percentile calculations
    mem.sort(u64, sorted, {}, std.sort.asc(u64));

    // Calculate all statistics
    const sample_mean = mean(samples);
    const sample_stddev = standardDeviation(samples, sample_mean);
    const sample_min = sorted[0];
    const sample_max = sorted[sorted.len - 1];

    // Calculate total
    var total: u64 = 0;
    for (samples) |s| {
        total = math.add(u64, total, s) catch math.maxInt(u64);
    }

    const stats = Stats{
        .iterations = samples.len,
        .total_ns = total,
        .min_ns = sample_min,
        .max_ns = sample_max,
        .p50_ns = percentile(sorted, 50),
        .p75_ns = percentile(sorted, 75),
        .p90_ns = percentile(sorted, 90),
        .p99_ns = percentile(sorted, 99),
        .mean_ns = sample_mean,
        .stddev_ns = sample_stddev,
    };

    // Post-conditions
    std.debug.assert(stats.min_ns <= stats.max_ns);
    std.debug.assert(stats.p50_ns >= stats.min_ns and stats.p50_ns <= stats.max_ns);

    return stats;
}

/// Calculates the nth percentile from pre-sorted samples using linear interpolation.
///
/// Pre-conditions:
/// - sorted_samples is sorted in ascending order
/// - sorted_samples.len > 0
/// - p is in range [0, 100]
///
/// Post-conditions:
/// - result >= sorted_samples[0]
/// - result <= sorted_samples[n-1]
pub fn percentile(sorted_samples: []const u64, p: u8) u64 {
    // Pre-conditions
    std.debug.assert(p <= 100);
    std.debug.assert(sorted_samples.len > 0);

    const n = sorted_samples.len;

    // Handle edge cases
    if (n == 1) return sorted_samples[0];
    if (p == 0) return sorted_samples[0];
    if (p == 100) return sorted_samples[n - 1];

    // Linear interpolation for percentile
    // rank = p/100 * (n-1), gives fractional index
    const rank = @as(f64, @floatFromInt(p)) / 100.0 * @as(f64, @floatFromInt(n - 1));
    const lower_idx = @as(usize, @intFromFloat(@floor(rank)));
    const upper_idx = @min(lower_idx + 1, n - 1);
    const weight = rank - @floor(rank);

    // Blend between lower and upper values
    const lower_val = @as(f64, @floatFromInt(sorted_samples[lower_idx]));
    const upper_val = @as(f64, @floatFromInt(sorted_samples[upper_idx]));
    const blended = lower_val + weight * (upper_val - lower_val);

    // Convert back to u64, rounding to nearest
    const result = @as(u64, @intFromFloat(@round(blended)));

    // Post-conditions
    std.debug.assert(result >= sorted_samples[0]);
    std.debug.assert(result <= sorted_samples[n - 1]);

    return result;
}

/// Calculates the arithmetic mean of samples.
///
/// Pre-conditions:
/// - samples.len > 0
///
/// Post-conditions:
/// - result >= 0 (all inputs are u64)
pub fn mean(samples: []const u64) f64 {
    // Pre-conditions
    std.debug.assert(samples.len > 0);

    var sum: f64 = 0;
    for (samples) |s| {
        sum += @as(f64, @floatFromInt(s));
    }

    const result = sum / @as(f64, @floatFromInt(samples.len));

    // Post-conditions
    std.debug.assert(result >= 0);
    std.debug.assert(!math.isNan(result));

    return result;
}

/// Calculates the population standard deviation given samples and their mean.
/// Uses population formula (N divisor) for benchmark consistency.
///
/// Pre-conditions:
/// - samples.len > 0
/// - sample_mean is a valid (non-NaN) value
///
/// Post-conditions:
/// - result >= 0
pub fn standardDeviation(samples: []const u64, sample_mean: f64) f64 {
    // Pre-conditions
    std.debug.assert(samples.len > 0);
    std.debug.assert(!math.isNan(sample_mean));

    // Handle single sample case (no deviation)
    if (samples.len == 1) return 0;

    // Sum of squared differences from mean
    var sum_sq_diff: f64 = 0;
    for (samples) |s| {
        const diff = @as(f64, @floatFromInt(s)) - sample_mean;
        sum_sq_diff += diff * diff;
    }

    // Population standard deviation (divide by N, not N-1)
    const variance = sum_sq_diff / @as(f64, @floatFromInt(samples.len));
    const result = @sqrt(variance);

    // Post-conditions
    std.debug.assert(result >= 0);
    std.debug.assert(!math.isNan(result));

    return result;
}

// ============================================================================
// Throughput Calculations
// ============================================================================

/// Calculates operations per second from stats.
///
/// Pre-conditions:
/// - stats.iterations > 0
/// - stats.total_ns > 0 (meaningful timing)
///
/// Returns: ops/second as f64
pub fn throughputOpsPerSec(stats: Stats) f64 {
    // Pre-conditions
    std.debug.assert(stats.iterations > 0);

    // Handle zero-time edge case (prevent division by zero)
    if (stats.total_ns == 0) return 0;

    const ns_per_sec: f64 = 1_000_000_000.0;
    const total_time_sec = @as(f64, @floatFromInt(stats.total_ns)) / ns_per_sec;
    const result = @as(f64, @floatFromInt(stats.iterations)) / total_time_sec;

    // Post-conditions
    std.debug.assert(result >= 0);
    std.debug.assert(!math.isNan(result));

    return result;
}

/// Calculates throughput in megabytes per second if bytes_processed > 0.
/// Returns 0 if no bytes were processed.
///
/// Pre-conditions:
/// - stats contains valid timing data
///
/// Returns: MB/second as f64, or 0 if bytes_processed == 0
pub fn throughputMBps(stats: Stats) f64 {
    // Pre-conditions
    std.debug.assert(stats.iterations > 0);

    // No bytes processed - return 0
    if (stats.bytes_processed == 0) return 0;
    if (stats.total_ns == 0) return 0;

    const bytes_per_mb: f64 = 1024.0 * 1024.0;
    const ns_per_sec: f64 = 1_000_000_000.0;

    const mb_processed = @as(f64, @floatFromInt(stats.bytes_processed)) / bytes_per_mb;
    const total_time_sec = @as(f64, @floatFromInt(stats.total_ns)) / ns_per_sec;
    const result = mb_processed / total_time_sec;

    // Post-conditions
    std.debug.assert(result >= 0);
    std.debug.assert(!math.isNan(result));

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "percentile returns correct values for simple array" {
    const sorted = [_]u64{ 10, 20, 30, 40, 50 };

    // p0 = minimum
    try testing.expectEqual(@as(u64, 10), percentile(&sorted, 0));

    // p50 = median (middle value for odd-length array)
    try testing.expectEqual(@as(u64, 30), percentile(&sorted, 50));

    // p100 = maximum
    try testing.expectEqual(@as(u64, 50), percentile(&sorted, 100));
}

test "percentile handles single element" {
    const sorted = [_]u64{42};

    try testing.expectEqual(@as(u64, 42), percentile(&sorted, 0));
    try testing.expectEqual(@as(u64, 42), percentile(&sorted, 50));
    try testing.expectEqual(@as(u64, 42), percentile(&sorted, 100));
}

test "percentile interpolates correctly" {
    // Values: 100, 200 - p50 should be 150
    const sorted = [_]u64{ 100, 200 };
    try testing.expectEqual(@as(u64, 150), percentile(&sorted, 50));

    // Values: 0, 100 - p25 should be 25
    const sorted2 = [_]u64{ 0, 100 };
    try testing.expectEqual(@as(u64, 25), percentile(&sorted2, 25));
}

test "mean calculation" {
    // Simple average: (10 + 20 + 30) / 3 = 20
    const samples = [_]u64{ 10, 20, 30 };
    try testing.expectEqual(@as(f64, 20.0), mean(&samples));

    // Single value
    const single = [_]u64{42};
    try testing.expectEqual(@as(f64, 42.0), mean(&single));
}

test "standard deviation calculation" {
    // Identical values have zero stddev
    const identical = [_]u64{ 100, 100, 100, 100 };
    try testing.expectEqual(@as(f64, 0.0), standardDeviation(&identical, 100.0));

    // Known stddev: [1, 2, 3, 4, 5] has mean=3, variance=2, stddev≈1.414
    const samples = [_]u64{ 1, 2, 3, 4, 5 };
    const expected_stddev = @sqrt(@as(f64, 2.0));
    try testing.expectApproxEqAbs(expected_stddev, standardDeviation(&samples, 3.0), 0.001);
}

test "calculateStats comprehensive test" {
    const samples = [_]u64{ 100, 200, 150, 180, 120, 160, 140, 190, 130, 170 };
    const stats = calculateStats(&samples);

    // Check iteration count
    try testing.expectEqual(@as(u64, 10), stats.iterations);

    // Check min/max
    try testing.expectEqual(@as(u64, 100), stats.min_ns);
    try testing.expectEqual(@as(u64, 200), stats.max_ns);

    // Check mean (sum=1540, mean=154)
    try testing.expectApproxEqAbs(@as(f64, 154.0), stats.mean_ns, 0.001);

    // Check total
    try testing.expectEqual(@as(u64, 1540), stats.total_ns);

    // Percentiles should be within range
    try testing.expect(stats.p50_ns >= stats.min_ns);
    try testing.expect(stats.p50_ns <= stats.max_ns);
    try testing.expect(stats.p75_ns >= stats.p50_ns);
    try testing.expect(stats.p90_ns >= stats.p75_ns);
    try testing.expect(stats.p99_ns >= stats.p90_ns);
}

test "throughputOpsPerSec calculation" {
    var stats = Stats{
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
    };

    // 1000 ops in 1 second = 1000 ops/sec
    try testing.expectApproxEqAbs(@as(f64, 1000.0), throughputOpsPerSec(stats), 0.001);

    // 1000 ops in 0.5 seconds = 2000 ops/sec
    stats.total_ns = 500_000_000;
    try testing.expectApproxEqAbs(@as(f64, 2000.0), throughputOpsPerSec(stats), 0.001);
}

test "throughputMBps calculation" {
    var stats = Stats{
        .iterations = 100,
        .total_ns = 1_000_000_000, // 1 second
        .min_ns = 9_000_000,
        .max_ns = 11_000_000,
        .p50_ns = 10_000_000,
        .p75_ns = 10_500_000,
        .p90_ns = 10_800_000,
        .p99_ns = 10_950_000,
        .mean_ns = 10_000_000,
        .stddev_ns = 500_000,
        .bytes_processed = 1024 * 1024, // 1 MB
    };

    // 1 MB in 1 second = 1 MB/s
    try testing.expectApproxEqAbs(@as(f64, 1.0), throughputMBps(stats), 0.001);

    // No bytes processed returns 0
    stats.bytes_processed = 0;
    try testing.expectEqual(@as(f64, 0), throughputMBps(stats));
}

test "stats handles edge cases" {
    // Single sample
    const single = [_]u64{42};
    const stats = calculateStats(&single);
    try testing.expectEqual(@as(u64, 42), stats.min_ns);
    try testing.expectEqual(@as(u64, 42), stats.max_ns);
    try testing.expectEqual(@as(u64, 42), stats.p50_ns);
    try testing.expectEqual(@as(f64, 0.0), stats.stddev_ns);
}
