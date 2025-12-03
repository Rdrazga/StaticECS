//! Backend-specific configuration types for StaticECS schedulers.
//!
//! This module defines configuration structures for different scheduler backends:
//! - io_uring batch operations
//! - Work-stealing parallelism
//! - Adaptive hybrid scheduling

const core = @import("core_types.zig");

// Re-export ExecutionModel for BackendConfig users
pub const ExecutionModel = core.ExecutionModel;

// ============================================================================
// Backend Configuration Types
// ============================================================================

/// Backend-specific configuration for scheduler execution models.
/// Each variant contains settings relevant to that particular backend.
/// Tiger Style: All bounds configurable via these settings.
pub const BackendConfig = union(enum) {
    /// No backend-specific config (for simple models).
    none: void,
    /// io_uring batch backend configuration.
    io_uring_batch: IoUringBatchConfig,
    /// Work-stealing backend configuration.
    work_stealing: WorkStealingConfig,
    /// Adaptive hybrid backend configuration.
    adaptive: AdaptiveConfig,
};

/// Configuration for io_uring batch backend (Linux only).
/// Controls submission/completion queue sizes and batching behavior.
/// Tiger Style: Fixed bounds, power-of-two sizes for efficiency.
pub const IoUringBatchConfig = struct {
    /// Submission queue depth. Must be power of 2.
    /// Default 256 balances memory usage with batching efficiency.
    sq_entries: u16 = 256,
    /// Completion queue depth. Usually 2x sq_entries.
    /// Default 512 prevents completion queue overflow.
    cq_entries: u16 = 512,
    /// Maximum operations to batch per phase.
    /// Default 64 balances syscall reduction with latency.
    batch_size: u16 = 64,
    /// Enable kernel-side polling (IORING_SETUP_SQPOLL).
    /// Reduces syscalls but uses CPU. Best for high-throughput servers.
    kernel_poll: bool = false,
    /// CPU affinity for submission thread (when kernel_poll enabled).
    /// null = no affinity (OS decides).
    sq_thread_cpu: ?u8 = null,
    /// Idle timeout in milliseconds before sq thread goes to sleep.
    /// Only relevant when kernel_poll is true.
    sq_thread_idle_ms: u32 = 1000,
};

/// Configuration for work-stealing backend.
/// Controls worker threads, queue sizes, and stealing behavior.
/// Tiger Style: Per-core optimization, bounded queues.
pub const WorkStealingConfig = struct {
    /// Worker thread count. 0 = auto-detect CPU count.
    worker_count: u16 = 0,
    /// Local queue capacity per worker. Must be power of 2.
    /// Default 256 balances memory per-worker with queue depth.
    local_queue_size: u16 = 256,
    /// Number of tasks to steal in one operation.
    /// Default 32 balances fairness with stealing overhead.
    steal_batch: u8 = 32,
    /// Enable LIFO slot for producer cache locality.
    /// Improves cache performance for producer-heavy workloads.
    lifo_slot: bool = true,
    /// Spin iterations before parking a worker thread.
    /// Higher = lower latency, more CPU usage when idle.
    spin_count: u16 = 100,
};

/// Configuration for adaptive hybrid backend.
/// Controls thresholds for switching between underlying backends.
/// Tiger Style: Metric-driven, configurable windows.
pub const AdaptiveConfig = struct {
    /// Switch to batch mode when pending I/O operations exceed this.
    /// Default 64 triggers batching under moderate I/O load.
    batch_threshold: u32 = 64,
    /// Switch to work-stealing when CPU load imbalance exceeds this ratio.
    /// 0.3 = switch when slowest worker is 30% behind fastest.
    imbalance_threshold: f32 = 0.3,
    /// Metrics measurement window size (in ticks).
    /// Default 100 provides stable measurements without too much lag.
    window_size: u32 = 100,
    /// Minimum ticks between backend switches (cooldown period).
    /// Default 10 prevents oscillation between backends.
    switch_cooldown: u32 = 10,
    /// Which backend to start with. If null, auto-detect based on platform.
    initial_backend: ?ExecutionModel = null,
};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "BackendConfig defaults - none variant" {
    // Verify that none variant works correctly
    const cfg = BackendConfig{ .none = {} };

    // Should be the none variant
    switch (cfg) {
        .none => {
            // Success - this is expected
        },
        else => {
            return error.UnexpectedVariant;
        },
    }
}

test "BackendConfig defaults - io_uring_batch" {
    // Verify io_uring_batch defaults are sensible
    const cfg = BackendConfig{ .io_uring_batch = .{} };

    switch (cfg) {
        .io_uring_batch => |io_cfg| {
            // Verify power-of-two queue sizes
            try std.testing.expectEqual(@as(u16, 256), io_cfg.sq_entries);
            try std.testing.expectEqual(@as(u16, 512), io_cfg.cq_entries);
            try std.testing.expectEqual(@as(u16, 64), io_cfg.batch_size);

            // Verify cq_entries is 2x sq_entries
            try std.testing.expectEqual(io_cfg.sq_entries * 2, io_cfg.cq_entries);

            // Verify kernel polling is disabled by default
            try std.testing.expect(!io_cfg.kernel_poll);
            try std.testing.expectEqual(@as(?u8, null), io_cfg.sq_thread_cpu);
            try std.testing.expectEqual(@as(u32, 1000), io_cfg.sq_thread_idle_ms);
        },
        else => {
            return error.UnexpectedVariant;
        },
    }
}

test "BackendConfig defaults - work_stealing" {
    // Verify work_stealing defaults are sensible
    const cfg = BackendConfig{ .work_stealing = .{} };

    switch (cfg) {
        .work_stealing => |ws_cfg| {
            // Verify auto-detect worker count by default
            try std.testing.expectEqual(@as(u16, 0), ws_cfg.worker_count);

            // Verify power-of-two local queue size
            try std.testing.expectEqual(@as(u16, 256), ws_cfg.local_queue_size);

            // Verify reasonable steal batch size
            try std.testing.expectEqual(@as(u8, 32), ws_cfg.steal_batch);

            // Verify LIFO slot enabled by default for cache performance
            try std.testing.expect(ws_cfg.lifo_slot);

            // Verify spin count is reasonable
            try std.testing.expectEqual(@as(u16, 100), ws_cfg.spin_count);
        },
        else => {
            return error.UnexpectedVariant;
        },
    }
}

test "BackendConfig defaults - adaptive" {
    // Verify adaptive backend defaults are sensible
    const cfg = BackendConfig{ .adaptive = .{} };

    switch (cfg) {
        .adaptive => |adp_cfg| {
            // Verify threshold for batch mode switching
            try std.testing.expectEqual(@as(u32, 64), adp_cfg.batch_threshold);

            // Verify imbalance threshold is reasonable (0.3 = 30%)
            try std.testing.expect(adp_cfg.imbalance_threshold > 0.0);
            try std.testing.expect(adp_cfg.imbalance_threshold < 1.0);
            try std.testing.expectApproxEqAbs(@as(f32, 0.3), adp_cfg.imbalance_threshold, 0.001);

            // Verify measurement window is reasonable
            try std.testing.expectEqual(@as(u32, 100), adp_cfg.window_size);

            // Verify cooldown prevents oscillation
            try std.testing.expectEqual(@as(u32, 10), adp_cfg.switch_cooldown);
            try std.testing.expect(adp_cfg.switch_cooldown < adp_cfg.window_size);

            // Verify no initial backend by default (auto-detect)
            try std.testing.expectEqual(@as(?ExecutionModel, null), adp_cfg.initial_backend);
        },
        else => {
            return error.UnexpectedVariant;
        },
    }
}

test "IoUringBatchConfig validation" {
    // Test custom configuration values
    const custom_cfg = IoUringBatchConfig{
        .sq_entries = 512,
        .cq_entries = 1024,
        .batch_size = 128,
        .kernel_poll = true,
        .sq_thread_cpu = 3,
        .sq_thread_idle_ms = 500,
    };

    try std.testing.expectEqual(@as(u16, 512), custom_cfg.sq_entries);
    try std.testing.expectEqual(@as(u16, 1024), custom_cfg.cq_entries);
    try std.testing.expectEqual(@as(u16, 128), custom_cfg.batch_size);
    try std.testing.expect(custom_cfg.kernel_poll);
    try std.testing.expectEqual(@as(?u8, 3), custom_cfg.sq_thread_cpu);
    try std.testing.expectEqual(@as(u32, 500), custom_cfg.sq_thread_idle_ms);
}

test "WorkStealingConfig validation" {
    // Test custom worker count
    const custom_cfg = WorkStealingConfig{
        .worker_count = 8,
        .local_queue_size = 512,
        .steal_batch = 64,
        .lifo_slot = false,
        .spin_count = 200,
    };

    try std.testing.expectEqual(@as(u16, 8), custom_cfg.worker_count);
    try std.testing.expectEqual(@as(u16, 512), custom_cfg.local_queue_size);
    try std.testing.expectEqual(@as(u8, 64), custom_cfg.steal_batch);
    try std.testing.expect(!custom_cfg.lifo_slot);
    try std.testing.expectEqual(@as(u16, 200), custom_cfg.spin_count);
}

test "AdaptiveConfig with initial backend" {
    // Test setting initial backend
    const blocking_cfg = AdaptiveConfig{
        .initial_backend = .blocking_single_thread,
    };
    try std.testing.expectEqual(ExecutionModel.blocking_single_thread, blocking_cfg.initial_backend.?);

    const evented_cfg = AdaptiveConfig{
        .initial_backend = .evented_single_thread,
    };
    try std.testing.expectEqual(ExecutionModel.evented_single_thread, evented_cfg.initial_backend.?);

    const concurrent_cfg = AdaptiveConfig{
        .initial_backend = .concurrent_threadpool,
    };
    try std.testing.expectEqual(ExecutionModel.concurrent_threadpool, concurrent_cfg.initial_backend.?);
}
