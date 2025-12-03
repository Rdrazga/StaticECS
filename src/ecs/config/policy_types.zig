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

// ============================================================================
// Generation Overflow Policy Types
// ============================================================================

/// Action to take when entity generation is about to wrap around.
/// This addresses EN-1 (generation wrap-around without tracking).
pub const GenerationWrapAction = enum {
    /// Silently wrap (current/legacy behavior, potentially unsafe).
    /// Use only when wrap risk is acceptable and tracking is handled externally.
    silent_wrap,

    /// Log a warning and wrap. Useful for production monitoring.
    log_and_wrap,

    /// Panic in debug builds, log in release. Default for safety-first development.
    debug_panic,

    /// Always panic on wrap. Use when generation collision is unacceptable.
    always_panic,
};

/// GenerationPolicy governs how the ECS handles entity generation lifecycle.
/// Addresses EN-1 (wrap-around tracking) and EN-3 (near-overflow assertion).
///
/// Tiger Style:
/// - Fail-fast in debug (debug_panic default)
/// - Configurable thresholds for early warning
/// - Observable via stats tracking
pub const GenerationPolicy = struct {
    /// Action when generation counter wraps from max back to 0.
    on_wrap: GenerationWrapAction = .debug_panic,

    /// Fraction of max_generation that triggers warning (0.0-1.0).
    /// At this threshold, a warning is logged in debug builds.
    /// Set to 1.0 to disable pre-wrap warnings.
    /// Default 0.9 = warn at 90% of max generation.
    warn_threshold: f32 = 0.9,

    /// Enable tracking of generation statistics.
    /// When true, EntityManager tracks epoch count, max generation seen, etc.
    /// Small overhead but useful for monitoring in long-running applications.
    enable_stats: bool = true,

    /// Compute the warning threshold as an absolute generation value.
    /// Returns the generation number at which warnings should trigger.
    pub fn computeWarnThreshold(self: GenerationPolicy, comptime max_gen: u32) u32 {
        if (self.warn_threshold >= 1.0) return max_gen;
        if (self.warn_threshold <= 0.0) return 0;
        const threshold_float = @as(f32, @floatFromInt(max_gen)) * self.warn_threshold;
        return @intFromFloat(threshold_float);
    }
};
