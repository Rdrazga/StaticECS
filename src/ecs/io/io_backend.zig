//! I/O Backend Abstraction
//!
//! This module provides an abstraction layer over Zig's std.Io API for async operations.
//! It wraps std.Io.Threaded (cross-platform) and std.Io.Evented (platform-specific) to
//! provide a unified interface for the ECS scheduler.
//!
//! Target: Zig 0.16.0-dev.1470+32dc46aae or later
//!
//! Tiger Style: All bounds configurable, explicit error handling, fail-fast.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ============================================================================
// Version Detection
// ============================================================================

/// Check if std.Io is available (Zig 0.16+).
/// We detect by checking if std.Io has the expected types.
pub fn hasStdIo() bool {
    // Check for std.Io.Threaded which should exist in 0.16+
    return @hasDecl(std, "Io") and @hasDecl(std.Io, "Threaded");
}

/// Check if `std.Io.Evented` is available on this platform.
/// Returns false if Evented is void (unsupported platforms).
pub fn hasEventedBackend() bool {
    if (!hasStdIo()) return false;
    return std.Io.Evented != void;
}

// ============================================================================
// Backend Options
// ============================================================================

/// Configuration options for I/O backend initialization.
pub const BackendOptions = union(enum) {
    /// Blocking mode - no async support, all operations synchronous.
    blocking: void,

    /// Evented mode - single-threaded async via event loop.
    /// Uses io_uring on Linux, kqueue on BSD/macOS, falls back to threaded.
    evented: EventedOptions,

    /// Thread pool mode - full parallel execution.
    /// Uses std.Io.Threaded for cross-platform thread pool.
    threadpool: ThreadpoolOptions,
};

/// Options for evented (single-threaded async) backend.
pub const EventedOptions = struct {
    /// Maximum number of pending async operations.
    /// Tiger Style: Configure based on expected workload.
    max_pending_ops: u32 = 256,
};

/// Options for thread pool backend.
pub const ThreadpoolOptions = struct {
    /// Number of worker threads. 0 = auto-detect (CPU count).
    thread_count: u32 = 0,

    /// Stack size for worker threads.
    stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
};

// ============================================================================
// I/O Backend
// ============================================================================

/// Error types for I/O backend operations.
pub const IoBackendError = error{
    /// Backend initialization failed.
    InitFailed,
    /// Concurrent operation requested but not supported.
    ConcurrencyUnavailable,
    /// I/O operation failed.
    IoFailed,
    /// Backend is not initialized or has been deinitialized.
    NotInitialized,
    /// Queue is full, cannot schedule more operations.
    QueueFull,
    /// Operation was cancelled.
    Cancelled,
};

/// Backend mode enumeration.
pub const BackendMode = enum {
    blocking,
    evented,
    threadpool,
};

/// I/O Backend provides async operation scheduling and execution.
///
/// This is the core abstraction over std.Io. Systems interact with
/// the scheduler through IoContext, which wraps this backend.
///
/// Thread safety: Backend methods are safe to call from any thread
/// when using threadpool mode. In evented mode, only call from the
/// event loop thread.
pub const IoBackend = struct {
    const Self = @This();

    /// Backend storage union
    backend: BackendStorage,

    /// Backend mode for capability queries.
    mode: BackendMode,

    /// Allocator used for backend resources.
    allocator: Allocator,

    const BackendStorage = if (hasStdIo())
        RealBackendStorage
    else
        StubBackendStorage;

    const RealBackendStorage = union(enum) {
        none: void,
        threaded: std.Io.Threaded,
        evented: if (hasEventedBackend()) std.Io.Evented else void,
    };

    const StubBackendStorage = struct {
        pending: u32 = 0,
    };

    /// Initialize an I/O backend with the given options.
    ///
    /// Tiger Style: Fails fast if configuration is invalid.
    pub fn init(allocator: Allocator, options: BackendOptions) IoBackendError!Self {
        if (comptime hasStdIo()) {
            return initReal(allocator, options);
        } else {
            return initStub(allocator, options);
        }
    }

    fn initReal(allocator: Allocator, options: BackendOptions) IoBackendError!Self {
        return switch (options) {
            .blocking => .{
                .backend = .{ .none = {} },
                .mode = .blocking,
                .allocator = allocator,
            },
            .evented => blk: {
                if (comptime hasEventedBackend()) {
                    // Use evented backend (io_uring/kqueue)
                    break :blk .{
                        .backend = .{ .evented = std.Io.init(allocator) },
                        .mode = .evented,
                        .allocator = allocator,
                    };
                } else {
                    // Fall back to single-threaded Threaded
                    break :blk .{
                        .backend = .{ .threaded = std.Io.Threaded.init_single_threaded },
                        .mode = .evented,
                        .allocator = allocator,
                    };
                }
            },
            .threadpool => |tp| blk: {
                var threaded = std.Io.Threaded.init(allocator);
                if (tp.stack_size != std.Thread.SpawnConfig.default_stack_size) {
                    threaded.stack_size = tp.stack_size;
                }
                // async_limit and concurrent_limit can be configured if needed
                if (tp.thread_count > 0) {
                    threaded.async_limit = std.Io.Limit.limited(tp.thread_count);
                    threaded.concurrent_limit = std.Io.Limit.limited(tp.thread_count);
                }
                break :blk .{
                    .backend = .{ .threaded = threaded },
                    .mode = .threadpool,
                    .allocator = allocator,
                };
            },
        };
    }

    fn initStub(allocator: Allocator, options: BackendOptions) IoBackendError!Self {
        return .{
            .backend = .{ .pending = 0 },
            .mode = switch (options) {
                .blocking => .blocking,
                .evented => .evented,
                .threadpool => .threadpool,
            },
            .allocator = allocator,
        };
    }

    /// Deinitialize the backend, releasing all resources.
    pub fn deinit(self: *Self) void {
        if (comptime hasStdIo()) {
            switch (self.backend) {
                .none => {},
                .threaded => |*t| t.deinit(),
                .evented => |*e| {
                    if (comptime hasEventedBackend()) {
                        e.deinit();
                    }
                },
            }
        }
    }

    /// Get the underlying std.Io interface.
    /// Returns null for blocking mode or stub implementation.
    pub fn getIo(self: *Self) ?std.Io {
        if (comptime !hasStdIo()) return null;

        return switch (self.backend) {
            .none => null,
            .threaded => |*t| t.io(),
            .evented => |*e| blk: {
                if (comptime hasEventedBackend()) {
                    break :blk e.io();
                } else {
                    break :blk null;
                }
            },
        };
    }

    /// Check if async operations are supported.
    pub fn supportsAsync(self: *const Self) bool {
        return self.mode != .blocking;
    }

    /// Check if concurrent (parallel) operations are supported.
    pub fn supportsConcurrency(self: *const Self) bool {
        return self.mode == .threadpool;
    }

    /// Schedule async work using a Group.
    ///
    /// In blocking mode: Executes `func` immediately and synchronously.
    /// In evented/threadpool mode: Schedules via std.Io.Group.
    ///
    /// The group must be waited on or cancelled before the frame ends.
    pub fn scheduleAsync(
        self: *Self,
        group: *std.Io.Group,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) void {
        if (comptime !hasStdIo()) {
            // Stub: Execute synchronously
            @call(.auto, func, args);
            return;
        }

        if (self.getIo()) |io| {
            group.async(io, func, args);
        } else {
            // Blocking fallback
            @call(.auto, func, args);
        }
    }

    /// Schedule concurrent work using a Group.
    ///
    /// Returns error.ConcurrencyUnavailable if backend doesn't support
    /// concurrent execution.
    ///
    /// Tiger Style: Fail fast if preconditions not met.
    pub fn scheduleConcurrent(
        self: *Self,
        group: *std.Io.Group,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) error{ConcurrencyUnavailable}!void {
        if (!self.supportsConcurrency()) {
            return error.ConcurrencyUnavailable;
        }

        if (comptime !hasStdIo()) {
            // Stub: Execute synchronously
            @call(.auto, func, args);
            return;
        }

        if (self.getIo()) |io| {
            group.concurrent(io, func, args) catch {
                return error.ConcurrencyUnavailable;
            };
        } else {
            return error.ConcurrencyUnavailable;
        }
    }

    /// Wait for all tasks in a group to complete.
    pub fn waitGroup(self: *Self, group: *std.Io.Group) void {
        if (comptime !hasStdIo()) return;

        if (self.getIo()) |io| {
            group.wait(io);
        }
    }

    /// Cancel all tasks in a group.
    pub fn cancelGroup(self: *Self, group: *std.Io.Group) void {
        if (comptime !hasStdIo()) return;

        if (self.getIo()) |io| {
            group.cancel(io);
        }
    }
};

/// Group type for async operations.
/// Uses std.Io.Group when available, otherwise a stub.
pub const Group = if (hasStdIo())
    std.Io.Group
else
    StubGroup;

/// Stub Group for when std.Io is unavailable.
pub const StubGroup = struct {
    pub const init: StubGroup = .{};

    pub fn async(_: *StubGroup, _: anytype, func: anytype, args: anytype) void {
        @call(.auto, func, args);
    }

    pub fn concurrent(_: *StubGroup, _: anytype, func: anytype, args: anytype) error{ConcurrencyUnavailable}!void {
        @call(.auto, func, args);
    }

    pub fn wait(_: *StubGroup, _: anytype) void {}
    pub fn cancel(_: *StubGroup, _: anytype) void {}
};

// ============================================================================
// Tests
// ============================================================================

test "IoBackend: blocking mode init/deinit" {
    var backend = try IoBackend.init(std.testing.allocator, .blocking);
    defer backend.deinit();

    try std.testing.expect(!backend.supportsAsync());
    try std.testing.expect(!backend.supportsConcurrency());
}

test "IoBackend: evented mode init/deinit" {
    var backend = try IoBackend.init(std.testing.allocator, .{ .evented = .{} });
    defer backend.deinit();

    try std.testing.expect(backend.supportsAsync());
    try std.testing.expect(!backend.supportsConcurrency());
}

test "IoBackend: threadpool mode init/deinit" {
    var backend = try IoBackend.init(std.testing.allocator, .{ .threadpool = .{} });
    defer backend.deinit();

    try std.testing.expect(backend.supportsAsync());
    try std.testing.expect(backend.supportsConcurrency());
}

test "IoBackend: scheduleAsync executes callback (blocking)" {
    var backend = try IoBackend.init(std.testing.allocator, .blocking);
    defer backend.deinit();

    var executed = false;

    const helper = struct {
        fn run(ptr: *bool) void {
            ptr.* = true;
        }
    };

    var group: Group = .init;
    backend.scheduleAsync(&group, helper.run, .{&executed});
    backend.waitGroup(&group);

    try std.testing.expect(executed);
}

test "IoBackend: scheduleAsync with threadpool" {
    var backend = try IoBackend.init(std.testing.allocator, .{ .threadpool = .{} });
    defer backend.deinit();

    var executed = false;

    const helper = struct {
        fn run(ptr: *bool) void {
            ptr.* = true;
        }
    };

    var group: Group = .init;
    backend.scheduleAsync(&group, helper.run, .{&executed});
    backend.waitGroup(&group);

    try std.testing.expect(executed);
}

test "IoBackend: scheduleConcurrent succeeds in threadpool" {
    var backend = try IoBackend.init(std.testing.allocator, .{ .threadpool = .{} });
    defer backend.deinit();

    var executed = false;

    const helper = struct {
        fn run(ptr: *bool) void {
            ptr.* = true;
        }
    };

    var group: Group = .init;
    try backend.scheduleConcurrent(&group, helper.run, .{&executed});
    backend.waitGroup(&group);

    try std.testing.expect(executed);
}

test "IoBackend: scheduleConcurrent fails in blocking mode" {
    var backend = try IoBackend.init(std.testing.allocator, .blocking);
    defer backend.deinit();

    var executed = false;

    const helper = struct {
        fn run(ptr: *bool) void {
            ptr.* = true;
        }
    };

    var group: Group = .init;
    const result = backend.scheduleConcurrent(&group, helper.run, .{&executed});

    try std.testing.expectError(error.ConcurrencyUnavailable, result);
    try std.testing.expect(!executed);
}

test "hasStdIo detection" {
    // This should return true on Zig 0.16+
    const has_io = hasStdIo();
    // Just verify it compiles and returns a bool
    try std.testing.expect(has_io or !has_io);
}

test "hasEventedBackend detection" {
    const has_evented = hasEventedBackend();
    // Just verify it compiles and returns a bool
    try std.testing.expect(has_evented or !has_evented);
}
