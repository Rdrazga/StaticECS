//! Backend Selector
//!
//! This module selects the appropriate scheduler backend based on configuration.
//! The selection happens at comptime, so there's zero runtime overhead from
//! backends that aren't selected.
//!
//! ## Selection Logic
//!
//! | ExecutionModel | Backend |
//! |----------------|---------|
//! | blocking_single_thread | BlockingBackend |
//! | evented_single_thread | BlockingBackend (with IoContext) |
//! | concurrent_threadpool | BlockingBackend (with parallel stages) |
//! | io_uring_batch | IoUringBatchBackend (Linux only) |
//! | work_stealing | WorkStealingBackend |
//! | adaptive_hybrid | AdaptiveBackend |
//!
//! ## Future Backends
//!
//! When additional backends are implemented, they will be integrated here.
//! The comptime switch ensures unused backends are never compiled.

const std = @import("std");
const builtin = @import("builtin");

const config_mod = @import("../../config.zig");
const WorldConfig = config_mod.WorldConfig;
const ExecutionModel = config_mod.ExecutionModel;

const blocking = @import("blocking.zig");
const BlockingBackend = blocking.BlockingBackend;

// Phase 4.2: io_uring batch backend
const io_uring_batch = @import("io_uring_batch.zig");
const IoUringBatchBackend = io_uring_batch.IoUringBatchBackend;
const IoUringFallbackBackend = io_uring_batch.IoUringFallbackBackend;

// Phase 4.3: Work-stealing backend
const work_stealing = @import("work_stealing.zig");
const WorkStealingBackend = work_stealing.WorkStealingBackend;

// Phase 4.4: Adaptive hybrid backend
const adaptive = @import("adaptive.zig");
const AdaptiveBackend = adaptive.AdaptiveBackend;

// ============================================================================
// Backend Selection
// ============================================================================

/// Select the appropriate backend type based on configuration.
///
/// This function is evaluated at comptime, ensuring that only the selected
/// backend is compiled into the final binary.
///
/// Tiger Style: Comptime selection eliminates runtime branching and dead code.
pub fn SelectBackend(comptime cfg: WorldConfig, comptime WorldType: type) type {
    return switch (cfg.schedule.execution_model) {
        // Core backends (always available)
        .blocking_single_thread => BlockingBackend(cfg, WorldType),
        .evented_single_thread => BlockingBackend(cfg, WorldType),
        .concurrent_threadpool => BlockingBackend(cfg, WorldType),

        // Phase 4.2: io_uring batch backend (Linux only)
        .io_uring_batch => if (io_uring_batch.io_uring_available)
            IoUringBatchBackend(cfg, WorldType)
        else
            IoUringFallbackBackend(cfg, WorldType),

        // Phase 4.3: Work-stealing backend
        .work_stealing => WorkStealingBackend(cfg, WorldType),

        // Phase 4.4: Adaptive hybrid backend
        .adaptive_hybrid => AdaptiveBackend(cfg, WorldType),
    };
}

/// Check if a backend is available on the current platform.
///
/// This is useful for runtime checks or documentation generation.
pub fn isBackendAvailable(model: ExecutionModel) bool {
    return switch (model) {
        .blocking_single_thread => true,
        .evented_single_thread => true,
        .concurrent_threadpool => true,
        .io_uring_batch => io_uring_batch.io_uring_available,
        .work_stealing => true, // Will use fallback on non-supported platforms
        .adaptive_hybrid => true, // Will use fallback on non-supported platforms
    };
}

/// Get the human-readable name of a backend.
pub fn getBackendName(model: ExecutionModel) []const u8 {
    return switch (model) {
        .blocking_single_thread => "Blocking (single-threaded)",
        .evented_single_thread => "Evented (single-threaded with IoContext)",
        .concurrent_threadpool => "Threadpool (parallel stages)",
        .io_uring_batch => "io_uring Batch (Linux syscall batching)",
        .work_stealing => "Work-Stealing (per-core queues)",
        .adaptive_hybrid => "Adaptive (runtime backend switching)",
    };
}

/// Get the description of a backend's characteristics.
pub fn getBackendDescription(model: ExecutionModel) []const u8 {
    return switch (model) {
        .blocking_single_thread =>
        \\Sequential execution on calling thread.
        \\Best for: Simple apps, debugging, predictable execution.
        \\Overhead: Minimal.
        ,
        .evented_single_thread =>
        \\Sequential execution with async I/O support.
        \\Best for: I/O-bound workloads on single thread.
        \\Overhead: IoContext creation.
        ,
        .concurrent_threadpool =>
        \\Parallel stage execution via thread pool.
        \\Best for: CPU-bound workloads with independent systems.
        \\Overhead: Thread synchronization.
        ,
        .io_uring_batch =>
        \\Batched syscalls via Linux io_uring.
        \\Best for: High-throughput servers with many I/O operations.
        \\Overhead: io_uring setup, Linux-only.
        ,
        .work_stealing =>
        \\Parallel execution with per-core queues and work stealing.
        \\Best for: CPU-bound parallel workloads with variable task sizes.
        \\Overhead: Queue management, thread coordination.
        ,
        .adaptive_hybrid =>
        \\Dynamic backend switching based on runtime metrics.
        \\Best for: Mixed workloads with varying I/O and CPU patterns.
        \\Overhead: Metrics collection, backend switching.
        ,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "SelectBackend returns BlockingBackend for blocking model" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .systems = .{ .systems = &.{} },
        .schedule = .{ .execution_model = .blocking_single_thread },
        .options = .{ .max_entities = 100 },
    };

    const WorldType = @import("../../world.zig").World(cfg);
    const Backend = SelectBackend(cfg, WorldType);

    // Verify it's the blocking backend by checking for expected methods
    try std.testing.expect(@hasDecl(Backend, "tick"));
    try std.testing.expect(@hasDecl(Backend, "reset"));
    try std.testing.expect(@hasDecl(Backend, "getStats"));
}

test "isBackendAvailable" {
    try std.testing.expect(isBackendAvailable(.blocking_single_thread));
    try std.testing.expect(isBackendAvailable(.evented_single_thread));
    try std.testing.expect(isBackendAvailable(.concurrent_threadpool));
    // io_uring availability depends on platform
    if (builtin.os.tag == .linux) {
        try std.testing.expect(isBackendAvailable(.io_uring_batch));
    }
    try std.testing.expect(isBackendAvailable(.work_stealing));
    try std.testing.expect(isBackendAvailable(.adaptive_hybrid));
}

test "getBackendName" {
    const name = getBackendName(.blocking_single_thread);
    try std.testing.expect(name.len > 0);
    try std.testing.expectEqualStrings("Blocking (single-threaded)", name);
}
