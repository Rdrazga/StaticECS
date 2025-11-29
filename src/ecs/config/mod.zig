//! StaticECS Configuration Types
//!
//! This module defines the central `WorldConfig` type and all its sub-structs.
//! WorldConfig is the single source of truth for a world's architecture,
//! describing components, archetypes, systems, scheduling, tick behavior,
//! and runtime policies.
//!
//! ## Module Organization
//!
//! The configuration types are organized into logical groups:
//! - `core_types`: Phase, execution model, parallelism enums
//! - `policy_types`: Runtime error handling policies
//! - `tracing_types`: Tracing level and sink configuration
//! - `definition_types`: Archetype and system definitions
//! - `spec_types`: Components, systems, schedule specifications
//! - `backend_config`: Scheduler backend configurations
//! - `pipeline_config`: Entity flow pipeline modes
//! - `scalability_config`: NUMA, huge pages, affinity, clustering
//! - `coordination_config`: Multi-world coordination
//! - `world_config`: Central WorldConfig struct
//! - `world_config_view`: Stable read-only accessor
//! - `validation`: Compile-time validation functions

const std = @import("std");

// ============================================================================
// Core Types (Phase, Execution, Parallelism)
// ============================================================================

pub const core_types = @import("core_types.zig");

pub const PhaseDef = core_types.PhaseDef;
pub const DEFAULT_PHASES = core_types.DEFAULT_PHASES;
pub const Phase = core_types.Phase;
pub const AsynchronyKind = core_types.AsynchronyKind;
pub const ParallelismMode = core_types.ParallelismMode;
pub const ExecutionModel = core_types.ExecutionModel;
pub const TickMode = core_types.TickMode;
pub const LayoutMode = core_types.LayoutMode;
pub const CapacityMode = core_types.CapacityMode;

// ============================================================================
// Policy Types (Error Handling)
// ============================================================================

pub const policy_types = @import("policy_types.zig");

pub const InvariantPolicy = policy_types.InvariantPolicy;
pub const InitPolicy = policy_types.InitPolicy;
pub const FramePolicy = policy_types.FramePolicy;
pub const RuntimePolicy = policy_types.RuntimePolicy;

// ============================================================================
// Tracing Types
// ============================================================================

pub const tracing_types = @import("tracing_types.zig");

pub const TraceLevel = tracing_types.TraceLevel;
pub const TraceSink = tracing_types.TraceSink;
pub const TracingSpec = tracing_types.TracingSpec;

// ============================================================================
// Definition Types (Archetype, System)
// ============================================================================

pub const definition_types = @import("definition_types.zig");

pub const ArchetypeDef = definition_types.ArchetypeDef;
pub const SystemDef = definition_types.SystemDef;
pub const asSystemFn = definition_types.asSystemFn;

// ============================================================================
// Spec Types (Components, Systems, Schedule)
// ============================================================================

pub const spec_types = @import("spec_types.zig");

pub const ComponentsSpec = spec_types.ComponentsSpec;
pub const ArchetypesSpec = spec_types.ArchetypesSpec;
pub const SystemsSpec = spec_types.SystemsSpec;
pub const ScheduleSpec = spec_types.ScheduleSpec;
pub const TickSpec = spec_types.TickSpec;
pub const ResourcesSpec = spec_types.ResourcesSpec;
pub const PhasesSpec = spec_types.PhasesSpec;
pub const Options = spec_types.Options;

// ============================================================================
// Backend Configuration
// ============================================================================

pub const backend_config = @import("backend_config.zig");

pub const BackendConfig = backend_config.BackendConfig;
pub const IoUringBatchConfig = backend_config.IoUringBatchConfig;
pub const WorkStealingConfig = backend_config.WorkStealingConfig;
pub const AdaptiveConfig = backend_config.AdaptiveConfig;

// ============================================================================
// Pipeline Configuration
// ============================================================================

pub const pipeline_config = @import("pipeline_config.zig");

pub const PipelineMode = pipeline_config.PipelineMode;
pub const ExternalPipelineConfig = pipeline_config.ExternalPipelineConfig;
pub const DefaultFastPathPredicate = pipeline_config.DefaultFastPathPredicate;
pub const HybridPipelineConfig = pipeline_config.HybridPipelineConfig;
pub const PipelineConfig = pipeline_config.PipelineConfig;

// ============================================================================
// Scalability Configuration
// ============================================================================

pub const scalability_config = @import("scalability_config.zig");

pub const NumaConfig = scalability_config.NumaConfig;
pub const HugePageConfig = scalability_config.HugePageConfig;
pub const AffinityConfig = scalability_config.AffinityConfig;
pub const ClusterConfig = scalability_config.ClusterConfig;
pub const ScalabilityConfig = scalability_config.ScalabilityConfig;

// ============================================================================
// Coordination Configuration
// ============================================================================

pub const coordination_config = @import("coordination_config.zig");

pub const WorldRole = coordination_config.WorldRole;
pub const TransferQueueConfig = coordination_config.TransferQueueConfig;
pub const ComponentRoute = coordination_config.ComponentRoute;
pub const RoutingConfig = coordination_config.RoutingConfig;
pub const WorldCoordinationConfig = coordination_config.WorldCoordinationConfig;

// ============================================================================
// WorldConfig and View
// ============================================================================

pub const world_config_mod = @import("world_config.zig");
pub const world_config_view_mod = @import("world_config_view.zig");

pub const WorldConfig = world_config_mod.WorldConfig;
pub const WorldConfigView = world_config_view_mod.WorldConfigView;

// ============================================================================
// Validation
// ============================================================================

pub const validation = @import("validation.zig");

pub const validateWorldConfig = validation.validateWorldConfig;
pub const validatePipelineConfig = validation.validatePipelineConfig;
pub const validateCoordinationConfig = validation.validateCoordinationConfig;
pub const validateScalabilityConfig = validation.validateScalabilityConfig;
pub const validateSchedulerConfig = validation.validateSchedulerConfig;
pub const componentInSpec = validation.componentInSpec;
pub const componentSetsEqual = validation.componentSetsEqual;

// ============================================================================
// Tests (moved to mod_test.zig for better organization)
// ============================================================================

test {
    _ = @import("mod_test.zig");
}
