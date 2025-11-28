//! Configuration validation for StaticECS.
//!
//! This module provides compile-time validation functions for WorldConfig
//! and its sub-configurations. Validation is performed at compile time
//! with informative error messages.

const std = @import("std");

const world_config = @import("world_config.zig");
const spec = @import("spec_types.zig");
const pipeline = @import("pipeline_config.zig");
const coordination = @import("coordination_config.zig");
const scalability = @import("scalability_config.zig");

// Re-export types used in public API
pub const WorldConfig = world_config.WorldConfig;
pub const ComponentsSpec = spec.ComponentsSpec;
pub const PipelineConfig = pipeline.PipelineConfig;
pub const WorldCoordinationConfig = coordination.WorldCoordinationConfig;
pub const ScalabilityConfig = scalability.ScalabilityConfig;

// ============================================================================
// Validation Error Types
// ============================================================================

/// Validation error types for compile-time config checking.
pub const ConfigValidationError = error{
    /// Component referenced in archetype not found in ComponentsSpec.
    ComponentNotInSpec,
    /// Duplicate archetype definition (same component set).
    DuplicateArchetype,
    /// System references component not in ComponentsSpec.
    SystemComponentNotInSpec,
    /// Single archetype mode requires exactly one archetype.
    SingleArchetypeModeViolation,
    /// Invalid execution model for given asynchrony/parallelism combination.
    InvalidExecutionModelCombination,
    /// Fixed-rate tick mode requires target_hz to be set.
    FixedRateMissingHz,
    /// max_entities must be greater than zero.
    ZeroMaxEntities,
    /// Transfer queue capacity must be power of 2.
    TransferQueueCapacityNotPowerOfTwo,
    /// Transfer batch size exceeds queue capacity.
    TransferBatchSizeExceedsCapacity,
    /// Component route references invalid target world.
    InvalidRouteTarget,
};

// ============================================================================
// Main Validation Function
// ============================================================================

/// Validates a WorldConfig at compile time.
/// Emits @compileError on invalid configurations.
pub fn validateWorldConfig(comptime cfg: WorldConfig) void {
    // Validate entity_index_bits range [8, 24]
    if (cfg.options.entity_index_bits < 8 or cfg.options.entity_index_bits > 24) {
        @compileError("WorldConfig: entity_index_bits must be between 8 and 24 (inclusive)");
    }

    // Compute max possible index from bit width
    const max_index: u32 = (@as(u32, 1) << cfg.options.entity_index_bits) - 1;

    // Validate max_entities > 0
    if (cfg.options.max_entities == 0) {
        @compileError("WorldConfig: max_entities must be greater than zero");
    }

    // Validate max_entities fits in entity_index_bits
    if (cfg.options.max_entities > max_index) {
        @compileError("WorldConfig: max_entities exceeds capacity of entity_index_bits");
    }

    // Validate phases
    if (cfg.phases.phases.len == 0) {
        @compileError("WorldConfig: at least one phase must be defined");
    }
    if (cfg.phases.phases.len > cfg.options.max_phases) {
        @compileError("WorldConfig: phase count exceeds max_phases option");
    }

    // Validate single archetype mode
    if (cfg.options.layout_mode == .single_archetype) {
        if (cfg.archetypes.archetypes.len != 1) {
            @compileError("WorldConfig: single_archetype layout_mode requires exactly one archetype definition");
        }
    }

    // Validate fixed-rate tick mode
    if (cfg.tick.mode == .fixed_rate) {
        if (cfg.tick.target_hz == null) {
            @compileError("WorldConfig: fixed_rate tick mode requires target_hz to be set");
        }
    }

    // Validate archetype component references
    for (cfg.archetypes.archetypes) |arch| {
        for (arch.components) |comp| {
            if (!componentInSpec(cfg.components, comp)) {
                @compileError("WorldConfig: archetype '" ++ arch.name ++ "' references component not in ComponentsSpec");
            }
        }
    }

    // Validate system component references and phase indices
    const phase_count = cfg.phases.phases.len;
    for (cfg.systems.systems) |sys| {
        // Validate phase index
        if (sys.phase >= phase_count) {
            @compileError("WorldConfig: system '" ++ sys.name ++ "' references invalid phase index");
        }
        for (sys.read_components) |comp| {
            if (!componentInSpec(cfg.components, comp)) {
                @compileError("WorldConfig: system '" ++ sys.name ++ "' read_components references component not in ComponentsSpec");
            }
        }
        for (sys.write_components) |comp| {
            if (!componentInSpec(cfg.components, comp)) {
                @compileError("WorldConfig: system '" ++ sys.name ++ "' write_components references component not in ComponentsSpec");
            }
        }
    }

    // Validate no duplicate archetypes (same component sets)
    const archs = cfg.archetypes.archetypes;
    for (archs, 0..) |arch_a, i| {
        for (archs[i + 1 ..]) |arch_b| {
            if (componentSetsEqual(arch_a.components, arch_b.components)) {
                @compileError("WorldConfig: duplicate archetype definitions with same component set: '" ++ arch_a.name ++ "' and '" ++ arch_b.name ++ "'");
            }
        }
    }

    // Validate coordination config (only for coordinated worlds)
    if (cfg.coordination.role != .standalone) {
        validateCoordinationConfig(cfg.coordination);
    }

    // Validate pipeline config
    validatePipelineConfig(cfg.pipeline);

    // Validate scalability config (only when features are enabled)
    if (cfg.scalability.anyEnabled()) {
        validateScalabilityConfig(cfg.scalability);
    }
}

// ============================================================================
// Sub-Configuration Validation
// ============================================================================

/// Validates pipeline-specific configuration at compile time.
pub fn validatePipelineConfig(comptime pipeline_cfg: PipelineConfig) void {
    // Validate external mode settings
    if (pipeline_cfg.mode == .external or pipeline_cfg.mode == .hybrid) {
        // Batch size must be positive
        if (pipeline_cfg.external.batch_size == 0) {
            @compileError("WorldConfig: pipeline.external.batch_size must be at least 1");
        }

        // Buffer sizes must be positive
        if (pipeline_cfg.external.export_buffer_size == 0) {
            @compileError("WorldConfig: pipeline.external.export_buffer_size must be at least 1");
        }
        if (pipeline_cfg.external.import_buffer_size == 0) {
            @compileError("WorldConfig: pipeline.external.import_buffer_size must be at least 1");
        }
    }

    // Validate hybrid mode settings
    if (pipeline_cfg.mode == .hybrid) {
        // Fast-path capacity must be positive
        if (pipeline_cfg.hybrid.fast_path_capacity == 0) {
            @compileError("WorldConfig: pipeline.hybrid.fast_path_capacity must be at least 1");
        }

        // Verify predicate type has canFastPath method
        const PredicateType = pipeline_cfg.hybrid.fast_path_predicate_type;
        if (!@hasDecl(PredicateType, "canFastPath")) {
            @compileError("WorldConfig: pipeline.hybrid.fast_path_predicate_type must have canFastPath method");
        }
    }
}

/// Validates coordination-specific configuration at compile time.
pub fn validateCoordinationConfig(comptime coord: WorldCoordinationConfig) void {
    // Validate transfer queue capacity is power of 2
    if (!std.math.isPowerOfTwo(coord.transfer_queue.capacity)) {
        @compileError("WorldConfig: transfer_queue.capacity must be power of 2 for lock-free efficiency");
    }

    // Validate batch size doesn't exceed capacity
    if (coord.transfer_queue.batch_size > coord.transfer_queue.capacity) {
        @compileError("WorldConfig: transfer_queue.batch_size exceeds queue capacity");
    }

    // Validate batch size is reasonable (at least 1)
    if (coord.transfer_queue.batch_size == 0) {
        @compileError("WorldConfig: transfer_queue.batch_size must be at least 1");
    }
}

/// Validates scalability-specific configuration at compile time.
pub fn validateScalabilityConfig(comptime scale: ScalabilityConfig) void {
    // Validate cluster config
    if (scale.cluster.enabled) {
        // Node ID must be less than total instances
        if (scale.cluster.node_id >= scale.cluster.total_instances) {
            @compileError("WorldConfig: scalability.cluster.node_id must be less than total_instances");
        }

        // Total instances must be at least 1
        if (scale.cluster.total_instances == 0) {
            @compileError("WorldConfig: scalability.cluster.total_instances must be at least 1");
        }

        // Heartbeat interval must be positive
        if (scale.cluster.heartbeat_interval_ms == 0) {
            @compileError("WorldConfig: scalability.cluster.heartbeat_interval_ms must be at least 1");
        }

        // Peer timeout must be greater than heartbeat interval
        if (scale.cluster.peer_timeout_ms <= scale.cluster.heartbeat_interval_ms) {
            @compileError("WorldConfig: scalability.cluster.peer_timeout_ms must be greater than heartbeat_interval_ms");
        }
    }

    // Validate huge pages threshold is at least page size
    if (scale.huge_pages.enabled) {
        const page_size = @intFromEnum(scale.huge_pages.size);
        if (scale.huge_pages.threshold > 0 and scale.huge_pages.threshold < page_size) {
            @compileError("WorldConfig: scalability.huge_pages.threshold should be at least the page size");
        }
    }

    // Validate NUMA interleave config
    if (scale.numa.enabled and scale.numa.strategy == .interleave) {
        if (scale.numa.interleave.page_size == 0) {
            @compileError("WorldConfig: scalability.numa.interleave.page_size must be at least 1");
        }
    }
}

/// Validates scheduler-specific configuration at compile time.
pub fn validateSchedulerConfig(comptime cfg: WorldConfig) void {
    // First validate world config
    validateWorldConfig(cfg);

    // Validate execution model compatibility with system modes
    for (cfg.systems.systems) |sys| {
        // blocking_single_thread ignores parallelism hints, no validation needed
        // evented_single_thread: parallelism creates logical tasks but no true parallelism
        // concurrent_threadpool: full parallelism support

        // For blocking_single_thread, warn if parallelism is specified but won't be used
        // (This is informational, not an error - the config is still valid)

        // Validate that may_async is only used with compatible execution models
        if (sys.asynchrony == .may_async) {
            if (cfg.schedule.execution_model == .blocking_single_thread) {
                // This is valid but the async hint is ignored - no error
            }
        }
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Helper: check if a component type exists in ComponentsSpec.
pub fn componentInSpec(comptime spec_cfg: ComponentsSpec, comptime T: type) bool {
    inline for (spec_cfg.types) |comp| {
        if (comp == T) return true;
    }
    return false;
}

/// Helper: check if two component sets are equal (same types, order-independent).
pub fn componentSetsEqual(comptime a: []const type, comptime b: []const type) bool {
    if (a.len != b.len) return false;
    inline for (a) |ta| {
        var found = false;
        inline for (b) |tb| {
            if (ta == tb) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}
