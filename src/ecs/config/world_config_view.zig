//! Stable read-only view over WorldConfig for StaticECS.
//!
//! WorldConfigView provides a stable accessor interface over WorldConfig,
//! designed for better API stability when querying configuration values.

const world_config = @import("world_config.zig");
const core = @import("core_types.zig");
const tracing = @import("tracing_types.zig");
const coordination = @import("coordination_config.zig");
const pipeline = @import("pipeline_config.zig");

// Re-export types used in the public API
pub const WorldConfig = world_config.WorldConfig;
pub const LayoutMode = core.LayoutMode;
pub const TickMode = core.TickMode;
pub const ExecutionModel = core.ExecutionModel;
pub const TraceLevel = tracing.TraceLevel;
pub const WorldRole = coordination.WorldRole;
pub const PipelineMode = pipeline.PipelineMode;

// ============================================================================
// WorldConfigView - Stable Read-Only View
// ============================================================================

/// WorldConfigView provides a stable, read-only view over a WorldConfig.
/// Prefer using this over direct config access for better API stability.
pub const WorldConfigView = struct {
    config: WorldConfig,

    pub fn init(cfg: WorldConfig) WorldConfigView {
        return .{ .config = cfg };
    }

    /// Returns the layout mode from Options.
    pub fn layoutMode(self: WorldConfigView) LayoutMode {
        return self.config.options.layout_mode;
    }

    /// Returns the max entity count from Options.
    pub fn maxEntities(self: WorldConfigView) u32 {
        return self.config.options.max_entities;
    }

    /// Returns the tick mode from TickSpec.
    pub fn tickMode(self: WorldConfigView) TickMode {
        return self.config.tick.mode;
    }

    /// Returns the target tick frequency (if in fixed_rate mode).
    pub fn tickTargetHz(self: WorldConfigView) ?u32 {
        return self.config.tick.target_hz;
    }

    /// Returns the core version pin from Options.
    pub fn coreVersionPin(self: WorldConfigView) ?struct { major: u32, minor: u32, patch: u32 } {
        return self.config.options.core_version;
    }

    /// Returns the execution model from ScheduleSpec.
    pub fn executionModel(self: WorldConfigView) ExecutionModel {
        return self.config.schedule.execution_model;
    }

    /// Returns the trace level from TracingSpec.
    pub fn traceLevel(self: WorldConfigView) TraceLevel {
        return self.config.tracing.level;
    }

    /// Returns whether this world participates in multi-world coordination.
    pub fn isCoordinated(self: WorldConfigView) bool {
        return self.config.isCoordinated();
    }

    /// Returns the world's role in multi-world coordination.
    pub fn worldRole(self: WorldConfigView) WorldRole {
        return self.config.worldRole();
    }

    /// Returns the world's ID in a coordinator.
    pub fn worldId(self: WorldConfigView) u8 {
        return self.config.coordination.world_id;
    }

    /// Returns the pipeline mode for this world.
    pub fn pipelineMode(self: WorldConfigView) PipelineMode {
        return self.config.pipelineMode();
    }

    /// Returns whether this world uses external pipeline mode.
    pub fn isExternalPipeline(self: WorldConfigView) bool {
        return self.config.isExternalPipeline();
    }

    /// Returns whether this world uses hybrid pipeline mode.
    pub fn isHybridPipeline(self: WorldConfigView) bool {
        return self.config.isHybridPipeline();
    }

    /// Returns whether any scalability features are enabled.
    pub fn hasScalabilityFeatures(self: WorldConfigView) bool {
        return self.config.hasScalabilityFeatures();
    }

    /// Returns whether NUMA allocation is enabled.
    pub fn wantsNuma(self: WorldConfigView) bool {
        return self.config.wantsNuma();
    }

    /// Returns whether huge pages are enabled.
    pub fn wantsHugePages(self: WorldConfigView) bool {
        return self.config.wantsHugePages();
    }

    /// Returns whether thread affinity is enabled.
    pub fn wantsAffinity(self: WorldConfigView) bool {
        return self.config.wantsAffinity();
    }

    /// Returns whether cluster mode is enabled.
    pub fn wantsCluster(self: WorldConfigView) bool {
        return self.config.wantsCluster();
    }

    /// Returns the cluster node ID (0 if not in cluster mode).
    pub fn clusterNodeId(self: WorldConfigView) u16 {
        return self.config.clusterNodeId();
    }
};
