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
    /// Returns null if no version is pinned.
    pub fn coreVersionPin(self: WorldConfigView) @TypeOf(@as(spec.Options, .{}).core_version) {
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

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");
const spec = @import("spec_types.zig");

test "WorldConfigView init" {
    // Test view initialization
    const cfg = WorldConfig{
        .options = .{ .max_entities = 5000 },
    };

    const view = WorldConfigView.init(cfg);

    // View should reflect config values
    try std.testing.expectEqual(@as(u32, 5000), view.maxEntities());
}

test "WorldConfigView layoutMode" {
    // Test layout mode accessor
    const multi_cfg = WorldConfig{
        .options = .{ .layout_mode = .multi_archetype },
    };
    const multi_view = WorldConfigView.init(multi_cfg);
    try std.testing.expectEqual(LayoutMode.multi_archetype, multi_view.layoutMode());

    const single_cfg = WorldConfig{
        .options = .{ .layout_mode = .single_archetype },
    };
    const single_view = WorldConfigView.init(single_cfg);
    try std.testing.expectEqual(LayoutMode.single_archetype, single_view.layoutMode());
}

test "WorldConfigView maxEntities" {
    // Test max entities accessor
    const cfg = WorldConfig{
        .options = .{ .max_entities = 100000 },
    };
    const view = WorldConfigView.init(cfg);

    try std.testing.expectEqual(@as(u32, 100000), view.maxEntities());
}

test "WorldConfigView tickMode" {
    // Test tick mode accessor
    const fixed_cfg = WorldConfig{
        .tick = .{ .mode = .fixed_rate, .target_hz = 60 },
    };
    const fixed_view = WorldConfigView.init(fixed_cfg);
    try std.testing.expectEqual(TickMode.fixed_rate, fixed_view.tickMode());
    try std.testing.expectEqual(@as(?u32, 60), fixed_view.tickTargetHz());

    const manual_cfg = WorldConfig{
        .tick = .{ .mode = .manual },
    };
    const manual_view = WorldConfigView.init(manual_cfg);
    try std.testing.expectEqual(TickMode.manual, manual_view.tickMode());
}

test "WorldConfigView executionModel" {
    // Test execution model accessor
    const blocking_cfg = WorldConfig{
        .schedule = .{ .execution_model = .blocking_single_thread },
    };
    const blocking_view = WorldConfigView.init(blocking_cfg);
    try std.testing.expectEqual(ExecutionModel.blocking_single_thread, blocking_view.executionModel());

    const evented_cfg = WorldConfig{
        .schedule = .{ .execution_model = .evented_single_thread },
    };
    const evented_view = WorldConfigView.init(evented_cfg);
    try std.testing.expectEqual(ExecutionModel.evented_single_thread, evented_view.executionModel());

    const concurrent_cfg = WorldConfig{
        .schedule = .{ .execution_model = .concurrent_threadpool },
    };
    const concurrent_view = WorldConfigView.init(concurrent_cfg);
    try std.testing.expectEqual(ExecutionModel.concurrent_threadpool, concurrent_view.executionModel());
}

test "WorldConfigView traceLevel" {
    // Test trace level accessor
    const off_cfg = WorldConfig{
        .tracing = .{ .level = .off },
    };
    const off_view = WorldConfigView.init(off_cfg);
    try std.testing.expectEqual(TraceLevel.off, off_view.traceLevel());

    const systems_cfg = WorldConfig{
        .tracing = .{ .level = .systems },
    };
    const systems_view = WorldConfigView.init(systems_cfg);
    try std.testing.expectEqual(TraceLevel.systems, systems_view.traceLevel());

    const verbose_cfg = WorldConfig{
        .tracing = .{ .level = .verbose },
    };
    const verbose_view = WorldConfigView.init(verbose_cfg);
    try std.testing.expectEqual(TraceLevel.verbose, verbose_view.traceLevel());
}

test "WorldConfigView isCoordinated" {
    // Test coordination status accessor
    const standalone_cfg = WorldConfig{
        .coordination = .{ .role = .standalone },
    };
    const standalone_view = WorldConfigView.init(standalone_cfg);
    try std.testing.expect(!standalone_view.isCoordinated());
    try std.testing.expectEqual(WorldRole.standalone, standalone_view.worldRole());

    const io_cfg = WorldConfig{
        .coordination = .{ .role = .io, .world_id = 3 },
    };
    const io_view = WorldConfigView.init(io_cfg);
    try std.testing.expect(io_view.isCoordinated());
    try std.testing.expectEqual(WorldRole.io, io_view.worldRole());
    try std.testing.expectEqual(@as(u8, 3), io_view.worldId());
}

test "WorldConfigView pipelineMode" {
    // Test pipeline mode accessor
    const internal_cfg = WorldConfig{
        .pipeline = .{ .mode = .internal },
    };
    const internal_view = WorldConfigView.init(internal_cfg);
    try std.testing.expectEqual(PipelineMode.internal, internal_view.pipelineMode());
    try std.testing.expect(!internal_view.isExternalPipeline());
    try std.testing.expect(!internal_view.isHybridPipeline());

    const external_cfg = WorldConfig{
        .pipeline = .{ .mode = .external },
    };
    const external_view = WorldConfigView.init(external_cfg);
    try std.testing.expectEqual(PipelineMode.external, external_view.pipelineMode());
    try std.testing.expect(external_view.isExternalPipeline());

    const hybrid_cfg = WorldConfig{
        .pipeline = .{ .mode = .hybrid },
    };
    const hybrid_view = WorldConfigView.init(hybrid_cfg);
    try std.testing.expectEqual(PipelineMode.hybrid, hybrid_view.pipelineMode());
    try std.testing.expect(hybrid_view.isHybridPipeline());
}

test "WorldConfigView scalability features" {
    // Test scalability feature accessors
    const no_scale_cfg = WorldConfig{};
    const no_scale_view = WorldConfigView.init(no_scale_cfg);
    try std.testing.expect(!no_scale_view.hasScalabilityFeatures());
    try std.testing.expect(!no_scale_view.wantsNuma());
    try std.testing.expect(!no_scale_view.wantsHugePages());
    try std.testing.expect(!no_scale_view.wantsAffinity());
    try std.testing.expect(!no_scale_view.wantsCluster());

    const full_scale_cfg = WorldConfig{
        .scalability = .{
            .numa = .{ .enabled = true },
            .huge_pages = .{ .enabled = true },
            .affinity = .{ .enabled = true },
            .cluster = .{ .enabled = true, .node_id = 7 },
        },
    };
    const full_scale_view = WorldConfigView.init(full_scale_cfg);
    try std.testing.expect(full_scale_view.hasScalabilityFeatures());
    try std.testing.expect(full_scale_view.wantsNuma());
    try std.testing.expect(full_scale_view.wantsHugePages());
    try std.testing.expect(full_scale_view.wantsAffinity());
    try std.testing.expect(full_scale_view.wantsCluster());
    try std.testing.expectEqual(@as(u16, 7), full_scale_view.clusterNodeId());
}

test "WorldConfigView coreVersionPin" {
    // Test version pin accessor
    const no_version_cfg = WorldConfig{};
    const no_version_view = WorldConfigView.init(no_version_cfg);
    // coreVersionPin returns null when not set
    try std.testing.expect(no_version_view.coreVersionPin() == null);

    const versioned_cfg = WorldConfig{
        .options = .{
            .core_version = .{ .major = 1, .minor = 2, .patch = 3 },
        },
    };
    const versioned_view = WorldConfigView.init(versioned_cfg);
    const version = versioned_view.coreVersionPin().?;
    try std.testing.expectEqual(@as(u32, 1), version.major);
    try std.testing.expectEqual(@as(u32, 2), version.minor);
    try std.testing.expectEqual(@as(u32, 3), version.patch);
}

test "WorldConfigView immutability" {
    // Test that view provides read-only access by creating two separate views
    const cfg1 = WorldConfig{
        .options = .{ .max_entities = 1000 },
    };
    const cfg2 = WorldConfig{
        .options = .{ .max_entities = 2000 },
    };

    const view1 = WorldConfigView.init(cfg1);
    const view2 = WorldConfigView.init(cfg2);

    // Each view reflects its own config
    try std.testing.expectEqual(@as(u32, 1000), view1.maxEntities());
    try std.testing.expectEqual(@as(u32, 2000), view2.maxEntities());

    // Views are independent
    try std.testing.expect(view1.maxEntities() != view2.maxEntities());
}
