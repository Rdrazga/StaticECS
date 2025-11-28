//! Central WorldConfig type for StaticECS.
//!
//! WorldConfig is the single source of truth for a world's architecture,
//! describing components, archetypes, systems, scheduling, tick behavior,
//! and runtime policies.

const spec = @import("spec_types.zig");
const policy = @import("policy_types.zig");
const tracing = @import("tracing_types.zig");
const coordination = @import("coordination_config.zig");
const pipeline = @import("pipeline_config.zig");
const scalability = @import("scalability_config.zig");

// Re-export types used in WorldConfig fields
pub const ComponentsSpec = spec.ComponentsSpec;
pub const ArchetypesSpec = spec.ArchetypesSpec;
pub const SystemsSpec = spec.SystemsSpec;
pub const ResourcesSpec = spec.ResourcesSpec;
pub const PhasesSpec = spec.PhasesSpec;
pub const ScheduleSpec = spec.ScheduleSpec;
pub const TickSpec = spec.TickSpec;
pub const Options = spec.Options;
pub const RuntimePolicy = policy.RuntimePolicy;
pub const TracingSpec = tracing.TracingSpec;
pub const WorldCoordinationConfig = coordination.WorldCoordinationConfig;
pub const WorldRole = coordination.WorldRole;
pub const PipelineConfig = pipeline.PipelineConfig;
pub const PipelineMode = pipeline.PipelineMode;
pub const ScalabilityConfig = scalability.ScalabilityConfig;

// ============================================================================
// WorldConfig - The Central Configuration Type
// ============================================================================

/// WorldConfig is the central compile-time description of a world.
/// It aggregates all configuration segments into a single structure.
pub const WorldConfig = struct {
    components: ComponentsSpec = .{},
    archetypes: ArchetypesSpec = .{},
    systems: SystemsSpec = .{},
    resources: ResourcesSpec = .{},
    phases: PhasesSpec = .{},
    schedule: ScheduleSpec = .{},
    tick: TickSpec = .{},
    options: Options = .{},
    policies: RuntimePolicy = .{},
    tracing: TracingSpec = .{},
    /// Multi-world coordination settings.
    /// Only used when role != .standalone.
    coordination: WorldCoordinationConfig = .{},
    /// Pipeline configuration for entity flow control.
    /// Controls internal/external/hybrid processing modes.
    pipeline: PipelineConfig = .{},
    /// Scalability settings for vertical and horizontal scaling.
    /// Controls NUMA, huge pages, affinity, and clustering.
    scalability: ScalabilityConfig = .{},

    /// Returns the number of component types in this config.
    pub fn componentCount(self: WorldConfig) usize {
        return self.components.types.len;
    }

    /// Returns the number of archetypes in this config.
    pub fn archetypeCount(self: WorldConfig) usize {
        return self.archetypes.archetypes.len;
    }

    /// Returns the number of systems in this config.
    pub fn systemCount(self: WorldConfig) usize {
        return self.systems.systems.len;
    }

    /// Returns the number of resource types in this config.
    pub fn resourceCount(self: WorldConfig) usize {
        return self.resources.types.len;
    }

    /// Returns the number of phases in this config.
    pub fn phaseCount(self: WorldConfig) usize {
        return self.phases.phases.len;
    }

    /// Returns whether this world participates in multi-world coordination.
    pub fn isCoordinated(self: WorldConfig) bool {
        return self.coordination.role != .standalone;
    }

    /// Returns the world's role in multi-world coordination.
    pub fn worldRole(self: WorldConfig) WorldRole {
        return self.coordination.role;
    }

    /// Returns the pipeline mode for this world.
    pub fn pipelineMode(self: WorldConfig) PipelineMode {
        return self.pipeline.mode;
    }

    /// Returns whether this world uses external pipeline mode.
    pub fn isExternalPipeline(self: WorldConfig) bool {
        return self.pipeline.mode == .external;
    }

    /// Returns whether this world uses hybrid pipeline mode.
    pub fn isHybridPipeline(self: WorldConfig) bool {
        return self.pipeline.mode == .hybrid;
    }

    /// Returns whether any scalability features are enabled.
    pub fn hasScalabilityFeatures(self: WorldConfig) bool {
        return self.scalability.anyEnabled();
    }

    /// Returns whether NUMA allocation is enabled.
    pub fn wantsNuma(self: WorldConfig) bool {
        return self.scalability.wantsNuma();
    }

    /// Returns whether huge pages are enabled.
    pub fn wantsHugePages(self: WorldConfig) bool {
        return self.scalability.wantsHugePages();
    }

    /// Returns whether thread affinity is enabled.
    pub fn wantsAffinity(self: WorldConfig) bool {
        return self.scalability.wantsAffinity();
    }

    /// Returns whether cluster mode is enabled.
    pub fn wantsCluster(self: WorldConfig) bool {
        return self.scalability.wantsCluster();
    }

    /// Returns the cluster node ID (0 if not in cluster mode).
    pub fn clusterNodeId(self: WorldConfig) u16 {
        return self.scalability.cluster.node_id;
    }
};
