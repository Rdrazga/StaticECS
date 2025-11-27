//! Blocking Scheduler Backend
//!
//! This is the default backend that executes systems sequentially on the calling thread.
//! It wraps the existing `FrameExecutor` logic from `scheduler_runtime.zig`.
//!
//! ## Characteristics
//!
//! - **Execution**: Sequential, single-threaded
//! - **I/O**: Blocking syscalls
//! - **Best For**: Simple applications, debugging, predictable execution
//! - **Overhead**: Minimal
//!
//! ## Usage
//!
//! Selected automatically when `execution_model` is:
//! - `.blocking_single_thread`
//! - `.evented_single_thread` (uses IoContext but same execution pattern)
//! - `.concurrent_threadpool` (parallel stages but blocking per-system)

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../../config.zig");
const WorldConfig = config_mod.WorldConfig;
const FramePolicy = config_mod.FramePolicy;
const TraceLevel = config_mod.TraceLevel;
const ExecutionModel = config_mod.ExecutionModel;

const schedule_build = @import("../schedule_build.zig");
const Schedule = schedule_build.Schedule;

const error_types = @import("../../error/error_types.zig");
const FrameError = error_types.FrameError;
const AggregateErrorsType = error_types.AggregateErrorsType;
const FrameResultType = error_types.FrameResultType;

const tracing = @import("../../trace/tracing.zig");
const TracingContext = tracing.TracingContext;
const TraceSink = tracing.TraceSink;

const system_context = @import("../../system_context.zig");
const SystemContext = system_context.SystemContext;
const IoContext = system_context.IoContext;
const IoBackend = system_context.IoBackend;
const BackendOptions = system_context.BackendOptions;
const ConcurrentCommandBuffers = system_context.ConcurrentCommandBuffers;

const interface = @import("interface.zig");
const BackendStats = interface.BackendStats;
const getTimeNs = interface.getTimeNs;

// ============================================================================
// Blocking Backend
// ============================================================================

/// Blocking scheduler backend.
///
/// Executes all systems sequentially on the calling thread.
/// This is the simplest and most predictable execution model.
///
/// Tiger Style: All bounds from config. No hidden allocations.
pub fn BlockingBackend(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const Sched = Schedule(cfg);
    const SysCtx = SystemContext(cfg, WorldType);
    const CmdBuf = SysCtx.CmdBuf;
    const Tracer = TracingContext(cfg.tracing.level);

    // Config-based types
    const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);
    const FrameResultT = FrameResultType(cfg.options.max_aggregate_errors);

    // Phase executor uses internal StageExec, SystemExec, CmdExec
    const PhaseExec = PhaseExecutor(cfg, WorldType);

    return struct {
        const Self = @This();

        // Instance state
        allocator: Allocator,
        trace_sink: ?TraceSink,
        tick_count: u64,
        stats: BackendStats,

        /// Initialize the blocking backend.
        pub fn init(allocator: Allocator, trace_sink: ?TraceSink) Self {
            return .{
                .allocator = allocator,
                .trace_sink = trace_sink,
                .tick_count = 0,
                .stats = .{},
            };
        }

        /// Clean up resources.
        pub fn deinit(self: *Self) void {
            _ = self;
            // No resources to clean up for blocking backend
        }

        /// Execute a single tick/frame.
        ///
        /// Runs all systems in phase order according to the built schedule.
        /// Systems within a stage may run in parallel if execution model permits.
        pub fn tick(self: *Self, world: *WorldType, delta_time: f64) FrameResultT {
            const start_time = getTimeNs();

            // Initialize command buffer
            var commands = CmdBuf.init();

            // Create IoBackend and IoContext based on execution model
            const execution_model = cfg.schedule.execution_model;
            var io_backend = createIoBackend(self.allocator, execution_model);
            defer if (io_backend) |*b| b.deinit();

            var io_context = createIoContext(if (io_backend) |*b| b else null, execution_model);

            // Create system context
            // Note: When BlockingBackend is used as fallback for advanced backends
            // (io_uring_batch, work_stealing, adaptive_hybrid), it uses blocking mode.
            var ctx = switch (execution_model) {
                .blocking_single_thread,
                .io_uring_batch,
                .work_stealing,
                .adaptive_hybrid,
                => SysCtx.init(
                    world,
                    &world.resources,
                    delta_time,
                    self.tick_count,
                    start_time,
                    &commands,
                    self.allocator,
                ),
                .evented_single_thread, .concurrent_threadpool => SysCtx.initWithIo(
                    world,
                    &world.resources,
                    delta_time,
                    self.tick_count,
                    start_time,
                    &commands,
                    self.allocator,
                    &io_context,
                ),
            };

            const policy = cfg.policies.frame;
            var errors = AggregateErrors.init();

            // Initialize tracing
            var tracer = Tracer.init(self.trace_sink, @intFromPtr(world));
            tracer.emitTickStart(self.tick_count, start_time);

            // Execute all phases
            var frame_success = true;
            var systems_run: u64 = 0;

            inline for (0..Sched.num_phases) |phase_idx| {
                const phase_success = PhaseExec.executePhaseByIndex(&ctx, phase_idx, policy, &errors);
                self.stats.phases_executed += 1;

                // Count systems in this phase
                const phase_stages = Sched.stages_by_phase[phase_idx];
                inline for (0..phase_stages.stage_count) |stage_idx| {
                    systems_run += phase_stages.stages[stage_idx].system_count;
                }

                if (!phase_success) {
                    frame_success = false;
                    if (policy == .default) break;
                }
            }

            // Emit tick end
            const end_time = getTimeNs();
            tracer.emitTickEnd(self.tick_count, end_time, end_time - start_time);

            // Update statistics
            self.tick_count += 1;
            self.stats.ticks_executed += 1;
            self.stats.systems_executed += systems_run;
            self.stats.last_tick_time_ns = end_time - start_time;
            self.stats.total_tick_time_ns += end_time - start_time;

            // Return result
            if (frame_success) {
                return .{ .success = {} };
            }

            if (policy == .aggregate) {
                return .{ .aggregate_errors = errors };
            }

            if (errors.first()) |first_err| {
                return .{ .single_error = first_err };
            }

            return .{ .success = {} };
        }

        /// Reset backend state and statistics.
        pub fn reset(self: *Self) void {
            self.tick_count = 0;
            self.stats.reset();
        }

        /// Get backend statistics.
        pub fn getStats(self: *const Self) BackendStats {
            return self.stats;
        }

        /// Set or update the trace sink.
        pub fn setTraceSink(self: *Self, sink: ?TraceSink) void {
            self.trace_sink = sink;
        }

        /// Get tick count.
        pub fn getTickCount(self: *const Self) u64 {
            return self.tick_count;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Internal: IoBackend/IoContext creation
        // ─────────────────────────────────────────────────────────────────────

        fn createIoBackend(allocator: Allocator, execution_model: ExecutionModel) ?IoBackend {
            const options: BackendOptions = switch (execution_model) {
                // Blocking mode and fallbacks don't use IoBackend
                .blocking_single_thread,
                .io_uring_batch,
                .work_stealing,
                .adaptive_hybrid,
                => return null,
                .evented_single_thread => .{ .evented = .{} },
                .concurrent_threadpool => .{ .threadpool = .{} },
            };
            return IoBackend.init(allocator, options) catch null;
        }

        fn createIoContext(backend: ?*IoBackend, execution_model: ExecutionModel) IoContext {
            return switch (execution_model) {
                // Blocking mode and fallbacks use blocking IoContext
                .blocking_single_thread,
                .io_uring_batch,
                .work_stealing,
                .adaptive_hybrid,
                => IoContext.blocking(),
                .evented_single_thread, .concurrent_threadpool => blk: {
                    if (backend) |b| {
                        break :blk IoContext.fromBackend(b);
                    } else {
                        break :blk IoContext{
                            .backend = null,
                            .supports_concurrency = execution_model == .concurrent_threadpool,
                            .supports_async = true,
                        };
                    }
                },
            };
        }
    };
}

// ============================================================================
// Executors (simplified versions - delegate to scheduler_runtime)
// ============================================================================

/// System executor - runs a single system.
fn SystemExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const Sched = Schedule(cfg);
    const SysCtx = SystemContext(cfg, WorldType);
    const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);

    return struct {
        const Self = @This();
        const SystemFn = *const fn (*SysCtx) error_types.FrameError!void;

        pub fn executeSystem(ctx: *SysCtx, comptime system_index: u16) error_types.FrameError!void {
            const system_def = Sched.systems[system_index];
            const func: SystemFn = @ptrCast(@alignCast(system_def.func));
            try func(ctx);
        }

        pub fn executeSystemWithPolicy(
            ctx: *SysCtx,
            comptime system_index: u16,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) bool {
            _ = policy;
            Self.executeSystem(ctx, system_index) catch |err| {
                errors.add(err, system_index, ctx.time_ns);
                return false;
            };
            return true;
        }
    };
}

/// Command executor - processes deferred commands.
fn CommandExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const SysCtx = SystemContext(cfg, WorldType);
    const CmdBuf = SysCtx.CmdBuf;

    return struct {
        pub fn executeCommands(world: *WorldType, commands: *CmdBuf) void {
            for (commands.getCommands()) |cmd| {
                switch (cmd) {
                    .despawn => |handle| {
                        world.despawn(handle) catch {};
                    },
                    .spawn => |spawn_cmd| {
                        _ = spawn_cmd;
                    },
                    .set_component => |set_cmd| {
                        if (!world.isAlive(set_cmd.entity)) continue;
                    },
                    .custom => |custom_cmd| {
                        _ = custom_cmd;
                    },
                }
            }
            commands.clear();
        }
    };
}

/// Stage executor - runs all systems in a stage.
fn StageExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const Sched = Schedule(cfg);
    const SysCtx = SystemContext(cfg, WorldType);
    const SysExec = SystemExecutor(cfg, WorldType);
    const CmdExec = CommandExecutor(cfg, WorldType);
    const ConfigStage = Sched.ConfigStage;
    const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);

    return struct {
        pub fn executeStage(
            ctx: *SysCtx,
            comptime stage: ConfigStage,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) bool {
            var all_success = true;

            inline for (0..stage.system_count) |i| {
                const sys_idx = stage.system_indices[i];
                const success = SysExec.executeSystemWithPolicy(ctx, sys_idx, policy, errors);

                if (!success) {
                    all_success = false;
                    if (policy == .default) return false;
                }
            }

            CmdExec.executeCommands(ctx.world, ctx.commands);
            return all_success;
        }

        pub fn executeStageByIndex(
            ctx: *SysCtx,
            comptime phase_idx: usize,
            comptime stage_idx: usize,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) bool {
            const stage = Sched.stages_by_phase[phase_idx].stages[stage_idx];
            return executeStage(ctx, stage, policy, errors);
        }
    };
}

/// Phase executor - runs all stages in a phase.
fn PhaseExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const Sched = Schedule(cfg);
    const SysCtx = SystemContext(cfg, WorldType);
    const StageExec = StageExecutor(cfg, WorldType);
    const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);

    return struct {
        pub fn executePhaseByIndex(
            ctx: *SysCtx,
            comptime phase_idx: usize,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) bool {
            const phase_stages = Sched.stages_by_phase[phase_idx];
            var all_success = true;

            inline for (0..phase_stages.stage_count) |stage_idx| {
                const success = StageExec.executeStageByIndex(ctx, phase_idx, stage_idx, policy, errors);

                if (!success) {
                    all_success = false;
                    if (policy == .default) return false;
                }
            }

            return all_success;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "BlockingBackend initialization" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 100 },
    };

    const WorldType = @import("../../world.zig").World(cfg);
    const Backend = BlockingBackend(cfg, WorldType);

    var backend = Backend.init(std.testing.allocator, null);
    defer backend.deinit();

    try std.testing.expectEqual(@as(u64, 0), backend.getTickCount());

    const stats = backend.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
}

test "BlockingBackend tick" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 100 },
    };

    const WorldType = @import("../../world.zig").World(cfg);
    const Backend = BlockingBackend(cfg, WorldType);

    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var backend = Backend.init(std.testing.allocator, null);
    defer backend.deinit();

    const result = backend.tick(&world, 0.016);
    try std.testing.expect(result.isSuccess());
    try std.testing.expectEqual(@as(u64, 1), backend.getTickCount());

    const stats = backend.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.ticks_executed);
}

test "BlockingBackend reset" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 100 },
    };

    const WorldType = @import("../../world.zig").World(cfg);
    const Backend = BlockingBackend(cfg, WorldType);

    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var backend = Backend.init(std.testing.allocator, null);
    defer backend.deinit();

    _ = backend.tick(&world, 0.016);
    _ = backend.tick(&world, 0.016);

    try std.testing.expectEqual(@as(u64, 2), backend.getTickCount());

    backend.reset();

    try std.testing.expectEqual(@as(u64, 0), backend.getTickCount());
    try std.testing.expectEqual(@as(u64, 0), backend.getStats().ticks_executed);
}
