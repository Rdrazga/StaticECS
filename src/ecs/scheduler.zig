//! ECS Scheduler
//!
//! The Scheduler handles system execution based on the static schedule.
//! It provides frame execution, fixed-rate loops, and tracing integration.
//!
//! ## Architecture
//!
//! The scheduler is built in two layers:
//! 1. **Schedule (comptime)**: Analyzes system dependencies and builds execution order
//! 2. **Executor (runtime)**: Runs systems according to the built schedule
//!
//! ## Usage
//!
//! ```zig
//! const MyScheduler = ecs.Scheduler(my_config);
//! var scheduler = MyScheduler.init(&world, trace_sink);
//!
//! // Single frame execution
//! const result = scheduler.tick(0.016);
//!
//! // Fixed-rate loop
//! scheduler.runFixedRate(.{ .target_hz = 60 }, &stop_flag);
//! ```

const std = @import("std");

const config_mod = @import("config.zig");
const WorldConfig = config_mod.WorldConfig;
const Phase = config_mod.Phase;
const ExecutionModel = config_mod.ExecutionModel;
const TraceLevel = config_mod.TraceLevel;

const world_mod = @import("world.zig");
const schedule_build = @import("scheduler/schedule_build.zig");
const scheduler_runtime = @import("scheduler/scheduler_runtime.zig");

const tracing = @import("trace/tracing.zig");
const TraceSink = tracing.TraceSink;
const TracingContext = tracing.TracingContext;

const error_types = @import("error/error_types.zig");
const FrameResult = error_types.FrameResult;
const AggregateErrors = error_types.AggregateErrors;

// Backend selection
const backend_select = @import("scheduler/backends/select.zig");
const backend_interface = @import("scheduler/backends/interface.zig");
pub const BackendStats = backend_interface.BackendStats;
pub const SelectBackend = backend_select.SelectBackend;

// Re-export runtime types
pub const FrameContext = scheduler_runtime.FrameContext;
pub const FrameExecutor = scheduler_runtime.FrameExecutor;
pub const FixedRateConfig = scheduler_runtime.FixedRateConfig;
pub const runFixedRateLoop = scheduler_runtime.runFixedRateLoop;

// Re-export build types
pub const Schedule = schedule_build.Schedule;
pub const Stage = schedule_build.Stage;
pub const buildConflictMatrix = schedule_build.buildConflictMatrix;
pub const systemsConflict = schedule_build.systemsConflict;

// ============================================================================
// Scheduler Type Generator
// ============================================================================

/// Generates a specialized Scheduler type for a given configuration.
///
/// The Scheduler provides:
/// - Per-frame execution via `tick()`
/// - Fixed-rate loop via `runFixedRate()`
/// - Access to the underlying Schedule
/// - Tracing integration
pub fn Scheduler(comptime cfg: WorldConfig) type {
    // Validate scheduler-specific configuration at comptime
    comptime {
        config_mod.validateSchedulerConfig(cfg);
    }

    return struct {
        const Self = @This();

        /// The World type this scheduler operates on.
        pub const WorldType = world_mod.World(cfg);

        /// The compile-time schedule.
        pub const ScheduleType = Schedule(cfg);

        /// The selected backend type for this configuration.
        pub const BackendType = SelectBackend(cfg, WorldType);

        /// Frame executor for this configuration (legacy, for backward compatibility).
        pub const Executor = FrameExecutor(cfg, WorldType);

        /// Tracing context type.
        pub const Tracer = TracingContext(cfg.tracing.level);

        // Instance state
        world: *WorldType,
        backend: BackendType,
        accumulated_time: f64,
        allocator: std.mem.Allocator,

        /// Initialize a new scheduler bound to a world.
        pub fn init(world: *WorldType, trace_sink: ?TraceSink, allocator: std.mem.Allocator) Self {
            return .{
                .world = world,
                .backend = BackendType.init(allocator, trace_sink),
                .accumulated_time = 0.0,
                .allocator = allocator,
            };
        }

        /// Deinitialize the scheduler, releasing all resources.
        ///
        /// This cleans up backend resources including:
        /// - Thread pools (work_stealing backend)
        /// - io_uring rings (io_uring_batch backend)
        /// - Any other backend-specific resources
        ///
        /// Should be called when the scheduler is no longer needed,
        /// typically in World.deinit() or at application shutdown.
        pub fn deinit(self: *Self) void {
            self.backend.deinit();
        }

        /// Execute a single frame/tick.
        ///
        /// This runs all systems in phase order according to the built schedule.
        /// The backend determines HOW systems are executed (blocking, parallel, batched, etc).
        ///
        /// Parameters:
        /// - `delta_time`: Time since last frame in seconds
        ///
        /// Returns a FrameResult indicating success or error(s).
        pub fn tick(self: *Self, delta_time: f64) FrameResult {
            const result = self.backend.tick(self.world, delta_time);
            self.accumulated_time += delta_time;
            return result;
        }

        /// Execute multiple ticks at once.
        ///
        /// Useful for batch processing or catch-up scenarios.
        pub fn tickN(self: *Self, delta_time: f64, count: u32) FrameResult {
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const result = self.tick(delta_time);
                if (result.isError()) {
                    return result;
                }
            }
            return .{ .success = {} };
        }

        /// Run a fixed-rate loop until the stop flag is set.
        ///
        /// This provides consistent timing for game/simulation loops.
        /// Uses the scheduler's backend for tick execution, which includes
        /// tracing support configured via setTraceSink().
        ///
        /// Parameters:
        /// - `rate_config`: Target frame rate and timing parameters
        /// - `stop_flag`: Pointer to a volatile flag that stops the loop when true
        ///
        /// Returns the final frame result (success or last error encountered).
        pub fn runFixedRate(
            self: *Self,
            rate_config: FixedRateConfig,
            stop_flag: *const volatile bool,
        ) FrameResult {
            const frame_time_ns: u64 = @divTrunc(1_000_000_000, rate_config.target_hz);
            var last_frame_instant = std.time.Instant.now() catch return .{ .success = {} };
            var last_result: FrameResult = .{ .success = {} };

            while (!stop_flag.*) {
                const now_instant = std.time.Instant.now() catch continue;
                const elapsed: u64 = now_instant.since(last_frame_instant);

                if (elapsed >= frame_time_ns) {
                    const delta_seconds: f64 = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;
                    last_result = self.tick(delta_seconds);
                    last_frame_instant = now_instant;
                } else {
                    // Sleep for remaining time to avoid busy-waiting
                    const sleep_ns = frame_time_ns - elapsed;
                    std.time.sleep(sleep_ns);
                }
            }
            return last_result;
        }

        /// Get the current tick count.
        pub fn getTickCount(self: *const Self) u64 {
            return self.backend.getTickCount();
        }

        /// Get total accumulated time.
        pub fn getAccumulatedTime(self: *const Self) f64 {
            return self.accumulated_time;
        }

        /// Reset statistics.
        pub fn resetStats(self: *Self) void {
            self.backend.reset();
            self.accumulated_time = 0.0;
        }

        /// Set or update the trace sink.
        pub fn setTraceSink(self: *Self, sink: ?TraceSink) void {
            self.backend.setTraceSink(sink);
        }

        /// Get backend statistics.
        pub fn getBackendStats(self: *const Self) backend_interface.BackendStats {
            return self.backend.getStats();
        }

        // ============================================================================
        // Schedule Introspection (comptime)
        // ============================================================================

        /// Get the number of systems in the schedule.
        pub fn getSystemCount() comptime_int {
            return ScheduleType.system_count;
        }

        /// Get the phases in the execution order.
        pub fn getPhases() []const Phase {
            return ScheduleType.getExecutionOrder();
        }

        /// Get the stages for a specific phase.
        pub fn getStagesForPhase(comptime phase: Phase) []const Stage {
            return ScheduleType.getStagesForPhase(phase);
        }

        /// Check if two systems conflict (for debugging/visualization).
        pub fn checkSystemsConflict(comptime sys_a: u16, comptime sys_b: u16) bool {
            return ScheduleType.conflict_matrix[sys_a * ScheduleType.system_count + sys_b];
        }

        /// Get the execution model.
        pub fn getExecutionModel() ExecutionModel {
            return cfg.schedule.execution_model;
        }

        /// Get the trace level.
        pub fn getTraceLevel() TraceLevel {
            return cfg.tracing.level;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Scheduler instantiation" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = world_mod.World(cfg);
    const TestScheduler = Scheduler(cfg);

    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    var scheduler = TestScheduler.init(&world, null, std.testing.allocator);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(u64, 0), scheduler.getTickCount());
}

test "Scheduler single tick" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = world_mod.World(cfg);
    const TestScheduler = Scheduler(cfg);

    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    var scheduler = TestScheduler.init(&world, null, std.testing.allocator);
    defer scheduler.deinit();

    const result = scheduler.tick(0.016);

    try std.testing.expect(result.isSuccess());
    try std.testing.expectEqual(@as(u64, 1), scheduler.getTickCount());
    try std.testing.expect(scheduler.getAccumulatedTime() > 0.0);
}

test "Scheduler multiple ticks" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = world_mod.World(cfg);
    const TestScheduler = Scheduler(cfg);

    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    var scheduler = TestScheduler.init(&world, null, std.testing.allocator);
    defer scheduler.deinit();

    const result = scheduler.tickN(0.016, 10);

    try std.testing.expect(result.isSuccess());
    try std.testing.expectEqual(@as(u64, 10), scheduler.getTickCount());
}

test "Scheduler statistics reset" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = world_mod.World(cfg);
    const TestScheduler = Scheduler(cfg);

    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    var scheduler = TestScheduler.init(&world, null, std.testing.allocator);
    defer scheduler.deinit();

    _ = scheduler.tick(0.016);
    _ = scheduler.tick(0.016);
    _ = scheduler.tick(0.016);

    try std.testing.expectEqual(@as(u64, 3), scheduler.getTickCount());

    scheduler.resetStats();

    try std.testing.expectEqual(@as(u64, 0), scheduler.getTickCount());
    try std.testing.expectEqual(@as(f64, 0.0), scheduler.getAccumulatedTime());
}

// Test config for Scheduler comptime introspection (module level for comptime evaluation)
const SchedulerTestConfig = struct {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { vx: f32, vy: f32 };

    fn dummyMovementSystem(_: *anyopaque) void {}

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        } },
        .systems = .{ .systems = &.{
            .{
                .name = "movement",
                .func = config_mod.asSystemFn(dummyMovementSystem),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
            },
        } },
        .options = .{ .max_entities = 100 },
    };
};

test "Scheduler comptime introspection" {
    const TestScheduler = Scheduler(SchedulerTestConfig.cfg);

    try std.testing.expectEqual(1, TestScheduler.getSystemCount());
    try std.testing.expectEqual(ExecutionModel.blocking_single_thread, TestScheduler.getExecutionModel());
    try std.testing.expectEqual(TraceLevel.off, TestScheduler.getTraceLevel());
}
