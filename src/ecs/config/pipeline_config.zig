//! Pipeline configuration types for StaticECS (Phase 6).
//!
//! This module defines entity flow pipeline configurations:
//! - Internal: ECS manages entity lifecycle
//! - External: User manages entity flow with batch APIs
//! - Hybrid: Fast-path bypass for simple entities

// ============================================================================
// Pipeline Mode
// ============================================================================

/// Pipeline entity flow mode.
/// Determines how entities flow through processing stages.
/// Tiger Style: Mode selection at comptime enables zero-cost abstractions.
pub const PipelineMode = enum {
    /// ECS manages entity lifecycle internally.
    /// Entities flow through phases automatically.
    /// Best for: complex state machines, game-like processing.
    internal,

    /// User code manages entity flow externally.
    /// ECS provides batch import/export APIs.
    /// Best for: high-throughput pipelines, event streams.
    external,

    /// Hybrid mode with fast-path bypass.
    /// Simple entities bypass ECS, complex use full pipeline.
    /// Best for: HTTP servers, mixed workloads.
    hybrid,
};

// ============================================================================
// External Pipeline Configuration
// ============================================================================

/// External pipeline configuration.
/// Controls batch sizes and buffer capacities for external mode.
/// Tiger Style: All bounds configurable.
pub const ExternalPipelineConfig = struct {
    /// Maximum batch size for import/export operations.
    /// Default 256 balances memory usage with batching efficiency.
    batch_size: u32 = 256,

    /// Enable zero-copy imports when possible.
    /// When true, avoids copying component data during import.
    zero_copy: bool = true,

    /// Export buffer capacity (max entities buffered for export).
    /// Default 4096 allows high throughput.
    export_buffer_size: u32 = 4096,

    /// Import buffer capacity (max entities buffered for import).
    /// Default 4096 allows high throughput.
    import_buffer_size: u32 = 4096,
};

// ============================================================================
// Hybrid Pipeline Configuration
// ============================================================================

/// Default fast-path predicate that rejects all entities.
/// Users should provide their own predicate for actual fast-path logic.
pub const DefaultFastPathPredicate = struct {
    /// Returns true if entity data can use fast-path processing.
    /// Default implementation returns false (no fast-path).
    pub fn canFastPath(entity_data: anytype) bool {
        _ = entity_data;
        return false;
    }
};

/// Hybrid pipeline configuration.
/// Controls fast-path behavior and fallback settings.
/// Tiger Style: Predicate type is comptime for zero overhead when not matching.
pub const HybridPipelineConfig = struct {
    /// Fast-path predicate function type.
    /// Must have `fn canFastPath(data: anytype) bool` method.
    /// Default rejects all entities (no fast-path).
    fast_path_predicate_type: type = DefaultFastPathPredicate,

    /// Maximum entities in fast-path queue per tick.
    /// Default 1024 balances throughput with memory.
    fast_path_capacity: u32 = 1024,

    /// Fallback to ECS when fast-path queue is full.
    /// When false, returns error.FastPathFull instead.
    fallback_on_full: bool = true,
};

// ============================================================================
// Combined Pipeline Configuration
// ============================================================================

/// Pipeline configuration options.
/// Added to WorldConfig as the `pipeline` field.
/// Tiger Style: Zero overhead when using internal mode (default).
pub const PipelineConfig = struct {
    /// Pipeline mode selection.
    mode: PipelineMode = .internal,

    /// External mode settings (only used when mode == .external).
    external: ExternalPipelineConfig = .{},

    /// Hybrid mode settings (only used when mode == .hybrid).
    hybrid: HybridPipelineConfig = .{},
};
