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

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "WorldConfig defaults" {
    // Verify default configuration
    const cfg = WorldConfig{};

    // Verify all specs have empty defaults
    try std.testing.expectEqual(@as(usize, 0), cfg.componentCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.archetypeCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.systemCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.resourceCount());
}

test "WorldConfig phaseCount" {
    // Verify phase count from config
    const cfg = WorldConfig{};

    // Should have default 5 phases (pre_update, update, post_update, render, network)
    try std.testing.expectEqual(@as(usize, 5), cfg.phaseCount());
}

test "WorldConfig componentCount" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { value: u32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity, Health } },
    };

    try std.testing.expectEqual(@as(usize, 3), cfg.componentCount());
}

test "WorldConfig archetypeCount" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{
            .archetypes = &.{
                .{ .name = "static", .components = &.{Position} },
                .{ .name = "moving", .components = &.{ Position, Velocity } },
            },
        },
    };

    try std.testing.expectEqual(@as(usize, 2), cfg.archetypeCount());
}

test "WorldConfig systemCount" {
    // Test systemCount with empty systems (systems spec tested more thoroughly in scheduler tests)
    const cfg = WorldConfig{
        .systems = .{
            .systems = &.{},
        },
    };

    try std.testing.expectEqual(@as(usize, 0), cfg.systemCount());
}

test "WorldConfig isCoordinated" {
    // Standalone world is not coordinated
    const standalone_cfg = WorldConfig{};
    try std.testing.expect(!standalone_cfg.isCoordinated());
    try std.testing.expectEqual(WorldRole.standalone, standalone_cfg.worldRole());

    // Accept world is coordinated
    const accept_cfg = WorldConfig{
        .coordination = .{ .role = .accept },
    };
    try std.testing.expect(accept_cfg.isCoordinated());
    try std.testing.expectEqual(WorldRole.accept, accept_cfg.worldRole());

    // IO world is coordinated
    const io_cfg = WorldConfig{
        .coordination = .{ .role = .io },
    };
    try std.testing.expect(io_cfg.isCoordinated());
    try std.testing.expectEqual(WorldRole.io, io_cfg.worldRole());
}

test "WorldConfig pipelineMode" {
    // Default pipeline mode is internal
    const default_cfg = WorldConfig{};
    try std.testing.expectEqual(PipelineMode.internal, default_cfg.pipelineMode());
    try std.testing.expect(!default_cfg.isExternalPipeline());
    try std.testing.expect(!default_cfg.isHybridPipeline());

    // External pipeline mode
    const external_cfg = WorldConfig{
        .pipeline = .{ .mode = .external },
    };
    try std.testing.expectEqual(PipelineMode.external, external_cfg.pipelineMode());
    try std.testing.expect(external_cfg.isExternalPipeline());
    try std.testing.expect(!external_cfg.isHybridPipeline());

    // Hybrid pipeline mode
    const hybrid_cfg = WorldConfig{
        .pipeline = .{ .mode = .hybrid },
    };
    try std.testing.expectEqual(PipelineMode.hybrid, hybrid_cfg.pipelineMode());
    try std.testing.expect(!hybrid_cfg.isExternalPipeline());
    try std.testing.expect(hybrid_cfg.isHybridPipeline());
}

test "WorldConfig hasScalabilityFeatures" {
    // Default has no scalability features
    const default_cfg = WorldConfig{};
    try std.testing.expect(!default_cfg.hasScalabilityFeatures());
    try std.testing.expect(!default_cfg.wantsNuma());
    try std.testing.expect(!default_cfg.wantsHugePages());
    try std.testing.expect(!default_cfg.wantsAffinity());
    try std.testing.expect(!default_cfg.wantsCluster());

    // With NUMA enabled
    const numa_cfg = WorldConfig{
        .scalability = .{ .numa = .{ .enabled = true } },
    };
    try std.testing.expect(numa_cfg.hasScalabilityFeatures());
    try std.testing.expect(numa_cfg.wantsNuma());

    // With huge pages enabled
    const huge_cfg = WorldConfig{
        .scalability = .{ .huge_pages = .{ .enabled = true } },
    };
    try std.testing.expect(huge_cfg.hasScalabilityFeatures());
    try std.testing.expect(huge_cfg.wantsHugePages());

    // With affinity enabled
    const affinity_cfg = WorldConfig{
        .scalability = .{ .affinity = .{ .enabled = true } },
    };
    try std.testing.expect(affinity_cfg.hasScalabilityFeatures());
    try std.testing.expect(affinity_cfg.wantsAffinity());

    // With cluster enabled
    const cluster_cfg = WorldConfig{
        .scalability = .{ .cluster = .{ .enabled = true, .node_id = 5 } },
    };
    try std.testing.expect(cluster_cfg.hasScalabilityFeatures());
    try std.testing.expect(cluster_cfg.wantsCluster());
    try std.testing.expectEqual(@as(u16, 5), cluster_cfg.clusterNodeId());
}

test "WorldConfig options" {
    // Test custom options
    const cfg = WorldConfig{
        .options = .{
            .max_entities = 50000,
            .max_systems_per_stage = 64,
            .max_stages_per_phase = 32,
        },
    };

    try std.testing.expectEqual(@as(u32, 50000), cfg.options.max_entities);
    try std.testing.expectEqual(@as(u16, 64), cfg.options.max_systems_per_stage);
    try std.testing.expectEqual(@as(u16, 32), cfg.options.max_stages_per_phase);
}

test "WorldConfig complete example" {
    // Test a complete game-like configuration (without systems - tested in scheduler)
    const Position = struct { x: f32, y: f32, z: f32 };
    const Velocity = struct { dx: f32, dy: f32, dz: f32 };
    const Health = struct { current: u32, max: u32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity, Health } },
        .archetypes = .{
            .archetypes = &.{
                .{ .name = "static", .components = &.{Position} },
                .{ .name = "moving", .components = &.{ Position, Velocity } },
                .{ .name = "player", .components = &.{ Position, Velocity, Health } },
            },
        },
        .systems = .{ .systems = &.{} },
        .options = .{ .max_entities = 10000 },
        .tick = .{ .mode = .fixed_rate, .target_hz = 60 },
    };

    try std.testing.expectEqual(@as(usize, 3), cfg.componentCount());
    try std.testing.expectEqual(@as(usize, 3), cfg.archetypeCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.systemCount()); // No systems in this test
    try std.testing.expectEqual(@as(u32, 10000), cfg.options.max_entities);
    try std.testing.expect(!cfg.isCoordinated());
    try std.testing.expect(!cfg.hasScalabilityFeatures());
}
