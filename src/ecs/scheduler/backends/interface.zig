//! Scheduler Backend Interface
//!
//! This module defines the comptime interface that all scheduler backends must satisfy.
//! Backends control how systems are executed - blocking, batched I/O, work-stealing, etc.
//!
//! ## Architecture
//!
//! The scheduler uses duck-typing to verify backend compliance at compile time.
//! Each backend is a type generator that produces a specialized executor for a given config.
//!
//! ## Usage
//!
//! Backends are selected via `WorldConfig.schedule.execution_model`:
//!
//! ```zig
//! const cfg = ecs.WorldConfig{
//!     .schedule = .{
//!         .execution_model = .blocking_single_thread,  // Selects BlockingBackend
//!     },
//! };
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../../config.zig");
const WorldConfig = config_mod.WorldConfig;
const ExecutionModel = config_mod.ExecutionModel;

const error_types = @import("../../error/error_types.zig");

// ============================================================================
// Backend Statistics
// ============================================================================

/// Statistics collected by scheduler backends.
/// All backends should track these metrics for observability.
pub const BackendStats = struct {
    /// Total ticks executed since init
    ticks_executed: u64 = 0,
    /// Total systems executed (across all ticks)
    systems_executed: u64 = 0,
    /// Total phases executed
    phases_executed: u64 = 0,
    /// Syscalls batched (for io_uring backend)
    syscalls_batched: u64 = 0,
    /// Tasks stolen (for work-stealing backend)
    tasks_stolen: u64 = 0,
    /// Backend switches (for adaptive backend)
    backend_switches: u64 = 0,
    /// Total time spent in tick() (nanoseconds)
    total_tick_time_ns: u64 = 0,
    /// Last tick duration (nanoseconds)
    last_tick_time_ns: u64 = 0,

    /// Reset all statistics to zero.
    pub fn reset(self: *BackendStats) void {
        self.* = .{};
    }
};

// ============================================================================
// Backend Interface Verification
// ============================================================================

/// Verifies that a type satisfies the scheduler backend interface at comptime.
///
/// A valid backend must have:
/// - `pub fn tick(self: *Self, world: *WorldType, delta_time: f64) FrameResult`
/// - `pub fn reset(self: *Self) void`
/// - `pub fn getStats(self: *const Self) BackendStats`
///
/// This function is called at comptime during backend selection to ensure
/// type safety without runtime overhead.
pub fn verifyBackendInterface(comptime BackendType: type, comptime WorldType: type) void {
    const FrameResult = error_types.FrameResult;

    // Check for required methods
    if (!@hasDecl(BackendType, "tick")) {
        @compileError("Backend must have `tick(self, world, delta_time) FrameResult` method");
    }
    if (!@hasDecl(BackendType, "reset")) {
        @compileError("Backend must have `reset(self) void` method");
    }
    if (!@hasDecl(BackendType, "getStats")) {
        @compileError("Backend must have `getStats(self) BackendStats` method");
    }

    // Verify tick signature
    const tick_info = @typeInfo(@TypeOf(BackendType.tick));
    if (tick_info != .@"fn") {
        @compileError("Backend.tick must be a function");
    }

    const tick_fn = tick_info.@"fn";

    // Check parameter count (self, world, delta_time)
    if (tick_fn.params.len != 3) {
        @compileError("Backend.tick must have 3 parameters: (self, world, delta_time)");
    }

    // Check self parameter
    if (tick_fn.params[0].type) |param_type| {
        const param_info = @typeInfo(param_type);
        if (param_info != .pointer) {
            @compileError("Backend.tick first parameter must be *Self");
        }
    }

    // Check world parameter
    if (tick_fn.params[1].type) |param_type| {
        const param_info = @typeInfo(param_type);
        if (param_info != .pointer) {
            @compileError("Backend.tick second parameter must be *WorldType");
        }
        // Verify it's the correct world type
        if (param_info.pointer.child != WorldType) {
            @compileError("Backend.tick world parameter type mismatch");
        }
    }

    // Check delta_time parameter (f64)
    if (tick_fn.params[2].type) |param_type| {
        if (param_type != f64) {
            @compileError("Backend.tick third parameter must be f64");
        }
    }

    // Check return type (FrameResult)
    if (tick_fn.return_type) |ret_type| {
        if (ret_type != FrameResult) {
            @compileError("Backend.tick must return FrameResult");
        }
    }
}

// ============================================================================
// Backend Interface Type (Documentation Reference)
// ============================================================================

/// Reference interface that documents what a backend must implement.
/// This is NOT used directly - backends are duck-typed for maximum flexibility.
///
/// Each backend is a comptime type generator:
/// ```zig
/// pub fn MyBackend(comptime cfg: WorldConfig, comptime WorldType: type) type {
///     return struct {
///         // ... instance state ...
///
///         pub fn init(allocator: Allocator) @This() { ... }
///         pub fn deinit(self: *@This()) void { ... }
///         pub fn tick(self: *@This(), world: *WorldType, delta_time: f64) FrameResult { ... }
///         pub fn reset(self: *@This()) void { ... }
///         pub fn getStats(self: *const @This()) BackendStats { ... }
///     };
/// }
/// ```
pub const BackendInterfaceDoc = struct {
    /// Initialize the backend.
    /// Called once when the scheduler is created.
    pub const init = fn (allocator: Allocator) @This();

    /// Clean up backend resources.
    /// Called when the scheduler is destroyed.
    pub const deinit = fn (self: *@This()) void;

    /// Execute a single tick/frame.
    ///
    /// This is the core method that runs all systems according to the schedule.
    /// The backend determines HOW systems are executed (sequential, parallel, batched, etc).
    ///
    /// Parameters:
    /// - `world`: The ECS world to operate on
    /// - `delta_time`: Time since last tick in seconds
    ///
    /// Returns: FrameResult indicating success or error(s)
    pub const tick = fn (self: *@This(), world: anytype, delta_time: f64) error_types.FrameResult;

    /// Reset the backend to initial state.
    /// Clears all statistics and cached state.
    pub const reset = fn (self: *@This()) void;

    /// Get current backend statistics.
    /// Returns a copy of the stats (safe for concurrent access).
    pub const getStats = fn (self: *const @This()) BackendStats;
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Get time in nanoseconds using Zig 0.16 Instant API.
/// Returns 0 if time cannot be obtained.
pub fn getTimeNs() u64 {
    const instant = std.time.Instant.now() catch return 0;

    // Use a base instant for relative timing
    const base = struct {
        var value: ?std.time.Instant = null;
    };

    if (base.value == null) {
        base.value = instant;
    }

    return instant.since(base.value.?);
}

// ============================================================================
// Tests
// ============================================================================

test "BackendStats initialization" {
    var stats = BackendStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
    try std.testing.expectEqual(@as(u64, 0), stats.systems_executed);

    stats.ticks_executed = 100;
    stats.reset();

    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
}

test "getTimeNs returns value" {
    const t1 = getTimeNs();
    // Second call should be >= first
    const t2 = getTimeNs();
    try std.testing.expect(t2 >= t1);
}
