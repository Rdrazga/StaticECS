//! Custom Executor Integration
//!
//! Provides interfaces for integrating external processing units with the ECS
//! pipeline. This includes GPU compute, SIMD worker pools, and external thread
//! pools.
//!
//! ## Features
//!
//! - **GPU Compute Interface**: Placeholder for GPU compute dispatch
//! - **SIMD Worker Pool Interface**: High-throughput data-parallel processing
//! - **External Thread Pool**: Integration with external threading libraries
//!
//! Tiger Style: All interfaces are comptime-configurable.
//! Unused interfaces compile to nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;

// ============================================================================
// Executor Types
// ============================================================================

/// Type of external executor.
pub const ExecutorType = enum {
    /// CPU-based executor (default).
    cpu,
    /// GPU compute executor.
    gpu,
    /// SIMD-optimized executor.
    simd,
    /// External thread pool executor.
    thread_pool,
};

/// Executor status for monitoring.
pub const ExecutorStatus = enum {
    /// Executor is idle, ready for work.
    idle,
    /// Executor is currently processing.
    busy,
    /// Executor has encountered an error.
    error_state,
    /// Executor is not available on this platform.
    unavailable,
};

// ============================================================================
// GPU Compute Interface (Placeholder)
// ============================================================================

/// GPU compute executor configuration.
///
/// **EXPERIMENTAL**: Placeholder - not yet implemented.
///
/// Status: All operations return `error.GpuUnavailable`.
/// This configuration struct exists to preserve the API design
/// for future GPU compute integration.
///
/// Future plans:
/// - SPIR-V compute shader generation
/// - Vulkan/Metal backend support
/// - Automatic CPU fallback for unsupported hardware
///
/// See: [`docs/EXPERIMENTAL.md`](../../../docs/EXPERIMENTAL.md) for status tracking.
pub const GpuComputeConfig = struct {
    /// GPU device index to use (0 = default).
    device_index: u32 = 0,
    /// Maximum work groups to dispatch.
    max_work_groups: u32 = 256,
    /// Work group size (threads per group).
    work_group_size: u32 = 64,
    /// Enable GPU-CPU memory sharing.
    shared_memory: bool = false,
};

/// **EXPERIMENTAL**: GPU compute executor.
///
/// Status: Placeholder - not yet implemented.
/// Currently returns `error.GpuUnavailable` for all operations.
///
/// This executor interface is designed for future GPU compute dispatch
/// but has no functional implementation. All methods immediately fail.
///
/// Future plans:
/// - SPIR-V compute shader generation from component queries
/// - Vulkan/Metal/WebGPU backend support
/// - Automatic CPU fallback for unsupported hardware
/// - GPU↔CPU memory transfer optimization
///
/// What doesn't work:
/// - `init()` - Always returns `error.GpuUnavailable`
/// - `dispatch()` - Always returns `error.GpuUnavailable`
/// - `sync()` - Always returns `error.GpuUnavailable`
///
/// See: [`docs/EXPERIMENTAL.md`](../../../docs/EXPERIMENTAL.md) for status tracking.
pub fn GpuComputeExecutor(comptime cfg: WorldConfig) type {
    return struct {
        const Self = @This();

        config: GpuComputeConfig,
        status: ExecutorStatus,

        /// Initialize GPU compute executor.
        /// Returns error if GPU is not available.
        pub fn init(gpu_config: GpuComputeConfig) error{GpuUnavailable}!Self {
            _ = cfg;
            // Placeholder: GPU not yet implemented
            _ = gpu_config;
            return error.GpuUnavailable;
        }

        /// Dispatch compute work to GPU.
        pub fn dispatch(self: *Self, comptime KernelFn: type, data: anytype) !void {
            _ = self;
            _ = KernelFn;
            _ = data;
            return error.GpuUnavailable;
        }

        /// Wait for GPU computation to complete.
        pub fn sync(self: *Self) !void {
            _ = self;
            return error.GpuUnavailable;
        }

        /// Get current executor status.
        pub fn getStatus(self: *const Self) ExecutorStatus {
            return self.status;
        }

        /// Deinitialize GPU resources.
        pub fn deinit(self: *Self) void {
            _ = self;
        }
    };
}

// ============================================================================
// Batch Worker Pool Interface
// ============================================================================

/// **EXPERIMENTAL**: Batch worker pool configuration.
///
/// Configures batch processing of entity arrays. Provides cache-friendly
/// sequential access patterns but does NOT use hardware SIMD intrinsics.
///
/// See: [`docs/EXPERIMENTAL.md`](../../../docs/EXPERIMENTAL.md) for status tracking.
pub const BatchWorkerConfig = struct {
    /// Number of worker threads.
    worker_count: u32 = 0, // 0 = auto-detect
    /// Vector width hint (reserved for future SIMD - currently unused).
    vector_width: u32 = 0,
    /// Chunk size for work distribution.
    chunk_size: u32 = 1024,
    /// Enable prefetching.
    prefetch: bool = true,
};

/// @deprecated Use `BatchWorkerConfig` instead. Renamed for accuracy.
pub const SimdWorkerConfig = BatchWorkerConfig;

/// **EXPERIMENTAL**: Batch worker pool for parallel entity processing.
///
/// Processes entities in batches across threads but does NOT use hardware
/// SIMD intrinsics. For true SIMD, implement custom processing with @Vector types.
///
/// What works:
/// - `processArray()` - Processes arrays sequentially per batch
/// - `processArrays()` - Processes paired arrays sequentially
/// - `reduce()` - Performs reduction sequentially
/// - Statistics tracking (items/batches processed)
///
/// Benefits of batch processing (without SIMD):
/// - Sequential memory access for CPU prefetching
/// - Reduced function call overhead via batching
/// - Cache-line friendly access patterns
///
/// What doesn't work:
/// - No actual SIMD intrinsics (`@Vector`) are used
/// - No architecture-specific optimizations (SSE, AVX, NEON)
/// - Performance is identical to scalar processing
///
/// Future plans:
/// - `@Vector(N, T)` batch operations for numeric types
/// - CPU feature detection (SSE4.2, AVX2, NEON)
/// - Fallback to scalar for non-vectorizable types
///
/// See: [`docs/EXPERIMENTAL.md`](../../../docs/EXPERIMENTAL.md) for status tracking.
pub fn BatchWorkerPool(comptime cfg: WorldConfig) type {
    return struct {
        const Self = @This();

        config: BatchWorkerConfig,
        status: ExecutorStatus,
        allocator: Allocator,

        // Statistics
        items_processed: u64,
        batches_processed: u64,

        /// Initialize batch worker pool.
        pub fn init(allocator: Allocator, batch_config: BatchWorkerConfig) !Self {
            _ = cfg;
            return .{
                .config = batch_config,
                .status = .idle,
                .allocator = allocator,
                .items_processed = 0,
                .batches_processed = 0,
            };
        }

        /// Process array with batch-optimized function.
        ///
        /// Processes each element sequentially. Future versions may use SIMD.
        pub fn processArray(
            self: *Self,
            comptime T: type,
            data: []T,
            comptime ProcessFn: fn (*T) void,
        ) void {
            self.status = .busy;
            defer self.status = .idle;

            // Sequential implementation - batch processing pattern
            // Future: consider @Vector for numeric types
            for (data) |*item| {
                ProcessFn(item);
            }

            self.items_processed += data.len;
            self.batches_processed += 1;
        }

        /// Process two arrays with batch-optimized function.
        pub fn processArrays(
            self: *Self,
            comptime T1: type,
            comptime T2: type,
            data1: []T1,
            data2: []T2,
            comptime ProcessFn: fn (*T1, *T2) void,
        ) void {
            self.status = .busy;
            defer self.status = .idle;

            const len = @min(data1.len, data2.len);
            for (0..len) |i| {
                ProcessFn(&data1[i], &data2[i]);
            }

            self.items_processed += len;
            self.batches_processed += 1;
        }

        /// Apply reduction across array.
        pub fn reduce(
            self: *Self,
            comptime T: type,
            comptime R: type,
            data: []const T,
            initial: R,
            comptime ReduceFn: fn (R, T) R,
        ) R {
            self.status = .busy;
            defer self.status = .idle;

            var result = initial;
            for (data) |item| {
                result = ReduceFn(result, item);
            }

            self.items_processed += data.len;
            self.batches_processed += 1;
            return result;
        }

        /// Get executor status.
        pub fn getStatus(self: *const Self) ExecutorStatus {
            return self.status;
        }

        /// Get processing statistics.
        pub fn getStats(self: *const Self) struct {
            items_processed: u64,
            batches_processed: u64,
        } {
            return .{
                .items_processed = self.items_processed,
                .batches_processed = self.batches_processed,
            };
        }

        /// Reset statistics.
        pub fn resetStats(self: *Self) void {
            self.items_processed = 0;
            self.batches_processed = 0;
        }

        /// Deinitialize worker pool.
        pub fn deinit(self: *Self) void {
            _ = self;
        }
    };
}

/// @deprecated Use `BatchWorkerPool` instead. Renamed for accuracy -
/// no SIMD intrinsics are used.
pub const SimdWorkerPool = BatchWorkerPool;

// ============================================================================
// External Thread Pool Interface
// ============================================================================

/// **EXPERIMENTAL**: External thread pool configuration.
///
/// Status: Incomplete - configuration only, no functional dispatch.
///
/// This configuration is used by `ExternalThreadPool` which does not
/// actually dispatch tasks to threads. See pool documentation for details.
///
/// See: [`docs/EXPERIMENTAL.md`](../../../docs/EXPERIMENTAL.md) for status tracking.
pub const ExternalThreadPoolConfig = struct {
    /// Maximum concurrent tasks.
    max_tasks: u32 = 64,
    /// Task queue depth.
    queue_depth: u32 = 256,
    /// Priority levels supported.
    priority_levels: u8 = 3,
};

/// Task handle for tracking submitted work.
pub const TaskHandle = struct {
    id: u64,
    status: TaskStatus,
};

/// Task status.
pub const TaskStatus = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

/// **EXPERIMENTAL**: External thread pool executor.
///
/// Status: Incomplete - task submission does not dispatch.
/// Thread spawning structure exists but work items are never executed.
///
/// This interface is designed for integrating with external thread pools
/// (OS thread pools, libuv, game engine job systems, etc.) but has no
/// functional implementation.
///
/// What works:
/// - `init()` - Creates pool structure
/// - `submitTask()` - Creates `TaskHandle` with incrementing ID
/// - `getTaskStatus()` - Returns handle's status field
/// - `getStatus()` - Returns executor status
///
/// What doesn't work:
/// - Submitted tasks are never executed
/// - `waitTask()` is a no-op (returns immediately)
/// - `cancelTask()` is a no-op
/// - No actual thread management occurs
///
/// Future plans:
/// - OS thread pool backends (Windows ThreadPool, GCD, etc.)
/// - Integration with external libraries (libuv, tokio FFI)
/// - Work-stealing coordination with internal scheduler
///
/// See: [`docs/EXPERIMENTAL.md`](../../../docs/EXPERIMENTAL.md) for status tracking.
pub fn ExternalThreadPool(comptime cfg: WorldConfig) type {
    return struct {
        const Self = @This();

        config: ExternalThreadPoolConfig,
        status: ExecutorStatus,
        next_task_id: u64,

        /// Initialize external thread pool interface.
        pub fn init(pool_config: ExternalThreadPoolConfig) Self {
            _ = cfg;
            return .{
                .config = pool_config,
                .status = .idle,
                .next_task_id = 0,
            };
        }

        /// Submit task to external pool.
        pub fn submitTask(
            self: *Self,
            comptime TaskFn: type,
            args: anytype,
        ) !TaskHandle {
            _ = TaskFn;
            _ = args;

            const handle = TaskHandle{
                .id = self.next_task_id,
                .status = .pending,
            };
            self.next_task_id += 1;

            // Placeholder: actual submission would go to external pool
            return handle;
        }

        /// Wait for task completion.
        pub fn waitTask(self: *Self, handle: TaskHandle) !void {
            _ = self;
            _ = handle;
            // Placeholder: would wait on actual task
        }

        /// Cancel pending task.
        pub fn cancelTask(self: *Self, handle: TaskHandle) !void {
            _ = self;
            _ = handle;
            // Placeholder: would cancel actual task
        }

        /// Get task status.
        pub fn getTaskStatus(self: *const Self, handle: TaskHandle) TaskStatus {
            _ = self;
            return handle.status;
        }

        /// Get executor status.
        pub fn getStatus(self: *const Self) ExecutorStatus {
            return self.status;
        }

        /// Deinitialize thread pool interface.
        pub fn deinit(self: *Self) void {
            _ = self;
        }
    };
}

// ============================================================================
// Executor Selection Helper
// ============================================================================

/// Select appropriate executor based on configuration.
pub fn selectExecutor(comptime cfg: WorldConfig, comptime executor_type: ExecutorType) type {
    return switch (executor_type) {
        .cpu => void, // Use standard ECS scheduler
        .gpu => GpuComputeExecutor(cfg),
        .simd => BatchWorkerPool(cfg), // Note: despite enum name, uses batch processing not SIMD
        .thread_pool => ExternalThreadPool(cfg),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ExecutorType enum" {
    try std.testing.expect(@intFromEnum(ExecutorType.cpu) != @intFromEnum(ExecutorType.gpu));
    try std.testing.expect(@intFromEnum(ExecutorType.simd) != @intFromEnum(ExecutorType.thread_pool));
}

test "ExecutorStatus enum" {
    try std.testing.expect(@intFromEnum(ExecutorStatus.idle) != @intFromEnum(ExecutorStatus.busy));
    try std.testing.expect(@intFromEnum(ExecutorStatus.error_state) != @intFromEnum(ExecutorStatus.unavailable));
}

test "GpuComputeConfig defaults" {
    const config = GpuComputeConfig{};
    try std.testing.expectEqual(@as(u32, 0), config.device_index);
    try std.testing.expectEqual(@as(u32, 256), config.max_work_groups);
    try std.testing.expectEqual(@as(u32, 64), config.work_group_size);
    try std.testing.expectEqual(false, config.shared_memory);
}

test "BatchWorkerConfig defaults" {
    const config = BatchWorkerConfig{};
    try std.testing.expectEqual(@as(u32, 0), config.worker_count);
    try std.testing.expectEqual(@as(u32, 0), config.vector_width);
    try std.testing.expectEqual(@as(u32, 1024), config.chunk_size);
    try std.testing.expectEqual(true, config.prefetch);
}

test "BatchWorkerPool basic operations" {
    const test_config = WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
    };

    const Pool = BatchWorkerPool(test_config);
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();

    // Process array
    var data = [_]i32{ 1, 2, 3, 4, 5 };
    const double = struct {
        fn f(x: *i32) void {
            x.* *= 2;
        }
    }.f;

    pool.processArray(i32, &data, double);

    try std.testing.expectEqual(@as(i32, 2), data[0]);
    try std.testing.expectEqual(@as(i32, 4), data[1]);
    try std.testing.expectEqual(@as(i32, 10), data[4]);

    // Check stats
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u64, 5), stats.items_processed);
    try std.testing.expectEqual(@as(u64, 1), stats.batches_processed);
}

test "BatchWorkerPool reduce" {
    const test_config = WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
    };

    const Pool = BatchWorkerPool(test_config);
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();

    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const sum = struct {
        fn f(acc: i32, x: i32) i32 {
            return acc + x;
        }
    }.f;

    const result = pool.reduce(i32, i32, &data, 0, sum);
    try std.testing.expectEqual(@as(i32, 15), result);
}

test "ExternalThreadPoolConfig defaults" {
    const config = ExternalThreadPoolConfig{};
    try std.testing.expectEqual(@as(u32, 64), config.max_tasks);
    try std.testing.expectEqual(@as(u32, 256), config.queue_depth);
    try std.testing.expectEqual(@as(u8, 3), config.priority_levels);
}

test "ExternalThreadPool basic" {
    const test_config = WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
    };

    const Pool = ExternalThreadPool(test_config);
    var pool = Pool.init(.{});
    defer pool.deinit();

    try std.testing.expectEqual(ExecutorStatus.idle, pool.getStatus());
}

test "TaskStatus enum" {
    try std.testing.expect(@intFromEnum(TaskStatus.pending) != @intFromEnum(TaskStatus.completed));
    try std.testing.expect(@intFromEnum(TaskStatus.running) != @intFromEnum(TaskStatus.failed));
}

test "selectExecutor" {
    const test_config = WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
    };

    // CPU executor is void
    const CpuType = selectExecutor(test_config, .cpu);
    try std.testing.expect(CpuType == void);

    // GPU executor is a type
    const GpuType = selectExecutor(test_config, .gpu);
    try std.testing.expect(GpuType != void);

    // SIMD executor is a type
    const SimdType = selectExecutor(test_config, .simd);
    try std.testing.expect(SimdType != void);
}
