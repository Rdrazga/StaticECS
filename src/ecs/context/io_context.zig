//! I/O Context - Async Operation Capabilities
//!
//! This module provides I/O capabilities to systems that need them.
//! It wraps IoBackend to provide async operation scheduling.
//!
//! Design follows Zig 0.16 philosophy: "Async is not concurrency"
//! - `scheduleAsync()`: Expresses asynchrony (tasks may complete out of order)
//! - `scheduleConcurrent()`: Requires concurrent execution (may fail if unavailable)

const std = @import("std");
const io_backend = @import("../io/io_backend.zig");
pub const IoBackend = io_backend.IoBackend;
pub const IoBackendError = io_backend.IoBackendError;
pub const BackendOptions = io_backend.BackendOptions;
pub const Group = io_backend.Group;

// ============================================================================
// Error Types
// ============================================================================

/// Error type for I/O context operations.
pub const IoError = error{
    /// I/O context is not available (blocking execution model).
    IoNotAvailable,
    /// Concurrent async not supported (single-threaded evented model).
    ConcurrencyUnavailable,
};

// ============================================================================
// IoContext
// ============================================================================

/// IoContext provides I/O capabilities to systems that need them.
/// This wraps IoBackend to provide async operation scheduling.
///
/// When IoBackend is not available (blocking execution model), operations either:
/// - Execute synchronously (for `scheduleAsync()`)
/// - Return an error (for `scheduleConcurrent()`)
pub const IoContext = struct {
    const Self = @This();

    /// Pointer to the underlying IoBackend.
    /// Null when in blocking mode (no async support).
    backend: ?*IoBackend = null,

    /// True if this context supports concurrent async operations.
    /// False for blocking and single-threaded evented models.
    supports_concurrency: bool = false,

    /// True if any async capabilities are available.
    /// False only in blocking_single_thread mode.
    supports_async: bool = false,

    /// Create an IoContext for blocking execution (no async support).
    pub fn blocking() Self {
        return .{
            .backend = null,
            .supports_concurrency = false,
            .supports_async = false,
        };
    }

    /// Create an IoContext from an IoBackend.
    /// Automatically determines async/concurrency support from backend capabilities.
    pub fn fromBackend(backend: *IoBackend) Self {
        return .{
            .backend = backend,
            .supports_concurrency = backend.supportsConcurrency(),
            .supports_async = backend.supportsAsync(),
        };
    }

    /// Create an IoContext for evented execution (async but no concurrency).
    /// Deprecated: Use fromBackend() with an evented IoBackend.
    pub fn evented(io_ptr: *anyopaque) Self {
        _ = io_ptr;
        return .{
            .backend = null, // Legacy: will be removed when fully migrated
            .supports_concurrency = false,
            .supports_async = true,
        };
    }

    /// Create an IoContext for concurrent execution (full async + concurrency).
    /// Deprecated: Use fromBackend() with a threadpool IoBackend.
    pub fn concurrent(io_ptr: *anyopaque) Self {
        _ = io_ptr;
        return .{
            .backend = null, // Legacy: will be removed when fully migrated
            .supports_concurrency = true,
            .supports_async = true,
        };
    }

    /// Check if async operations are available.
    pub fn hasAsync(self: *const Self) bool {
        return self.supports_async;
    }

    /// Check if concurrent async operations are available.
    pub fn hasConcurrency(self: *const Self) bool {
        return self.supports_concurrency;
    }

    /// Get the IoBackend for direct access.
    /// Returns null if in blocking mode.
    pub fn getBackend(self: *Self) ?*IoBackend {
        return self.backend;
    }

    /// Schedule an async operation through the backend using a Group.
    ///
    /// In blocking mode: Executes immediately and synchronously.
    /// In evented mode: Queues for event loop execution.
    /// In threadpool mode: Queues for parallel execution.
    ///
    /// The caller must wait on or cancel the Group before it goes out of scope.
    ///
    /// Parameters:
    ///   - group: Group to track the async operation
    ///   - func: Function to execute asynchronously
    ///   - args: Arguments tuple to pass to func
    pub fn scheduleAsync(
        self: *Self,
        group: *Group,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) void {
        if (self.backend) |b| {
            b.scheduleAsync(group, func, args);
        } else {
            // Blocking fallback: execute synchronously
            @call(.auto, func, args);
        }
    }

    /// Schedule an operation that requires concurrent execution.
    ///
    /// Returns error.ConcurrencyUnavailable if backend doesn't support
    /// concurrent execution (blocking or evented mode).
    ///
    /// Parameters:
    ///   - group: Group to track the concurrent operation
    ///   - func: Function to execute concurrently
    ///   - args: Arguments tuple to pass to func
    pub fn scheduleConcurrent(
        self: *Self,
        group: *Group,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) error{ConcurrencyUnavailable}!void {
        if (self.backend) |b| {
            return b.scheduleConcurrent(group, func, args);
        } else {
            return error.ConcurrencyUnavailable;
        }
    }

    /// Wait for all tasks in a group to complete.
    pub fn waitGroup(self: *Self, group: *Group) void {
        if (self.backend) |b| {
            b.waitGroup(group);
        }
    }

    /// Cancel all tasks in a group.
    pub fn cancelGroup(self: *Self, group: *Group) void {
        if (self.backend) |b| {
            b.cancelGroup(group);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "IoContext creation and properties" {
    // Create blocking context (the standard way)
    var io_ctx = IoContext.blocking();
    try std.testing.expect(!io_ctx.hasAsync());
    try std.testing.expect(!io_ctx.hasConcurrency());
    try std.testing.expect(io_ctx.getBackend() == null);
    try std.testing.expect(!io_ctx.supports_async);
    try std.testing.expect(!io_ctx.supports_concurrency);
}

test "IoContext async/concurrent capability reporting" {
    // Async-only context (evented mode)
    const async_ctx = IoContext{
        .backend = null,
        .supports_async = true,
        .supports_concurrency = false,
    };
    try std.testing.expect(async_ctx.hasAsync());
    try std.testing.expect(!async_ctx.hasConcurrency());

    // Full concurrent context (threadpool mode)
    const concurrent_ctx = IoContext{
        .backend = null,
        .supports_async = true,
        .supports_concurrency = true,
    };
    try std.testing.expect(concurrent_ctx.hasAsync());
    try std.testing.expect(concurrent_ctx.hasConcurrency());
}
