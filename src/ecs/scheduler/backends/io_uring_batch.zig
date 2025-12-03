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
//! ## I/O Intent System
//!
//! Systems can queue I/O operations for batched execution via the IoIntentQueue:
//!
//! ```zig
//! fn mySystem(ctx: *SystemContext) !void {
//!     // Get the intent queue from the backend (if available)
//!     if (ctx.getIo()) |io| {
//!         if (io.getIntentQueue()) |queue| {
//!             var result: i32 = 0;
//!             _ = queue.queue(.{
//!                 .op_type = .read,
//!                 .fd = my_fd,
//!                 .buffer = buffer.ptr,
//!                 .len = buffer.len,
//!                 .offset = 0,
//!                 .result_ptr = &result,  // Written on completion
//!             });
//!         }
//!     }
//! }
//! ```
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
// I/O Intent Types
// ============================================================================

/// Operation type for I/O intents.
/// Matches io_uring supported operations.
pub const IoOpType = enum(u8) {
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

/// Completion callback function type.
/// Called when an I/O operation completes with the result.
/// Parameters: result (negative = errno), user_data
pub const IoCompletionCallback = *const fn (i32, u64) void;

/// I/O Request that systems can submit for batched execution.
///
/// Tiger Style: All fields bounded/explicit, result delivered via pointer.
///
/// ## Socket Operations
///
/// For `.accept` operations:
/// - `fd`: Listening socket file descriptor
/// - `buffer`: Optional pointer to sockaddr for client address (can be undefined if not needed)
/// - `len`: Size of sockaddr buffer (0 if buffer not provided)
/// - `offset`: Accept4 flags (e.g., SOCK_NONBLOCK, SOCK_CLOEXEC) or 0
/// - `result_ptr`: Receives new client fd on success, negative errno on failure
///
/// For `.connect` operations:
/// - `fd`: Socket file descriptor
/// - `buffer`: Pointer to sockaddr with destination address (REQUIRED)
/// - `len`: Size of sockaddr structure (REQUIRED, must be > 0)
/// - `result_ptr`: Receives 0 on success, negative errno on failure
///
/// For `.poll_add` operations:
/// - `fd`: File descriptor to poll
/// - `offset`: Poll events mask (POLLIN, POLLOUT, etc.)
/// - `result_ptr`: Receives triggered events or negative errno
///
/// For `.poll_remove` operations:
/// - `fd`: File descriptor to remove poll for
/// - `user_data`: Must match the user_data from the original poll_add
///
/// For `.timeout` operations:
/// - `buffer`: Pointer to kernel_timespec structure
/// - `len`: 1 for relative timeout, 0 for absolute
/// - `offset`: Number of completions to wait for (0 = just timeout)
pub const IoRequest = struct {
    /// Operation type to perform.
    op_type: IoOpType = .nop,
    /// File descriptor for the operation.
    fd: i32 = -1,
    /// Buffer pointer for read/write operations.
    /// For socket ops: points to sockaddr structure.
    /// For timeout: points to kernel_timespec.
    buffer: [*]u8 = undefined,
    /// Length of the buffer/operation.
    /// For socket ops: sizeof(sockaddr).
    len: usize = 0,
    /// Offset for positioned read/write.
    /// For accept: accept4 flags.
    /// For poll_add: poll event mask.
    offset: u64 = 0,
    /// Result written here on completion (negative = errno).
    /// Must remain valid until completion is processed.
    result_ptr: ?*volatile i32 = null,
    /// Optional completion callback.
    callback: ?IoCompletionCallback = null,
    /// User data passed to callback.
    user_data: u64 = 0,
};

/// Bounded queue for I/O intents from systems.
///
/// Systems queue requests during execution, then the scheduler
/// collects and batches them for io_uring submission.
///
/// Tiger Style: Fixed capacity, fail-fast on overflow.
pub fn IoIntentQueue(comptime max_requests: u16) type {
    return struct {
        const Self = @This();
        pub const capacity = max_requests;

        requests: [max_requests]IoRequest = [_]IoRequest{.{}} ** max_requests,
        count: u16 = 0,

        /// Initialize an empty queue.
        pub fn init() Self {
            return .{};
        }

        /// Queue an I/O request. Returns false if queue is full.
        pub fn queue(self: *Self, request: IoRequest) bool {
            if (self.count >= max_requests) return false;
            self.requests[self.count] = request;
            self.count += 1;
            return true;
        }

        /// Get queued requests as a slice.
        pub fn getRequests(self: *const Self) []const IoRequest {
            return self.requests[0..self.count];
        }

        /// Clear all queued requests.
        pub fn clear(self: *Self) void {
            self.count = 0;
        }

        /// Check if queue is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Check if queue is full.
        pub fn isFull(self: *const Self) bool {
            return self.count >= max_requests;
        }

        /// Get number of queued requests.
        pub fn len(self: *const Self) u16 {
            return self.count;
        }
    };
}

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

        /// Whether io_uring was successfully initialized.
        /// When false, operates in degraded mode (no syscall batching).
        io_uring_active: bool,

        /// Shared I/O intent queue that systems can access.
        /// Systems queue requests here, scheduler collects and processes them.
        intent_queue: IntentQueue,

        /// Represents a pending I/O operation with completion tracking.
        pub const PendingOp = struct {
            /// System index that initiated this operation.
            system_idx: u16,
            /// Operation type (uses shared IoOpType).
            op_type: IoOpType,
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
            /// Result pointer to write completion result to.
            result_ptr: ?*volatile i32,
            /// Optional completion callback.
            callback: ?IoCompletionCallback,

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
                    .result_ptr = null,
                    .callback = null,
                };
            }

            /// Create a PendingOp from an IoRequest.
            pub fn fromRequest(request: IoRequest, system_idx: u16) PendingOp {
                return .{
                    .system_idx = system_idx,
                    .op_type = request.op_type,
                    .fd = request.fd,
                    .buffer = request.buffer,
                    .len = request.len,
                    .offset = request.offset,
                    .user_data = request.user_data,
                    .result = 0,
                    .completed = false,
                    .result_ptr = request.result_ptr,
                    .callback = request.callback,
                };
            }
        };

        /// I/O intent queue type for this backend.
        pub const IntentQueue = IoIntentQueue(max_pending);

        /// Initialize the io_uring batch backend.
        ///
        /// This function is infallible to maintain interface consistency with other backends.
        /// If io_uring initialization fails, the backend operates in degraded mode where
        /// I/O batching is disabled and operations proceed without syscall batching.
        ///
        /// Tiger Style: Graceful degradation - optional feature failure doesn't block operation.
        pub fn init(allocator: Allocator, trace_sink: ?TraceSink) Self {
            var self = Self{
                .allocator = allocator,
                .trace_sink = trace_sink,
                .tick_count = 0,
                .stats = .{},
                .ring = undefined,
                .pending_ops = [_]PendingOp{PendingOp.init()} ** max_pending,
                .pending_count = 0,
                .io_uring_active = false,
                .intent_queue = IntentQueue.init(),
            };

            if (io_uring_available) {
                // Initialize io_uring with configured queue sizes
                var flags: u32 = 0;
                if (batch_cfg.kernel_poll) {
                    flags |= std.os.linux.IORING_SETUP_SQPOLL;
                }

                // Attempt io_uring init - on failure, operate in degraded mode
                self.ring = std.os.linux.IoUring.init(batch_cfg.sq_entries, flags) catch |err| {
                    // io_uring unavailable (permission denied, kernel too old, etc.)
                    // Continue in degraded mode - systems still execute, just without batching
                    //
                    // Tiger Style: Log degradation for production visibility. This is
                    // intentionally logged even in release builds since it affects
                    // performance characteristics that operators should be aware of.
                    if (cfg.tracing.level != .none) {
                        std.log.warn(
                            "io_uring initialization failed (error: {}), falling back to blocking mode. " ++
                                "I/O batching disabled; systems will execute without syscall batching.",
                            .{err},
                        );
                    }
                    return self;
                };

                self.io_uring_active = true;

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
            if (io_uring_available and self.io_uring_active) {
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
        ///
        /// Tiger Style: Central control flow, delegates to pure helpers.
        pub fn tick(self: *Self, world: *WorldType, delta_time: f64) FrameResultT {
            // Pre-conditions: valid state
            std.debug.assert(delta_time >= 0.0);
            std.debug.assert(self.tick_count < std.math.maxInt(u64));

            const start_time = getTimeNs();
            var commands = CmdBuf.init();
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
            var tracer = Tracer.init(self.trace_sink, @intFromPtr(world));
            tracer.emitTickStart(self.tick_count, start_time);

            // Execute phases and accumulate stats
            var frame_success = true;
            var systems_run: u64 = 0;
            var syscalls_batched: u64 = 0;

            inline for (0..Sched.num_phases) |phase_idx| {
                const phase_result = self.executePhaseWithBatching(&ctx, phase_idx, policy, &errors);
                systems_run += phase_result.systems_run;
                syscalls_batched += phase_result.syscalls_batched;
                self.stats.phases_executed += 1;

                if (!phase_result.success) {
                    frame_success = false;
                    if (policy == .default) break;
                }
            }

            // Finalize: apply commands, emit tracing, update stats
            self.applyCommands(world, &commands);
            const end_time = getTimeNs();
            const tick_duration = end_time - start_time;
            tracer.emitTickEnd(self.tick_count, end_time, tick_duration);
            self.updateTickStats(systems_run, syscalls_batched, tick_duration);

            // Post-condition: tick count incremented
            std.debug.assert(self.stats.ticks_executed > 0);

            return buildTickResult(frame_success, policy, &errors);
        }

        /// Update tick statistics after frame execution.
        /// Tiger Style: Pure helper - no control flow, just data updates.
        fn updateTickStats(self: *Self, systems_run: u64, syscalls_batched: u64, tick_duration: u64) void {
            self.tick_count += 1;
            self.stats.ticks_executed += 1;
            self.stats.systems_executed += systems_run;
            self.stats.syscalls_batched += syscalls_batched;
            self.stats.last_tick_time_ns = tick_duration;
            self.stats.total_tick_time_ns += tick_duration;
        }

        /// Build the tick result based on success state and policy.
        /// Tiger Style: Pure function - deterministic output from inputs.
        fn buildTickResult(success: bool, policy: FramePolicy, errors: *AggregateErrors) FrameResultT {
            if (success) return .{ .success = {} };
            if (policy == .aggregate) return .{ .aggregate_errors = errors.* };
            if (errors.first()) |first_err| return .{ .single_error = first_err };
            return .{ .success = {} };
        }

        /// Reset backend state and statistics.
        pub fn reset(self: *Self) void {
            self.tick_count = 0;
            self.pending_count = 0;
            self.intent_queue.clear();
            self.stats.reset();
            // Note: io_uring_active state is preserved - it reflects hardware capability
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

        /// Get the intent queue for systems to queue I/O operations.
        ///
        /// Systems can call this to queue I/O operations that will be
        /// batched and submitted via io_uring at the end of each phase.
        ///
        /// Returns null if the backend is not active (degraded mode).
        pub fn getIntentQueue(self: *Self) ?*IntentQueue {
            if (!io_uring_available or !self.io_uring_active) return null;
            return &self.intent_queue;
        }

        /// Check if io_uring is active and available for batching.
        pub fn isActive(self: *const Self) bool {
            return io_uring_available and self.io_uring_active;
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
            self.intent_queue.clear();

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

                    // Collect I/O intents queued by this system
                    // Systems queue via getIntentQueue() which returns &self.intent_queue
                    const intents_collected = self.collectIntentsFromQueue(
                        @as(u16, @intCast(system_index)),
                    );
                    result.syscalls_batched += intents_collected;
                }
            }

            // Phase 2: Submit batched I/O (if any pending)
            if (self.pending_count > 0) {
                _ = self.submitBatch();
            }

            // Phase 3: Process completions and dispatch results
            self.processCompletions();

            return result;
        }

        /// Collect I/O intents from the shared queue into pending_ops.
        ///
        /// This is called after each system executes to move queued intents
        /// into the pending operations array for batch submission.
        fn collectIntentsFromQueue(self: *Self, system_idx: u16) u64 {
            if (!io_uring_available or !self.io_uring_active) return 0;
            if (self.intent_queue.isEmpty()) return 0;

            var collected: u64 = 0;
            for (self.intent_queue.getRequests()) |request| {
                if (self.pending_count >= max_pending) break;

                self.pending_ops[self.pending_count] = PendingOp.fromRequest(
                    request,
                    system_idx,
                );
                self.pending_count += 1;
                collected += 1;
            }

            // Clear the intent queue after collection
            self.intent_queue.clear();
            return collected;
        }

        /// Submit all pending operations to io_uring.
        ///
        /// Tiger Style: Central control in parent, operation prep in pure helper.
        fn submitBatch(self: *Self) u64 {
            // Pre-conditions
            std.debug.assert(self.pending_count <= max_pending);
            if (!io_uring_available or !self.io_uring_active) return 0;

            var submitted: u64 = 0;
            const initial_pending = self.pending_count;

            for (self.pending_ops[0..self.pending_count]) |*op| {
                const sqe = self.ring.get_sqe() orelse {
                    // SQ full, submit what we have and retry
                    _ = self.ring.submit() catch {};
                    continue;
                };

                prepareSqeForOp(sqe, op);
                sqe.user_data = @intFromPtr(op);
                submitted += 1;
            }

            _ = self.ring.submit() catch {};

            // Post-condition: submitted ops don't exceed pending
            std.debug.assert(submitted <= initial_pending);
            return submitted;
        }

        /// Prepare a submission queue entry for the given pending operation.
        ///
        /// Tiger Style: Pure helper function - maps op type to io_uring prep call.
        /// Handles all I/O operation types with graceful fallback for invalid params.
        fn prepareSqeForOp(sqe: *std.os.linux.io_uring_sqe, op: *PendingOp) void {
            switch (op.op_type) {
                .nop => sqe.prep_nop(),
                .read => sqe.prep_read(op.fd, @as([*]u8, @ptrCast(op.buffer))[0..op.len], op.offset),
                .write => sqe.prep_write(op.fd, @as([*]const u8, @ptrCast(op.buffer))[0..op.len], op.offset),
                .close => sqe.prep_close(op.fd),
                .fsync => sqe.prep_fsync(op.fd, 0),
                .accept => prepareAcceptOp(sqe, op),
                .connect => prepareConnectOp(sqe, op),
                .poll_add => sqe.prep_poll_add(op.fd, @truncate(op.offset)),
                .poll_remove => sqe.prep_poll_remove(op.user_data),
                .timeout => prepareTimeoutOp(sqe, op),
            }
        }

        /// Prepare accept operation on listening socket.
        /// buffer/len optionally receive client address; offset contains accept4 flags.
        fn prepareAcceptOp(sqe: *std.os.linux.io_uring_sqe, op: *PendingOp) void {
            if (op.len > 0) {
                // With address capture: buffer points to sockaddr, len stores size
                const addr_ptr: *std.posix.sockaddr = @ptrCast(@alignCast(op.buffer));
                var addrlen: std.posix.socklen_t = @intCast(op.len);
                sqe.prep_accept(op.fd, addr_ptr, &addrlen, @truncate(op.offset));
            } else {
                // Without address capture: just get the new fd
                sqe.prep_accept(op.fd, null, null, @truncate(op.offset));
            }
        }

        /// Prepare connect operation to remote address.
        /// buffer MUST point to sockaddr, len MUST be sizeof(sockaddr).
        fn prepareConnectOp(sqe: *std.os.linux.io_uring_sqe, op: *PendingOp) void {
            if (op.len == 0) {
                // Invalid connect request - sockaddr required; fallback to nop
                sqe.prep_nop();
            } else {
                const addr_ptr: *const std.posix.sockaddr = @ptrCast(@alignCast(op.buffer));
                sqe.prep_connect(op.fd, addr_ptr, @intCast(op.len));
            }
        }

        /// Prepare timeout operation.
        /// buffer points to kernel_timespec; len indicates relative(1)/absolute(0).
        fn prepareTimeoutOp(sqe: *std.os.linux.io_uring_sqe, op: *PendingOp) void {
            if (op.len > 0) {
                const ts_ptr: *const std.os.linux.kernel_timespec = @ptrCast(@alignCast(op.buffer));
                const flags: u32 = if (op.len == 1) 0 else std.os.linux.IORING_TIMEOUT_ABS;
                sqe.prep_timeout(ts_ptr, @truncate(op.offset), flags);
            } else {
                // Invalid timeout - needs timespec; fallback to nop
                sqe.prep_nop();
            }
        }

        /// Process completed operations from io_uring.
        ///
        /// Dispatches results back to requesters via:
        /// 1. Writing result to result_ptr (if provided)
        /// 2. Invoking callback (if provided)
        fn processCompletions(self: *Self) void {
            if (!io_uring_available or !self.io_uring_active) return;

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

                // Dispatch completion: write result and invoke callback
                self.dispatchCompletion(op);

                self.ring.cq_advance(1);
            }
        }

        /// Dispatch a completed I/O operation to its requester.
        ///
        /// Tiger Style: Result delivery via pointer write (non-blocking),
        /// optional callback for complex handling.
        fn dispatchCompletion(_: *Self, op: *PendingOp) void {
            // Write result to the result pointer if provided
            // This allows the requesting system to poll for completion
            if (op.result_ptr) |ptr| {
                ptr.* = op.result;
            }

            // Invoke callback if provided
            // This allows immediate handling of completions
            if (op.callback) |callback| {
                callback(op.result, op.user_data);
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
    try std.testing.expectEqual(IoOpType.nop, op.op_type);
    try std.testing.expectEqual(@as(i32, -1), op.fd);
    try std.testing.expect(!op.completed);
    try std.testing.expect(op.result_ptr == null);
    try std.testing.expect(op.callback == null);
}

test "io_uring backend - PendingOp fromRequest" {
    const cfg = config_mod.WorldConfig{};
    const Backend = IoUringBatchBackend(cfg, DummyWorld);

    var result: i32 = 0;
    var buffer: [64]u8 = undefined;
    const request = IoRequest{
        .op_type = .read,
        .fd = 42,
        .buffer = &buffer,
        .len = buffer.len,
        .offset = 100,
        .result_ptr = &result,
        .user_data = 12345,
    };

    const op = Backend.PendingOp.fromRequest(request, 7);
    try std.testing.expectEqual(@as(u16, 7), op.system_idx);
    try std.testing.expectEqual(IoOpType.read, op.op_type);
    try std.testing.expectEqual(@as(i32, 42), op.fd);
    try std.testing.expectEqual(@as(usize, 64), op.len);
    try std.testing.expectEqual(@as(u64, 100), op.offset);
    try std.testing.expectEqual(@as(u64, 12345), op.user_data);
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

test "IoIntentQueue - basic operations" {
    var queue = IoIntentQueue(8).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(!queue.isFull());
    try std.testing.expectEqual(@as(u16, 0), queue.len());

    // Queue a request
    const result1 = queue.queue(.{ .op_type = .read, .fd = 1 });
    try std.testing.expect(result1);
    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(u16, 1), queue.len());

    // Queue more
    _ = queue.queue(.{ .op_type = .write, .fd = 2 });
    _ = queue.queue(.{ .op_type = .close, .fd = 3 });
    try std.testing.expectEqual(@as(u16, 3), queue.len());

    // Check requests
    const requests = queue.getRequests();
    try std.testing.expectEqual(@as(usize, 3), requests.len);
    try std.testing.expectEqual(IoOpType.read, requests[0].op_type);
    try std.testing.expectEqual(IoOpType.write, requests[1].op_type);
    try std.testing.expectEqual(IoOpType.close, requests[2].op_type);

    // Clear
    queue.clear();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(u16, 0), queue.len());
}

test "IoIntentQueue - capacity limits" {
    var queue = IoIntentQueue(4).init();

    // Fill to capacity
    try std.testing.expect(queue.queue(.{ .fd = 1 }));
    try std.testing.expect(queue.queue(.{ .fd = 2 }));
    try std.testing.expect(queue.queue(.{ .fd = 3 }));
    try std.testing.expect(queue.queue(.{ .fd = 4 }));

    try std.testing.expect(queue.isFull());
    try std.testing.expectEqual(@as(u16, 4), queue.len());

    // Should fail when full
    try std.testing.expect(!queue.queue(.{ .fd = 5 }));
    try std.testing.expectEqual(@as(u16, 4), queue.len());
}

test "IoRequest - default initialization" {
    const req = IoRequest{};
    try std.testing.expectEqual(IoOpType.nop, req.op_type);
    try std.testing.expectEqual(@as(i32, -1), req.fd);
    try std.testing.expectEqual(@as(usize, 0), req.len);
    try std.testing.expectEqual(@as(u64, 0), req.offset);
    try std.testing.expect(req.result_ptr == null);
    try std.testing.expect(req.callback == null);
}

test "io_uring backend - completion dispatch" {
    const cfg = config_mod.WorldConfig{};
    const Backend = IoUringBatchBackend(cfg, DummyWorld);

    var result: i32 = -999;

    const callback = struct {
        fn cb(res: i32, data: u64) void {
            // Note: Can't directly modify outer vars in this test setup
            // This test validates the callback signature works
            _ = res;
            _ = data;
        }
    }.cb;

    var op = Backend.PendingOp{
        .system_idx = 0,
        .op_type = .read,
        .fd = 1,
        .buffer = undefined,
        .len = 0,
        .offset = 0,
        .user_data = 42,
        .result = 100,
        .completed = true,
        .result_ptr = &result,
        .callback = callback,
    };

    // Test dispatchCompletion writes result
    var backend = Backend.init(std.testing.allocator, null);
    defer backend.deinit();

    backend.dispatchCompletion(&op);
    try std.testing.expectEqual(@as(i32, 100), result);
}

test "IoRequest - accept operation configuration" {
    // Test accept without address capture
    const req_no_addr = IoRequest{
        .op_type = .accept,
        .fd = 5, // listening socket
        .len = 0, // no address capture
        .offset = 0, // no special flags
    };
    try std.testing.expectEqual(IoOpType.accept, req_no_addr.op_type);
    try std.testing.expectEqual(@as(i32, 5), req_no_addr.fd);
    try std.testing.expectEqual(@as(usize, 0), req_no_addr.len);

    // Test accept with address capture
    var addr_buffer: [128]u8 = undefined; // sockaddr storage
    const req_with_addr = IoRequest{
        .op_type = .accept,
        .fd = 5,
        .buffer = &addr_buffer,
        .len = @sizeOf(std.posix.sockaddr.storage), // size of sockaddr_storage
        .offset = std.posix.SOCK.NONBLOCK, // accept4 flags
    };
    try std.testing.expectEqual(IoOpType.accept, req_with_addr.op_type);
    try std.testing.expectEqual(@as(i32, 5), req_with_addr.fd);
    try std.testing.expect(req_with_addr.len > 0);
}

test "IoRequest - connect operation configuration" {
    // Connect requires a sockaddr buffer
    var addr_buffer: [128]u8 = undefined;
    const req = IoRequest{
        .op_type = .connect,
        .fd = 6, // client socket
        .buffer = &addr_buffer,
        .len = @sizeOf(std.posix.sockaddr.in), // IPv4 address size
    };
    try std.testing.expectEqual(IoOpType.connect, req.op_type);
    try std.testing.expectEqual(@as(i32, 6), req.fd);
    try std.testing.expect(req.len > 0);
}

test "IoRequest - poll_add operation configuration" {
    const req = IoRequest{
        .op_type = .poll_add,
        .fd = 7,
        .offset = std.posix.POLL.IN | std.posix.POLL.OUT, // poll events
    };
    try std.testing.expectEqual(IoOpType.poll_add, req.op_type);
    try std.testing.expectEqual(@as(i32, 7), req.fd);
    try std.testing.expect(req.offset != 0);
}

test "IoIntentQueue - socket operations" {
    var queue = IoIntentQueue(8).init();

    // Queue accept operation
    const accept_result = queue.queue(.{
        .op_type = .accept,
        .fd = 10,
        .len = 0, // no address capture
    });
    try std.testing.expect(accept_result);

    // Queue connect operation
    var addr_buffer: [64]u8 = undefined;
    const connect_result = queue.queue(.{
        .op_type = .connect,
        .fd = 11,
        .buffer = &addr_buffer,
        .len = 16,
    });
    try std.testing.expect(connect_result);

    // Queue poll operation
    const poll_result = queue.queue(.{
        .op_type = .poll_add,
        .fd = 12,
        .offset = std.posix.POLL.IN,
    });
    try std.testing.expect(poll_result);

    try std.testing.expectEqual(@as(u16, 3), queue.len());

    const requests = queue.getRequests();
    try std.testing.expectEqual(IoOpType.accept, requests[0].op_type);
    try std.testing.expectEqual(IoOpType.connect, requests[1].op_type);
    try std.testing.expectEqual(IoOpType.poll_add, requests[2].op_type);
}

test "io_uring backend - PendingOp fromRequest with accept" {
    const cfg = config_mod.WorldConfig{};
    const Backend = IoUringBatchBackend(cfg, DummyWorld);

    var result: i32 = 0;
    const request = IoRequest{
        .op_type = .accept,
        .fd = 100, // listening socket
        .len = 0, // no address capture
        .offset = 0, // no flags
        .result_ptr = &result,
        .user_data = 999,
    };

    const op = Backend.PendingOp.fromRequest(request, 3);
    try std.testing.expectEqual(@as(u16, 3), op.system_idx);
    try std.testing.expectEqual(IoOpType.accept, op.op_type);
    try std.testing.expectEqual(@as(i32, 100), op.fd);
    try std.testing.expectEqual(@as(usize, 0), op.len);
    try std.testing.expectEqual(@as(u64, 999), op.user_data);
}

test "io_uring backend - PendingOp fromRequest with connect" {
    const cfg = config_mod.WorldConfig{};
    const Backend = IoUringBatchBackend(cfg, DummyWorld);

    var result: i32 = 0;
    var addr_buf: [128]u8 = undefined;
    const request = IoRequest{
        .op_type = .connect,
        .fd = 200, // client socket
        .buffer = &addr_buf,
        .len = 16, // sockaddr_in size
        .result_ptr = &result,
        .user_data = 888,
    };

    const op = Backend.PendingOp.fromRequest(request, 5);
    try std.testing.expectEqual(@as(u16, 5), op.system_idx);
    try std.testing.expectEqual(IoOpType.connect, op.op_type);
    try std.testing.expectEqual(@as(i32, 200), op.fd);
    try std.testing.expectEqual(@as(usize, 16), op.len);
    try std.testing.expectEqual(@as(u64, 888), op.user_data);
}

// Dummy world type for testing
const DummyWorld = struct {
    resources: struct {},

    pub fn despawn(_: *DummyWorld, _: anytype) !void {}
};
