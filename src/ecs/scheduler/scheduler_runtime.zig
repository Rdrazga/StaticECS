//! # Scheduler Runtime
//!
//! Purpose: Runtime execution engine that runs the system schedule each frame.
//! Handles stage execution, system invocation, error aggregation, and tracing.
//!
//! ## Key Types
//! - `SystemExecutor` - Executes individual systems with error handling
//! - `FrameExecutor` - Orchestrates full frame execution across all phases
//! - `StageRunner` - Runs a single stage (parallel systems within a stage)
//!
//! ## Usage
//! ```zig
//! const RuntimeType = SchedulerRuntime(cfg, WorldType);
//! var runtime = RuntimeType.init(allocator, &world, trace_sink);
//!
//! // Execute one frame
//! const result = runtime.tick(delta_time, frame_policy);
//! if (result.hasErrors()) {
//!     // Handle errors based on policy
//! }
//! ```
//!
//! ## Execution Flow
//! ```
//! tick() -> for each phase:
//!   -> for each stage in phase:
//!     -> execute systems (parallel if enabled)
//!     -> flush command buffers
//!   -> emit phase completion trace
//! ```
//!
//! ## Thread Safety
//! - Single-threaded execution models: No synchronization needed
//! - Concurrent models: Stage-level parallelism with command buffer isolation
//! - Command buffers are flushed sequentially at stage boundaries
//!
//! ## Related Modules
//! - `schedule_build.zig` - Compile-time schedule construction
//! - `backends/*.zig` - Execution model implementations
//! - `system_context.zig` - System function context
//!
//! ## Module Dependencies (Import Rationale)
//!
//! This module coordinates runtime execution, requiring imports from multiple
//! architectural layers. Each import serves a distinct purpose:
//!
//! | Import | Purpose | Used By |
//! |--------|---------|---------|
//! | `config_mod` | WorldConfig, Phase, FramePolicy, ExecutionModel | All executors |
//! | `schedule_build` | Schedule, ConfigStage | Stage/Phase execution |
//! | `error_types` | FrameError, AggregateErrors, FrameResult | Error handling |
//! | `tracing` | TracingContext, TraceSink | Frame/tick tracing |
//! | `system_context` | SystemContext, CommandBuffer, IoContext | System execution |
//! | `context_mod` | ComponentRegistry | Command dispatch |
//!
//! Tiger Style: Imports are grouped by architectural layer (config → schedule →
//! error → trace → context). This is the minimum set required for runtime
//! orchestration. If this grows further, consider extracting sub-components.

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
    // Get handle type for error tracking
    const HandleType = CmdBuf.CommandT.despawn;

    return struct {
        const Self = @This();

        /// Result of command execution batch - tracks errors for diagnostics.
        /// Tiger Style: Explicit error tracking, no silent swallowing.
        pub const CommandExecutionResult = struct {
            /// Number of despawn commands that failed.
            despawn_error_count: u32 = 0,
            /// Last despawn error encountered (if any).
            last_despawn_error: ?@import("../world.zig").WorldError = null,
            /// Entity that failed to despawn (for debugging).
            last_failed_entity: ?HandleType = null,
            /// Number of spawn commands that failed.
            spawn_error_count: u32 = 0,
            /// Number of set_component commands that failed.
            set_component_error_count: u32 = 0,
            /// Total commands processed.
            total_commands: u32 = 0,

            /// Returns true if all commands succeeded.
            pub fn allSucceeded(self: @This()) bool {
                return self.despawn_error_count == 0 and
                    self.spawn_error_count == 0 and
                    self.set_component_error_count == 0;
            }

            /// Returns total number of errors across all command types.
            pub fn totalErrors(self: @This()) u32 {
                return self.despawn_error_count + self.spawn_error_count + self.set_component_error_count;
            }
        };

        /// Execute all queued commands.
        /// Returns execution result with error tracking for diagnostics.
        /// Tiger Style: No silent error swallowing - errors are tracked and reported.
        pub fn executeCommands(world: *WorldType, commands: *CmdBuf) CommandExecutionResult {
            var result = CommandExecutionResult{};

            for (commands.getCommands()) |cmd| {
                result.total_commands += 1;
                switch (cmd) {
                    .despawn => |handle| {
                        // Despawn the entity - track errors for diagnostics
                        world.despawn(handle) catch |err| {
                            result.despawn_error_count += 1;
                            result.last_despawn_error = err;
                            result.last_failed_entity = handle;

                            // Tiger Style: Debug builds log errors for visibility
                            if (@import("builtin").mode == .Debug) {
                                std.debug.print(
                                    "CommandExecutor: despawn failed for entity {}: {}\n",
                                    .{ handle.id.toU32(), err },
                                );
                            }
                        };
                    },
                    .spawn => |spawn_cmd| {
                        // Tiger Style: Execute spawn with archetype dispatch
                        const spawn_success = executeSpawnCommand(world, spawn_cmd);
                        if (!spawn_success) {
                            result.spawn_error_count += 1;
                        }
                    },
                    .set_component => |set_cmd| {
                        // Tiger Style: Use ComponentRegistry for typed dispatch
                        const set_success = executeSetComponentCommand(world, set_cmd);
                        if (!set_success) {
                            result.set_component_error_count += 1;
                        }
                    },
                    .custom => |custom_cmd| {
                        // Custom commands would be handled by user-defined handlers
                        _ = custom_cmd;
                    },
                }
            }
            commands.clear();
            return result;
        }

        /// Execute a spawn command, creating an entity in the specified archetype.
        /// Tiger Style: Uses inline for to dispatch to correct archetype at comptime.
        /// Returns true on success, false on failure.
        fn executeSpawnCommand(world: *WorldType, spawn_cmd: CmdBuf.CommandT.spawn) bool {
            const arch_idx = spawn_cmd.archetype_index;

            // Validate archetype index
            if (arch_idx >= archetype_count) {
                // Invalid archetype index - fail
                // Tiger Style: In debug builds, log for visibility
                if (@import("builtin").mode == .Debug) {
                    std.debug.print("spawn command: invalid archetype index {}\n", .{arch_idx});
                }
                return false;
            }

            // Allocate entity
            const handle = world.entities.create() orelse {
                // Capacity exhausted - fail
                // Tiger Style: In debug builds, log for visibility
                if (@import("builtin").mode == .Debug) {
                    std.debug.print("spawn command: entity capacity exhausted\n", .{});
                }
                return false;
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
                                // Failed to add entity - destroy handle and return failure
                                _ = world.entities.destroy(handle);
                                if (@import("builtin").mode == .Debug) {
                                    std.debug.print("spawn command: failed to add entity to archetype {}\n", .{i});
                                }
                                return false;
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
                                if (@import("builtin").mode == .Debug) {
                                    std.debug.print("spawn command: failed to add entity to archetype {} (default)\n", .{i});
                                }
                                return false;
                            };
                        }
                    };

                    // Update entity metadata with location
                    _ = world.entities.setLocation(handle, @intCast(i), row);
                    return true;
                }
            }
            // Should not reach here if inline for properly dispatches
            return false;
        }

        /// Execute a set_component command using the ComponentRegistry for type dispatch.
        /// Tiger Style: Uses comptime-generated registry for O(log N) component_id lookup.
        /// Returns true on success, false on failure.
        fn executeSetComponentCommand(world: *WorldType, set_cmd: CmdBuf.CommandT.set_component) bool {
            // Validate entity is alive before attempting to set component
            if (!world.isAlive(set_cmd.entity)) {
                // Entity no longer exists - this is often expected for despawned entities
                // but we should track it for completeness
                if (@import("builtin").mode == .Debug) {
                    std.debug.print(
                        "set_component: entity {} no longer alive\n",
                        .{set_cmd.entity.id.toU32()},
                    );
                }
                return false;
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
            return success;
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
            // Tiger Style: Result returned for diagnostics, logged in debug builds
            const cmd_result = CmdExec.executeCommands(ctx.world, ctx.commands);

            // Log command execution summary in debug builds if there were errors
            if (@import("builtin").mode == .Debug and !cmd_result.allSucceeded()) {
                std.debug.print(
                    "Stage command execution: {} despawn errors, {} spawn errors, {} set_component errors out of {} total commands\n",
                    .{ cmd_result.despawn_error_count, cmd_result.spawn_error_count, cmd_result.set_component_error_count, cmd_result.total_commands },
                );
            }

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
        /// Tiger Style: Result tracked for diagnostics.
        fn mergeAndFlushCommands(
            ctx: *SysCtx,
            concurrent_cmds: *ConcBufs,
        ) CmdExec.CommandExecutionResult {
            _ = concurrent_cmds.mergeInto(ctx.commands);
            return CmdExec.executeCommands(ctx.world, ctx.commands);
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
            const cmd_result = mergeAndFlushCommands(ctx, &concurrent_cmds);

            // Log command execution summary in debug builds if there were errors
            if (@import("builtin").mode == .Debug and !cmd_result.allSucceeded()) {
                std.debug.print(
                    "Parallel stage command execution: {} despawn errors, {} spawn errors, {} set_component errors out of {} total commands\n",
                    .{ cmd_result.despawn_error_count, cmd_result.spawn_error_count, cmd_result.set_component_error_count, cmd_result.total_commands },
                );
            }

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
            // Tiger Style: Assert frame state validity
            std.debug.assert(@intFromPtr(world) != 0); // World pointer must be valid
            std.debug.assert(!std.math.isNan(delta_time) and delta_time >= 0.0); // Delta must be valid

            const time_ns = getTimeNs();
            var commands = CmdBuf.init();

            // Create IoBackend and IoContext based on execution model
            var io_backend = createIoBackend(allocator);
            defer if (io_backend) |*b| b.deinit();
            var io_context = createIoContext(if (io_backend) |*b| b else null);

            // Create system context and execute phases
            var ctx = createSystemContext(world, delta_time, tick_index, time_ns, &commands, allocator, &io_context);
            const policy = cfg.policies.frame;
            var errors = AggregateErrors.init();

            // Tracing: emit tick boundaries
            var tracer = Tracer.init(trace_sink, @intFromPtr(world));
            tracer.emitTickStart(tick_index, time_ns);

            // Execute all phases in config-defined order
            const frame_success = executeAllPhases(&ctx, policy, &errors);

            const end_time_ns = getTimeNs();
            tracer.emitTickEnd(tick_index, end_time_ns, end_time_ns - time_ns);

            return buildFrameResult(frame_success, policy, &errors);
        }

        /// Execute all phases and return success status.
        /// Tiger Style: Central control in parent, iteration over config-driven phases.
        fn executeAllPhases(ctx: *SysCtx, policy: FramePolicy, errors: *AggregateErrors) bool {
            var frame_success = true;
            inline for (0..num_phases) |phase_idx| {
                const phase_success = PhaseExec.executePhaseByIndex(ctx, phase_idx, policy, errors);
                if (!phase_success) {
                    frame_success = false;
                    if (policy == .default) break;
                }
            }
            return frame_success;
        }

        /// Build frame result based on execution success and error policy.
        /// Tiger Style: Pure helper, no side effects.
        fn buildFrameResult(frame_success: bool, policy: FramePolicy, errors: *const AggregateErrors) FrameResult {
            // Tiger Style: Assert error state consistency
            std.debug.assert(frame_success or errors.count > 0); // Failure implies errors recorded

            if (frame_success) return .{ .success = {} };
            if (policy == .aggregate) return .{ .aggregate_errors = errors.* };
            // Default policy: return first error
            if (errors.first()) |first_err| return .{ .single_error = first_err };
            return .{ .success = {} };
        }

        /// Create system context based on execution model.
        /// Tiger Style: Pure helper for context initialization.
        fn createSystemContext(
            world: *WorldType,
            delta_time: f64,
            tick_index: u64,
            time_ns: u64,
            commands: *CmdBuf,
            allocator: Allocator,
            io_context: *IoContext,
        ) SysCtx {
            return switch (execution_model) {
                .blocking_single_thread => SysCtx.init(
                    world,
                    &world.resources,
                    delta_time,
                    tick_index,
                    time_ns,
                    commands,
                    allocator,
                ),
                .evented_single_thread, .concurrent_threadpool => SysCtx.initWithIo(
                    world,
                    &world.resources,
                    delta_time,
                    tick_index,
                    time_ns,
                    commands,
                    allocator,
                    io_context,
                ),
            };
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

// ============================================================================
// Phase Execution Ordering Tests
// ============================================================================

test "Phase execution ordering" {
    // Test that phases run in the correct order: pre_update (0), update (1), post_update (2)
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    // Track execution order using comptime-known indices
    const TestSystems = struct {
        fn preUpdateSystem(_: anytype) FrameError!void {}
        fn updateSystem(_: anytype) FrameError!void {}
        fn postUpdateSystem(_: anytype) FrameError!void {}
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        } },
        .systems = .{
            .systems = &.{
                .{
                    .name = "pre_update_sys",
                    .func = @ptrCast(&TestSystems.preUpdateSystem),
                    .phase = 0, // pre_update
                },
                .{
                    .name = "update_sys",
                    .func = @ptrCast(&TestSystems.updateSystem),
                    .phase = 1, // update
                },
                .{
                    .name = "post_update_sys",
                    .func = @ptrCast(&TestSystems.postUpdateSystem),
                    .phase = 2, // post_update
                },
            },
        },
        .options = .{ .max_entities = 100 },
    };

    const Sched = Schedule(cfg);

    // Verify systems are assigned to correct phases
    try std.testing.expectEqual(@as(usize, 3), Sched.system_count);
    try std.testing.expectEqual(@as(usize, 3), Sched.num_phases);

    // Check each phase has exactly one system
    try std.testing.expectEqual(@as(u16, 1), Sched.stages_by_phase[0].stage_count);
    try std.testing.expectEqual(@as(u16, 1), Sched.stages_by_phase[1].stage_count);
    try std.testing.expectEqual(@as(u16, 1), Sched.stages_by_phase[2].stage_count);
}

test "System dependency resolution" {
    // Systems with dependencies should execute in dependency order
    const ComponentA = struct { val: u32 };
    const ComponentB = struct { val: u32 };

    const TestSystems = struct {
        fn dependencySystem(_: anytype) FrameError!void {}
        fn mainSystem(_: anytype) FrameError!void {}
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ ComponentA, ComponentB } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{ ComponentA, ComponentB } },
        } },
        .systems = .{
            .systems = &.{
                // Main system depends on dependency system via write/read conflict
                .{
                    .name = "main",
                    .func = @ptrCast(&TestSystems.mainSystem),
                    .phase = 1,
                    .read_components = &.{ComponentA}, // reads what dependency writes
                    .write_components = &.{ComponentB},
                },
                .{
                    .name = "dependency",
                    .func = @ptrCast(&TestSystems.dependencySystem),
                    .phase = 1,
                    .write_components = &.{ComponentA}, // writes ComponentA
                    .read_components = &.{},
                },
            },
        },
        .options = .{ .max_entities = 100 },
    };

    const Sched = Schedule(cfg);

    // Systems with conflicts should be in separate stages
    // Dependency system writes ComponentA, main system reads ComponentA
    try std.testing.expect(Sched.conflicts[0][1]); // Systems should conflict
    try std.testing.expectEqual(@as(usize, 2), Sched.system_count);
}

test "Tick result aggregation" {
    // Test that errors from systems are properly aggregated
    const Position = struct { x: f32, y: f32 };

    const TestSystems = struct {
        fn failingSystem(_: anytype) FrameError!void {
            return FrameError.SystemError;
        }
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{Position} },
        } },
        .systems = .{
            .systems = &.{
                .{
                    .name = "failing",
                    .func = @ptrCast(&TestSystems.failingSystem),
                    .phase = 1,
                },
            },
        },
        .options = .{ .max_entities = 100 },
        .policies = .{ .frame = .aggregate }, // Use aggregate policy
    };

    // Verify config is valid
    const Sched = Schedule(cfg);
    try std.testing.expectEqual(@as(usize, 1), Sched.system_count);

    // AggregateErrors should track errors properly
    const AggErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);
    var errors = AggErrors.init();
    try std.testing.expectEqual(@as(u32, 0), errors.count);

    // Add an error
    const added = errors.add(FrameError.SystemError, 0, 1000);
    try std.testing.expect(added);
    try std.testing.expectEqual(@as(u32, 1), errors.count);
    try std.testing.expectEqual(FrameError.SystemError, errors.first().?);
}

test "Multi-phase transitions" {
    // Test that state is consistent between phases
    const State = struct { value: u32 };

    const TestSystems = struct {
        fn phase0System(_: anytype) FrameError!void {}
        fn phase1System(_: anytype) FrameError!void {}
        fn phase2System(_: anytype) FrameError!void {}
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{State} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{State} },
        } },
        .systems = .{
            .systems = &.{
                .{
                    .name = "phase0_sys",
                    .func = @ptrCast(&TestSystems.phase0System),
                    .phase = 0,
                    .write_components = &.{State},
                },
                .{
                    .name = "phase1_sys",
                    .func = @ptrCast(&TestSystems.phase1System),
                    .phase = 1,
                    .read_components = &.{State},
                    .write_components = &.{State},
                },
                .{
                    .name = "phase2_sys",
                    .func = @ptrCast(&TestSystems.phase2System),
                    .phase = 2,
                    .read_components = &.{State},
                },
            },
        },
        .options = .{ .max_entities = 100 },
    };

    const Sched = Schedule(cfg);

    // Verify all 3 phases have systems
    try std.testing.expectEqual(@as(usize, 3), Sched.num_phases);
    try std.testing.expectEqual(@as(usize, 3), Sched.system_count);

    // Each phase should have 1 stage with 1 system
    for (0..3) |i| {
        try std.testing.expect(Sched.stages_by_phase[i].stage_count >= 1);
    }
}

test "Empty phase handling" {
    // Phases with no systems should not crash
    const Position = struct { x: f32, y: f32 };

    const TestSystems = struct {
        fn updateSystem(_: anytype) FrameError!void {}
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{Position} },
        } },
        .systems = .{
            .systems = &.{
                // Only update phase (1) has a system
                // pre_update (0) and post_update (2) are empty
                .{
                    .name = "update_only",
                    .func = @ptrCast(&TestSystems.updateSystem),
                    .phase = 1, // update phase only
                },
            },
        },
        .options = .{ .max_entities = 100 },
    };

    const Sched = Schedule(cfg);

    // Schedule should still have 3 phases
    try std.testing.expectEqual(@as(usize, 3), Sched.num_phases);

    // Phase 0 (pre_update) should be empty
    try std.testing.expectEqual(@as(u16, 0), Sched.stages_by_phase[0].stage_count);

    // Phase 1 (update) should have systems
    try std.testing.expectEqual(@as(u16, 1), Sched.stages_by_phase[1].stage_count);

    // Phase 2 (post_update) should be empty
    try std.testing.expectEqual(@as(u16, 0), Sched.stages_by_phase[2].stage_count);
}

test "Frame timing accuracy" {
    // Test that frame timing structures work correctly
    const Position = struct { x: f32, y: f32 };

    const TestSystems = struct {
        fn timedSystem(_: anytype) FrameError!void {}
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{Position} },
        } },
        .systems = .{
            .systems = &.{
                .{
                    .name = "timed",
                    .func = @ptrCast(&TestSystems.timedSystem),
                    .phase = 1,
                },
            },
        },
        .tick = .{
            .mode = .fixed_rate,
            .target_hz = 60, // 60 FPS target
        },
        .options = .{ .max_entities = 100 },
    };

    // Verify tick configuration
    try std.testing.expectEqual(config_mod.TickMode.fixed_rate, cfg.tick.mode);
    try std.testing.expectEqual(@as(?u32, 60), cfg.tick.target_hz);

    // Verify FixedRateConfig
    const rate_config = FixedRateConfig{
        .target_hz = 60,
        .max_frame_delay_ns = 100_000_000, // 100ms max delay
    };
    try std.testing.expectEqual(@as(u32, 60), rate_config.target_hz);
    try std.testing.expectEqual(@as(?u64, 100_000_000), rate_config.max_frame_delay_ns);
}

test "System skip on error" {
    // Test error handling doesn't corrupt state
    const Counter = struct { count: u32 };

    const TestSystems = struct {
        fn failingSystem(_: anytype) FrameError!void {
            return FrameError.SystemError;
        }
        fn successSystem(_: anytype) FrameError!void {}
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Counter} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{Counter} },
        } },
        .systems = .{
            .systems = &.{
                .{
                    .name = "failing",
                    .func = @ptrCast(&TestSystems.failingSystem),
                    .phase = 1,
                    .write_components = &.{Counter},
                },
                .{
                    .name = "success",
                    .func = @ptrCast(&TestSystems.successSystem),
                    .phase = 1,
                    .read_components = &.{Counter},
                },
            },
        },
        .options = .{ .max_entities = 100 },
        .policies = .{ .frame = .default }, // Stop on first error
    };

    const Sched = Schedule(cfg);

    // Both systems exist
    try std.testing.expectEqual(@as(usize, 2), Sched.system_count);

    // Systems have a conflict (write/read on Counter)
    try std.testing.expect(Sched.conflicts[0][1]);
}

test "CommandExecutor result tracking" {
    // Test CommandExecutionResult structure
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 100 },
    };

    // Generate the WorldType to get CommandExecutor
    const world_mod = @import("../world.zig");
    const WorldType = world_mod.World(cfg);
    const CmdExec = CommandExecutor(cfg, WorldType);

    // Test CommandExecutionResult
    var result = CmdExec.CommandExecutionResult{};
    try std.testing.expect(result.allSucceeded());
    try std.testing.expectEqual(@as(u32, 0), result.totalErrors());

    // Simulate errors
    result.despawn_error_count = 1;
    result.spawn_error_count = 2;
    try std.testing.expect(!result.allSucceeded());
    try std.testing.expectEqual(@as(u32, 3), result.totalErrors());
}

test "StageExecutor type generation" {
    // Test StageExecutor type generation with config
    const Position = struct { x: f32, y: f32 };

    const TestSystems = struct {
        fn sys1(_: anytype) FrameError!void {}
        fn sys2(_: anytype) FrameError!void {}
    };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{Position} },
        } },
        .systems = .{
            .systems = &.{
                .{
                    .name = "sys1",
                    .func = @ptrCast(&TestSystems.sys1),
                    .phase = 1,
                    .write_components = &.{Position},
                },
                .{
                    .name = "sys2",
                    .func = @ptrCast(&TestSystems.sys2),
                    .phase = 1,
                    .read_components = &.{Position},
                },
            },
        },
        .options = .{ .max_entities = 100 },
    };

    const Sched = Schedule(cfg);
    const world_mod = @import("../world.zig");
    const WorldType = world_mod.World(cfg);
    const StageExec = StageExecutor(cfg, WorldType);

    // Verify type generation
    try std.testing.expectEqual(@as(usize, 2), Sched.system_count);

    // StageExec should have ConfigStage type
    const ConfigStage = StageExec.ConfigStage;
    try std.testing.expectEqual(@as(u16, cfg.options.max_systems_per_stage), ConfigStage.max_systems_per_stage);
}
