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
