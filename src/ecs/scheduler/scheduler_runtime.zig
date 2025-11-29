//! Scheduler Runtime Execution
//!
//! This module handles per-frame execution of the system schedule,
//! including stage execution, system invocation, and error handling.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const Phase = config_mod.Phase;
const FramePolicy = config_mod.FramePolicy;
const TraceLevel = config_mod.TraceLevel;
const SystemDef = config_mod.SystemDef;
const ExecutionModel = config_mod.ExecutionModel;

const schedule_build = @import("schedule_build.zig");
const Schedule = schedule_build.Schedule;
// Note: Stage types are now config-sized, accessed via Schedule(cfg).ConfigStage

const error_types = @import("../error/error_types.zig");
const FrameError = error_types.FrameError;
// Config-based error types - parameterized by max_aggregate_errors
const AggregateErrorsType = error_types.AggregateErrorsType;
const FrameResultType = error_types.FrameResultType;

const tracing = @import("../trace/tracing.zig");
const TracingContext = tracing.TracingContext;
const TraceSink = tracing.TraceSink;

const system_context = @import("../system_context.zig");
const SystemContext = system_context.SystemContext;
const CommandBufferType = system_context.CommandBufferType;
const IoContext = system_context.IoContext;
const IoBackend = system_context.IoBackend;
const BackendOptions = system_context.BackendOptions;
const ConcurrentCommandBuffers = system_context.ConcurrentCommandBuffers;

const context_mod = @import("../context/mod.zig");
const ComponentRegistry = context_mod.ComponentRegistry;

// ============================================================================
// System Executor
// ============================================================================

/// Executes a single system using the proper SystemContext.
/// Tiger Style: Uses config-based types for all bounds.
pub fn SystemExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const Sched = Schedule(cfg);

    return struct {
        const Self = @This();
        const SysCtx = SystemContext(cfg, WorldType);
        const CmdBuf = SysCtx.CmdBuf; // Use config-based CommandBuffer from SystemContext
        /// Config-based aggregate errors type.
        const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);

        /// The expected system function signature.
        pub const SystemFn = *const fn (*SysCtx) FrameError!void;

        /// Execute a system by index.
        pub fn executeSystem(
            ctx: *SysCtx,
            comptime system_index: u16,
        ) FrameError!void {
            const system_def = Sched.systems[system_index];

            // Cast the opaque function pointer to the expected signature
            const func: SystemFn = @ptrCast(@alignCast(system_def.func));

            // Invoke the system
            try func(ctx);
        }

        /// Execute a system with error handling based on frame policy.
        /// Tiger Style: AggregateErrors sized by config.
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

// ============================================================================
// Command Executor
// ============================================================================

/// Processes deferred commands after system execution.
/// Tiger Style: Uses config-based CommandBuffer type and ComponentRegistry for type dispatch.
pub fn CommandExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const SysCtx = SystemContext(cfg, WorldType);
    const CmdBuf = SysCtx.CmdBuf;
    const archetype_count = cfg.archetypes.archetypes.len;
    const CompRegistry = ComponentRegistry(cfg, WorldType);

    return struct {
        const Self = @This();

        /// Execute all queued commands.
        pub fn executeCommands(world: *WorldType, commands: *CmdBuf) void {
            for (commands.getCommands()) |cmd| {
                switch (cmd) {
                    .despawn => |handle| {
                        // Despawn the entity - ignore errors and continue
                        world.despawn(handle) catch {};
                    },
                    .spawn => |spawn_cmd| {
                        // Tiger Style: Execute spawn with archetype dispatch
                        executeSpawnCommand(world, spawn_cmd);
                    },
                    .set_component => |set_cmd| {
                        // Tiger Style: Use ComponentRegistry for typed dispatch
                        executeSetComponentCommand(world, set_cmd);
                    },
                    .custom => |custom_cmd| {
                        // Custom commands would be handled by user-defined handlers
                        _ = custom_cmd;
                    },
                }
            }
            commands.clear();
        }

        /// Execute a spawn command, creating an entity in the specified archetype.
        /// Tiger Style: Uses inline for to dispatch to correct archetype at comptime.
        fn executeSpawnCommand(world: *WorldType, spawn_cmd: CmdBuf.CommandT.spawn) void {
            const arch_idx = spawn_cmd.archetype_index;

            // Validate archetype index
            if (arch_idx >= archetype_count) {
                // Invalid archetype index - skip silently (fail-safe)
                // Tiger Style: In debug builds, this would be caught by assertions
                if (@import("builtin").mode == .Debug) {
                    std.debug.print("spawn command: invalid archetype index {}\n", .{arch_idx});
                }
                return;
            }

            // Allocate entity
            const handle = world.entities.create() orelse {
                // Capacity exhausted - skip silently (fail-safe)
                if (@import("builtin").mode == .Debug) {
                    std.debug.print("spawn command: entity capacity exhausted\n", .{});
                }
                return;
            };

            // Dispatch to correct archetype using comptime inline for
            inline for (0..archetype_count) |i| {
                if (arch_idx == i) {
                    const table = &world.storage[i];
                    const TableType = @TypeOf(table.*);

                    // Add entity with component data
                    const row = blk: {
                        if (spawn_cmd.data_size > 0) {
                            // Has component data - unpack from bytes
                            const expected_size = TableType.packedComponentSize();
                            std.debug.assert(spawn_cmd.data_size == expected_size);

                            break :blk table.addEntityFromBytes(
                                handle.toId(),
                                spawn_cmd.data[0..spawn_cmd.data_size],
                            ) catch {
                                // Failed to add entity - destroy handle and skip
                                _ = world.entities.destroy(handle);
                                return;
                            };
                        } else {
                            // No component data - use default values
                            // Create a zeroed component tuple
                            var default_data: [TableType.packedComponentSize()]u8 = undefined;
                            @memset(&default_data, 0);

                            break :blk table.addEntityFromBytes(
                                handle.toId(),
                                &default_data,
                            ) catch {
                                _ = world.entities.destroy(handle);
                                return;
                            };
                        }
                    };

                    // Update entity metadata with location
                    _ = world.entities.setLocation(handle, @intCast(i), row);
                    return;
                }
            }
        }

        /// Execute a set_component command using the ComponentRegistry for type dispatch.
        /// Tiger Style: Uses comptime-generated registry for O(log N) component_id lookup.
        fn executeSetComponentCommand(world: *WorldType, set_cmd: CmdBuf.CommandT.set_component) void {
            // Validate entity is alive before attempting to set component
            if (!world.isAlive(set_cmd.entity)) {
                // Entity no longer exists, skip silently (common case for despawned entities)
                return;
            }

            // Use ComponentRegistry to dispatch to typed setter
            const success = CompRegistry.executeSetComponent(
                world,
                set_cmd.entity,
                set_cmd.component_id,
                &set_cmd.data,
                set_cmd.size,
            );

            // Tiger Style: In debug mode, report failures for debugging
            if (!success) {
                if (@import("builtin").mode == .Debug) {
                    std.debug.print(
                        "set_component: failed for entity {} component_id {}\n",
                        .{ set_cmd.entity.id.toU32(), set_cmd.component_id },
                    );
                }
            }
        }
    };
}

// ============================================================================
// Stage Executor
// ============================================================================

/// Executes all systems in a stage.
/// Tiger Style: Uses config-based Stage type.
pub fn StageExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const Sched = Schedule(cfg);
    return struct {
        const Self = @This();
        const SysCtx = SystemContext(cfg, WorldType);
        const SysExec = SystemExecutor(cfg, WorldType);
        const CmdExec = CommandExecutor(cfg, WorldType);
        /// Config-based stage type.
        const ConfigStage = Sched.ConfigStage;
        /// Config-based aggregate errors type.
        const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);

        /// Execute all systems in a stage sequentially.
        /// For blocking_single_thread, all systems run on the current thread.
        /// Tiger Style: AggregateErrors sized by config.
        pub fn executeStage(
            ctx: *SysCtx,
            comptime stage: ConfigStage,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) bool {
            var all_success = true;

            // Iterate over the valid system indices using system_count
            inline for (0..stage.system_count) |i| {
                const sys_idx = stage.system_indices[i];
                const success = SysExec.executeSystemWithPolicy(ctx, sys_idx, policy, errors);

                if (!success) {
                    all_success = false;

                    // Under default policy, stop on first error
                    if (policy == .default) {
                        return false;
                    }
                    // Under aggregate policy, continue to collect more errors
                }
            }

            // Process deferred commands after the stage completes
            CmdExec.executeCommands(ctx.world, ctx.commands);

            return all_success;
        }

        /// Execute a stage by phase and stage index (comptime).
        /// Used by PhaseExecutor when iterating over stage indices.
        /// Tiger Style: AggregateErrors sized by config.
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

        // ==================================================================
        // Parallel Execution Helpers (Tiger Style: pure leaves, ≤70 lines)
        // ==================================================================

        /// Concurrent command buffers type alias for parallel execution.
        const ConcBufs = ConcurrentCommandBuffers(
            cfg.options.max_systems_per_stage,
            cfg.options.max_commands_per_frame,
            cfg.options.max_component_data_size,
        );

        /// Decision helper: determines if parallel execution should be used.
        /// Returns false if IoContext is unavailable or lacks concurrency.
        fn shouldUseParallel(ctx: *const SysCtx) bool {
            return ctx.io != null and ctx.hasConcurrency();
        }

        /// Check if all systems have completed execution.
        fn allCompleted(completed: []const bool) bool {
            for (completed) |c| {
                if (!c) return false;
            }
            return true;
        }

        /// Schedule and execute all systems in a stage for parallel execution.
        /// In stub mode, systems execute immediately but use isolated command buffers.
        fn scheduleAndExecuteSystems(
            ctx: *SysCtx,
            io: *IoContext,
            comptime stage: ConfigStage,
            concurrent_cmds: *ConcBufs,
            system_errors: *[stage.system_count]?FrameError,
            completed: *[stage.system_count]bool,
        ) void {
            inline for (0..stage.system_count) |i| {
                const sys_idx = stage.system_indices[i];
                const per_system_cmds = concurrent_cmds.getForSystem(@intCast(i));

                // Schedule system through IoBackend (stub: called immediately)
                const SystemTask = struct {
                    fn execute(task_ctx: *const anyopaque) void {
                        _ = task_ctx;
                    }
                };
                io.scheduleAsync(SystemTask.execute, @ptrCast(&sys_idx)) catch {};

                // Stub: execute system immediately
                SysExec.executeSystem(ctx, sys_idx) catch |err| {
                    system_errors[i] = err;
                };
                completed[i] = true;
                _ = per_system_cmds;
            }
        }

        /// Poll IoBackend until all systems report completion.
        fn waitForCompletion(io: *IoContext, completed: []const bool) void {
            if (io.getBackend()) |backend| {
                while (!allCompleted(completed)) {
                    _ = backend.poll() catch break;
                }
            }
        }

        /// Collect errors from system execution and add to aggregate.
        /// Returns true if all systems succeeded, false otherwise.
        fn collectErrors(
            comptime stage: ConfigStage,
            system_errors: *const [stage.system_count]?FrameError,
            policy: FramePolicy,
            errors: *AggregateErrors,
            time_ns: u64,
        ) bool {
            var all_success = true;
            for (0..stage.system_count) |i| {
                if (system_errors[i]) |err| {
                    all_success = false;
                    errors.add(err, stage.system_indices[i], time_ns);
                    if (policy == .default) {
                        // Note: Can't stop already-running systems in true parallel
                    }
                }
            }
            return all_success;
        }

        /// Merge per-system command buffers and execute deferred commands.
        fn mergeAndFlushCommands(
            ctx: *SysCtx,
            concurrent_cmds: *ConcBufs,
        ) void {
            _ = concurrent_cmds.mergeInto(ctx.commands);
            CmdExec.executeCommands(ctx.world, ctx.commands);
        }

        // ==================================================================
        // Main Parallel Executor (Tiger Style: central control, ≤70 lines)
        // ==================================================================

        /// Execute all systems in a stage with potential parallelism.
        ///
        /// In threadpool mode, systems in a stage can run concurrently because
        /// the schedule builder already ensures no conflicts within a stage.
        ///
        /// Note: Current implementation uses stub IoBackend which executes
        /// sequentially. When std.Io is stable, this will enable true parallelism.
        ///
        /// Tiger Style: Uses ConcurrentCommandBuffers sized from config for
        /// per-system command isolation during parallel execution.
        pub fn executeStageParallel(
            ctx: *SysCtx,
            comptime stage: ConfigStage,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) bool {
            // Fall back to sequential if parallel not available
            if (!shouldUseParallel(ctx)) {
                return executeStage(ctx, stage, policy, errors);
            }

            const io = ctx.io.?;

            // Setup: create per-system command buffers and tracking arrays
            var concurrent_cmds = ConcBufs.init();
            var system_errors: [stage.system_count]?FrameError = .{null} ** stage.system_count;
            var completed: [stage.system_count]bool = .{false} ** stage.system_count;

            // Schedule and execute all systems
            scheduleAndExecuteSystems(ctx, io, stage, &concurrent_cmds, &system_errors, &completed);

            // Wait for completion (stub: immediate return)
            waitForCompletion(io, &completed);

            // Collect errors and determine success
            const all_success = collectErrors(stage, &system_errors, policy, errors, ctx.time_ns);

            // Merge commands and execute deferred operations
            mergeAndFlushCommands(ctx, &concurrent_cmds);

            return all_success;
        }
    };
}

// ============================================================================
// Phase Executor
// ============================================================================

/// Executes all stages in a phase.
/// Tiger Style: Uses config-based aggregate errors type.
pub fn PhaseExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    return struct {
        const Self = @This();
        const SysCtx = SystemContext(cfg, WorldType);
        const Sched = Schedule(cfg);
        const StageExec = StageExecutor(cfg, WorldType);
        /// Config-based aggregate errors type.
        const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);

        /// Execute all stages in a phase by index sequentially.
        /// Tiger Style: AggregateErrors sized by config. Phases are config-driven.
        pub fn executePhaseByIndex(
            ctx: *SysCtx,
            comptime phase_idx: usize,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) bool {
            const phase_stages = Sched.stages_by_phase[phase_idx];
            var all_success = true;

            // Iterate over valid stages using stage_count
            inline for (0..phase_stages.stage_count) |stage_idx| {
                const success = StageExec.executeStageByIndex(ctx, phase_idx, stage_idx, policy, errors);

                if (!success) {
                    all_success = false;

                    if (policy == .default) {
                        return false;
                    }
                }
            }

            return all_success;
        }

        /// Execute all stages in a phase sequentially (backward compatible with Phase enum).
        pub fn executePhase(
            ctx: *SysCtx,
            comptime phase: Phase,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) bool {
            return executePhaseByIndex(ctx, phase.index(), policy, errors);
        }
    };
}

// ============================================================================
// Frame Executor
// ============================================================================

/// Executes a complete frame (all phases).
/// Tiger Style: Uses config-based CommandBuffer and error types. Phases are config-driven.
pub fn FrameExecutor(comptime cfg: WorldConfig, comptime WorldType: type) type {
    return struct {
        const Self = @This();
        const SysCtx = SystemContext(cfg, WorldType);
        const CmdBuf = SysCtx.CmdBuf; // Config-based CommandBuffer
        const Sched = Schedule(cfg);
        const PhaseExec = PhaseExecutor(cfg, WorldType);
        const Tracer = TracingContext(cfg.tracing.level);
        /// Config-based aggregate errors type.
        const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);
        /// Config-based frame result type.
        pub const FrameResult = FrameResultType(cfg.options.max_aggregate_errors);
        /// Number of phases from config.
        const num_phases = Sched.num_phases;

        /// The configured execution model for this world.
        pub const execution_model = cfg.schedule.execution_model;

        /// Execute a complete frame.
        /// Tiger Style: Returns config-sized FrameResult. Phases are config-driven.
        /// IoContext is created based on execution model:
        /// - blocking_single_thread: No IoContext (null)
        /// - evented_single_thread: IoContext with async but no concurrency (stub until std.Io ready)
        /// - concurrent_threadpool: IoContext with full concurrency (stub until std.Io ready)
        pub fn executeFrame(
            world: *WorldType,
            delta_time: f64,
            tick_index: u64,
            trace_sink: ?TraceSink,
            allocator: Allocator,
        ) FrameResult {
            const time_ns = getTimeNs();

            // Initialize command buffer
            var commands = CmdBuf.init();

            // Create IoBackend and IoContext based on execution model
            var io_backend = createIoBackend(allocator);
            defer if (io_backend) |*b| b.deinit();

            var io_context = createIoContext(if (io_backend) |*b| b else null);

            // Create system context with resources from world
            var ctx = switch (execution_model) {
                .blocking_single_thread => SysCtx.init(
                    world,
                    &world.resources,
                    delta_time,
                    tick_index,
                    time_ns,
                    &commands,
                    allocator,
                ),
                .evented_single_thread, .concurrent_threadpool => SysCtx.initWithIo(
                    world,
                    &world.resources,
                    delta_time,
                    tick_index,
                    time_ns,
                    &commands,
                    allocator,
                    &io_context,
                ),
            };

            const policy = cfg.policies.frame;
            var errors = AggregateErrors.init();

            // Initialize tracing context
            var tracer = Tracer.init(trace_sink, @intFromPtr(world));

            // Emit tick start
            tracer.emitTickStart(tick_index, time_ns);

            // Execute all phases in config-defined order (using phase indices)
            var frame_success = true;

            inline for (0..num_phases) |phase_idx| {
                const phase_success = PhaseExec.executePhaseByIndex(&ctx, phase_idx, policy, &errors);

                if (!phase_success) {
                    frame_success = false;

                    if (policy == .default) {
                        break;
                    }
                }
            }

            // Emit tick end
            const end_time_ns = getTimeNs();
            tracer.emitTickEnd(tick_index, end_time_ns, end_time_ns - time_ns);

            // Return result based on policy and errors
            if (frame_success) {
                return .{ .success = {} };
            }

            if (policy == .aggregate) {
                return .{ .aggregate_errors = errors };
            }

            // Default policy: return first error
            if (errors.first()) |first_err| {
                return .{ .single_error = first_err };
            }

            return .{ .success = {} };
        }

        /// Create IoBackend based on execution model.
        /// Tiger Style: Execution model is config-driven.
        ///
        /// Current implementation uses stub backend (synchronous fallback)
        /// until Zig 0.16 std.Io is stable.
        ///
        /// Note: In production, IoBackend should be created once and reused
        /// across frames. This per-frame creation is for API compatibility.
        fn createIoBackend(allocator: Allocator) ?IoBackend {
            const options: BackendOptions = switch (execution_model) {
                .blocking_single_thread => return null, // No backend needed
                .evented_single_thread => .{ .evented = .{} },
                .concurrent_threadpool => .{ .threadpool = .{} },
            };
            return IoBackend.init(allocator, options) catch null;
        }

        /// Creates IoContext from optional backend.
        fn createIoContext(backend: ?*IoBackend) IoContext {
            return switch (execution_model) {
                .blocking_single_thread => IoContext.blocking(),
                .evented_single_thread, .concurrent_threadpool => blk: {
                    if (backend) |b| {
                        break :blk IoContext.fromBackend(b);
                    } else {
                        // Fallback if backend creation failed
                        break :blk IoContext{
                            .backend = null,
                            .supports_concurrency = execution_model == .concurrent_threadpool,
                            .supports_async = true,
                        };
                    }
                },
            };
        }

        fn getTimeNs() u64 {
            // Zig 0.16: Use Instant API instead of deprecated nanoTimestamp
            const instant = std.time.Instant.now() catch return 0;
            // Return nanoseconds since epoch approximation using a base instant
            // For frame timing, we care about deltas, so this works
            // Thread-local storage: each thread gets its own time base to avoid
            // data races when multiple threads call this concurrently.
            const base = struct {
                threadlocal var value: ?std.time.Instant = null;
            };
            if (base.value == null) {
                base.value = instant;
            }
            return instant.since(base.value.?);
        }
    };
}

// ============================================================================
// Fixed-Rate Loop
// ============================================================================

/// Configuration for fixed-rate loops.
pub const FixedRateConfig = struct {
    target_hz: u32,
    max_frame_delay_ns: ?u64 = null,
};

/// Run a fixed-rate loop until stopped.
pub fn runFixedRateLoop(
    comptime cfg: WorldConfig,
    comptime WorldType: type,
    world: *WorldType,
    rate_config: FixedRateConfig,
    trace_sink: ?TraceSink,
    allocator: Allocator,
    should_stop: *const fn () bool,
) void {
    const FrameExec = FrameExecutor(cfg, WorldType);
    const frame_time_ns: u64 = @divTrunc(1_000_000_000, rate_config.target_hz);

    var tick_index: u64 = 0;
    // Zig 0.16: Use Instant API instead of deprecated nanoTimestamp
    var last_frame_instant = std.time.Instant.now() catch return;

    while (!should_stop()) {
        const now_instant = std.time.Instant.now() catch continue;
        const elapsed: u64 = now_instant.since(last_frame_instant);

        if (elapsed >= frame_time_ns) {
            const delta_seconds: f64 = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;

            _ = FrameExec.executeFrame(world, delta_seconds, tick_index, trace_sink, allocator);

            tick_index += 1;
            last_frame_instant = now_instant;
        } else {
            // Sleep for remaining time
            const sleep_ns = frame_time_ns - elapsed;
            std.time.sleep(sleep_ns);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "FrameExecutor basic structure" {
    const Position = struct { x: f32, y: f32 };

    // Create a simple system function for testing
    const TestSystems = struct {
        fn dummySystem(_: anytype) FrameError!void {
            // Do nothing
        }
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{
            .systems = &.{
                .{
                    .name = "test",
                    .func = @ptrCast(&TestSystems.dummySystem),
                    .phase = 1, // update phase index
                },
            },
        },
        .options = .{ .max_entities = 100 },
    };

    const Sched = Schedule(cfg);
    try std.testing.expectEqual(@as(usize, 1), Sched.system_count);
}
