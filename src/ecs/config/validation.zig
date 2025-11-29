//! Configuration validation for StaticECS.
//!
//! This module provides compile-time validation functions for WorldConfig
//! and its sub-configurations. Validation is performed at compile time
//! with informative error messages.

const std = @import("std");
const builtin = @import("builtin");

const world_config = @import("world_config.zig");
const spec = @import("spec_types.zig");
const pipeline = @import("pipeline_config.zig");
const coordination = @import("coordination_config.zig");
const scalability = @import("scalability_config.zig");
const backend = @import("backend_config.zig");

// Re-export types used in public API
pub const WorldConfig = world_config.WorldConfig;
pub const ComponentsSpec = spec.ComponentsSpec;
pub const PipelineConfig = pipeline.PipelineConfig;
pub const WorldCoordinationConfig = coordination.WorldCoordinationConfig;
pub const ScalabilityConfig = scalability.ScalabilityConfig;
pub const BackendConfig = backend.BackendConfig;
pub const ExecutionModel = backend.ExecutionModel;

// ============================================================================
// Main Validation Function
// ============================================================================

/// Validates all aspects of WorldConfig at compile time.
/// Master validation function - coordinates sub-validators.
/// Emits @compileError on invalid configurations.
pub fn validateWorldConfig(comptime cfg: WorldConfig) void {
    // Core configuration validation
    validateEntityConfig(cfg);
    validatePhaseConfig(cfg);
    validateScheduleConfig(cfg);
    validateComponentRefs(cfg);

    // Sub-configuration validation (conditional)
    if (cfg.coordination.role != .standalone) {
        validateCoordinationConfig(cfg.coordination);
    }
    validatePipelineConfig(cfg.pipeline);
    if (cfg.scalability.anyEnabled()) {
        validateScalabilityConfig(cfg.scalability);
    }
    validateBackendConfig(cfg.schedule.execution_model, cfg.schedule.backend_config);
}

// ============================================================================
// Core Validation Sub-Functions
// ============================================================================

/// Validates entity limits and ID configuration.
/// Checks entity_index_bits range and max_entities bounds.
fn validateEntityConfig(comptime cfg: WorldConfig) void {
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
}

/// Validates execution phases configuration.
/// Ensures at least one phase exists and count is within limits.
fn validatePhaseConfig(comptime cfg: WorldConfig) void {
    if (cfg.phases.phases.len == 0) {
        @compileError("WorldConfig: at least one phase must be defined");
    }
    if (cfg.phases.phases.len > cfg.options.max_phases) {
        @compileError("WorldConfig: phase count exceeds max_phases option");
    }
}

/// Validates scheduling mode configuration.
/// Checks layout_mode and tick_mode consistency.
fn validateScheduleConfig(comptime cfg: WorldConfig) void {
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
}

/// Validates component type references in archetypes and systems.
/// Ensures all referenced components exist in ComponentsSpec,
/// validates system phase indices, and checks for duplicate archetypes.
fn validateComponentRefs(comptime cfg: WorldConfig) void {
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

/// Validates backend-specific configuration at compile time.
/// Ensures execution_model and backend_config are consistent, and validates
/// platform requirements and parameter bounds.
pub fn validateBackendConfig(comptime execution_model: ExecutionModel, comptime backend_cfg: BackendConfig) void {
    // 1. Platform validation: io_uring is Linux-only
    if (execution_model == .io_uring_batch) {
        if (builtin.target.os.tag != .linux) {
            @compileError("io_uring_batch execution model is only available on Linux");
        }
    }

    // 2. Execution model / backend config consistency
    switch (execution_model) {
        .blocking_single_thread, .evented_single_thread, .concurrent_threadpool => {
            // These models should use .none backend config or be validated loosely
            // No strict requirement - allow any backend_config (may be ignored)
        },
        .io_uring_batch => {
            // Validate io_uring specific config when provided
            if (backend_cfg == .io_uring_batch) {
                const io_cfg = backend_cfg.io_uring_batch;
                // sq_entries must be power of 2
                if (!std.math.isPowerOfTwo(io_cfg.sq_entries)) {
                    @compileError("io_uring_batch: sq_entries must be power of 2");
                }
                // cq_entries must be power of 2
                if (!std.math.isPowerOfTwo(io_cfg.cq_entries)) {
                    @compileError("io_uring_batch: cq_entries must be power of 2");
                }
                // cq_entries should be >= sq_entries
                if (io_cfg.cq_entries < io_cfg.sq_entries) {
                    @compileError("io_uring_batch: cq_entries should be >= sq_entries");
                }
                // batch_size must be positive and <= sq_entries
                if (io_cfg.batch_size == 0) {
                    @compileError("io_uring_batch: batch_size must be at least 1");
                }
                if (io_cfg.batch_size > io_cfg.sq_entries) {
                    @compileError("io_uring_batch: batch_size exceeds sq_entries");
                }
            }
        },
        .work_stealing => {
            // Validate work_stealing specific config when provided
            if (backend_cfg == .work_stealing) {
                const ws_cfg = backend_cfg.work_stealing;
                // local_queue_size must be power of 2
                if (!std.math.isPowerOfTwo(ws_cfg.local_queue_size)) {
                    @compileError("work_stealing: local_queue_size must be power of 2");
                }
                // worker_count has reasonable max (0 = auto-detect is valid)
                if (ws_cfg.worker_count > 256) {
                    @compileError("work_stealing: worker_count maximum is 256");
                }
                // steal_batch should not exceed local_queue_size
                if (ws_cfg.steal_batch > ws_cfg.local_queue_size) {
                    @compileError("work_stealing: steal_batch exceeds local_queue_size");
                }
            }
        },
        .adaptive_hybrid => {
            // Validate adaptive specific config when provided
            if (backend_cfg == .adaptive) {
                const adapt_cfg = backend_cfg.adaptive;
                // batch_threshold must be positive
                if (adapt_cfg.batch_threshold == 0) {
                    @compileError("adaptive: batch_threshold must be at least 1");
                }
                // imbalance_threshold must be in (0, 1)
                if (adapt_cfg.imbalance_threshold <= 0.0 or adapt_cfg.imbalance_threshold >= 1.0) {
                    @compileError("adaptive: imbalance_threshold must be between 0 and 1 (exclusive)");
                }
                // window_size must be positive
                if (adapt_cfg.window_size == 0) {
                    @compileError("adaptive: window_size must be at least 1");
                }
                // switch_cooldown must be less than window_size to be meaningful
                if (adapt_cfg.switch_cooldown >= adapt_cfg.window_size) {
                    @compileError("adaptive: switch_cooldown should be less than window_size");
                }
                // Validate initial_backend if specified
                if (adapt_cfg.initial_backend) |initial| {
                    // initial_backend should not be adaptive_hybrid (recursive)
                    if (initial == .adaptive_hybrid) {
                        @compileError("adaptive: initial_backend cannot be adaptive_hybrid");
                    }
                    // initial_backend io_uring requires Linux
                    if (initial == .io_uring_batch and builtin.target.os.tag != .linux) {
                        @compileError("adaptive: initial_backend io_uring_batch requires Linux");
                    }
                }
            }
        },
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
