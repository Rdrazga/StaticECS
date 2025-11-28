//! Runtime policy types for StaticECS configuration.
//!
//! This module defines policies that govern how the ECS runtime handles:
//! - Internal invariant violations
//! - Initialization and capability errors
//! - Per-frame execution errors

// ============================================================================
// Policy Types
// ============================================================================

/// InvariantPolicy governs how StaticECS reacts to internal invariant violations.
pub const InvariantPolicy = enum {
    /// Immediate fail-fast with contextual diagnostics.
    default,
    /// Minimal diagnostics before abort.
    fail_fast_minimal,
};

/// InitPolicy governs how initialization/Io-capability errors are surfaced.
pub const InitPolicy = enum {
    /// Fail initialization without panicking, return error describing first failure.
    default,
    /// Aggregate and report multiple capability issues before failing.
    aggregate_and_fail,
};

/// FramePolicy governs how per-frame system execution errors are handled.
pub const FramePolicy = enum {
    /// First error wins: stop executing, return error without panicking.
    default,
    /// Run all systems, collect all errors, return aggregate report.
    aggregate,
};

/// RuntimePolicy groups all runtime error-handling policies.
/// Embedded in WorldConfig as the `policies` field.
pub const RuntimePolicy = struct {
    invariants: InvariantPolicy = .default,
    init: InitPolicy = .default,
    frame: FramePolicy = .default,
};
