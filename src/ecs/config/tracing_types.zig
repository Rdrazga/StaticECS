//! Tracing configuration types for StaticECS.
//!
//! This module defines tracing-related types:
//! - Trace levels for controlling emission verbosity
//! - Trace sinks for custom trace consumers
//! - TracingSpec for world-level configuration

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

/// TraceSink is an opaque pointer to a user-provided trace consumer.
/// The actual structure is defined in trace/tracing.zig.
pub const TraceSink = *const anyopaque;

/// TracingSpec configures tracing behavior for a world.
pub const TracingSpec = struct {
    level: TraceLevel = .off,
    sink: ?TraceSink = null,
};
