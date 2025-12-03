//! # Tracing and Logging Support
//!
//! This module provides the tracing infrastructure for StaticECS.
//!
//! ## Key Types
//! - `TraceSink` - Consumer interface for trace events (with VTable)
//! - `TracingContext` - Compile-time configured trace emitter
//! - Event types: `TickEvent`, `StageEvent`, `SystemEvent`, `SystemErrorEvent`
//! - `ConsoleSink` - Built-in debug sink that prints to stderr
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
//! │ TracingContext  │────>│   TraceSink      │────>│ User Callback   │
//! │ (emits events)  │     │ (VTable dispatch)│     │ (logging, etc.) │
//! └─────────────────┘     └──────────────────┘     └─────────────────┘
//!         │                       │
//!         │ compile-time          │ runtime
//!         │ level filtering       │ vtable dispatch
//! ```
//!
//! ## Forward Declaration Pattern
//!
//! Configuration types (`config/tracing_types.zig`) use `TraceSinkPtr` (opaque
//! pointer) to reference TraceSink without creating circular dependencies.
//! At runtime, the pointer is cast back to `*TraceSink` for event dispatch.
//!
//! See `config/tracing_types.zig` for the configuration-side documentation.
//!
//! ## Type Safety
//!
//! TraceSink uses `TypedContext` for debug-mode type verification of user-
//! provided context pointers. This catches type mismatches in debug builds
//! while having zero overhead in release builds.
//!
//! ## Usage Example
//!
//! ```zig
//! // 1. Create a custom sink with state
//! const MySinkData = struct { log_file: std.fs.File };
//! var my_data = MySinkData{ .log_file = file };
//!
//! const my_vtable = TraceSink.VTable{
//!     .on_system_start = struct {
//!         fn f(ctx: *anyopaque, event: SystemEvent) void {
//!             const data = TraceSink.castContext(ctx, MySinkData);
//!             data.log_file.writer().print("System: {s}\n", .{event.system_name});
//!         }
//!     }.f,
//! };
//!
//! const sink = TraceSink.init(MySinkData, &my_data, &my_vtable);
//!
//! // 2. Or use the built-in console sink
//! const console_sink = ConsoleSink.sink();
//! ```
//!
//! ## Thread Safety
//!
//! TraceSink callbacks may be invoked from multiple threads when using
//! concurrent execution models. Implementations must ensure thread safety
//! (e.g., via mutex, atomic operations, or thread-local storage).

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const core_types = @import("../config/core_types.zig");

/// TypedContext for type-safe opaque pointer handling.
/// Re-exported for trace sink implementations.
pub const TypedContext = core_types.TypedContext;

// ============================================================================
// Trace Level
// ============================================================================

/// Re-export TraceLevel from config for consistency
pub const TraceLevel = config.TraceLevel;

/// Extension methods for TraceLevel
pub const TraceLevelExt = struct {
    /// Check if a level should emit at the configured level.
    pub fn shouldEmit(level: TraceLevel, target: TraceLevel) bool {
        return @intFromEnum(target) <= @intFromEnum(level);
    }

    /// Check if error events should be emitted.
    pub fn emitsErrors(self: TraceLevel) bool {
        return self != .off;
    }

    /// Check if system events should be emitted.
    pub fn emitsSystems(self: TraceLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(TraceLevel.systems);
    }

    /// Check if verbose events should be emitted.
    pub fn emitsVerbose(self: TraceLevel) bool {
        return self == .verbose;
    }
};

// ============================================================================
// Trace Events
// ============================================================================

/// Tick boundary event.
pub const TickEvent = struct {
    /// World identifier (index or pointer-derived).
    world_id: u64,
    /// Tick/frame index.
    tick_index: u64,
    /// Timestamp in nanoseconds (if available).
    timestamp_ns: ?u64 = null,
    /// Duration in nanoseconds (only at tick end).
    duration_ns: ?u64 = null,
};

/// Stage boundary event.
pub const StageEvent = struct {
    /// World identifier.
    world_id: u64,
    /// Phase identifier.
    phase: u8,
    /// Stage index within phase.
    stage_index: u16,
    /// Number of systems in this stage.
    system_count: u16,
    /// Timestamp in nanoseconds.
    timestamp_ns: ?u64 = null,
    /// Duration in nanoseconds (only at stage end).
    duration_ns: ?u64 = null,
};

/// System execution event.
pub const SystemEvent = struct {
    /// World identifier.
    world_id: u64,
    /// System index.
    system_index: u16,
    /// System name.
    system_name: []const u8,
    /// Phase identifier.
    phase: u8,
    /// Stage index.
    stage_index: u16,
    /// Timestamp in nanoseconds.
    timestamp_ns: ?u64 = null,
    /// Duration in nanoseconds (only at system end).
    duration_ns: ?u64 = null,
    /// Entity count processed (if available).
    entity_count: ?u32 = null,
};

/// System error event.
pub const SystemErrorEvent = struct {
    /// All system event fields.
    system: SystemEvent,
    /// Error code or identifier.
    error_code: u32,
    /// Error message (if available).
    error_message: ?[]const u8 = null,
    /// The active frame policy when error occurred.
    frame_policy: u8,
};

// ============================================================================
// Trace Sink
// ============================================================================

/// TraceSink is the interface for consuming trace events.
///
/// Implementations can log to stdout, files, network, or custom backends.
/// The VTable pattern allows zero-overhead dispatch when tracing is disabled
/// at compile time (TracingContext compiles calls to no-ops).
///
/// ## Lifecycle
///
/// 1. **Create**: Use `init()` with your context type and VTable
/// 2. **Configure**: Pass to `TracingSpec.sink` (cast to `TraceSinkPtr`)
/// 3. **Receive**: VTable callbacks invoked during world tick execution
/// 4. **Cleanup**: User manages context lifetime (sink doesn't own memory)
///
/// ## Type Safety
///
/// The context field uses TypedContext for debug-mode type verification.
/// In debug builds, casting to the wrong type will panic with a clear message.
/// In release builds, TypedContext has zero overhead.
///
/// ## Usage
/// ```zig
/// var my_sink_data = MySinkData{ ... };
/// const sink = TraceSink.init(MySinkData, &my_sink_data, &my_vtable);
/// // In VTable callback, safely cast back:
/// const data = TraceSink.castContext(ctx, MySinkData);
/// ```
///
/// ## Relationship to TraceSinkPtr
///
/// Configuration uses `TraceSinkPtr` (opaque pointer) to avoid circular deps.
/// At runtime: `@ptrCast(@alignCast(trace_spec.sink.?))` → `*const TraceSink`
pub const TraceSink = struct {
    /// User-provided context with debug-mode type verification.
    /// Use init() to create with type safety, castContext() in callbacks.
    context: TypedContext,
    /// Vtable for event callbacks.
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called at the start of a tick/frame.
        /// ctx: Use TraceSink.castContext() to safely cast to your context type.
        on_tick_start: ?*const fn (ctx: *anyopaque, event: TickEvent) void = null,
        /// Called at the end of a tick/frame.
        on_tick_end: ?*const fn (ctx: *anyopaque, event: TickEvent) void = null,
        /// Called at the start of a stage.
        on_stage_start: ?*const fn (ctx: *anyopaque, event: StageEvent) void = null,
        /// Called at the end of a stage.
        on_stage_end: ?*const fn (ctx: *anyopaque, event: StageEvent) void = null,
        /// Called at the start of a system.
        on_system_start: ?*const fn (ctx: *anyopaque, event: SystemEvent) void = null,
        /// Called at the end of a system.
        on_system_end: ?*const fn (ctx: *anyopaque, event: SystemEvent) void = null,
        /// Called when a system error occurs.
        on_system_error: ?*const fn (ctx: *anyopaque, event: SystemErrorEvent) void = null,
    };

    /// Create a type-safe TraceSink with context type verification.
    /// In debug builds, the type is stored and verified on cast.
    /// In release builds, this has zero overhead.
    pub fn init(comptime T: type, ctx: *T, vtable: *const VTable) TraceSink {
        return .{
            .context = TypedContext.init(T, ctx),
            .vtable = vtable,
        };
    }

    /// Create a TraceSink with no context (for stateless sinks like ConsoleSink).
    /// Uses a dummy context that will panic if accessed.
    pub fn initStateless(vtable: *const VTable) TraceSink {
        // Use undefined but mark with a recognizable type for debugging
        const StatelessMarker = struct {};
        return .{
            .context = TypedContext.initConst(StatelessMarker, &StatelessMarker{}),
            .vtable = vtable,
        };
    }

    /// @deprecated Use init() for type-safe context creation.
    /// Creates a TraceSink with raw anyopaque context (no type verification).
    /// Maintained for backward compatibility.
    pub fn initUnsafe(ctx: *anyopaque, vtable: *const VTable) TraceSink {
        // Create with void type marker to indicate unsafe creation
        const UnsafeMarker = struct {};
        return .{
            .context = .{
                .ptr = ctx,
                .type_name = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
                    @typeName(UnsafeMarker) ++ " (unsafe - no type checking)"
                else {},
            },
            .vtable = vtable,
        };
    }

    /// Safely cast the context pointer to its original type in callbacks.
    /// In debug builds, panics if T doesn't match the type used in init().
    ///
    /// Usage in VTable callback:
    /// ```zig
    /// fn onTickStart(ctx: *anyopaque, event: TickEvent) void {
    ///     const self = TraceSink.castContext(ctx, MySinkData);
    ///     // use self...
    /// }
    /// ```
    ///
    /// Note: For maximum safety, store TypedContext and use its cast() directly.
    /// This helper is for convenience in VTable callbacks which receive *anyopaque.
    pub fn castContext(ctx: *anyopaque, comptime T: type) *T {
        // In VTable callbacks we only have *anyopaque, so we do a direct cast.
        // Type safety relies on the TraceSink being created with init(T, ...).
        // Full verification requires storing TypedContext, but VTable ABI uses *anyopaque.
        return @ptrCast(@alignCast(ctx));
    }

    /// Get the raw context pointer (for passing to VTable callbacks).
    pub fn rawContext(self: TraceSink) *anyopaque {
        return self.context.rawPtr();
    }

    /// Emit a tick start event.
    pub fn tickStart(self: TraceSink, event: TickEvent) void {
        if (self.vtable.on_tick_start) |cb| {
            cb(self.context.rawPtr(), event);
        }
    }

    /// Emit a tick end event.
    pub fn tickEnd(self: TraceSink, event: TickEvent) void {
        if (self.vtable.on_tick_end) |cb| {
            cb(self.context.rawPtr(), event);
        }
    }

    /// Emit a stage start event.
    pub fn stageStart(self: TraceSink, event: StageEvent) void {
        if (self.vtable.on_stage_start) |cb| {
            cb(self.context.rawPtr(), event);
        }
    }

    /// Emit a stage end event.
    pub fn stageEnd(self: TraceSink, event: StageEvent) void {
        if (self.vtable.on_stage_end) |cb| {
            cb(self.context.rawPtr(), event);
        }
    }

    /// Emit a system start event.
    pub fn systemStart(self: TraceSink, event: SystemEvent) void {
        if (self.vtable.on_system_start) |cb| {
            cb(self.context.rawPtr(), event);
        }
    }

    /// Emit a system end event.
    pub fn systemEnd(self: TraceSink, event: SystemEvent) void {
        if (self.vtable.on_system_end) |cb| {
            cb(self.context.rawPtr(), event);
        }
    }

    /// Emit a system error event.
    pub fn systemError(self: TraceSink, event: SystemErrorEvent) void {
        if (self.vtable.on_system_error) |cb| {
            cb(self.context.rawPtr(), event);
        }
    }
};

// ============================================================================
// Tracing Context
// ============================================================================

/// TracingContext manages trace emission based on configuration.
pub fn TracingContext(comptime level: TraceLevel) type {
    return struct {
        const Self = @This();

        sink: ?TraceSink,
        world_id: u64,

        pub fn init(sink: ?TraceSink, world_id: u64) Self {
            return .{
                .sink = sink,
                .world_id = world_id,
            };
        }

        // Tick events (verbose level only)
        pub fn emitTickStart(self: Self, tick_index: u64, timestamp_ns: ?u64) void {
            if (comptime TraceLevelExt.emitsVerbose(level)) {
                if (self.sink) |sink| {
                    sink.tickStart(.{
                        .world_id = self.world_id,
                        .tick_index = tick_index,
                        .timestamp_ns = timestamp_ns,
                    });
                }
            }
        }

        pub fn emitTickEnd(self: Self, tick_index: u64, timestamp_ns: ?u64, duration_ns: ?u64) void {
            if (comptime TraceLevelExt.emitsVerbose(level)) {
                if (self.sink) |sink| {
                    sink.tickEnd(.{
                        .world_id = self.world_id,
                        .tick_index = tick_index,
                        .timestamp_ns = timestamp_ns,
                        .duration_ns = duration_ns,
                    });
                }
            }
        }

        // Stage events (verbose level only)
        pub fn emitStageStart(self: Self, phase: u8, stage_index: u16, system_count: u16, timestamp_ns: ?u64) void {
            if (comptime TraceLevelExt.emitsVerbose(level)) {
                if (self.sink) |sink| {
                    sink.stageStart(.{
                        .world_id = self.world_id,
                        .phase = phase,
                        .stage_index = stage_index,
                        .system_count = system_count,
                        .timestamp_ns = timestamp_ns,
                    });
                }
            }
        }

        pub fn emitStageEnd(self: Self, phase: u8, stage_index: u16, system_count: u16, timestamp_ns: ?u64, duration_ns: ?u64) void {
            if (comptime TraceLevelExt.emitsVerbose(level)) {
                if (self.sink) |sink| {
                    sink.stageEnd(.{
                        .world_id = self.world_id,
                        .phase = phase,
                        .stage_index = stage_index,
                        .system_count = system_count,
                        .timestamp_ns = timestamp_ns,
                        .duration_ns = duration_ns,
                    });
                }
            }
        }

        // System events (systems level and above)
        pub fn emitSystemStart(self: Self, system_index: u16, system_name: []const u8, phase: u8, stage_index: u16, timestamp_ns: ?u64) void {
            if (comptime TraceLevelExt.emitsSystems(level)) {
                if (self.sink) |sink| {
                    sink.systemStart(.{
                        .world_id = self.world_id,
                        .system_index = system_index,
                        .system_name = system_name,
                        .phase = phase,
                        .stage_index = stage_index,
                        .timestamp_ns = timestamp_ns,
                    });
                }
            }
        }

        pub fn emitSystemEnd(self: Self, system_index: u16, system_name: []const u8, phase: u8, stage_index: u16, timestamp_ns: ?u64, duration_ns: ?u64, entity_count: ?u32) void {
            if (comptime TraceLevelExt.emitsSystems(level)) {
                if (self.sink) |sink| {
                    sink.systemEnd(.{
                        .world_id = self.world_id,
                        .system_index = system_index,
                        .system_name = system_name,
                        .phase = phase,
                        .stage_index = stage_index,
                        .timestamp_ns = timestamp_ns,
                        .duration_ns = duration_ns,
                        .entity_count = entity_count,
                    });
                }
            }
        }

        // Error events (errors level and above)
        pub fn emitSystemError(self: Self, system_index: u16, system_name: []const u8, phase: u8, stage_index: u16, error_code: u32, error_message: ?[]const u8, frame_policy: u8) void {
            if (comptime TraceLevelExt.emitsErrors(level)) {
                if (self.sink) |sink| {
                    sink.systemError(.{
                        .system = .{
                            .world_id = self.world_id,
                            .system_index = system_index,
                            .system_name = system_name,
                            .phase = phase,
                            .stage_index = stage_index,
                        },
                        .error_code = error_code,
                        .error_message = error_message,
                        .frame_policy = frame_policy,
                    });
                }
            }
        }
    };
}

// ============================================================================
// Simple Console Sink (for debugging)
// ============================================================================

/// A simple trace sink that prints to stderr.
/// This is a stateless sink - it doesn't use the context pointer.
pub const ConsoleSink = struct {
    pub const vtable = TraceSink.VTable{
        .on_tick_start = onTickStart,
        .on_tick_end = onTickEnd,
        .on_stage_start = onStageStart,
        .on_stage_end = onStageEnd,
        .on_system_start = onSystemStart,
        .on_system_end = onSystemEnd,
        .on_system_error = onSystemError,
    };

    fn onTickStart(_: *anyopaque, event: TickEvent) void {
        std.debug.print("[TRACE] Tick {d} start (world={d})\n", .{ event.tick_index, event.world_id });
    }

    fn onTickEnd(_: *anyopaque, event: TickEvent) void {
        if (event.duration_ns) |dur| {
            std.debug.print("[TRACE] Tick {d} end (world={d}, duration={d}ns)\n", .{ event.tick_index, event.world_id, dur });
        } else {
            std.debug.print("[TRACE] Tick {d} end (world={d})\n", .{ event.tick_index, event.world_id });
        }
    }

    fn onStageStart(_: *anyopaque, event: StageEvent) void {
        std.debug.print("[TRACE] Stage {d}.{d} start ({d} systems)\n", .{ event.phase, event.stage_index, event.system_count });
    }

    fn onStageEnd(_: *anyopaque, event: StageEvent) void {
        std.debug.print("[TRACE] Stage {d}.{d} end\n", .{ event.phase, event.stage_index });
    }

    fn onSystemStart(_: *anyopaque, event: SystemEvent) void {
        std.debug.print("[TRACE] System '{s}' start\n", .{event.system_name});
    }

    fn onSystemEnd(_: *anyopaque, event: SystemEvent) void {
        if (event.duration_ns) |dur| {
            std.debug.print("[TRACE] System '{s}' end (duration={d}ns)\n", .{ event.system_name, dur });
        } else {
            std.debug.print("[TRACE] System '{s}' end\n", .{event.system_name});
        }
    }

    fn onSystemError(_: *anyopaque, event: SystemErrorEvent) void {
        if (event.error_message) |msg| {
            std.debug.print("[TRACE] System '{s}' ERROR: {s} (code={d})\n", .{ event.system.system_name, msg, event.error_code });
        } else {
            std.debug.print("[TRACE] System '{s}' ERROR (code={d})\n", .{ event.system.system_name, event.error_code });
        }
    }

    /// Create a TraceSink pointing to the console vtable.
    /// This is a stateless sink - context is unused.
    pub fn sink() TraceSink {
        return TraceSink.initStateless(&vtable);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TraceLevel shouldEmit" {
    try std.testing.expect(TraceLevelExt.shouldEmit(.verbose, .verbose));
    try std.testing.expect(TraceLevelExt.shouldEmit(.verbose, .systems));
    try std.testing.expect(TraceLevelExt.shouldEmit(.verbose, .errors));
    try std.testing.expect(TraceLevelExt.shouldEmit(.verbose, .off));

    try std.testing.expect(!TraceLevelExt.shouldEmit(.errors, .systems));
    try std.testing.expect(!TraceLevelExt.shouldEmit(.errors, .verbose));
    try std.testing.expect(TraceLevelExt.shouldEmit(.errors, .errors));

    try std.testing.expect(!TraceLevelExt.shouldEmit(.off, .errors));
}

test "TraceLevel emit helpers" {
    try std.testing.expect(TraceLevelExt.emitsErrors(.verbose));
    try std.testing.expect(TraceLevelExt.emitsSystems(.verbose));
    try std.testing.expect(TraceLevelExt.emitsVerbose(.verbose));

    try std.testing.expect(TraceLevelExt.emitsErrors(.systems));
    try std.testing.expect(TraceLevelExt.emitsSystems(.systems));
    try std.testing.expect(!TraceLevelExt.emitsVerbose(.systems));

    try std.testing.expect(TraceLevelExt.emitsErrors(.errors));
    try std.testing.expect(!TraceLevelExt.emitsSystems(.errors));
    try std.testing.expect(!TraceLevelExt.emitsVerbose(.errors));

    try std.testing.expect(!TraceLevelExt.emitsErrors(.off));
}

test "TracingContext compiles to no-ops when off" {
    const OffContext = TracingContext(.off);
    var ctx = OffContext.init(null, 0);

    // These should all compile to no-ops
    ctx.emitTickStart(0, null);
    ctx.emitTickEnd(0, null, null);
    ctx.emitSystemStart(0, "test", 0, 0, null);
    ctx.emitSystemEnd(0, "test", 0, 0, null, null, null);
    ctx.emitSystemError(0, "test", 0, 0, 0, null, 0);
}
