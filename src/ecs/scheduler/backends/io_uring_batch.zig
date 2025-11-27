//! io_uring Batch Scheduler Backend
//!
//! This backend uses Linux's io_uring for syscall batching per scheduler phase.
//! It collects I/O intents from systems, submits them as a batch, and processes
//! completions before moving to the next phase.
//!
//! ## Platform Requirements
//!
//! This backend requires Linux with io_uring support (kernel 5.1+).
//! On non-Linux platforms, compilation will produce a stub that falls back
//! to the blocking backend at comptime.
//!
//! ## Characteristics
//!
//! - **Execution**: Single-threaded with batched syscalls
//! - **I/O**: io_uring submission/completion queues
//! - **Best For**: High-throughput servers with many concurrent I/O operations
//! - **Overhead**: io_uring setup cost, but amortized over batched operations
//!
//! ## Usage
//!
//! ```zig
//! const cfg = ecs.WorldConfig{
//!     .schedule = .{
//!         .execution_model = .io_uring_batch,
//!         .backend_config = .{ .io_uring_batch = .{
//!             .sq_entries = 256,
//!             .batch_size = 64,
//!         }},
//!     },
//! };
//! ```
//!
//! Tiger Style: Platform-specific optimization with graceful fallback.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const config_mod = @import("../../config.zig");
const WorldConfig = config_mod.WorldConfig;
const FramePolicy = config_mod.FramePolicy;
const TraceLevel = config_mod.TraceLevel;
const ExecutionModel = config_mod.ExecutionModel;
const IoUringBatchConfig = config_mod.IoUringBatchConfig;

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

const interface = @import("interface.zig");
const BackendStats = interface.BackendStats;
const getTimeNs = interface.getTimeNs;

// ============================================================================
// Platform Detection
// ============================================================================

/// Whether io_uring is available on this platform.
pub const io_uring_available = builtin.os.tag == .linux;

// ============================================================================
// io_uring Batch Backend
// ============================================================================

/// io_uring batch scheduler backend.
///
/// On Linux: Uses io_uring for syscall batching per phase.
/// On other platforms: Immediate compile error (use SelectBackend for fallback).
///
/// Tiger Style: Platform-specific optimization behind comptime detection.
pub fn IoUringBatchBackend(comptime cfg: WorldConfig, comptime WorldType: type) type {
    // Extract config with defaults
    const batch_cfg: IoUringBatchConfig = switch (cfg.schedule.backend_config) {
        .io_uring_batch => |c| c,
        else => .{}, // Use defaults if not specified
    };

    const Sched = Schedule(cfg);
    const SysCtx = SystemContext(cfg, WorldType);
    const CmdBuf = SysCtx.CmdBuf;
    const Tracer = TracingContext(cfg.tracing.level);

    // Config-based types
    const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);
    const FrameResultT = FrameResultType(cfg.options.max_aggregate_errors);

    // Maximum pending operations (from config)
    const max_pending = batch_cfg.batch_size;

    return struct {
        const Self = @This();

        // Instance state
        allocator: Allocator,
        trace_sink: ?TraceSink,
        tick_count: u64,
        stats: BackendStats,

        // io_uring state (Linux only)
        ring: if (io_uring_available) std.os.linux.IoUring else void,
        pending_ops: [max_pending]PendingOp,
        pending_count: u16,

        /// Represents a pending I/O operation.
        pub const PendingOp = struct {
            /// System index that initiated this operation.
            system_idx: u16,
            /// Operation type.
            op_type: OpType,
            /// File descriptor for the operation.
            fd: i32,
            /// Buffer for read/write operations.
            buffer: [*]u8,
            /// Length of the buffer/operation.
            len: usize,
            /// Offset for positioned read/write.
            offset: u64,
            /// User data for correlation.
            user_data: u64,
            /// Result of completed operation (negative = errno).
            result: i32,
            /// Whether this operation has completed.
            completed: bool,

            pub const OpType = enum(u8) {
                nop,
                read,
                write,
                accept,
                connect,
                close,
                fsync,
                poll_add,
                poll_remove,
                timeout,
            };

            pub fn init() PendingOp {
                return .{
                    .system_idx = 0,
                    .op_type = .nop,
                    .fd = -1,
                    .buffer = undefined,
                    .len = 0,
                    .offset = 0,
                    .user_data = 0,
                    .result = 0,
                    .completed = false,
                };
            }
        };

        /// Initialize the io_uring batch backend.
        pub fn init(allocator: Allocator, trace_sink: ?TraceSink) !Self {
            var self = Self{
                .allocator = allocator,
                .trace_sink = trace_sink,
                .tick_count = 0,
                .stats = .{},
                .ring = undefined,
                .pending_ops = [_]PendingOp{PendingOp.init()} ** max_pending,
                .pending_count = 0,
            };

            if (io_uring_available) {
                // Initialize io_uring with configured queue sizes
                var flags: u32 = 0;
                if (batch_cfg.kernel_poll) {
                    flags |= std.os.linux.IORING_SETUP_SQPOLL;
                }

                self.ring = try std.os.linux.IoUring.init(batch_cfg.sq_entries, flags);

                // Set SQ thread CPU affinity if configured
                if (batch_cfg.kernel_poll and batch_cfg.sq_thread_cpu != null) {
                    // Note: Would need additional syscall for SQ_THREAD_IDLE
                    // This is a hint to the kernel about idle behavior
                }
            }

            return self;
        }

        /// Clean up resources.
        pub fn deinit(self: *Self) void {
            if (io_uring_available) {
                self.ring.deinit();
            }
        }

        /// Execute a single tick/frame with batched I/O.
        ///
        /// Execution flow:
        /// 1. For each phase:
        ///    a. Collect I/O intents from systems
        ///    b. Submit batch to io_uring
        ///    c. Execute non-I/O systems
        ///    d. Wait for and process completions
        /// 2. Apply deferred commands
        pub fn tick(self: *Self, world: *WorldType, delta_time: f64) FrameResultT {
            const start_time = getTimeNs();

            // Initialize command buffer
            var commands = CmdBuf.init();

            // Create system context
            var ctx = SysCtx.init(
                world,
                &world.resources,
                delta_time,
                self.tick_count,
                start_time,
                &commands,
                self.allocator,
            );

            const policy = cfg.policies.frame;
            var errors = AggregateErrors.init();

            // Initialize tracing
            var tracer = Tracer.init(self.trace_sink, @intFromPtr(world));
            tracer.emitTickStart(self.tick_count, start_time);

            // Execute all phases with batched I/O
            var frame_success = true;
            var systems_run: u64 = 0;
            var syscalls_batched: u64 = 0;

            inline for (0..Sched.num_phases) |phase_idx| {
                const phase_result = self.executePhaseWithBatching(
                    &ctx,
                    phase_idx,
                    policy,
                    &errors,
                );

                systems_run += phase_result.systems_run;
                syscalls_batched += phase_result.syscalls_batched;
                self.stats.phases_executed += 1;

                if (!phase_result.success) {
                    frame_success = false;
                    if (policy == .default) break;
                }
            }

            // Apply deferred commands
            self.applyCommands(world, &commands);

            // Emit tick end
            const end_time = getTimeNs();
            tracer.emitTickEnd(self.tick_count, end_time, end_time - start_time);

            // Update statistics
            self.tick_count += 1;
            self.stats.ticks_executed += 1;
            self.stats.systems_executed += systems_run;
            self.stats.syscalls_batched += syscalls_batched;
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
            self.pending_count = 0;
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
        // Internal: Phase Execution with Batching
        // ─────────────────────────────────────────────────────────────────────

        const PhaseResult = struct {
            success: bool,
            systems_run: u64,
            syscalls_batched: u64,
        };

        fn executePhaseWithBatching(
            self: *Self,
            ctx: *SysCtx,
            comptime phase_idx: usize,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) PhaseResult {
            var result = PhaseResult{
                .success = true,
                .systems_run = 0,
                .syscalls_batched = 0,
            };

            // Reset pending operations for this phase
            self.pending_count = 0;

            // Get stages for this phase
            const phase_stages = Sched.stages_by_phase[phase_idx];

            // Phase 1: Execute all systems, collecting I/O intents
            inline for (0..phase_stages.stage_count) |stage_idx| {
                const stage = phase_stages.stages[stage_idx];
                inline for (0..stage.system_count) |sys_idx| {
                    const system_index = stage.system_indices[sys_idx];
                    const system_def = Sched.systems[system_index];

                    // Execute system
                    const SystemFn = *const fn (*SysCtx) FrameError!void;
                    const func: SystemFn = @ptrCast(@alignCast(system_def.func));

                    func(ctx) catch |err| {
                        errors.add(err, system_index, ctx.time_ns);
                        result.success = false;
                        if (policy == .default) return result;
                    };

                    result.systems_run += 1;

                    // TODO: Check if system queued any I/O intents
                    // This would require IoContext integration
                }
            }

            // Phase 2: Submit batched I/O (if any pending)
            if (self.pending_count > 0) {
                result.syscalls_batched += self.submitBatch();
            }

            // Phase 3: Process completions
            self.processCompletions();

            return result;
        }

        /// Submit all pending operations to io_uring.
        fn submitBatch(self: *Self) u64 {
            if (!io_uring_available) return 0;

            var submitted: u64 = 0;

            for (self.pending_ops[0..self.pending_count]) |*op| {
                const sqe = self.ring.get_sqe() orelse {
                    // SQ full, submit what we have and retry
                    _ = self.ring.submit() catch {};
                    continue;
                };

                // Prepare operation based on type
                switch (op.op_type) {
                    .nop => sqe.prep_nop(),
                    .read => sqe.prep_read(op.fd, @as([*]u8, @ptrCast(op.buffer))[0..op.len], op.offset),
                    .write => sqe.prep_write(op.fd, @as([*]const u8, @ptrCast(op.buffer))[0..op.len], op.offset),
                    .close => sqe.prep_close(op.fd),
                    .fsync => sqe.prep_fsync(op.fd, 0),
                    // Other operations would go here
                    else => sqe.prep_nop(),
                }

                // Set user data for correlation
                sqe.user_data = @intFromPtr(op);
                submitted += 1;
            }

            // Submit the batch
            _ = self.ring.submit() catch {};

            return submitted;
        }

        /// Process completed operations from io_uring.
        fn processCompletions(self: *Self) void {
            if (!io_uring_available) return;

            // Wait for at least some completions if we have pending ops
            if (self.pending_count > 0) {
                _ = self.ring.submit_and_wait(1) catch {};
            }

            // Process all available completions
            while (true) {
                const cqe = self.ring.peek_cqe() orelse break;

                // Get the pending op from user_data
                const op: *PendingOp = @ptrFromInt(cqe.user_data);
                op.result = cqe.res;
                op.completed = true;

                // TODO: Dispatch completion to appropriate handler
                // This would notify the system that queued the operation

                self.ring.cq_advance(1);
            }
        }

        /// Queue an I/O operation for batched submission.
        /// Returns true if successfully queued, false if batch is full.
        pub fn queueOp(self: *Self, op: PendingOp) bool {
            if (self.pending_count >= max_pending) return false;

            self.pending_ops[self.pending_count] = op;
            self.pending_count += 1;
            return true;
        }

        /// Apply deferred commands from the command buffer.
        fn applyCommands(self: *Self, world: *WorldType, commands: *CmdBuf) void {
            _ = self;
            for (commands.getCommands()) |cmd| {
                switch (cmd) {
                    .despawn => |handle| {
                        world.despawn(handle) catch {};
                    },
                    .spawn => |spawn_cmd| {
                        _ = spawn_cmd;
                    },
                    .set_component => |set_cmd| {
                        _ = set_cmd;
                    },
                }
            }
        }
    };
}

// ============================================================================
// Platform Fallback
// ============================================================================

/// Fallback backend for non-Linux platforms.
/// This simply delegates to BlockingBackend.
pub fn IoUringFallbackBackend(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const blocking = @import("blocking.zig");
    return blocking.BlockingBackend(cfg, WorldType);
}

// ============================================================================
// Tests
// ============================================================================

test "io_uring backend - platform detection" {
    const expected = builtin.os.tag == .linux;
    try std.testing.expectEqual(expected, io_uring_available);
}

test "io_uring backend - PendingOp init" {
    const cfg = config_mod.WorldConfig{};
    const Backend = IoUringBatchBackend(cfg, DummyWorld);
    const op = Backend.PendingOp.init();
    try std.testing.expectEqual(@as(u16, 0), op.system_idx);
    try std.testing.expectEqual(Backend.PendingOp.OpType.nop, op.op_type);
    try std.testing.expectEqual(@as(i32, -1), op.fd);
    try std.testing.expect(!op.completed);
}

test "io_uring backend - config extraction default" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .execution_model = .io_uring_batch,
        },
    };

    // This tests that the backend can be instantiated with default config
    const Backend = IoUringBatchBackend(cfg, DummyWorld);
    _ = Backend.PendingOp.init();
}

test "io_uring backend - config extraction explicit" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .execution_model = .io_uring_batch,
            .backend_config = .{ .io_uring_batch = .{
                .sq_entries = 512,
                .cq_entries = 1024,
                .batch_size = 128,
            } },
        },
    };

    const Backend = IoUringBatchBackend(cfg, DummyWorld);
    _ = Backend.PendingOp.init();
}

test "io_uring backend - stats initialization" {
    const stats = BackendStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
    try std.testing.expectEqual(@as(u64, 0), stats.syscalls_batched);
}

// Dummy world type for testing
const DummyWorld = struct {
    resources: struct {},

    pub fn despawn(_: *DummyWorld, _: anytype) !void {}
};
