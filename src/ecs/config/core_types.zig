//! Core enumeration and type definitions for StaticECS configuration.
//!
//! This module contains fundamental types used throughout the configuration system:
//! - Phase definitions for execution ordering
//! - Execution model selection
//! - Parallelism and asynchrony modes
//! - Layout and tick modes
//! - Type-safe context wrapper for opaque pointers

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Type-Safe Context Wrapper
// ============================================================================

/// TypedContext provides debug-mode type verification for opaque pointers.
///
/// This wrapper addresses the type-safety issues with `*anyopaque` patterns:
/// - Zero overhead in release builds (no type_name storage)
/// - Runtime type verification in debug/safe builds
/// - Compile-time type safety at creation site
///
/// Tiger_Style: Fail-fast on type mismatches in debug builds.
///
/// Usage:
/// ```zig
/// // Create with type safety
/// var my_data = MyStruct{ ... };
/// const ctx = TypedContext.init(&my_data);
///
/// // Cast back with verification
/// const ptr = ctx.cast(MyStruct); // Panics in debug if type mismatch
/// ```
pub const TypedContext = struct {
    /// The opaque pointer to user data.
    ptr: *anyopaque,
    /// Type name stored only in debug/safe builds for verification.
    /// In release builds, this is a zero-size type (void).
    type_name: DebugTypeName,

    /// In debug/safe builds, store the type name for verification.
    /// In release builds, this is void (zero size).
    const DebugTypeName = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
        []const u8
    else
        void;

    /// Create a TypedContext from a typed pointer.
    /// The type information is captured at compile time.
    pub fn init(comptime T: type, ptr: *T) TypedContext {
        return .{
            .ptr = @ptrCast(ptr),
            .type_name = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
                @typeName(T)
            else {},
        };
    }

    /// Create a TypedContext from a const typed pointer.
    /// Returns a context with a const-cast pointer (caller must ensure safety).
    pub fn initConst(comptime T: type, ptr: *const T) TypedContext {
        return .{
            .ptr = @ptrCast(@constCast(ptr)),
            .type_name = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
                @typeName(T)
            else {},
        };
    }

    /// Cast back to the original typed pointer.
    /// In debug/safe builds, panics if the type doesn't match.
    /// In release builds, performs unchecked cast (zero overhead).
    pub fn cast(self: TypedContext, comptime T: type) *T {
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            const expected = @typeName(T);
            if (!std.mem.eql(u8, self.type_name, expected)) {
                std.debug.panic(
                    "TypedContext type mismatch: expected '{s}', got '{s}'",
                    .{ expected, self.type_name },
                );
            }
        }
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Cast back to a const typed pointer.
    /// In debug/safe builds, panics if the type doesn't match.
    pub fn castConst(self: TypedContext, comptime T: type) *const T {
        return self.cast(T);
    }

    /// Get the raw opaque pointer (for interop with C APIs).
    /// Prefer cast() when possible for type safety.
    pub fn rawPtr(self: TypedContext) *anyopaque {
        return self.ptr;
    }

    /// Get the type name (only in debug/safe builds).
    /// Returns null in release builds.
    pub fn getTypeName(self: TypedContext) ?[]const u8 {
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            return self.type_name;
        }
        return null;
    }
};

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

// ============================================================================
// Storage Mode Types
// ============================================================================

/// CapacityMode controls archetype table storage allocation strategy.
/// Tiger_Style: Fixed mode enforces static allocation post-init.
pub const CapacityMode = enum {
    /// Fixed capacity - preallocated arrays, returns error on overflow.
    /// Tiger_Style compliant: no dynamic allocation after initialization.
    /// Storage is sized by max_entities or expected_entities_per_archetype.
    fixed,
    /// Dynamic capacity - grows as needed using ArrayList.
    /// Backward compatible but violates Tiger_Style static allocation rule.
    /// Use only when entity count is truly unbounded.
    dynamic,
};
