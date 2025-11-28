//! Core enumeration and type definitions for StaticECS configuration.
//!
//! This module contains fundamental types used throughout the configuration system:
//! - Phase definitions for execution ordering
//! - Execution model selection
//! - Parallelism and asynchrony modes
//! - Layout and tick modes

// ============================================================================
// Phase Types
// ============================================================================

/// Phase definition for custom phase sequences.
/// Tiger Style: Phases are configurable - define your own execution bands.
pub const PhaseDef = struct {
    /// Phase name (for tracing and debugging).
    name: [:0]const u8,
    /// Execution order (lower = earlier). Used for sorting when specified.
    order: u8 = 0,
};

/// Default phases matching traditional game loop patterns.
/// Users can override with custom phases via WorldConfig.phases.
pub const DEFAULT_PHASES: []const PhaseDef = &.{
    .{ .name = "pre_update", .order = 0 },
    .{ .name = "update", .order = 1 },
    .{ .name = "post_update", .order = 2 },
    .{ .name = "render", .order = 3 },
    .{ .name = "network", .order = 4 },
};

/// Default phase enum for backward compatibility.
/// Maps to indices in DEFAULT_PHASES.
/// Use Phase.index() to get the u8 index for SystemDef.phase.
pub const Phase = enum(u8) {
    pre_update = 0,
    update = 1,
    post_update = 2,
    render = 3,
    network = 4,

    /// Returns the phase index for use with SystemDef.phase.
    pub fn index(self: Phase) u8 {
        return @intFromEnum(self);
    }

    /// Returns the numeric ordering value for this phase (alias for index).
    pub fn order(self: Phase) u8 {
        return @intFromEnum(self);
    }
};

// ============================================================================
// Execution Mode Types
// ============================================================================

/// AsynchronyKind describes how a system relates to async I/O.
pub const AsynchronyKind = enum {
    /// No asynchrony; the scheduler calls the system synchronously.
    none,
    /// The scheduler may launch the system via async Io primitives.
    /// Correctness must not depend on concurrent progress.
    may_async,
};

/// ParallelismMode describes intra-system parallelization strategy.
pub const ParallelismMode = enum {
    /// A single task handles the entire system.
    none,
    /// The entity set is partitioned into chunks processed by multiple tasks.
    by_entity,
    /// One task per matching archetype/component set.
    by_set,
    /// Reserved for higher-level orchestration across multiple worlds.
    by_world,
};

/// ExecutionModel selects the scheduler family and runtime semantics.
pub const ExecutionModel = enum {
    /// Single-threaded, blocking scheduler.
    blocking_single_thread,
    /// Single-threaded, evented Io with task switching.
    evented_single_thread,
    /// Multi-threaded scheduler backed by a thread pool.
    concurrent_threadpool,
    /// io_uring-based syscall batching (Linux only).
    /// Batches I/O operations per phase for reduced syscall overhead.
    io_uring_batch,
    /// Work-stealing scheduler with per-core queues.
    /// Optimal for CPU-bound parallel workloads.
    work_stealing,
    /// Adaptive hybrid that switches backends based on runtime metrics.
    /// Combines benefits of batching and parallelism dynamically.
    adaptive_hybrid,
};

// ============================================================================
// World Mode Types
// ============================================================================

/// TickMode configures how frames/ticks are driven.
pub const TickMode = enum {
    /// Manual ticking via explicit run_frame calls.
    manual,
    /// Fixed-rate ticking at a configured frequency.
    fixed_rate,
};

/// LayoutMode controls entity representation and storage layout.
pub const LayoutMode = enum {
    /// Multiple archetypes with full archetype transition support.
    multi_archetype,
    /// Single archetype with more compact entity representation.
    single_archetype,
};
