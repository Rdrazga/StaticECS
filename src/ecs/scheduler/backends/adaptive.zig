//! Adaptive Hybrid Scheduler Backend
//!
//! This backend dynamically switches between underlying backends based on
//! runtime metrics. It monitors I/O load and CPU imbalance to select the
//! most appropriate execution strategy.
//!
//! ## Characteristics
//!
//! - **Execution**: Dynamic, switches between backends
//! - **Scheduling**: Based on runtime metrics
//! - **Best For**: Mixed workloads with varying I/O and CPU patterns
//! - **Overhead**: Metrics collection, occasional backend switches
//!
//! ## Algorithm
//!
//! 1. Collect metrics before and after each tick
//! 2. Maintain rolling average over configured window
//! 3. Check thresholds for switching:
//!    - High I/O load → io_uring batch (if available) or blocking
//!    - CPU imbalance → work stealing
//!    - Light load → blocking (lowest overhead)
//! 4. Apply cooldown to prevent oscillation
//!
//! ## Usage
//!
//! ```zig
//! const cfg = ecs.WorldConfig{
//!     .schedule = .{
//!         .execution_model = .adaptive_hybrid,
//!         .backend_config = .{ .adaptive = .{
//!             .batch_threshold = 64,
//!             .imbalance_threshold = 0.3,
//!             .window_size = 100,
//!             .switch_cooldown = 10,
//!         }},
//!     },
//! };
//! ```
//!
//! Tiger Style: Metric-driven switching, configurable thresholds, cooldown.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const config_mod = @import("../../config.zig");
const WorldConfig = config_mod.WorldConfig;
const FramePolicy = config_mod.FramePolicy;
const TraceLevel = config_mod.TraceLevel;
const ExecutionModel = config_mod.ExecutionModel;
const AdaptiveConfig = config_mod.AdaptiveConfig;

const error_types = @import("../../error/error_types.zig");
const FrameResultType = error_types.FrameResultType;

const tracing = @import("../../trace/tracing.zig");
const TraceSink = tracing.TraceSink;

const interface = @import("interface.zig");
const BackendStats = interface.BackendStats;
const getTimeNs = interface.getTimeNs;

// Sub-backends
const blocking = @import("blocking.zig");
const BlockingBackend = blocking.BlockingBackend;

const work_stealing = @import("work_stealing.zig");
const WorkStealingBackend = work_stealing.WorkStealingBackend;

// ============================================================================
// I/O Metrics Constants
// ============================================================================

/// Maximum value for saturation counters to prevent overflow.
/// Tiger Style: All counters bounded to prevent unbounded growth.
const MAX_COUNTER: u64 = std.math.maxInt(u63);

/// Sentinel value for uninitialized latency.
const LATENCY_UNSET: u64 = std.math.maxInt(u64);

/// Number of latency histogram buckets (power-of-2 ranges).
/// Covers 1ns to ~1s in 30 buckets (2^0 to 2^30).
const LATENCY_BUCKETS: usize = 31;

// ============================================================================
// Adaptive Backend
// ============================================================================

/// Adaptive backend that switches between strategies based on runtime metrics.
///
/// The backend monitors:
/// - Pending I/O operations (suggests batching would help)
/// - CPU load imbalance (suggests work stealing would help)
///
/// Tiger Style: All thresholds configurable, metric-driven decisions.
pub fn AdaptiveBackend(comptime cfg: WorldConfig, comptime WorldType: type) type {
    // Extract config with defaults
    const adaptive_cfg: AdaptiveConfig = switch (cfg.schedule.backend_config) {
        .adaptive => |c| c,
        else => .{}, // Use defaults if not specified
    };

    // Window size for rolling averages (compile-time bounded)
    const window_size: u32 = if (adaptive_cfg.window_size > 256) 256 else adaptive_cfg.window_size;

    // Config-based result type
    const FrameResultT = FrameResultType(cfg.options.max_aggregate_errors);

    // Sub-backend types
    const BlockingBE = BlockingBackend(cfg, WorldType);
    const WorkStealingBE = WorkStealingBackend(cfg, WorldType);

    return struct {
        const Self = @This();

        /// Active execution mode.
        pub const Mode = enum(u8) {
            /// Simple blocking execution (lowest overhead).
            blocking,
            /// Work-stealing parallel execution.
            work_stealing,
        };

        // ─────────────────────────────────────────────────────────────────────
        // I/O Metrics Types
        // ─────────────────────────────────────────────────────────────────────

        /// I/O operation metrics for adaptive backend decision-making.
        ///
        /// Tracks comprehensive I/O statistics including operation counts,
        /// latencies, and intensity metrics used to determine optimal backend.
        ///
        /// Tiger Style:
        /// - All counters are saturating (bounded at MAX_COUNTER)
        /// - Latency min/max/avg tracked with proper initialization
        /// - Rolling window for intensity calculation (bounded by window_size)
        ///
        /// ## Usage
        /// ```zig
        /// const metrics = backend.getIOMetrics();
        /// if (metrics.getIOIntensity() > 10.0) {
        ///     // High I/O intensity detected
        /// }
        /// ```
        pub const IOMetrics = struct {
            // ─── Operation Counters ───
            /// Total I/O operations requested (saturating counter).
            total_ops_requested: u64 = 0,
            /// Currently pending I/O operations.
            pending_ops: u32 = 0,
            /// Maximum pending ops observed (high-water mark).
            peak_pending_ops: u32 = 0,
            /// Total I/O operations completed (saturating counter).
            completed_ops: u64 = 0,
            /// Total I/O operations that failed.
            failed_ops: u64 = 0,

            // ─── Latency Tracking (nanoseconds) ───
            /// Minimum observed I/O latency (LATENCY_UNSET if no ops).
            latency_min_ns: u64 = LATENCY_UNSET,
            /// Maximum observed I/O latency.
            latency_max_ns: u64 = 0,
            /// Sum of all latencies for average calculation.
            latency_sum_ns: u64 = 0,
            /// Count of latency samples (for average calculation).
            latency_sample_count: u64 = 0,

            // ─── Per-Frame Metrics ───
            /// Operations in current frame.
            current_frame_ops: u32 = 0,
            /// Operations in previous frame (for delta).
            last_frame_ops: u32 = 0,

            // ─── Rolling Window for Intensity ───
            /// Ring buffer of per-tick I/O counts.
            ops_per_tick: [window_size]u32 = [_]u32{0} ** window_size,
            /// Current index in ring buffer.
            tick_index: u32 = 0,
            /// Number of valid samples in ring buffer.
            tick_sample_count: u32 = 0,
            /// Cached rolling sum for efficiency.
            rolling_sum: u64 = 0,

            // ─── Peak Detection ───
            /// Peak I/O operations in a single tick.
            peak_ops_per_tick: u32 = 0,
            /// Tick count when peak was observed.
            peak_tick: u64 = 0,
            /// Number of ticks exceeding intensity threshold.
            high_intensity_ticks: u64 = 0,

            /// Record a new I/O operation request.
            /// Tiger Style: Saturating increment, assertion on invariant.
            pub fn recordRequest(self: *IOMetrics) void {
                // Saturating increment to prevent overflow
                if (self.total_ops_requested < MAX_COUNTER) {
                    self.total_ops_requested += 1;
                }

                // Track pending with bounded increment
                if (self.pending_ops < std.math.maxInt(u32)) {
                    self.pending_ops += 1;
                }

                // Update peak if needed
                if (self.pending_ops > self.peak_pending_ops) {
                    self.peak_pending_ops = self.pending_ops;
                }

                // Frame counter
                if (self.current_frame_ops < std.math.maxInt(u32)) {
                    self.current_frame_ops += 1;
                }

                // Invariant: pending <= total_requested - completed
                assert(self.pending_ops <= self.total_ops_requested - self.completed_ops + self.failed_ops);
            }

            /// Record an I/O operation completion with latency.
            /// Tiger Style: Validates pending > 0, tracks latency bounds.
            pub fn recordCompletion(self: *IOMetrics, latency_ns: u64, success: bool) void {
                // Decrement pending (should always be > 0)
                if (self.pending_ops > 0) {
                    self.pending_ops -= 1;
                }

                if (success) {
                    // Saturating increment completed
                    if (self.completed_ops < MAX_COUNTER) {
                        self.completed_ops += 1;
                    }
                } else {
                    // Track failures
                    if (self.failed_ops < MAX_COUNTER) {
                        self.failed_ops += 1;
                    }
                }

                // Track latency (only for successful ops with valid latency)
                if (success and latency_ns > 0 and latency_ns < LATENCY_UNSET) {
                    // Update min
                    if (latency_ns < self.latency_min_ns) {
                        self.latency_min_ns = latency_ns;
                    }
                    // Update max
                    if (latency_ns > self.latency_max_ns) {
                        self.latency_max_ns = latency_ns;
                    }
                    // Update sum (saturating)
                    const headroom = MAX_COUNTER - self.latency_sum_ns;
                    if (latency_ns <= headroom) {
                        self.latency_sum_ns += latency_ns;
                        self.latency_sample_count += 1;
                    }
                }

                // Invariant: completed + failed + pending == total_requested
                assert(self.completed_ops + self.failed_ops + self.pending_ops == self.total_ops_requested);
            }

            /// Called at end of each tick to update rolling metrics.
            /// Tiger Style: Bounded ring buffer, cached sum for O(1) average.
            pub fn endTick(self: *IOMetrics, tick_count: u64) void {
                const ops_this_tick = self.current_frame_ops;

                // Subtract old value from rolling sum before overwriting
                if (self.tick_sample_count == window_size) {
                    self.rolling_sum -= self.ops_per_tick[self.tick_index];
                }

                // Store current tick's ops
                self.ops_per_tick[self.tick_index] = ops_this_tick;

                // Add to rolling sum
                self.rolling_sum += ops_this_tick;

                // Advance ring buffer
                self.tick_index = (self.tick_index + 1) % window_size;
                if (self.tick_sample_count < window_size) {
                    self.tick_sample_count += 1;
                }

                // Peak detection
                if (ops_this_tick > self.peak_ops_per_tick) {
                    self.peak_ops_per_tick = ops_this_tick;
                    self.peak_tick = tick_count;
                }

                // High intensity detection (>2x average intensity)
                const avg = self.getIOIntensity();
                if (@as(f32, @floatFromInt(ops_this_tick)) > avg * 2.0 and avg > 0) {
                    if (self.high_intensity_ticks < MAX_COUNTER) {
                        self.high_intensity_ticks += 1;
                    }
                }

                // Reset frame counter for next tick
                self.last_frame_ops = ops_this_tick;
                self.current_frame_ops = 0;
            }

            /// Get average I/O operations per tick (intensity).
            /// Returns 0.0 if no samples collected.
            pub fn getIOIntensity(self: *const IOMetrics) f32 {
                if (self.tick_sample_count == 0) return 0.0;
                return @as(f32, @floatFromInt(self.rolling_sum)) /
                    @as(f32, @floatFromInt(self.tick_sample_count));
            }

            /// Get average I/O latency in nanoseconds.
            /// Returns 0 if no latency samples.
            pub fn getAverageLatencyNs(self: *const IOMetrics) u64 {
                if (self.latency_sample_count == 0) return 0;
                return self.latency_sum_ns / self.latency_sample_count;
            }

            /// Check if I/O intensity suggests io_uring would be beneficial.
            /// Tiger Style: Clear threshold-based decision.
            pub fn shouldUseIOUring(self: *const IOMetrics) bool {
                const intensity = self.getIOIntensity();
                // High I/O intensity (more than batch_threshold ops/tick avg)
                // suggests batching would be beneficial
                return intensity >= @as(f32, @floatFromInt(adaptive_cfg.batch_threshold));
            }

            /// Reset all metrics to initial state.
            pub fn reset(self: *IOMetrics) void {
                self.* = IOMetrics{};
            }
        };

        /// Metrics sample for one tick.
        pub const Sample = struct {
            /// Timestamp of this sample.
            timestamp: u64,
            /// Tick duration in nanoseconds.
            tick_duration_ns: u64,
            /// Estimated pending I/O operations.
            pending_io: u32,
            /// Systems executed this tick.
            systems_executed: u32,
        };

        /// Rolling metrics over the window.
        pub const Metrics = struct {
            /// Sample ring buffer.
            samples: [window_size]Sample,
            /// Current sample index.
            sample_idx: u32,
            /// Number of valid samples.
            sample_count: u32,
            /// Rolling average of pending I/O.
            pending_io_avg: f32,
            /// Rolling average of tick duration (for imbalance detection).
            tick_duration_avg: f32,
            /// Rolling variance of tick duration (for imbalance detection).
            tick_duration_variance: f32,

            pub fn init() Metrics {
                return .{
                    .samples = [_]Sample{.{
                        .timestamp = 0,
                        .tick_duration_ns = 0,
                        .pending_io = 0,
                        .systems_executed = 0,
                    }} ** window_size,
                    .sample_idx = 0,
                    .sample_count = 0,
                    .pending_io_avg = 0,
                    .tick_duration_avg = 0,
                    .tick_duration_variance = 0,
                };
            }

            /// Add a new sample and update rolling averages.
            pub fn addSample(self: *Metrics, sample: Sample) void {
                self.samples[self.sample_idx] = sample;
                self.sample_idx = (self.sample_idx + 1) % window_size;
                if (self.sample_count < window_size) {
                    self.sample_count += 1;
                }

                // Recalculate rolling averages
                self.recalculateAverages();
            }

            fn recalculateAverages(self: *Metrics) void {
                if (self.sample_count == 0) return;

                var io_sum: f64 = 0;
                var duration_sum: f64 = 0;

                const count = self.sample_count;
                for (self.samples[0..count]) |s| {
                    io_sum += @as(f64, @floatFromInt(s.pending_io));
                    duration_sum += @as(f64, @floatFromInt(s.tick_duration_ns));
                }

                self.pending_io_avg = @floatCast(io_sum / @as(f64, @floatFromInt(count)));
                self.tick_duration_avg = @floatCast(duration_sum / @as(f64, @floatFromInt(count)));

                // Calculate variance for imbalance detection
                var variance_sum: f64 = 0;
                for (self.samples[0..count]) |s| {
                    const diff = @as(f64, @floatFromInt(s.tick_duration_ns)) - duration_sum / @as(f64, @floatFromInt(count));
                    variance_sum += diff * diff;
                }
                self.tick_duration_variance = @floatCast(variance_sum / @as(f64, @floatFromInt(count)));
            }

            /// Calculate imbalance ratio (coefficient of variation).
            pub fn getImbalanceRatio(self: *const Metrics) f32 {
                if (self.tick_duration_avg < 1.0) return 0;
                const std_dev = @sqrt(self.tick_duration_variance);
                return @floatCast(std_dev / self.tick_duration_avg);
            }
        };

        // Instance state
        allocator: Allocator,
        trace_sink: ?TraceSink,
        tick_count: u64,
        stats: BackendStats,

        // Current mode and cooldown
        current_mode: Mode,
        cooldown: u32,

        // Sub-backends
        blocking_backend: BlockingBE,
        work_stealing_backend: WorkStealingBE,

        // Metrics
        metrics: Metrics,

        // I/O Metrics for adaptive decisions
        io_metrics: IOMetrics,

        /// Initialize the adaptive backend.
        pub fn init(allocator: Allocator, trace_sink: ?TraceSink) Self {
            // Determine initial mode
            const initial_mode: Mode = if (adaptive_cfg.initial_backend) |ib| switch (ib) {
                .blocking_single_thread => .blocking,
                .work_stealing => .work_stealing,
                else => .blocking,
            } else .blocking;

            return Self{
                .allocator = allocator,
                .trace_sink = trace_sink,
                .tick_count = 0,
                .stats = .{},
                .current_mode = initial_mode,
                .cooldown = 0,
                .blocking_backend = BlockingBE.init(allocator, trace_sink),
                .work_stealing_backend = WorkStealingBE.init(allocator, trace_sink),
                .metrics = Metrics.init(),
                .io_metrics = IOMetrics{},
            };
        }

        /// Clean up resources.
        pub fn deinit(self: *Self) void {
            self.blocking_backend.deinit();
            self.work_stealing_backend.deinit();
        }

        /// Execute a single tick/frame with adaptive backend selection.
        pub fn tick(self: *Self, world: *WorldType, delta_time: f64) FrameResultT {
            const start_time = getTimeNs();

            // Execute with current backend
            const result = switch (self.current_mode) {
                .blocking => self.blocking_backend.tick(world, delta_time),
                .work_stealing => self.work_stealing_backend.tick(world, delta_time),
            };

            const end_time = getTimeNs();
            const tick_duration = end_time - start_time;

            // Collect metrics
            const sample = Sample{
                .timestamp = end_time,
                .tick_duration_ns = tick_duration,
                .pending_io = self.io_metrics.pending_ops,
                .systems_executed = @intCast(self.getCurrentBackendStats().systems_executed -
                    (if (self.tick_count > 0) self.stats.systems_executed else 0)),
            };
            self.metrics.addSample(sample);

            // Update I/O metrics for this tick
            self.io_metrics.endTick(self.tick_count);

            // Check for backend switch (after cooldown)
            if (self.cooldown == 0) {
                if (self.shouldSwitch()) |new_mode| {
                    self.switchTo(new_mode);
                    self.cooldown = adaptive_cfg.switch_cooldown;
                    self.stats.backend_switches += 1;
                }
            } else {
                self.cooldown -= 1;
            }

            // Update statistics
            self.tick_count += 1;
            self.stats.ticks_executed += 1;
            self.stats.systems_executed = self.getCurrentBackendStats().systems_executed;
            self.stats.phases_executed = self.getCurrentBackendStats().phases_executed;
            self.stats.tasks_stolen = self.getCurrentBackendStats().tasks_stolen;
            self.stats.last_tick_time_ns = tick_duration;
            self.stats.total_tick_time_ns += tick_duration;

            return result;
        }

        /// Reset backend state and statistics.
        pub fn reset(self: *Self) void {
            self.tick_count = 0;
            self.cooldown = 0;
            self.stats.reset();
            self.metrics = Metrics.init();
            self.io_metrics.reset();
            self.blocking_backend.reset();
            self.work_stealing_backend.reset();
        }

        /// Get backend statistics.
        pub fn getStats(self: *const Self) BackendStats {
            return self.stats;
        }

        /// Set or update the trace sink.
        pub fn setTraceSink(self: *Self, sink: ?TraceSink) void {
            self.trace_sink = sink;
            self.blocking_backend.setTraceSink(sink);
            self.work_stealing_backend.setTraceSink(sink);
        }

        /// Get tick count.
        pub fn getTickCount(self: *const Self) u64 {
            return self.tick_count;
        }

        /// Get current execution mode.
        pub fn getCurrentMode(self: *const Self) Mode {
            return self.current_mode;
        }

        /// Get current metrics.
        pub fn getMetrics(self: *const Self) Metrics {
            return self.metrics;
        }

        /// Get I/O operation metrics for monitoring and adaptive decisions.
        ///
        /// Returns a copy of the current I/O metrics including:
        /// - Operation counts (requested, pending, completed, failed)
        /// - Latency statistics (min, max, average)
        /// - I/O intensity (operations per tick rolling average)
        /// - Peak detection data
        ///
        /// Tiger Style: Returns copy for thread-safety, no allocation.
        pub fn getIOMetrics(self: *const Self) IOMetrics {
            return self.io_metrics;
        }

        /// Record an I/O operation request from a system.
        /// Call this when a system queues an I/O operation.
        pub fn recordIORequest(self: *Self) void {
            self.io_metrics.recordRequest();
        }

        /// Record an I/O operation completion.
        /// Call this when an I/O operation finishes.
        ///
        /// Parameters:
        /// - latency_ns: Operation latency in nanoseconds
        /// - success: Whether the operation succeeded
        pub fn recordIOCompletion(self: *Self, latency_ns: u64, success: bool) void {
            self.io_metrics.recordCompletion(latency_ns, success);
        }

        // ─────────────────────────────────────────────────────────────────────
        // Internal: Backend Switching Logic
        // ─────────────────────────────────────────────────────────────────────

        fn getCurrentBackendStats(self: *const Self) BackendStats {
            return switch (self.current_mode) {
                .blocking => self.blocking_backend.getStats(),
                .work_stealing => self.work_stealing_backend.getStats(),
            };
        }

        fn shouldSwitch(self: *Self) ?Mode {
            // Need enough samples for reliable decision
            if (self.metrics.sample_count < window_size / 2) {
                return null;
            }

            const imbalance = self.metrics.getImbalanceRatio();
            const io_intensity = self.io_metrics.getIOIntensity();

            // Decision logic based on I/O metrics and CPU imbalance:
            //
            // High I/O intensity (io_uring beneficial):
            //   - Currently we don't have io_uring as an adaptive option
            //   - High I/O load should minimize thread overhead → stay blocking
            //   - Future: switch to io_uring when available
            //
            // High CPU imbalance: work-stealing helps distribute load
            // Low I/O + Low imbalance: blocking has lowest overhead

            // High CPU imbalance → work stealing helps distribute load
            // But only if I/O intensity is not extremely high (>4x threshold)
            // because work-stealing overhead isn't worth it in I/O-bound scenarios
            const io_bound_limit = @as(f32, @floatFromInt(adaptive_cfg.batch_threshold)) * 4.0;
            if (imbalance > adaptive_cfg.imbalance_threshold and io_intensity < io_bound_limit) {
                if (self.current_mode != .work_stealing) {
                    return .work_stealing;
                }
            }

            // Light load with low imbalance → blocking (lowest overhead)
            // Use I/O metrics: low intensity AND low imbalance → blocking
            const low_io_threshold = @as(f32, @floatFromInt(adaptive_cfg.batch_threshold)) / 4.0;
            if (io_intensity < low_io_threshold and
                imbalance < adaptive_cfg.imbalance_threshold / 2.0)
            {
                if (self.current_mode != .blocking) {
                    return .blocking;
                }
            }

            // High I/O intensity but low imbalance → stay in blocking mode
            // (io_uring would be better but not available in adaptive currently)
            // This prevents unnecessary switching to work-stealing in I/O-bound scenarios
            if (io_intensity >= @as(f32, @floatFromInt(adaptive_cfg.batch_threshold))) {
                if (self.current_mode == .work_stealing) {
                    // I/O-bound work doesn't benefit from stealing, switch to blocking
                    return .blocking;
                }
            }

            return null;
        }

        fn switchTo(self: *Self, new_mode: Mode) void {
            if (self.current_mode == new_mode) return;

            // Log the switch (via tracing would be better, but for now just track it)
            self.current_mode = new_mode;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "AdaptiveBackend - Mode enum" {
    const cfg = config_mod.WorldConfig{};
    const Backend = AdaptiveBackend(cfg, DummyWorld);

    try std.testing.expectEqual(Backend.Mode.blocking, Backend.Mode.blocking);
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Backend.Mode.blocking));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Backend.Mode.work_stealing));
}

test "AdaptiveBackend - Metrics init" {
    const cfg = config_mod.WorldConfig{};
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    const metrics = Backend.Metrics.init();

    try std.testing.expectEqual(@as(u32, 0), metrics.sample_count);
    try std.testing.expectEqual(@as(f32, 0), metrics.pending_io_avg);
}

test "AdaptiveBackend - Metrics sample" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .backend_config = .{
                .adaptive = .{
                    .window_size = 4, // Small window for testing
                },
            },
        },
    };
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    var metrics = Backend.Metrics.init();

    // Add samples
    metrics.addSample(.{ .timestamp = 1, .tick_duration_ns = 1000, .pending_io = 10, .systems_executed = 5 });
    metrics.addSample(.{ .timestamp = 2, .tick_duration_ns = 2000, .pending_io = 20, .systems_executed = 5 });

    try std.testing.expectEqual(@as(u32, 2), metrics.sample_count);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), metrics.pending_io_avg, 0.1);
}

test "AdaptiveBackend - config extraction" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .execution_model = .adaptive_hybrid,
            .backend_config = .{ .adaptive = .{
                .batch_threshold = 128,
                .imbalance_threshold = 0.5,
                .window_size = 200,
                .switch_cooldown = 20,
            } },
        },
    };

    const Backend = AdaptiveBackend(cfg, DummyWorld);
    _ = Backend.Metrics.init();
}

test "AdaptiveBackend - imbalance calculation" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .backend_config = .{ .adaptive = .{
                .window_size = 4,
            } },
        },
    };
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    var metrics = Backend.Metrics.init();

    // Add samples with varying durations (high variance = high imbalance)
    metrics.addSample(.{ .timestamp = 1, .tick_duration_ns = 1000, .pending_io = 0, .systems_executed = 1 });
    metrics.addSample(.{ .timestamp = 2, .tick_duration_ns = 5000, .pending_io = 0, .systems_executed = 1 });
    metrics.addSample(.{ .timestamp = 3, .tick_duration_ns = 1000, .pending_io = 0, .systems_executed = 1 });
    metrics.addSample(.{ .timestamp = 4, .tick_duration_ns = 5000, .pending_io = 0, .systems_executed = 1 });

    const imbalance = metrics.getImbalanceRatio();
    try std.testing.expect(imbalance > 0.5); // High variance means high imbalance
}

test "AdaptiveBackend - stats initialization" {
    const stats = BackendStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
    try std.testing.expectEqual(@as(u64, 0), stats.backend_switches);
}

test "IOMetrics - initialization" {
    const cfg = config_mod.WorldConfig{};
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    const io_metrics = Backend.IOMetrics{};

    try std.testing.expectEqual(@as(u64, 0), io_metrics.total_ops_requested);
    try std.testing.expectEqual(@as(u32, 0), io_metrics.pending_ops);
    try std.testing.expectEqual(@as(u64, 0), io_metrics.completed_ops);
    try std.testing.expectEqual(@as(u64, 0), io_metrics.failed_ops);
    try std.testing.expectEqual(LATENCY_UNSET, io_metrics.latency_min_ns);
    try std.testing.expectEqual(@as(u64, 0), io_metrics.latency_max_ns);
    try std.testing.expectEqual(@as(f32, 0.0), io_metrics.getIOIntensity());
    try std.testing.expectEqual(@as(u64, 0), io_metrics.getAverageLatencyNs());
}

test "IOMetrics - request and completion tracking" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .backend_config = .{ .adaptive = .{
                .window_size = 4,
            } },
        },
    };
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    var io_metrics = Backend.IOMetrics{};

    // Record some requests
    io_metrics.recordRequest();
    io_metrics.recordRequest();
    io_metrics.recordRequest();

    try std.testing.expectEqual(@as(u64, 3), io_metrics.total_ops_requested);
    try std.testing.expectEqual(@as(u32, 3), io_metrics.pending_ops);
    try std.testing.expectEqual(@as(u32, 3), io_metrics.peak_pending_ops);
    try std.testing.expectEqual(@as(u64, 0), io_metrics.completed_ops);

    // Complete one successfully with latency
    io_metrics.recordCompletion(1000, true);
    try std.testing.expectEqual(@as(u32, 2), io_metrics.pending_ops);
    try std.testing.expectEqual(@as(u64, 1), io_metrics.completed_ops);
    try std.testing.expectEqual(@as(u64, 1000), io_metrics.latency_min_ns);
    try std.testing.expectEqual(@as(u64, 1000), io_metrics.latency_max_ns);

    // Complete one with failure
    io_metrics.recordCompletion(0, false);
    try std.testing.expectEqual(@as(u32, 1), io_metrics.pending_ops);
    try std.testing.expectEqual(@as(u64, 1), io_metrics.completed_ops);
    try std.testing.expectEqual(@as(u64, 1), io_metrics.failed_ops);

    // Peak should remain at 3
    try std.testing.expectEqual(@as(u32, 3), io_metrics.peak_pending_ops);
}

test "IOMetrics - latency tracking" {
    const cfg = config_mod.WorldConfig{};
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    var io_metrics = Backend.IOMetrics{};

    // Record requests and completions with different latencies
    io_metrics.recordRequest();
    io_metrics.recordRequest();
    io_metrics.recordRequest();

    io_metrics.recordCompletion(500, true);
    io_metrics.recordCompletion(1500, true);
    io_metrics.recordCompletion(1000, true);

    // Min should be 500, max should be 1500
    try std.testing.expectEqual(@as(u64, 500), io_metrics.latency_min_ns);
    try std.testing.expectEqual(@as(u64, 1500), io_metrics.latency_max_ns);

    // Average should be 1000
    try std.testing.expectEqual(@as(u64, 1000), io_metrics.getAverageLatencyNs());
}

test "IOMetrics - rolling intensity calculation" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .backend_config = .{ .adaptive = .{
                .window_size = 4,
            } },
        },
    };
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    var io_metrics = Backend.IOMetrics{};

    // Tick 0: 10 ops
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        io_metrics.recordRequest();
    }
    io_metrics.endTick(0);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), io_metrics.getIOIntensity(), 0.1);

    // Tick 1: 20 ops
    i = 0;
    while (i < 20) : (i += 1) {
        io_metrics.recordRequest();
    }
    io_metrics.endTick(1);
    // Average of 10, 20 = 15
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), io_metrics.getIOIntensity(), 0.1);

    // Tick 2: 30 ops
    i = 0;
    while (i < 30) : (i += 1) {
        io_metrics.recordRequest();
    }
    io_metrics.endTick(2);
    // Average of 10, 20, 30 = 20
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), io_metrics.getIOIntensity(), 0.1);
}

test "IOMetrics - peak detection" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .backend_config = .{ .adaptive = .{
                .window_size = 4,
            } },
        },
    };
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    var io_metrics = Backend.IOMetrics{};

    // Tick 0: 5 ops
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        io_metrics.recordRequest();
    }
    io_metrics.endTick(0);

    try std.testing.expectEqual(@as(u32, 5), io_metrics.peak_ops_per_tick);
    try std.testing.expectEqual(@as(u64, 0), io_metrics.peak_tick);

    // Tick 1: 15 ops (new peak)
    i = 0;
    while (i < 15) : (i += 1) {
        io_metrics.recordRequest();
    }
    io_metrics.endTick(1);

    try std.testing.expectEqual(@as(u32, 15), io_metrics.peak_ops_per_tick);
    try std.testing.expectEqual(@as(u64, 1), io_metrics.peak_tick);

    // Tick 2: 10 ops (no new peak)
    i = 0;
    while (i < 10) : (i += 1) {
        io_metrics.recordRequest();
    }
    io_metrics.endTick(2);

    // Peak should remain at 15, tick 1
    try std.testing.expectEqual(@as(u32, 15), io_metrics.peak_ops_per_tick);
    try std.testing.expectEqual(@as(u64, 1), io_metrics.peak_tick);
}

test "IOMetrics - shouldUseIOUring" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .backend_config = .{ .adaptive = .{
                .batch_threshold = 20,
                .window_size = 4,
            } },
        },
    };
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    var io_metrics = Backend.IOMetrics{};

    // Below threshold - should not use io_uring
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        io_metrics.recordRequest();
    }
    io_metrics.endTick(0);
    try std.testing.expect(!io_metrics.shouldUseIOUring());

    // At threshold - should use io_uring
    i = 0;
    while (i < 30) : (i += 1) {
        io_metrics.recordRequest();
    }
    io_metrics.endTick(1);
    // Average is now (10 + 30) / 2 = 20, which equals threshold
    try std.testing.expect(io_metrics.shouldUseIOUring());
}

test "IOMetrics - reset" {
    const cfg = config_mod.WorldConfig{};
    const Backend = AdaptiveBackend(cfg, DummyWorld);
    var io_metrics = Backend.IOMetrics{};

    // Add some data
    io_metrics.recordRequest();
    io_metrics.recordRequest();
    io_metrics.recordCompletion(1000, true);
    io_metrics.endTick(0);

    // Verify data exists
    try std.testing.expect(io_metrics.total_ops_requested > 0);
    try std.testing.expect(io_metrics.getIOIntensity() > 0);

    // Reset
    io_metrics.reset();

    // Verify all is reset
    try std.testing.expectEqual(@as(u64, 0), io_metrics.total_ops_requested);
    try std.testing.expectEqual(@as(u32, 0), io_metrics.pending_ops);
    try std.testing.expectEqual(@as(f32, 0.0), io_metrics.getIOIntensity());
}

// Dummy world type for testing
const DummyWorld = struct {
    resources: struct {},

    pub fn despawn(_: *DummyWorld, _: anytype) !void {}
};
