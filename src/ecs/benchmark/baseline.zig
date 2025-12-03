//! Baseline comparison system for benchmark regression detection.
//!
//! Provides functionality to:
//! - Store baseline benchmark results to file
//! - Load baseline results from file
//! - Compare current results against baseline
//! - Detect regressions with configurable thresholds
//!
//! ## File Format
//! Simple line-based text format for portability:
//! ```text
//! # StaticECS Benchmark Baseline
//! # Version: 1.0.0
//! # Timestamp: 1701492000
//! # Commit: abc123def456...
//!
//! entity_spawn_10k,50000,55000,60000,1000
//! query_single_10k,30000,33000,38000,1000
//! ```
//!
//! ## Usage
//! ```zig
//! const baseline = @import("baseline.zig");
//!
//! // Load existing baseline
//! const base = baseline.load(allocator, "baselines/v1.0.0.txt") orelse {
//!     std.debug.print("No baseline found\n", .{});
//!     return;
//! };
//!
//! // Compare current results
//! const result = baseline.compare(base, current_entries, .{});
//! result.printReport();
//! ```

const std = @import("std");
const stats = @import("stats.zig");
const runner = @import("runner.zig");
const mem = std.mem;
const math = std.math;

// ============================================================================
// Constants
// ============================================================================

/// Maximum benchmark name length.
pub const MAX_NAME_LEN: usize = 128;

/// Maximum number of baseline entries.
pub const MAX_ENTRIES: usize = 512;

/// File format header prefix.
pub const HEADER_PREFIX: []const u8 = "# StaticECS Benchmark Baseline";

/// Current file format version.
pub const FORMAT_VERSION: []const u8 = "1.0.0";

// ============================================================================
// Configuration
// ============================================================================

/// Options for baseline comparison.
pub const CompareOptions = struct {
    /// Percentage change to flag as regression (default 10%).
    /// Value must be in range (0.0, 1.0).
    regression_threshold: f64 = 0.10,

    /// Percentage change to flag as improvement (default 10%).
    /// Value must be in range (0.0, 1.0).
    improvement_threshold: f64 = 0.10,

    /// Fail if any single benchmark regresses more than this (default 20%).
    /// Value must be in range (0.0, 1.0).
    fail_threshold: f64 = 0.20,

    /// Validates that all thresholds are in valid range.
    ///
    /// Pre-conditions: none
    /// Post-conditions: Returns true iff all thresholds in (0.0, 1.0).
    pub fn isValid(self: CompareOptions) bool {
        return self.regression_threshold > 0.0 and self.regression_threshold < 1.0 and
            self.improvement_threshold > 0.0 and self.improvement_threshold < 1.0 and
            self.fail_threshold > 0.0 and self.fail_threshold < 1.0;
    }
};

// ============================================================================
// Entry Types
// ============================================================================

/// A single baseline entry representing one benchmark result.
pub const BaselineEntry = struct {
    /// Benchmark name identifier.
    name: [MAX_NAME_LEN]u8,
    /// Actual length of name.
    name_len: usize,
    /// 50th percentile (median) in nanoseconds.
    p50_ns: u64,
    /// 90th percentile in nanoseconds.
    p90_ns: u64,
    /// 99th percentile in nanoseconds.
    p99_ns: u64,
    /// Number of iterations measured.
    iterations: u64,

    /// Creates a BaselineEntry from a BenchResult.
    ///
    /// Pre-conditions:
    /// - result.name.len <= MAX_NAME_LEN
    /// - result.stats.iterations > 0
    ///
    /// Post-conditions:
    /// - Returned entry has valid name and stats.
    pub fn fromBenchResult(result: runner.BenchResult) BaselineEntry {
        // Pre-conditions
        std.debug.assert(result.name.len <= MAX_NAME_LEN);
        std.debug.assert(result.stats.iterations > 0);

        var entry = BaselineEntry{
            .name = undefined,
            .name_len = result.name.len,
            .p50_ns = result.stats.p50_ns,
            .p90_ns = result.stats.p90_ns,
            .p99_ns = result.stats.p99_ns,
            .iterations = result.stats.iterations,
        };

        // Copy name
        @memset(&entry.name, 0);
        @memcpy(entry.name[0..result.name.len], result.name);

        // Post-conditions
        std.debug.assert(entry.name_len > 0);
        std.debug.assert(entry.iterations > 0);

        return entry;
    }

    /// Creates a BaselineEntry from raw values.
    ///
    /// Pre-conditions:
    /// - name.len <= MAX_NAME_LEN
    /// - iterations > 0
    pub fn init(
        name: []const u8,
        p50_ns: u64,
        p90_ns: u64,
        p99_ns: u64,
        iterations: u64,
    ) BaselineEntry {
        std.debug.assert(name.len <= MAX_NAME_LEN);
        std.debug.assert(iterations > 0);

        var entry = BaselineEntry{
            .name = undefined,
            .name_len = name.len,
            .p50_ns = p50_ns,
            .p90_ns = p90_ns,
            .p99_ns = p99_ns,
            .iterations = iterations,
        };

        @memset(&entry.name, 0);
        @memcpy(entry.name[0..name.len], name);

        return entry;
    }

    /// Returns the name as a slice.
    pub fn getName(self: *const BaselineEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ============================================================================
// Comparison Result Types
// ============================================================================

/// Entry representing a benchmark that regressed (got slower).
pub const RegressionEntry = struct {
    /// Benchmark name.
    name: [MAX_NAME_LEN]u8,
    name_len: usize,
    /// Baseline p50 in nanoseconds.
    baseline_p50: u64,
    /// Current p50 in nanoseconds.
    current_p50: u64,
    /// Percentage change (positive = slower).
    change_percent: f64,
    /// Whether this exceeds the fail threshold.
    exceeds_fail_threshold: bool,

    pub fn getName(self: *const RegressionEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Entry representing a benchmark that improved (got faster).
pub const ImprovementEntry = struct {
    /// Benchmark name.
    name: [MAX_NAME_LEN]u8,
    name_len: usize,
    /// Baseline p50 in nanoseconds.
    baseline_p50: u64,
    /// Current p50 in nanoseconds.
    current_p50: u64,
    /// Percentage change (negative = faster).
    change_percent: f64,

    pub fn getName(self: *const ImprovementEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Entry representing a stable benchmark (within threshold).
pub const StableEntry = struct {
    /// Benchmark name.
    name: [MAX_NAME_LEN]u8,
    name_len: usize,
    /// Baseline p50 in nanoseconds.
    baseline_p50: u64,
    /// Current p50 in nanoseconds.
    current_p50: u64,
    /// Percentage change.
    change_percent: f64,

    pub fn getName(self: *const StableEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Result of comparing current benchmarks against a baseline.
pub const ComparisonResult = struct {
    /// Benchmarks that got significantly slower.
    regressions: []RegressionEntry,
    regression_count: usize,
    /// Benchmarks that got significantly faster.
    improvements: []ImprovementEntry,
    improvement_count: usize,
    /// Benchmarks within threshold.
    stable: []StableEntry,
    stable_count: usize,
    /// Overall verdict - false if any regression exceeds fail threshold.
    passed: bool,
    /// Baseline timestamp for reporting.
    baseline_timestamp: i64,
    /// Baseline version for reporting.
    baseline_version: [64]u8,
    baseline_version_len: usize,

    /// Prints a formatted comparison report to debug output.
    pub fn printReport(self: *const ComparisonResult) void {
        std.debug.print("\n=== Benchmark Comparison vs Baseline ===\n", .{});
        std.debug.print("Baseline: {s}\n\n", .{self.baseline_version[0..self.baseline_version_len]});

        // Print regressions
        if (self.regression_count > 0) {
            std.debug.print("REGRESSIONS (action required):\n", .{});
            for (self.regressions[0..self.regression_count]) |reg| {
                const marker: []const u8 = if (reg.exceeds_fail_threshold) "FAIL" else "WARNING";
                const icon: []const u8 = if (reg.exceeds_fail_threshold) "X" else "!";
                std.debug.print("{s} {s}: {d:>10} -> {d:>10} ns (+{d:.1}%) {s}\n", .{
                    icon,
                    reg.getName(),
                    reg.baseline_p50,
                    reg.current_p50,
                    reg.change_percent * 100.0,
                    marker,
                });
            }
            std.debug.print("\n", .{});
        }

        // Print improvements
        if (self.improvement_count > 0) {
            std.debug.print("IMPROVEMENTS:\n", .{});
            for (self.improvements[0..self.improvement_count]) |imp| {
                std.debug.print("+ {s}: {d:>10} -> {d:>10} ns ({d:.1}%)\n", .{
                    imp.getName(),
                    imp.baseline_p50,
                    imp.current_p50,
                    imp.change_percent * 100.0,
                });
            }
            std.debug.print("\n", .{});
        }

        // Print stable
        if (self.stable_count > 0) {
            std.debug.print("STABLE (within threshold):\n", .{});
            for (self.stable[0..self.stable_count]) |stb| {
                const sign: []const u8 = if (stb.change_percent >= 0) "+" else "";
                std.debug.print("  {s}: {d:>10} -> {d:>10} ns ({s}{d:.1}%)\n", .{
                    stb.getName(),
                    stb.baseline_p50,
                    stb.current_p50,
                    sign,
                    stb.change_percent * 100.0,
                });
            }
            std.debug.print("\n", .{});
        }

        // Summary
        std.debug.print("Summary: {d} regressions, {d} improvements, {d} stable\n", .{
            self.regression_count,
            self.improvement_count,
            self.stable_count,
        });

        const result_str: []const u8 = if (self.passed) "PASS" else "FAIL (regression threshold exceeded)";
        std.debug.print("Result: {s}\n\n", .{result_str});
    }
};

// ============================================================================
// Baseline Container
// ============================================================================

/// A stored baseline containing benchmark results for comparison.
pub const Baseline = struct {
    /// Stored benchmark entries.
    entries: [MAX_ENTRIES]BaselineEntry,
    entry_count: usize,
    /// When this baseline was captured (Unix timestamp).
    timestamp: i64,
    /// Git commit hash (optional, 40 hex chars).
    commit_hash: [40]u8,
    has_commit_hash: bool,
    /// Version identifier.
    version: [64]u8,
    version_len: usize,

    /// Initializes an empty baseline.
    pub fn init() Baseline {
        return Baseline{
            .entries = undefined,
            .entry_count = 0,
            .timestamp = 0,
            .commit_hash = undefined,
            .has_commit_hash = false,
            .version = undefined,
            .version_len = 0,
        };
    }

    /// Sets the version string.
    pub fn setVersion(self: *Baseline, version: []const u8) void {
        std.debug.assert(version.len <= 64);
        @memset(&self.version, 0);
        @memcpy(self.version[0..version.len], version);
        self.version_len = version.len;
    }

    /// Sets the commit hash.
    pub fn setCommitHash(self: *Baseline, hash: []const u8) void {
        std.debug.assert(hash.len == 40);
        @memcpy(&self.commit_hash, hash[0..40]);
        self.has_commit_hash = true;
    }

    /// Adds an entry to the baseline.
    ///
    /// Pre-conditions:
    /// - self.entry_count < MAX_ENTRIES
    ///
    /// Post-conditions:
    /// - Entry is added, count incremented.
    pub fn addEntry(self: *Baseline, entry: BaselineEntry) void {
        std.debug.assert(self.entry_count < MAX_ENTRIES);
        self.entries[self.entry_count] = entry;
        self.entry_count += 1;
    }

    /// Finds an entry by name.
    ///
    /// Returns: Entry pointer if found, null otherwise.
    pub fn findByName(self: *const Baseline, name: []const u8) ?*const BaselineEntry {
        for (self.entries[0..self.entry_count]) |*entry| {
            if (mem.eql(u8, entry.getName(), name)) {
                return entry;
            }
        }
        return null;
    }

    /// Returns entries as a slice.
    pub fn getEntries(self: *const Baseline) []const BaselineEntry {
        return self.entries[0..self.entry_count];
    }

    /// Returns version as a slice.
    pub fn getVersion(self: *const Baseline) []const u8 {
        return self.version[0..self.version_len];
    }
};

// ============================================================================
// Comparison Logic
// ============================================================================

/// Calculates the percentage change between baseline and current values.
///
/// Formula: (current - baseline) / baseline
/// Positive result means current is slower (regression).
/// Negative result means current is faster (improvement).
///
/// Pre-conditions:
/// - baseline_ns > 0
///
/// Post-conditions:
/// - Result is not NaN.
pub fn calculateChange(baseline_ns: u64, current_ns: u64) f64 {
    std.debug.assert(baseline_ns > 0);

    const base_f = @as(f64, @floatFromInt(baseline_ns));
    const curr_f = @as(f64, @floatFromInt(current_ns));
    const result = (curr_f - base_f) / base_f;

    std.debug.assert(!math.isNan(result));
    return result;
}

/// Compares current benchmark results against a baseline.
///
/// Classification:
/// - Regression: change > regression_threshold (slower)
/// - Improvement: change < -improvement_threshold (faster)
/// - Stable: within thresholds
///
/// Pre-conditions:
/// - options.isValid() must be true
/// - baseline.entry_count > 0
///
/// Post-conditions:
/// - All current entries are classified.
/// - passed is false if any regression exceeds fail_threshold.
pub fn compare(
    baseline: *const Baseline,
    current: []const BaselineEntry,
    options: CompareOptions,
    // Output buffers (caller provides storage)
    reg_buf: []RegressionEntry,
    imp_buf: []ImprovementEntry,
    stb_buf: []StableEntry,
) ComparisonResult {
    // Pre-conditions
    std.debug.assert(options.isValid());

    var result = ComparisonResult{
        .regressions = reg_buf,
        .regression_count = 0,
        .improvements = imp_buf,
        .improvement_count = 0,
        .stable = stb_buf,
        .stable_count = 0,
        .passed = true,
        .baseline_timestamp = baseline.timestamp,
        .baseline_version = baseline.version,
        .baseline_version_len = baseline.version_len,
    };

    // Compare each current entry against baseline
    for (current) |curr| {
        const base_entry = baseline.findByName(curr.getName()) orelse continue;

        // Skip if baseline has zero (invalid data)
        if (base_entry.p50_ns == 0) continue;

        const change = calculateChange(base_entry.p50_ns, curr.p50_ns);

        if (change > options.regression_threshold) {
            // Regression detected
            const exceeds_fail = change > options.fail_threshold;
            if (exceeds_fail) {
                result.passed = false;
            }

            if (result.regression_count < reg_buf.len) {
                var reg = RegressionEntry{
                    .name = undefined,
                    .name_len = curr.name_len,
                    .baseline_p50 = base_entry.p50_ns,
                    .current_p50 = curr.p50_ns,
                    .change_percent = change,
                    .exceeds_fail_threshold = exceeds_fail,
                };
                @memcpy(&reg.name, &curr.name);
                result.regressions[result.regression_count] = reg;
                result.regression_count += 1;
            }
        } else if (change < -options.improvement_threshold) {
            // Improvement detected
            if (result.improvement_count < imp_buf.len) {
                var imp = ImprovementEntry{
                    .name = undefined,
                    .name_len = curr.name_len,
                    .baseline_p50 = base_entry.p50_ns,
                    .current_p50 = curr.p50_ns,
                    .change_percent = change,
                };
                @memcpy(&imp.name, &curr.name);
                result.improvements[result.improvement_count] = imp;
                result.improvement_count += 1;
            }
        } else {
            // Stable
            if (result.stable_count < stb_buf.len) {
                var stb = StableEntry{
                    .name = undefined,
                    .name_len = curr.name_len,
                    .baseline_p50 = base_entry.p50_ns,
                    .current_p50 = curr.p50_ns,
                    .change_percent = change,
                };
                @memcpy(&stb.name, &curr.name);
                result.stable[result.stable_count] = stb;
                result.stable_count += 1;
            }
        }
    }

    return result;
}

// ============================================================================
// File I/O
// ============================================================================

/// Parses a baseline from file content.
///
/// Pre-conditions:
/// - content is valid UTF-8 text.
///
/// Post-conditions:
/// - Returns null if parsing fails.
/// - Returns valid Baseline if successful.
pub fn parse(content: []const u8) ?Baseline {
    var baseline = Baseline.init();

    var lines = mem.splitScalar(u8, content, '\n');
    var header_found = false;

    while (lines.next()) |line| {
        // Skip empty lines
        const trimmed = mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Parse header comments
        if (trimmed[0] == '#') {
            if (!header_found and mem.startsWith(u8, trimmed, HEADER_PREFIX)) {
                header_found = true;
            } else if (mem.startsWith(u8, trimmed, "# Version:")) {
                const version = mem.trim(u8, trimmed["# Version:".len..], " ");
                if (version.len > 0 and version.len <= 64) {
                    baseline.setVersion(version);
                }
            } else if (mem.startsWith(u8, trimmed, "# Timestamp:")) {
                const ts_str = mem.trim(u8, trimmed["# Timestamp:".len..], " ");
                baseline.timestamp = std.fmt.parseInt(i64, ts_str, 10) catch 0;
            } else if (mem.startsWith(u8, trimmed, "# Commit:")) {
                const hash = mem.trim(u8, trimmed["# Commit:".len..], " ");
                if (hash.len == 40) {
                    baseline.setCommitHash(hash);
                }
            }
            continue;
        }

        // Parse data line: name,p50,p90,p99,iterations
        const entry = parseDataLine(trimmed) orelse continue;
        if (baseline.entry_count < MAX_ENTRIES) {
            baseline.addEntry(entry);
        }
    }

    // Validate we got some entries
    if (baseline.entry_count == 0) return null;

    return baseline;
}

/// Parses a single data line into a BaselineEntry.
fn parseDataLine(line: []const u8) ?BaselineEntry {
    var parts = mem.splitScalar(u8, line, ',');

    const name = parts.next() orelse return null;
    if (name.len == 0 or name.len > MAX_NAME_LEN) return null;

    const p50_str = parts.next() orelse return null;
    const p90_str = parts.next() orelse return null;
    const p99_str = parts.next() orelse return null;
    const iter_str = parts.next() orelse return null;

    const p50 = std.fmt.parseInt(u64, p50_str, 10) catch return null;
    const p90 = std.fmt.parseInt(u64, p90_str, 10) catch return null;
    const p99 = std.fmt.parseInt(u64, p99_str, 10) catch return null;
    const iterations = std.fmt.parseInt(u64, iter_str, 10) catch return null;

    if (iterations == 0) return null;

    return BaselineEntry.init(name, p50, p90, p99, iterations);
}

/// Formats a baseline to file content.
///
/// Pre-conditions:
/// - baseline has valid data.
/// - buf must be large enough to hold the formatted content.
///
/// Returns: Number of bytes written, or error.
pub fn format(baseline: *const Baseline, buf: []u8) !usize {
    var pos: usize = 0;

    // Write header
    pos = try appendLine(buf, pos, HEADER_PREFIX);
    pos = try appendFmt(buf, pos, "# Version: {s}\n", .{baseline.getVersion()});
    pos = try appendFmt(buf, pos, "# Timestamp: {d}\n", .{baseline.timestamp});
    if (baseline.has_commit_hash) {
        pos = try appendFmt(buf, pos, "# Commit: {s}\n", .{&baseline.commit_hash});
    }
    pos = try appendLine(buf, pos, "");

    // Write entries
    for (baseline.getEntries()) |entry| {
        pos = try appendFmt(buf, pos, "{s},{d},{d},{d},{d}\n", .{
            entry.getName(),
            entry.p50_ns,
            entry.p90_ns,
            entry.p99_ns,
            entry.iterations,
        });
    }

    return pos;
}

/// Appends a line to the buffer.
fn appendLine(buf: []u8, pos: usize, line: []const u8) !usize {
    if (pos + line.len + 1 > buf.len) return error.BufferTooSmall;
    @memcpy(buf[pos .. pos + line.len], line);
    buf[pos + line.len] = '\n';
    return pos + line.len + 1;
}

/// Appends formatted content to the buffer.
fn appendFmt(buf: []u8, pos: usize, comptime fmt: []const u8, args: anytype) !usize {
    const remaining = buf[pos..];
    const written = std.fmt.bufPrint(remaining, fmt, args) catch return error.BufferTooSmall;
    return pos + written.len;
}

/// Loads a baseline from a file path.
///
/// Returns: Baseline if loaded successfully, null otherwise.
pub fn load(allocator: std.mem.Allocator, path: []const u8) ?Baseline {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content);

    return parse(content);
}

/// Saves a baseline to a file path.
///
/// Returns: Error if save fails.
pub fn save(baseline: *const Baseline, path: []const u8) !void {
    var buf: [64 * 1024]u8 = undefined;
    const len = try format(baseline, &buf);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(buf[0..len]);
}

// ============================================================================
// Tests
// ============================================================================

test "BaselineEntry fromBenchResult" {
    const bench_result = runner.BenchResult{
        .name = "test_benchmark",
        .stats = stats.Stats{
            .iterations = 1000,
            .total_ns = 50_000_000,
            .min_ns = 45_000,
            .max_ns = 55_000,
            .p50_ns = 50_000,
            .p75_ns = 52_000,
            .p90_ns = 53_000,
            .p99_ns = 54_000,
            .mean_ns = 50_000,
            .stddev_ns = 2_000,
        },
    };

    const entry = BaselineEntry.fromBenchResult(bench_result);

    try std.testing.expectEqualStrings("test_benchmark", entry.getName());
    try std.testing.expectEqual(@as(u64, 50_000), entry.p50_ns);
    try std.testing.expectEqual(@as(u64, 53_000), entry.p90_ns);
    try std.testing.expectEqual(@as(u64, 54_000), entry.p99_ns);
    try std.testing.expectEqual(@as(u64, 1000), entry.iterations);
}

test "BaselineEntry init" {
    const entry = BaselineEntry.init("my_bench", 100, 200, 300, 500);

    try std.testing.expectEqualStrings("my_bench", entry.getName());
    try std.testing.expectEqual(@as(u64, 100), entry.p50_ns);
    try std.testing.expectEqual(@as(u64, 200), entry.p90_ns);
    try std.testing.expectEqual(@as(u64, 300), entry.p99_ns);
    try std.testing.expectEqual(@as(u64, 500), entry.iterations);
}

test "CompareOptions validation" {
    const valid = CompareOptions{
        .regression_threshold = 0.10,
        .improvement_threshold = 0.10,
        .fail_threshold = 0.20,
    };
    try std.testing.expect(valid.isValid());

    const invalid_zero = CompareOptions{
        .regression_threshold = 0.0,
        .improvement_threshold = 0.10,
        .fail_threshold = 0.20,
    };
    try std.testing.expect(!invalid_zero.isValid());

    const invalid_one = CompareOptions{
        .regression_threshold = 1.0,
        .improvement_threshold = 0.10,
        .fail_threshold = 0.20,
    };
    try std.testing.expect(!invalid_one.isValid());
}

test "calculateChange positive (regression)" {
    // 10% slower: 100 -> 110
    const change = calculateChange(100, 110);
    try std.testing.expectApproxEqAbs(@as(f64, 0.10), change, 0.001);

    // 50% slower: 100 -> 150
    const change2 = calculateChange(100, 150);
    try std.testing.expectApproxEqAbs(@as(f64, 0.50), change2, 0.001);
}

test "calculateChange negative (improvement)" {
    // 10% faster: 100 -> 90
    const change = calculateChange(100, 90);
    try std.testing.expectApproxEqAbs(@as(f64, -0.10), change, 0.001);

    // 20% faster: 100 -> 80
    const change2 = calculateChange(100, 80);
    try std.testing.expectApproxEqAbs(@as(f64, -0.20), change2, 0.001);
}

test "comparison detects regression" {
    var baseline = Baseline.init();
    baseline.setVersion("1.0.0");
    baseline.addEntry(BaselineEntry.init("bench_a", 100_000, 110_000, 120_000, 1000));

    var current = [_]BaselineEntry{
        BaselineEntry.init("bench_a", 125_000, 135_000, 145_000, 1000), // 25% slower
    };

    var reg_buf: [64]RegressionEntry = undefined;
    var imp_buf: [64]ImprovementEntry = undefined;
    var stb_buf: [64]StableEntry = undefined;

    const result = compare(&baseline, &current, .{}, &reg_buf, &imp_buf, &stb_buf);

    try std.testing.expectEqual(@as(usize, 1), result.regression_count);
    try std.testing.expectEqual(@as(usize, 0), result.improvement_count);
    try std.testing.expectEqual(@as(usize, 0), result.stable_count);
    try std.testing.expect(!result.passed); // 25% > 20% fail threshold
    try std.testing.expect(result.regressions[0].exceeds_fail_threshold);
}

test "comparison detects improvement" {
    var baseline = Baseline.init();
    baseline.setVersion("1.0.0");
    baseline.addEntry(BaselineEntry.init("bench_b", 100_000, 110_000, 120_000, 1000));

    var current = [_]BaselineEntry{
        BaselineEntry.init("bench_b", 80_000, 88_000, 96_000, 1000), // 20% faster
    };

    var reg_buf: [64]RegressionEntry = undefined;
    var imp_buf: [64]ImprovementEntry = undefined;
    var stb_buf: [64]StableEntry = undefined;

    const result = compare(&baseline, &current, .{}, &reg_buf, &imp_buf, &stb_buf);

    try std.testing.expectEqual(@as(usize, 0), result.regression_count);
    try std.testing.expectEqual(@as(usize, 1), result.improvement_count);
    try std.testing.expectEqual(@as(usize, 0), result.stable_count);
    try std.testing.expect(result.passed);
}

test "comparison detects stable" {
    var baseline = Baseline.init();
    baseline.setVersion("1.0.0");
    baseline.addEntry(BaselineEntry.init("bench_c", 100_000, 110_000, 120_000, 1000));

    var current = [_]BaselineEntry{
        BaselineEntry.init("bench_c", 105_000, 115_000, 125_000, 1000), // 5% slower (within threshold)
    };

    var reg_buf: [64]RegressionEntry = undefined;
    var imp_buf: [64]ImprovementEntry = undefined;
    var stb_buf: [64]StableEntry = undefined;

    const result = compare(&baseline, &current, .{}, &reg_buf, &imp_buf, &stb_buf);

    try std.testing.expectEqual(@as(usize, 0), result.regression_count);
    try std.testing.expectEqual(@as(usize, 0), result.improvement_count);
    try std.testing.expectEqual(@as(usize, 1), result.stable_count);
    try std.testing.expect(result.passed);
}

test "file format round trip" {
    // Create baseline
    var base = Baseline.init();
    base.setVersion("2.0.0");
    base.timestamp = 1701492000;
    base.addEntry(BaselineEntry.init("entity_spawn", 50000, 55000, 60000, 1000));
    base.addEntry(BaselineEntry.init("query_single", 30000, 33000, 38000, 500));

    // Format to buffer
    var buf: [4096]u8 = undefined;
    const len = try format(&base, &buf);

    // Parse back
    const parsed = parse(buf[0..len]) orelse {
        return error.ParseFailed;
    };

    try std.testing.expectEqualStrings("2.0.0", parsed.getVersion());
    try std.testing.expectEqual(@as(i64, 1701492000), parsed.timestamp);
    try std.testing.expectEqual(@as(usize, 2), parsed.entry_count);

    const entry1 = parsed.findByName("entity_spawn") orelse return error.EntryNotFound;
    try std.testing.expectEqual(@as(u64, 50000), entry1.p50_ns);

    const entry2 = parsed.findByName("query_single") orelse return error.EntryNotFound;
    try std.testing.expectEqual(@as(u64, 30000), entry2.p50_ns);
}

test "parse handles empty content" {
    const result = parse("");
    try std.testing.expect(result == null);
}

test "parse handles invalid data lines" {
    const content =
        \\# StaticECS Benchmark Baseline
        \\# Version: 1.0.0
        \\# Timestamp: 1701492000
        \\
        \\invalid_line_no_commas
        \\also,missing,fields
        \\valid_entry,100,200,300,500
    ;

    const parsed = parse(content) orelse return error.ParseFailed;
    // Only the valid entry should be parsed
    try std.testing.expectEqual(@as(usize, 1), parsed.entry_count);
}

test "Baseline findByName" {
    var baseline = Baseline.init();
    baseline.addEntry(BaselineEntry.init("alpha", 100, 200, 300, 1000));
    baseline.addEntry(BaselineEntry.init("beta", 400, 500, 600, 1000));
    baseline.addEntry(BaselineEntry.init("gamma", 700, 800, 900, 1000));

    const alpha = baseline.findByName("alpha") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u64, 100), alpha.p50_ns);

    const gamma = baseline.findByName("gamma") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u64, 700), gamma.p50_ns);

    try std.testing.expect(baseline.findByName("nonexistent") == null);
}

test "comparison with custom thresholds" {
    var baseline = Baseline.init();
    baseline.setVersion("1.0.0");
    baseline.addEntry(BaselineEntry.init("bench_d", 100_000, 110_000, 120_000, 1000));

    // 15% slower
    var current = [_]BaselineEntry{
        BaselineEntry.init("bench_d", 115_000, 126_500, 138_000, 1000),
    };

    var reg_buf: [64]RegressionEntry = undefined;
    var imp_buf: [64]ImprovementEntry = undefined;
    var stb_buf: [64]StableEntry = undefined;

    // With default thresholds (10% regression, 20% fail), this should be warning
    const result1 = compare(&baseline, &current, .{}, &reg_buf, &imp_buf, &stb_buf);
    try std.testing.expectEqual(@as(usize, 1), result1.regression_count);
    try std.testing.expect(result1.passed); // 15% < 20% fail threshold

    // With stricter thresholds (5% regression, 10% fail), this should fail
    const strict_opts = CompareOptions{
        .regression_threshold = 0.05,
        .improvement_threshold = 0.05,
        .fail_threshold = 0.10,
    };
    const result2 = compare(&baseline, &current, strict_opts, &reg_buf, &imp_buf, &stb_buf);
    try std.testing.expectEqual(@as(usize, 1), result2.regression_count);
    try std.testing.expect(!result2.passed); // 15% > 10% fail threshold
}
