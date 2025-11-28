//! StaticECS Configuration Types
//!
//! This module re-exports from the config/ directory for backwards compatibility.
//! See config/mod.zig for the modular implementation.
//!
//! ## Module Organization
//!
//! Configuration types are now organized into:
//! - `config/core_types.zig`: Phase, execution model, parallelism enums
//! - `config/policy_types.zig`: Runtime error handling policies
//! - `config/tracing_types.zig`: Tracing level and sink configuration
//! - `config/definition_types.zig`: Archetype and system definitions
//! - `config/spec_types.zig`: Components, systems, schedule specifications
//! - `config/backend_config.zig`: Scheduler backend configurations
//! - `config/pipeline_config.zig`: Entity flow pipeline modes
//! - `config/scalability_config.zig`: NUMA, huge pages, affinity, clustering
//! - `config/coordination_config.zig`: Multi-world coordination
//! - `config/world_config.zig`: Central WorldConfig struct
//! - `config/world_config_view.zig`: Stable read-only accessor
//! - `config/validation.zig`: Compile-time validation functions

const std = @import("std");

// Import the modular config
const config_mod = @import("config/mod.zig");

// ============================================================================
// Core Types (Phase, Execution, Parallelism)
// ============================================================================

pub const PhaseDef = config_mod.PhaseDef;
pub const DEFAULT_PHASES = config_mod.DEFAULT_PHASES;
pub const Phase = config_mod.Phase;
pub const AsynchronyKind = config_mod.AsynchronyKind;
pub const ParallelismMode = config_mod.ParallelismMode;
pub const ExecutionModel = config_mod.ExecutionModel;
pub const TickMode = config_mod.TickMode;
pub const LayoutMode = config_mod.LayoutMode;

// ============================================================================
// Policy Types (Error Handling)
// ============================================================================

pub const InvariantPolicy = config_mod.InvariantPolicy;
pub const InitPolicy = config_mod.InitPolicy;
pub const FramePolicy = config_mod.FramePolicy;
pub const RuntimePolicy = config_mod.RuntimePolicy;

// ============================================================================
// Tracing Types
// ============================================================================

pub const TraceLevel = config_mod.TraceLevel;
pub const TraceSink = config_mod.TraceSink;
pub const TracingSpec = config_mod.TracingSpec;

// ============================================================================
// Definition Types (Archetype, System)
// ============================================================================

pub const ArchetypeDef = config_mod.ArchetypeDef;
pub const SystemDef = config_mod.SystemDef;
pub const asSystemFn = config_mod.asSystemFn;

// ============================================================================
// Spec Types (Components, Systems, Schedule)
// ============================================================================

pub const ComponentsSpec = config_mod.ComponentsSpec;
pub const ArchetypesSpec = config_mod.ArchetypesSpec;
pub const SystemsSpec = config_mod.SystemsSpec;
pub const ScheduleSpec = config_mod.ScheduleSpec;
pub const TickSpec = config_mod.TickSpec;
pub const ResourcesSpec = config_mod.ResourcesSpec;
pub const PhasesSpec = config_mod.PhasesSpec;
pub const Options = config_mod.Options;

// ============================================================================
// Backend Configuration
// ============================================================================

pub const BackendConfig = config_mod.BackendConfig;
pub const IoUringBatchConfig = config_mod.IoUringBatchConfig;
pub const WorkStealingConfig = config_mod.WorkStealingConfig;
pub const AdaptiveConfig = config_mod.AdaptiveConfig;

// ============================================================================
// Pipeline Configuration
// ============================================================================

pub const PipelineMode = config_mod.PipelineMode;
pub const ExternalPipelineConfig = config_mod.ExternalPipelineConfig;
pub const DefaultFastPathPredicate = config_mod.DefaultFastPathPredicate;
pub const HybridPipelineConfig = config_mod.HybridPipelineConfig;
pub const PipelineConfig = config_mod.PipelineConfig;

// ============================================================================
// Scalability Configuration
// ============================================================================

pub const NumaConfig = config_mod.NumaConfig;
pub const HugePageConfig = config_mod.HugePageConfig;
pub const AffinityConfig = config_mod.AffinityConfig;
pub const ClusterConfig = config_mod.ClusterConfig;
pub const ScalabilityConfig = config_mod.ScalabilityConfig;

// ============================================================================
// Coordination Configuration
// ============================================================================

pub const WorldRole = config_mod.WorldRole;
pub const TransferQueueConfig = config_mod.TransferQueueConfig;
pub const ComponentRoute = config_mod.ComponentRoute;
pub const RoutingConfig = config_mod.RoutingConfig;
pub const WorldCoordinationConfig = config_mod.WorldCoordinationConfig;

// ============================================================================
// WorldConfig and View
// ============================================================================

pub const WorldConfig = config_mod.WorldConfig;
pub const WorldConfigView = config_mod.WorldConfigView;

// ============================================================================
// Validation
// ============================================================================

pub const ConfigValidationError = config_mod.ConfigValidationError;
pub const validateWorldConfig = config_mod.validateWorldConfig;
pub const validatePipelineConfig = config_mod.validatePipelineConfig;
pub const validateCoordinationConfig = config_mod.validateCoordinationConfig;
pub const validateScalabilityConfig = config_mod.validateScalabilityConfig;
pub const validateSchedulerConfig = config_mod.validateSchedulerConfig;
pub const componentInSpec = config_mod.componentInSpec;
pub const componentSetsEqual = config_mod.componentSetsEqual;

// ============================================================================
// Tests - Reference the tests in mod.zig
// ============================================================================

test {
    _ = config_mod;
}
