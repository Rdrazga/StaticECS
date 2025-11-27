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
                .pending_io = 0, // TODO: Get from IoContext when available
                .systems_executed = @intCast(self.getCurrentBackendStats().systems_executed -
                    (if (self.tick_count > 0) self.stats.systems_executed else 0)),
            };
            self.metrics.addSample(sample);

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

            const pending_io = self.metrics.pending_io_avg;
            const imbalance = self.metrics.getImbalanceRatio();

            // High I/O load doesn't benefit from work stealing
            // (would need io_uring for actual benefit, which isn't in adaptive currently)
            // For now, high I/O → stay blocking to minimize overhead

            // High CPU imbalance → work stealing helps distribute load
            if (imbalance > adaptive_cfg.imbalance_threshold) {
                if (self.current_mode != .work_stealing) {
                    return .work_stealing;
                }
            }

            // Light load with low imbalance → blocking (lowest overhead)
            if (pending_io < @as(f32, @floatFromInt(adaptive_cfg.batch_threshold)) / 4.0 and
                imbalance < adaptive_cfg.imbalance_threshold / 2.0)
            {
                if (self.current_mode != .blocking) {
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

// Dummy world type for testing
const DummyWorld = struct {
    resources: struct {},

    pub fn despawn(_: *DummyWorld, _: anytype) !void {}
};
