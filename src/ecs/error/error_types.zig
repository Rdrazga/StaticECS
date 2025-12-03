//! Error Types and Error Handling
//!
//! This module defines error sets and error handling infrastructure for StaticECS.

const std = @import("std");

// ============================================================================
// Error Categories
// ============================================================================

/// Invariant errors - internal ECS assumptions violated.
/// These indicate bugs or corruption and should fail fast.
pub const InvariantError = error{
    /// Entity index exceeds maximum bounds.
    EntityIndexOutOfBounds,
    /// Entity generation mismatch (stale handle).
    EntityGenerationMismatch,
    /// Archetype index is invalid.
    InvalidArchetypeIndex,
    /// Component storage corrupted or inconsistent.
    StorageCorruption,
    /// World state is inconsistent.
    WorldStateInconsistent,
    /// Scheduler state is corrupted.
    SchedulerStateCorrupted,
};

/// Initialization errors - problems during world/scheduler setup.
pub const InitError = error{
    /// Memory allocation failed during initialization.
    OutOfMemory,
    /// Required Io capability not available.
    IoCapabilityMissing,
    /// Concurrency support not available for configured execution model.
    ConcurrencyUnavailable,
    /// Thread pool initialization failed.
    ThreadPoolInitFailed,
    /// Invalid configuration detected at init time.
    InvalidConfiguration,
};

/// Frame execution errors - problems during system execution.
pub const FrameError = error{
    /// A system returned an error.
    SystemError,
    /// System execution timed out.
    SystemTimeout,
    /// System panicked during execution.
    SystemPanic,
    /// Entity capacity exhausted during frame.
    EntityCapacityExhausted,
    /// Memory allocation failed during frame.
    OutOfMemory,
    /// Query returned invalid results.
    QueryError,
    /// Frame was cancelled.
    FrameCancelled,
};

/// Combined error set for world operations.
pub const WorldError = InvariantError || InitError || FrameError || error{
    /// Entity handle is invalid.
    InvalidEntity,
    /// Archetype not found.
    ArchetypeNotFound,
    /// Component not found in archetype.
    ComponentNotFound,
    /// Capacity limit reached.
    CapacityExhausted,
};

/// Combined error set for scheduler operations.
pub const SchedulerError = InvariantError || InitError || FrameError || error{
    /// System not found in schedule.
    SystemNotFound,
    /// Invalid phase identifier.
    InvalidPhase,
    /// Stage construction failed.
    StageConstructionFailed,
    /// Conflict detected in schedule.
    ScheduleConflict,
};

// ============================================================================
// Error Context
// ============================================================================

/// Detailed error information for diagnostics.
pub const ErrorContext = struct {
    /// Error category identifier.
    category: ErrorCategory,
    /// Error code within category.
    code: u32,
    /// Human-readable error message.
    message: []const u8,
    /// Optional source location.
    source_location: ?std.builtin.SourceLocation = null,
    /// Optional world identifier.
    world_id: ?u64 = null,
    /// Optional system identifier.
    system_id: ?u16 = null,
    /// Optional entity identifier.
    entity_id: ?u32 = null,
    /// Optional additional data.
    data: ?*const anyopaque = null,
};

/// Error category enumeration.
pub const ErrorCategory = enum(u8) {
    invariant = 0,
    init = 1,
    frame = 2,
    world = 3,
    scheduler = 4,
};

// ============================================================================
// Error Result Types
// ============================================================================

/// Default maximum aggregate errors for backward compatibility.
pub const DEFAULT_MAX_AGGREGATE_ERRORS: u16 = 16;

/// Result type for frame execution that can contain multiple errors.
/// Tiger Style: Use FrameResultType for config-based sizing.
pub const FrameResult = FrameResultType(DEFAULT_MAX_AGGREGATE_ERRORS);

/// Parameterized frame result type with configurable error capacity.
/// Tiger Style: All bounds come from WorldConfig.options.max_aggregate_errors.
pub fn FrameResultType(comptime max_errors: u16) type {
    return union(enum) {
        const Self = @This();

        /// Frame completed successfully.
        success: void,
        /// Frame failed with a single error.
        single_error: FrameError,
        /// Frame aggregated multiple errors (when using aggregate policy).
        aggregate_errors: AggregateErrorsType(max_errors),

        pub fn isSuccess(self: Self) bool {
            return self == .success;
        }

        pub fn isError(self: Self) bool {
            return self != .success;
        }

        /// Get the first error if any.
        pub fn firstError(self: Self) ?FrameError {
            return switch (self) {
                .success => null,
                .single_error => |e| e,
                .aggregate_errors => |agg| agg.first(),
            };
        }
    };
}

/// Collection of aggregated errors from a frame.
/// Tiger Style: Use AggregateErrorsType for config-based sizing.
pub const AggregateErrors = AggregateErrorsType(DEFAULT_MAX_AGGREGATE_ERRORS);

/// Parameterized aggregate errors type with configurable capacity.
/// Tiger Style: All bounds come from WorldConfig.options.max_aggregate_errors.
pub fn AggregateErrorsType(comptime max_errors: u16) type {
    return struct {
        const Self = @This();

        /// Maximum errors this type can hold (from config).
        pub const max_error_count = max_errors;

        /// Number of errors collected.
        count: u32 = 0,
        /// Number of errors dropped due to capacity overflow.
        /// Tiger Style: Track overflow to prevent silent error loss.
        overflow_count: u32 = 0,
        /// Array of error entries (up to max_errors).
        errors: [max_errors]ErrorEntry = undefined,

        pub const ErrorEntry = struct {
            error_value: FrameError,
            system_index: u16,
            timestamp_ns: u64,
        };

        pub fn init() Self {
            return .{};
        }

        /// Add an error to the aggregate collection.
        /// Returns true if error was stored, false if dropped due to capacity.
        /// Tiger Style: Never silently drop errors - overflow is tracked and queryable.
        pub fn add(self: *Self, err: FrameError, system_index: u16, timestamp_ns: u64) bool {
            if (self.count < max_errors) {
                self.errors[self.count] = .{
                    .error_value = err,
                    .system_index = system_index,
                    .timestamp_ns = timestamp_ns,
                };
                self.count += 1;
                return true;
            }
            self.overflow_count += 1;
            return false;
        }

        pub fn first(self: Self) ?FrameError {
            if (self.count > 0) {
                return self.errors[0].error_value;
            }
            return null;
        }

        pub fn slice(self: *const Self) []const ErrorEntry {
            return self.errors[0..self.count];
        }

        /// Check if error buffer is full.
        pub fn isFull(self: *const Self) bool {
            return self.count >= max_errors;
        }

        /// Check if any errors were dropped due to capacity overflow.
        /// Tiger Style: Explicit overflow detection prevents silent error loss.
        pub fn hasOverflow(self: *const Self) bool {
            return self.overflow_count > 0;
        }

        /// Get the number of errors dropped due to capacity overflow.
        pub fn getOverflowCount(self: *const Self) u32 {
            return self.overflow_count;
        }

        /// Get total errors encountered (stored + dropped).
        pub fn totalErrorCount(self: *const Self) u32 {
            return self.count + self.overflow_count;
        }
    };
}

// ============================================================================
// Error Handlers
// ============================================================================

/// Default error handler that logs and returns/panics based on error type.
pub fn defaultErrorHandler(err: anyerror, context: ?ErrorContext) void {
    if (context) |ctx| {
        std.log.err("StaticECS error [{s}]: {s} (code={d})", .{
            @tagName(ctx.category),
            ctx.message,
            ctx.code,
        });
        if (ctx.source_location) |loc| {
            std.log.err("  at {s}:{d}:{d}", .{ loc.file, loc.line, loc.column });
        }
        if (ctx.world_id) |wid| {
            std.log.err("  world_id={d}", .{wid});
        }
        if (ctx.system_id) |sid| {
            std.log.err("  system_id={d}", .{sid});
        }
    } else {
        std.log.err("StaticECS error: {s}", .{@errorName(err)});
    }
}

/// Invariant check that panics with context on failure.
pub fn invariant(condition: bool, comptime message: []const u8) void {
    if (!condition) {
        @panic("StaticECS invariant violated: " ++ message);
    }
}

/// Debug-only invariant check (compiled out in release builds).
pub fn debugInvariant(condition: bool, comptime message: []const u8) void {
    if (std.debug.runtime_safety) {
        invariant(condition, message);
    }
}

// ============================================================================
// Error Code Helpers
// ============================================================================

/// Generate a unique error code from category and index.
pub fn makeErrorCode(category: ErrorCategory, index: u16) u32 {
    return (@as(u32, @intFromEnum(category)) << 16) | @as(u32, index);
}

/// Extract category from error code.
pub fn errorCategory(code: u32) ErrorCategory {
    return @enumFromInt(@as(u8, @truncate(code >> 16)));
}

/// Extract index from error code.
pub fn errorIndex(code: u32) u16 {
    return @truncate(code);
}

// ============================================================================
// Tests
// ============================================================================

test "ErrorCategory encoding" {
    const code = makeErrorCode(.invariant, 42);
    try std.testing.expectEqual(ErrorCategory.invariant, errorCategory(code));
    try std.testing.expectEqual(@as(u16, 42), errorIndex(code));
}

test "AggregateErrors" {
    var agg = AggregateErrors.init();
    try std.testing.expectEqual(@as(u32, 0), agg.count);
    try std.testing.expectEqual(@as(u32, 0), agg.overflow_count);
    try std.testing.expectEqual(@as(?FrameError, null), agg.first());
    try std.testing.expect(!agg.hasOverflow());

    // Add returns true when error stored successfully
    try std.testing.expect(agg.add(FrameError.SystemError, 0, 1000));
    try std.testing.expect(agg.add(FrameError.SystemTimeout, 1, 2000));

    try std.testing.expectEqual(@as(u32, 2), agg.count);
    try std.testing.expectEqual(FrameError.SystemError, agg.first().?);
    try std.testing.expect(!agg.hasOverflow());
    try std.testing.expectEqual(@as(u32, 2), agg.totalErrorCount());

    const entries = agg.slice();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u16, 0), entries[0].system_index);
    try std.testing.expectEqual(@as(u16, 1), entries[1].system_index);
}

test "AggregateErrors overflow tracking" {
    // Use small capacity for overflow testing
    const SmallAggregateErrors = AggregateErrorsType(2);

    var agg = SmallAggregateErrors.init();

    // Fill to capacity
    try std.testing.expect(agg.add(FrameError.SystemError, 0, 1000));
    try std.testing.expect(agg.add(FrameError.SystemTimeout, 1, 2000));

    try std.testing.expectEqual(@as(u32, 2), agg.count);
    try std.testing.expect(agg.isFull());
    try std.testing.expect(!agg.hasOverflow());
    try std.testing.expectEqual(@as(u32, 0), agg.getOverflowCount());
    try std.testing.expectEqual(@as(u32, 2), agg.totalErrorCount());

    // Attempt to add when full - should return false and track overflow
    try std.testing.expect(!agg.add(FrameError.SystemPanic, 2, 3000));
    try std.testing.expectEqual(@as(u32, 2), agg.count); // Count unchanged
    try std.testing.expect(agg.hasOverflow());
    try std.testing.expectEqual(@as(u32, 1), agg.getOverflowCount());
    try std.testing.expectEqual(@as(u32, 3), agg.totalErrorCount());

    // Add more errors when full
    try std.testing.expect(!agg.add(FrameError.QueryError, 3, 4000));
    try std.testing.expect(!agg.add(FrameError.FrameCancelled, 4, 5000));
    try std.testing.expectEqual(@as(u32, 2), agg.count); // Still only 2 stored
    try std.testing.expectEqual(@as(u32, 3), agg.getOverflowCount()); // 3 dropped
    try std.testing.expectEqual(@as(u32, 5), agg.totalErrorCount()); // 2 stored + 3 dropped

    // Verify stored errors are preserved (first 2)
    const entries = agg.slice();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(FrameError.SystemError, entries[0].error_value);
    try std.testing.expectEqual(FrameError.SystemTimeout, entries[1].error_value);
}

test "FrameResult" {
    const success = FrameResult{ .success = {} };
    try std.testing.expect(success.isSuccess());
    try std.testing.expect(!success.isError());
    try std.testing.expectEqual(@as(?FrameError, null), success.firstError());

    const single = FrameResult{ .single_error = FrameError.SystemError };
    try std.testing.expect(!single.isSuccess());
    try std.testing.expect(single.isError());
    try std.testing.expectEqual(FrameError.SystemError, single.firstError().?);
}
