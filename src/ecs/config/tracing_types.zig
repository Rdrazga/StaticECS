//! Tracing configuration types for StaticECS.
//!
//! This module defines tracing-related types used in WorldConfig:
//! - `TraceLevel` - controls trace emission verbosity (off/errors/systems/verbose)
//! - `TraceSinkPtr` - forward declaration for trace sink pointers
//! - `TracingSpec` - world-level tracing configuration
//!
//! ## Forward Declaration Pattern
//!
//! This module uses a forward declaration pattern for TraceSink to avoid
//! circular dependencies between configuration and implementation:
//!
//! ```
//! WorldConfig (config/)           TraceSink (trace/)
//!     │                               │
//!     └── TracingSpec                 └── Full implementation with VTable
//!            │                              │
//!            └── TraceSinkPtr ────────────→│ (cast at runtime)
//!                 (opaque pointer)
//! ```
//!
//! **Why forward declaration?**
//! - Configuration is compile-time and should be self-contained
//! - TraceSink depends on event types (TickEvent, SystemEvent, etc.)
//! - Separating config from runtime implementation enables clean module boundaries
//!
//! **Usage pattern:**
//! ```zig
//! // At configuration time (compile-time):
//! const config = WorldConfig{
//!     .tracing = .{
//!         .level = .systems,
//!         .sink = @ptrCast(&my_sink),  // Cast TraceSink* to TraceSinkPtr
//!     },
//! };
//!
//! // At runtime, cast back:
//! const sink: *const TraceSink = @ptrCast(@alignCast(config.tracing.sink));
//! sink.systemStart(event);
//! ```
//!
//! ## Related Modules
//! - `trace/tracing.zig` - Full TraceSink implementation, event types, TracingContext

const core = @import("core_types.zig");

// Re-export TypedContext for trace sink implementations.
// TypedContext provides debug-mode type verification for opaque pointers.
pub const TypedContext = core.TypedContext;

// ============================================================================
// Tracing Types
// ============================================================================

/// TraceLevel controls how much tracing data is emitted.
/// Uses u8 backing type for compatibility with tracing module.
pub const TraceLevel = enum(u8) {
    /// No tracing; all emission sites compile to no-ops.
    off = 0,
    /// Only error-related events are emitted.
    errors = 1,
    /// System start/end events plus errors.
    systems = 2,
    /// Verbose: all supported event types.
    verbose = 3,
};

/// TraceSinkPtr is the configuration-time reference to a trace sink.
///
/// This is a forward declaration (opaque pointer) to `trace.TraceSink`.
/// The indirection exists to avoid circular dependencies between:
/// - Configuration types (this module, loaded at compile-time for WorldConfig)
/// - Runtime implementation (trace/tracing.zig, with event types and VTable)
///
/// ## Lifecycle
///
/// 1. **Creation**: User creates a `TraceSink` in `trace/tracing.zig`
/// 2. **Configuration**: Cast `*TraceSink` to `TraceSinkPtr` for `TracingSpec`
/// 3. **Runtime**: Cast `TraceSinkPtr` back to `*TraceSink` when emitting events
///
/// ## Cast Pattern
/// ```zig
/// // Config time: TraceSink* → TraceSinkPtr
/// const spec = TracingSpec{
///     .level = .systems,
///     .sink = @ptrCast(&my_trace_sink),
/// };
///
/// // Runtime: TraceSinkPtr → TraceSink*
/// const sink: *const trace.TraceSink = @ptrCast(@alignCast(spec.sink.?));
/// ```
///
/// ## Why not use *const TraceSink directly?
///
/// `TraceSink` depends on event types (`TickEvent`, `SystemEvent`, etc.) which
/// would create a dependency cycle: config → tracing → config. The opaque
/// pointer breaks this cycle while preserving type safety (at cast boundaries).
pub const TraceSinkPtr = *const anyopaque;

/// TracingSpec configures tracing behavior for a world.
///
/// Tracing is disabled by default (level = .off). When enabled, trace events
/// are emitted to the configured sink. If no sink is configured, events are
/// silently dropped.
///
/// ## Configuration Example
/// ```zig
/// const config = WorldConfig{
///     .tracing = .{
///         .level = .systems,  // Emit system start/end events
///         .sink = @ptrCast(&trace.ConsoleSink.vtable),  // Print to stderr
///     },
/// };
/// ```
///
/// ## Trace Levels (cumulative)
/// - `.off` - No tracing; all emission sites compile to no-ops
/// - `.errors` - Only error events (system failures)
/// - `.systems` - System start/end + errors
/// - `.verbose` - All events (tick, stage, system, errors)
pub const TracingSpec = struct {
    /// Trace verbosity level. Higher levels include all lower events.
    level: TraceLevel = .off,
    /// Optional trace sink pointer. Cast to `trace.TraceSink` at runtime.
    /// When null and level != .off, trace events are silently dropped.
    /// The TraceSink struct uses TypedContext for type-safe VTable callbacks.
    sink: ?TraceSinkPtr = null,
};

// ============================================================================
// Deprecated: Legacy TraceSink alias
// ============================================================================

/// @deprecated Use TraceSinkPtr for configuration, or trace.TraceSink for implementation.
/// This alias maintained for backward compatibility.
pub const TraceSink = TraceSinkPtr;
