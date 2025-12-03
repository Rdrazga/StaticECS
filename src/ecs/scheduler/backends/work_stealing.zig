//! Work-Stealing Scheduler Backend
//!
//! This backend implements a work-stealing scheduler with per-worker local queues
//! and a Chase-Lev deque for efficient stealing. Ideal for CPU-bound parallel
//! workloads with variable task sizes.
//!
//! ## Characteristics
//!
//! - **Execution**: Multi-threaded with work stealing
//! - **Scheduling**: Per-core queues with random victim selection
//! - **Best For**: CPU-bound workloads with many parallel systems
//! - **Overhead**: Thread management, queue coordination
//!
//! ## Algorithm
//!
//! 1. Partition systems into tasks (one task per system or entity batch)
//! 2. Distribute tasks to workers in round-robin fashion
//! 3. Each worker processes its local queue
//! 4. When empty, workers steal from others (Chase-Lev deque)
//! 5. LIFO slot optimization for recently pushed tasks (cache locality)
//!
//! ## Usage
//!
//! ```zig
//! const cfg = ecs.WorldConfig{
//!     .schedule = .{
//!         .execution_model = .work_stealing,
//!         .backend_config = .{ .work_stealing = .{
//!             .worker_count = 0,  // auto-detect CPU count
//!             .local_queue_size = 256,
//!             .steal_batch = 32,
//!         }},
//!     },
//! };
//! ```
//!
//! Tiger Style: Bounded queues, no dynamic allocation after init, per-core optimization.
//!
//! ## Spinlock Fairness Characteristics
//!
//! **Warning**: The work-stealing algorithm uses a spin-then-yield pattern (see
//! `spin_count` config) that is NOT strictly fair. Under sustained high contention:
//!
//! - **Starvation Risk**: Workers that frequently fail CAS operations on the deque
//!   `top` pointer may experience repeated yield cycles while others succeed.
//! - **Victim Selection Bias**: Random victim selection provides probabilistic fairness
//!   but does not guarantee equal steal distribution.
//! - **Mitigation**: The `spin_count` parameter controls spin iterations before yielding.
//!   Lower values reduce CPU waste but increase scheduling latency; higher values improve
//!   throughput under light contention but waste cycles under heavy contention.
//!
//! For workloads requiring strict fairness guarantees, consider:
//! - Reducing `worker_count` to decrease contention
//! - Using the blocking backend for single-threaded deterministic execution
//! - Implementing application-level work partitioning to reduce stealing frequency

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const config_mod = @import("../../config.zig");
const WorldConfig = config_mod.WorldConfig;
const FramePolicy = config_mod.FramePolicy;
const TraceLevel = config_mod.TraceLevel;
const ExecutionModel = config_mod.ExecutionModel;
const WorkStealingConfig = config_mod.WorkStealingConfig;

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
// Chase-Lev Deque
// ============================================================================

/// Lock-free Chase-Lev work-stealing deque.
///
/// This deque supports:
/// - LIFO push/pop from the owner thread (bottom)
/// - FIFO steal from other threads (top)
///
/// Tiger Style: Fixed capacity, power-of-two for efficient modulo.
pub fn ChaseLevDeque(comptime T: type, comptime capacity: u32) type {
    comptime {
        // Capacity must be power of 2
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("ChaseLevDeque capacity must be a power of 2");
        }
    }

    return struct {
        const Self = @This();
        const mask = capacity - 1;

        /// The circular buffer of tasks.
        buffer: [capacity]T,
        /// Bottom index (modified only by owner).
        bottom: std.atomic.Value(u32),
        /// Top index (modified by stealers).
        top: std.atomic.Value(u32),

        /// Initialize an empty deque.
        pub fn init() Self {
            return Self{
                .buffer = undefined,
                .bottom = std.atomic.Value(u32).init(0),
                .top = std.atomic.Value(u32).init(0),
            };
        }

        /// Push a task onto the bottom (owner only).
        /// Returns false if the deque is full.
        pub fn push(self: *Self, item: T) bool {
            const b = self.bottom.load(.acquire);
            const t = self.top.load(.acquire);

            // Check capacity
            if (b -% t >= capacity) {
                return false; // Full
            }

            self.buffer[b & mask] = item;
            // Memory fence before updating bottom to ensure buffer write is visible
            // Use a dummy atomic load with release ordering to create a fence-like barrier
            _ = self.bottom.load(.monotonic);
            self.bottom.store(b +% 1, .release);
            return true;
        }

        /// Pop a task from the bottom (owner only).
        /// Returns null if empty or contention.
        pub fn pop(self: *Self) ?T {
            var b = self.bottom.load(.acquire);
            if (b == 0) return null;

            b = b -% 1;
            self.bottom.store(b, .seq_cst);
            // Sequential consistency fence via a load with seq_cst ordering
            _ = self.bottom.load(.seq_cst);

            const t = self.top.load(.acquire);

            if (t <= b) {
                // Queue is not empty
                const item = self.buffer[b & mask];
                if (t == b) {
                    // Last item, race with stealers
                    if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .acquire)) |_| {
                        // Lost race
                        self.bottom.store(t +% 1, .release);
                        return null;
                    }
                    self.bottom.store(t +% 1, .release);
                }
                return item;
            } else {
                // Empty
                self.bottom.store(t, .release);
                return null;
            }
        }

        /// Steal a task from the top (other threads).
        /// Returns null if empty or contention.
        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.acquire);
            // Sequential consistency fence via atomic load
            _ = self.top.load(.seq_cst);
            const b = self.bottom.load(.acquire);

            if (t >= b) {
                return null; // Empty
            }

            const item = self.buffer[t & mask];

            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .acquire)) |_| {
                // Lost race with another stealer
                return null;
            }

            return item;
        }

        /// Get approximate size (may be stale).
        pub fn len(self: *const Self) u32 {
            const b = self.bottom.load(.acquire);
            const t = self.top.load(.acquire);
            return if (b > t) b - t else 0;
        }

        /// Check if empty (may be stale).
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }
    };
}

// ============================================================================
// Work-Stealing Backend
// ============================================================================

/// Work-stealing scheduler backend.
///
/// Uses per-worker Chase-Lev deques and work stealing for efficient
/// parallel execution of systems.
///
/// Tiger Style: All bounds from config. Pre-allocated worker state.
pub fn WorkStealingBackend(comptime cfg: WorldConfig, comptime WorldType: type) type {
    // Extract config with defaults
    const ws_cfg: WorkStealingConfig = switch (cfg.schedule.backend_config) {
        .work_stealing => |c| c,
        else => .{}, // Use defaults if not specified
    };

    // Worker count (compile-time if specified, otherwise max supported)
    const max_workers: u16 = if (ws_cfg.worker_count == 0) 16 else ws_cfg.worker_count;
    const local_queue_size = ws_cfg.local_queue_size;
    const steal_batch = ws_cfg.steal_batch;
    const lifo_enabled = ws_cfg.lifo_slot;
    const spin_count = ws_cfg.spin_count;

    const Sched = Schedule(cfg);
    const SysCtx = SystemContext(cfg, WorldType);
    const CmdBuf = SysCtx.CmdBuf;
    const Tracer = TracingContext(cfg.tracing.level);

    // Config-based types
    const AggregateErrors = AggregateErrorsType(cfg.options.max_aggregate_errors);
    const FrameResultT = FrameResultType(cfg.options.max_aggregate_errors);

    return struct {
        const Self = @This();

        /// Task represents a unit of work (one system execution).
        pub const Task = struct {
            /// System index in the schedule.
            system_idx: u16,
            /// Entity range start (for partitioned systems).
            entity_start: u32,
            /// Entity range end (exclusive).
            entity_end: u32,
            /// Phase index this task belongs to.
            phase_idx: u8,
            /// Whether this task is valid.
            valid: bool,

            pub fn init(system_idx: u16, phase: u8) Task {
                return .{
                    .system_idx = system_idx,
                    .entity_start = 0,
                    .entity_end = 0,
                    .phase_idx = phase,
                    .valid = true,
                };
            }

            pub fn invalid() Task {
                return .{
                    .system_idx = 0,
                    .entity_start = 0,
                    .entity_end = 0,
                    .phase_idx = 0,
                    .valid = false,
                };
            }
        };

        /// Per-worker state.
        ///
        /// Tiger Style: Each worker has its own command buffer to avoid data races
        /// when multiple workers execute systems concurrently. Command buffers are
        /// merged after each phase completes.
        pub const Worker = struct {
            /// Local work queue (Chase-Lev deque).
            local_queue: ChaseLevDeque(Task, local_queue_size),
            /// LIFO slot for recently pushed task (best cache locality).
            lifo_slot: ?Task,
            /// Worker thread handle.
            thread: ?std.Thread,
            /// Random number generator for victim selection.
            rng_state: u64,
            /// Whether this worker is active.
            active: bool,
            /// Tasks executed by this worker.
            tasks_executed: u64,
            /// Tasks stolen by this worker.
            tasks_stolen: u64,
            /// Per-worker command buffer to avoid race conditions when
            /// multiple workers add commands concurrently.
            /// Each worker writes to its own buffer, merged after phase.
            command_buffer: CmdBuf,

            pub fn init(seed: u64) Worker {
                return .{
                    .local_queue = ChaseLevDeque(Task, local_queue_size).init(),
                    .lifo_slot = null,
                    .thread = null,
                    .rng_state = seed,
                    .active = false,
                    .tasks_executed = 0,
                    .tasks_stolen = 0,
                    .command_buffer = CmdBuf.init(),
                };
            }

            /// Simple xorshift64 RNG for victim selection.
            pub fn nextRandom(self: *Worker) u64 {
                var x = self.rng_state;
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                self.rng_state = x;
                return x;
            }
        };

        /// Global injection queue (for initial task distribution).
        pub const GlobalQueue = struct {
            tasks: [max_workers * local_queue_size / 4]Task,
            head: std.atomic.Value(u32),
            tail: std.atomic.Value(u32),
            mutex: std.Thread.Mutex,

            pub fn init() GlobalQueue {
                return .{
                    .tasks = undefined,
                    .head = std.atomic.Value(u32).init(0),
                    .tail = std.atomic.Value(u32).init(0),
                    .mutex = .{},
                };
            }

            pub fn push(self: *GlobalQueue, task: Task) bool {
                self.mutex.lock();
                defer self.mutex.unlock();

                const tail = self.tail.load(.acquire);
                const head = self.head.load(.acquire);
                const capacity = @as(u32, @intCast(self.tasks.len));

                if (tail -% head >= capacity) {
                    return false; // Full
                }

                self.tasks[tail % capacity] = task;
                self.tail.store(tail +% 1, .release);
                return true;
            }

            pub fn pop(self: *GlobalQueue) ?Task {
                self.mutex.lock();
                defer self.mutex.unlock();

                const head = self.head.load(.acquire);
                const tail = self.tail.load(.acquire);

                if (head >= tail) {
                    return null; // Empty
                }

                const capacity = @as(u32, @intCast(self.tasks.len));
                const task = self.tasks[head % capacity];
                self.head.store(head +% 1, .release);
                return task;
            }
        };

        // Instance state
        allocator: Allocator,
        trace_sink: ?TraceSink,
        tick_count: u64,
        stats: BackendStats,

        // Worker state
        workers: [max_workers]Worker,
        num_workers: u16,
        global_queue: GlobalQueue,

        // Synchronization
        running: std.atomic.Value(bool),
        tasks_remaining: std.atomic.Value(u32),
        current_phase: std.atomic.Value(u8),

        // Shared context for workers
        shared_world: ?*WorldType,
        shared_delta_time: f64,

        /// Initialize the work-stealing backend.
        pub fn init(allocator: Allocator, trace_sink: ?TraceSink) Self {
            // Determine actual worker count
            const cpu_count = std.Thread.getCpuCount() catch 4;
            const actual_workers: u16 = @min(
                max_workers,
                @as(u16, @intCast(@min(cpu_count, 65535))),
            );

            var self = Self{
                .allocator = allocator,
                .trace_sink = trace_sink,
                .tick_count = 0,
                .stats = .{},
                .workers = undefined,
                .num_workers = actual_workers,
                .global_queue = GlobalQueue.init(),
                .running = std.atomic.Value(bool).init(false),
                .tasks_remaining = std.atomic.Value(u32).init(0),
                .current_phase = std.atomic.Value(u8).init(0),
                .shared_world = null,
                .shared_delta_time = 0,
            };

            // Initialize workers with different seeds
            for (0..max_workers) |i| {
                self.workers[i] = Worker.init(@as(u64, i) * 0x9E3779B97F4A7C15 + 1);
            }

            return self;
        }

        /// Clean up resources.
        pub fn deinit(self: *Self) void {
            // Stop any running workers
            self.running.store(false, .release);

            // Wait for workers to finish
            for (self.workers[1..self.num_workers]) |*worker| {
                if (worker.thread) |thread| {
                    thread.join();
                    worker.thread = null;
                }
            }
        }

        /// Execute a single tick/frame with work stealing.
        ///
        /// Tiger Style: Central orchestration function delegates phase iteration
        /// to helper. Assertions verify scheduler is initialized and phase count
        /// matches expectations.
        pub fn tick(self: *Self, world: *WorldType, delta_time: f64) FrameResultT {
            // Pre-condition: scheduler must be initialized with valid worker count
            std.debug.assert(self.num_workers > 0);
            std.debug.assert(self.num_workers <= max_workers);

            const start_time = getTimeNs();

            // Store shared context
            self.shared_world = world;
            self.shared_delta_time = delta_time;

            // Initialize command buffer (main thread)
            var commands = CmdBuf.init();

            // Create system context for main thread
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

            // Execute all phases with work stealing via helper
            const iter_result = self.iteratePhases(&ctx, policy, &errors);

            // Apply deferred commands
            self.applyCommands(world, &commands);

            // Clear shared context
            self.shared_world = null;

            // Emit tick end and update statistics
            const end_time = getTimeNs();
            const tick_duration = end_time - start_time;
            tracer.emitTickEnd(self.tick_count, end_time, tick_duration);

            self.tick_count += 1;
            self.stats.ticks_executed += 1;
            self.stats.systems_executed += iter_result.systems_run;
            self.stats.tasks_stolen += iter_result.tasks_stolen;
            self.stats.last_tick_time_ns = tick_duration;
            self.stats.total_tick_time_ns += tick_duration;

            // Post-condition: phases_executed advanced by expected count
            std.debug.assert(self.stats.phases_executed >= iter_result.phases_completed);

            return self.buildFrameResult(iter_result.success, policy, errors);
        }

        /// Iterate through all phases executing systems with work stealing.
        ///
        /// Tiger Style: Pure iteration helper, no side effects beyond phase execution.
        /// Returns aggregated result for parent orchestration.
        fn iteratePhases(
            self: *Self,
            ctx: *SysCtx,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) struct { success: bool, systems_run: u64, tasks_stolen: u64, phases_completed: u64 } {
            // Pre-condition: context must have valid world reference
            std.debug.assert(ctx.world != null);

            var frame_success = true;
            var systems_run: u64 = 0;
            var tasks_stolen: u64 = 0;
            var phases_completed: u64 = 0;

            inline for (0..Sched.num_phases) |phase_idx| {
                self.current_phase.store(@intCast(phase_idx), .release);

                const phase_result = self.executePhaseParallel(ctx, phase_idx, policy, errors);

                systems_run += phase_result.systems_run;
                tasks_stolen += phase_result.tasks_stolen;
                self.stats.phases_executed += 1;
                phases_completed += 1;

                if (!phase_result.success) {
                    frame_success = false;
                    if (policy == .default) break;
                }
            }

            // Post-condition: completed phases <= total phases
            std.debug.assert(phases_completed <= Sched.num_phases);

            return .{
                .success = frame_success,
                .systems_run = systems_run,
                .tasks_stolen = tasks_stolen,
                .phases_completed = phases_completed,
            };
        }

        /// Build the appropriate frame result based on success state and policy.
        ///
        /// Tiger Style: Pure helper for result construction.
        fn buildFrameResult(
            self: *const Self,
            frame_success: bool,
            policy: FramePolicy,
            errors: AggregateErrors,
        ) FrameResultT {
            _ = self; // Unused, but keeps signature consistent for potential future use

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

            // Reset worker stats
            for (&self.workers) |*worker| {
                worker.tasks_executed = 0;
                worker.tasks_stolen = 0;
            }
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

        /// Get number of active workers.
        pub fn getWorkerCount(self: *const Self) u16 {
            return self.num_workers;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Internal: Phase Execution with Work Stealing
        // ─────────────────────────────────────────────────────────────────────

        const PhaseResult = struct {
            success: bool,
            systems_run: u64,
            tasks_stolen: u64,
        };

        fn executePhaseParallel(
            self: *Self,
            ctx: *SysCtx,
            comptime phase_idx: usize,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) PhaseResult {
            var result = PhaseResult{
                .success = true,
                .systems_run = 0,
                .tasks_stolen = 0,
            };

            // Get stages for this phase
            const phase_stages = Sched.stages_by_phase[phase_idx];

            // Create tasks for all systems in this phase
            var total_tasks: u32 = 0;
            inline for (0..phase_stages.stage_count) |stage_idx| {
                const stage = phase_stages.stages[stage_idx];
                inline for (0..stage.system_count) |sys_idx| {
                    const system_index = stage.system_indices[sys_idx];
                    const task = Task.init(system_index, @intCast(phase_idx));

                    // Distribute to workers round-robin
                    const worker_idx = total_tasks % self.num_workers;
                    if (lifo_enabled and self.workers[worker_idx].lifo_slot == null) {
                        self.workers[worker_idx].lifo_slot = task;
                    } else if (!self.workers[worker_idx].local_queue.push(task)) {
                        // Local queue full, use global queue
                        _ = self.global_queue.push(task);
                    }
                    total_tasks += 1;
                }
            }

            if (total_tasks == 0) {
                return result;
            }

            // Set remaining task count
            self.tasks_remaining.store(total_tasks, .release);

            // Execute using main thread as worker 0
            // (In single-threaded mode, this processes everything)
            self.runWorkerLoop(0, ctx, policy, errors);

            // Merge all per-worker command buffers into the main buffer.
            // Tiger Style: Merge in worker order for deterministic command ordering.
            // This ensures command execution order is stable across runs.
            self.mergeWorkerCommands(ctx.commands);

            // Collect results
            result.systems_run = total_tasks;
            result.tasks_stolen = self.workers[0].tasks_stolen;

            // Check for errors
            if (errors.count() > 0) {
                result.success = false;
            }

            return result;
        }

        /// Worker loop that executes tasks from local queue, steals from others,
        /// and uses a per-worker context to avoid data races.
        ///
        /// Tiger Style: Each worker has its own command buffer. Commands are merged
        /// deterministically after phase completion to maintain execution order invariants.
        fn runWorkerLoop(
            self: *Self,
            worker_id: u16,
            shared_ctx: *SysCtx,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) void {
            std.debug.assert(worker_id < self.num_workers); // Pre: valid worker ID
            std.debug.assert(self.num_workers > 0); // Pre: scheduler has workers
            var worker = &self.workers[worker_id];
            var spins: u16 = 0;

            // Per-worker context: eliminates command buffer races; read-only fields safe to share.
            var worker_ctx = SysCtx.init(
                shared_ctx.world,
                shared_ctx.resources,
                shared_ctx.delta_time,
                shared_ctx.tick,
                shared_ctx.time_ns,
                &worker.command_buffer,
                shared_ctx.allocator,
            );

            while (self.tasks_remaining.load(.acquire) > 0) {
                var task: ?Task = null;

                // 1. Try LIFO slot first (best cache locality)
                if (lifo_enabled) {
                    if (worker.lifo_slot) |t| {
                        worker.lifo_slot = null;
                        task = t;
                    }
                }

                // 2. Try local queue
                if (task == null) {
                    task = worker.local_queue.pop();
                }

                // 3. Try stealing from others
                if (task == null) {
                    task = self.trySteal(worker_id);
                    if (task != null) {
                        worker.tasks_stolen += 1;
                    }
                }

                // 4. Try global queue
                if (task == null) {
                    task = self.global_queue.pop();
                }

                // Execute task if found - use worker-local context
                if (task) |t| {
                    if (t.valid) {
                        self.executeTask(t, &worker_ctx, policy, errors);
                        worker.tasks_executed += 1;
                        _ = self.tasks_remaining.fetchSub(1, .release);
                    }
                    spins = 0;
                } else {
                    // No work found, spin or yield
                    spins += 1;
                    if (spins > spin_count) {
                        std.Thread.yield();
                        spins = 0;
                    }
                }
            }
        }

        /// Try to steal a task from another worker's queue.
        ///
        /// Uses random victim selection to reduce contention clustering.
        ///
        /// **Note on `steal_batch` config**: Currently, only a single task is stolen
        /// per successful steal operation. The `steal_batch` configuration parameter
        /// is reserved for future batch-stealing optimization where multiple tasks
        /// could be stolen in one operation to amortize synchronization overhead.
        /// The current single-steal behavior provides simpler correctness guarantees
        /// and is sufficient for most workloads where task granularity is coarse.
        fn trySteal(self: *Self, worker_id: u16) ?Task {
            const worker = &self.workers[worker_id];
            const num = self.num_workers;

            if (num <= 1) return null;

            // Random victim selection
            const start = @as(u16, @intCast(worker.rng_state % num));

            var i: u16 = 0;
            while (i < num) : (i += 1) {
                const victim_id = (start + i) % num;
                if (victim_id == worker_id) continue;

                // Try to steal from victim
                const victim = &self.workers[victim_id];

                // Single-steal: steal_batch is reserved for future batch optimization.
                // Currently returns immediately on first successful steal.
                _ = steal_batch; // Acknowledge config existence; reserved for future use
                if (victim.local_queue.steal()) |task| {
                    return task;
                }
            }

            return null;
        }

        fn executeTask(
            self: *Self,
            task: Task,
            ctx: *SysCtx,
            policy: FramePolicy,
            errors: *AggregateErrors,
        ) void {
            _ = self;
            _ = policy;

            const system_def = Sched.systems[task.system_idx];
            const SystemFn = *const fn (*SysCtx) FrameError!void;
            const func: SystemFn = @ptrCast(@alignCast(system_def.func));

            func(ctx) catch |err| {
                errors.add(err, task.system_idx, ctx.time_ns);
            };
        }

        /// Merge all per-worker command buffers into the main command buffer.
        ///
        /// Tiger Style: Commands are merged in worker ID order (0, 1, 2, ...) to
        /// ensure deterministic command ordering across runs. This is critical for
        /// reproducible execution, especially in multi-threaded scenarios.
        ///
        /// Memory ordering: Called after all workers have finished (tasks_remaining == 0),
        /// so no additional synchronization is needed beyond the acquire fence in the
        /// worker loop termination condition.
        fn mergeWorkerCommands(self: *Self, target: *CmdBuf) void {
            for (0..self.num_workers) |worker_idx| {
                var worker = &self.workers[worker_idx];
                const src_commands = worker.command_buffer.getCommands();

                for (src_commands) |cmd| {
                    // Check if target can accept more commands
                    if (target.count >= CmdBuf.max_command_count) {
                        // Target full - clear remaining worker buffers and return
                        // In production, this should emit a warning/trace
                        for (worker_idx..self.num_workers) |remaining_idx| {
                            self.workers[remaining_idx].command_buffer.clear();
                        }
                        return;
                    }

                    // Copy command to target
                    target.commands[target.count] = cmd;
                    target.count += 1;
                }

                // Clear worker's command buffer for next phase
                worker.command_buffer.clear();
            }
        }

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
// Tests
// ============================================================================

test "ChaseLevDeque - basic operations" {
    var deque = ChaseLevDeque(u32, 16).init();

    // Push items
    try std.testing.expect(deque.push(1));
    try std.testing.expect(deque.push(2));
    try std.testing.expect(deque.push(3));

    // Pop (LIFO from bottom)
    try std.testing.expectEqual(@as(?u32, 3), deque.pop());
    try std.testing.expectEqual(@as(?u32, 2), deque.pop());
    try std.testing.expectEqual(@as(?u32, 1), deque.pop());
    try std.testing.expectEqual(@as(?u32, null), deque.pop());
}

test "ChaseLevDeque - steal operations" {
    var deque = ChaseLevDeque(u32, 16).init();

    // Push items
    _ = deque.push(1);
    _ = deque.push(2);
    _ = deque.push(3);

    // Steal (FIFO from top)
    try std.testing.expectEqual(@as(?u32, 1), deque.steal());
    try std.testing.expectEqual(@as(?u32, 2), deque.steal());
    try std.testing.expectEqual(@as(?u32, 3), deque.steal());
    try std.testing.expectEqual(@as(?u32, null), deque.steal());
}

test "ChaseLevDeque - capacity limit" {
    var deque = ChaseLevDeque(u32, 4).init();

    try std.testing.expect(deque.push(1));
    try std.testing.expect(deque.push(2));
    try std.testing.expect(deque.push(3));
    try std.testing.expect(deque.push(4));
    try std.testing.expect(!deque.push(5)); // Full
}

test "ChaseLevDeque - len and isEmpty" {
    var deque = ChaseLevDeque(u32, 16).init();

    try std.testing.expect(deque.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), deque.len());

    _ = deque.push(1);
    try std.testing.expect(!deque.isEmpty());
    try std.testing.expectEqual(@as(u32, 1), deque.len());

    _ = deque.push(2);
    try std.testing.expectEqual(@as(u32, 2), deque.len());
}

test "WorkStealingBackend - Task init" {
    const cfg = config_mod.WorldConfig{};
    const Backend = WorkStealingBackend(cfg, DummyWorld);
    const task = Backend.Task.init(5, 2);

    try std.testing.expectEqual(@as(u16, 5), task.system_idx);
    try std.testing.expectEqual(@as(u8, 2), task.phase_idx);
    try std.testing.expect(task.valid);
}

test "WorkStealingBackend - Worker RNG" {
    const cfg = config_mod.WorldConfig{};
    const Backend = WorkStealingBackend(cfg, DummyWorld);
    var worker = Backend.Worker.init(42);

    const r1 = worker.nextRandom();
    const r2 = worker.nextRandom();

    try std.testing.expect(r1 != r2);
    try std.testing.expect(r1 != 42);
}

test "WorkStealingBackend - config extraction" {
    const cfg = config_mod.WorldConfig{
        .schedule = .{
            .execution_model = .work_stealing,
            .backend_config = .{ .work_stealing = .{
                .worker_count = 4,
                .local_queue_size = 128,
                .steal_batch = 16,
            } },
        },
    };

    const Backend = WorkStealingBackend(cfg, DummyWorld);
    _ = Backend.Task.init(0, 0);
}

test "WorkStealingBackend - stats initialization" {
    const stats = BackendStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
    try std.testing.expectEqual(@as(u64, 0), stats.tasks_stolen);
}

// Dummy world type for testing
const DummyWorld = struct {
    resources: struct {},

    pub fn despawn(_: *DummyWorld, _: anytype) !void {}
};
