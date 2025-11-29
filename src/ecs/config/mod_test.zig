//! Tests for the config module public API.
//!
//! These tests verify that the config module correctly re-exports
//! all types and provides expected default values.
//!
//! ## Test Coverage
//!
//! - WorldConfig defaults and methods
//! - WorldConfigView accessors
//! - Component spec helpers (componentInSpec, componentSetsEqual)
//! - Coordination configuration
//! - Pipeline configuration (Phase 6)
//! - Scalability configuration (Phase 7)

const std = @import("std");
const config = @import("mod.zig");

// Import types needed for testing
const WorldConfig = config.WorldConfig;
const WorldConfigView = config.WorldConfigView;
const LayoutMode = config.LayoutMode;
const TickMode = config.TickMode;
const ComponentsSpec = config.ComponentsSpec;
const componentInSpec = config.componentInSpec;
const componentSetsEqual = config.componentSetsEqual;
const WorldRole = config.WorldRole;
const WorldCoordinationConfig = config.WorldCoordinationConfig;
const PipelineMode = config.PipelineMode;
const PipelineConfig = config.PipelineConfig;
const ExternalPipelineConfig = config.ExternalPipelineConfig;
const HybridPipelineConfig = config.HybridPipelineConfig;
const DefaultFastPathPredicate = config.DefaultFastPathPredicate;
const NumaConfig = config.NumaConfig;
const HugePageConfig = config.HugePageConfig;
const AffinityConfig = config.AffinityConfig;
const ClusterConfig = config.ClusterConfig;
const ScalabilityConfig = config.ScalabilityConfig;

// ============================================================================
// WorldConfig Tests
// ============================================================================

test "WorldConfig defaults" {
    const cfg = WorldConfig{};
    try std.testing.expectEqual(@as(usize, 0), cfg.componentCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.archetypeCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.systemCount());
    try std.testing.expectEqual(LayoutMode.multi_archetype, cfg.options.layout_mode);
    try std.testing.expectEqual(@as(u32, 65536), cfg.options.max_entities);
}

test "WorldConfigView" {
    const cfg = WorldConfig{
        .options = .{ .max_entities = 1000, .layout_mode = .single_archetype },
        .tick = .{ .mode = .fixed_rate, .target_hz = 60 },
        .archetypes = .{ .archetypes = &.{.{ .name = "test", .components = &.{} }} },
    };

    const view = WorldConfigView.init(cfg);
    try std.testing.expectEqual(LayoutMode.single_archetype, view.layoutMode());
    try std.testing.expectEqual(@as(u32, 1000), view.maxEntities());
    try std.testing.expectEqual(TickMode.fixed_rate, view.tickMode());
    try std.testing.expectEqual(@as(?u32, 60), view.tickTargetHz());
}

// ============================================================================
// Component Spec Helper Tests
// ============================================================================

test "componentInSpec" {
    const TestComp = struct { x: i32 };
    const OtherComp = struct { y: f32 };

    const spec = ComponentsSpec{ .types = &.{TestComp} };
    try std.testing.expect(componentInSpec(spec, TestComp));
    try std.testing.expect(!componentInSpec(spec, OtherComp));
}

test "componentSetsEqual" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    try std.testing.expect(componentSetsEqual(&.{ A, B }, &.{ B, A }));
    try std.testing.expect(componentSetsEqual(&.{A}, &.{A}));
    try std.testing.expect(componentSetsEqual(&.{}, &.{}));
    try std.testing.expect(!componentSetsEqual(&.{ A, B }, &.{ A, C }));
    try std.testing.expect(!componentSetsEqual(&.{A}, &.{ A, B }));
}

// ============================================================================
// Coordination Tests
// ============================================================================

test "WorldRole enum" {
    // Test WorldRole values exist and are distinct
    try std.testing.expect(@intFromEnum(WorldRole.standalone) != @intFromEnum(WorldRole.accept));
    try std.testing.expect(@intFromEnum(WorldRole.io) != @intFromEnum(WorldRole.compute));
    try std.testing.expect(@intFromEnum(WorldRole.custom) != @intFromEnum(WorldRole.standalone));
}

test "WorldCoordinationConfig defaults" {
    const coord = WorldCoordinationConfig{};
    try std.testing.expectEqual(WorldRole.standalone, coord.role);
    try std.testing.expectEqual(@as(u8, 0), coord.world_id);
    try std.testing.expectEqual(@as(u32, 4096), coord.transfer_queue.capacity);
    try std.testing.expectEqual(@as(u32, 64), coord.transfer_queue.batch_size);
    try std.testing.expectEqual(false, coord.transfer_queue.spsc);
    try std.testing.expectEqual(@as(?u8, null), coord.routing.default_target);
}

test "WorldConfig isCoordinated" {
    // Standalone world (default)
    const standalone_cfg = WorldConfig{};
    try std.testing.expect(!standalone_cfg.isCoordinated());

    // Coordinated world
    const coord_cfg = WorldConfig{
        .coordination = .{
            .role = .io,
            .world_id = 1,
        },
    };
    try std.testing.expect(coord_cfg.isCoordinated());
    try std.testing.expectEqual(WorldRole.io, coord_cfg.worldRole());
}

test "WorldConfigView coordination accessors" {
    const cfg = WorldConfig{
        .coordination = .{
            .role = .compute,
            .world_id = 2,
            .routing = .{ .default_target = 1 },
        },
    };
    const view = WorldConfigView.init(cfg);

    try std.testing.expect(view.isCoordinated());
    try std.testing.expectEqual(WorldRole.compute, view.worldRole());
    try std.testing.expectEqual(@as(u8, 2), view.worldId());
}

test "TransferQueueConfig validation - power of 2" {
    // Valid power of 2 capacities should not compile error
    const valid_configs = [_]u32{ 64, 128, 256, 512, 1024, 2048, 4096 };
    inline for (valid_configs) |cap| {
        try std.testing.expect(std.math.isPowerOfTwo(cap));
    }
}

// ============================================================================
// Pipeline Configuration Tests (Phase 6)
// ============================================================================

test "PipelineMode enum" {
    // Test PipelineMode values exist and are distinct
    try std.testing.expect(@intFromEnum(PipelineMode.internal) != @intFromEnum(PipelineMode.external));
    try std.testing.expect(@intFromEnum(PipelineMode.external) != @intFromEnum(PipelineMode.hybrid));
    try std.testing.expect(@intFromEnum(PipelineMode.hybrid) != @intFromEnum(PipelineMode.internal));
}

test "PipelineConfig defaults" {
    const pipeline = PipelineConfig{};
    try std.testing.expectEqual(PipelineMode.internal, pipeline.mode);
    try std.testing.expectEqual(@as(u32, 256), pipeline.external.batch_size);
    try std.testing.expectEqual(true, pipeline.external.zero_copy);
    try std.testing.expectEqual(@as(u32, 4096), pipeline.external.export_buffer_size);
    try std.testing.expectEqual(@as(u32, 4096), pipeline.external.import_buffer_size);
    try std.testing.expectEqual(@as(u32, 1024), pipeline.hybrid.fast_path_capacity);
    try std.testing.expectEqual(true, pipeline.hybrid.fallback_on_full);
}

test "DefaultFastPathPredicate always returns false" {
    const TestData = struct { value: i32 };
    const result = DefaultFastPathPredicate.canFastPath(TestData{ .value = 42 });
    try std.testing.expect(!result);
}

test "WorldConfig pipelineMode" {
    // Default internal mode
    const internal_cfg = WorldConfig{};
    try std.testing.expectEqual(PipelineMode.internal, internal_cfg.pipelineMode());
    try std.testing.expect(!internal_cfg.isExternalPipeline());
    try std.testing.expect(!internal_cfg.isHybridPipeline());

    // External mode
    const external_cfg = WorldConfig{
        .pipeline = .{ .mode = .external },
    };
    try std.testing.expectEqual(PipelineMode.external, external_cfg.pipelineMode());
    try std.testing.expect(external_cfg.isExternalPipeline());
    try std.testing.expect(!external_cfg.isHybridPipeline());

    // Hybrid mode
    const hybrid_cfg = WorldConfig{
        .pipeline = .{ .mode = .hybrid },
    };
    try std.testing.expectEqual(PipelineMode.hybrid, hybrid_cfg.pipelineMode());
    try std.testing.expect(!hybrid_cfg.isExternalPipeline());
    try std.testing.expect(hybrid_cfg.isHybridPipeline());
}

test "WorldConfigView pipeline accessors" {
    const cfg = WorldConfig{
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{ .fast_path_capacity = 2048 },
        },
    };
    const view = WorldConfigView.init(cfg);

    try std.testing.expectEqual(PipelineMode.hybrid, view.pipelineMode());
    try std.testing.expect(!view.isExternalPipeline());
    try std.testing.expect(view.isHybridPipeline());
}

test "ExternalPipelineConfig custom values" {
    const external = ExternalPipelineConfig{
        .batch_size = 512,
        .zero_copy = false,
        .export_buffer_size = 8192,
        .import_buffer_size = 8192,
    };
    try std.testing.expectEqual(@as(u32, 512), external.batch_size);
    try std.testing.expectEqual(false, external.zero_copy);
    try std.testing.expectEqual(@as(u32, 8192), external.export_buffer_size);
    try std.testing.expectEqual(@as(u32, 8192), external.import_buffer_size);
}

test "HybridPipelineConfig custom predicate" {
    const CustomPredicate = struct {
        pub fn canFastPath(data: anytype) bool {
            _ = data;
            return true; // Always fast-path
        }
    };

    const hybrid = HybridPipelineConfig{
        .fast_path_predicate_type = CustomPredicate,
        .fast_path_capacity = 4096,
        .fallback_on_full = false,
    };

    try std.testing.expectEqual(@as(u32, 4096), hybrid.fast_path_capacity);
    try std.testing.expectEqual(false, hybrid.fallback_on_full);

    // Verify custom predicate works
    const TestData = struct { x: i32 };
    const result = CustomPredicate.canFastPath(TestData{ .x = 1 });
    try std.testing.expect(result);
}

// ============================================================================
// Scalability Configuration Tests (Phase 7)
// ============================================================================

test "NumaConfig defaults" {
    const numa = NumaConfig{};
    try std.testing.expectEqual(false, numa.enabled);
    try std.testing.expectEqual(NumaConfig.Strategy.local_preferred, numa.strategy);
    try std.testing.expectEqual(@as(?[]const NumaConfig.NodeBinding, null), numa.node_bindings);
    try std.testing.expectEqual(@as(usize, 4096), numa.interleave.page_size);
}

test "NumaConfig custom values" {
    const numa = NumaConfig{
        .enabled = true,
        .strategy = .interleave,
        .interleave = .{
            .page_size = 2 * 1024 * 1024, // 2MB
        },
    };
    try std.testing.expectEqual(true, numa.enabled);
    try std.testing.expectEqual(NumaConfig.Strategy.interleave, numa.strategy);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), numa.interleave.page_size);
}

test "HugePageConfig defaults" {
    const huge = HugePageConfig{};
    try std.testing.expectEqual(false, huge.enabled);
    try std.testing.expectEqual(HugePageConfig.PageSize.@"2MB", huge.size);
    try std.testing.expectEqual(true, huge.fallback);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), huge.threshold);
}

test "HugePageConfig custom values" {
    const huge = HugePageConfig{
        .enabled = true,
        .size = .@"1GB",
        .fallback = false,
        .threshold = 512 * 1024 * 1024, // 512MB
    };
    try std.testing.expectEqual(true, huge.enabled);
    try std.testing.expectEqual(HugePageConfig.PageSize.@"1GB", huge.size);
    try std.testing.expectEqual(false, huge.fallback);
    try std.testing.expectEqual(@as(usize, 512 * 1024 * 1024), huge.threshold);
}

test "HugePageConfig page size values" {
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), @intFromEnum(HugePageConfig.PageSize.@"2MB"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), @intFromEnum(HugePageConfig.PageSize.@"1GB"));
}

test "AffinityConfig defaults" {
    const aff = AffinityConfig{};
    try std.testing.expectEqual(false, aff.enabled);
    try std.testing.expectEqual(AffinityConfig.Strategy.sequential, aff.strategy);
    try std.testing.expectEqual(@as(?[]const AffinityConfig.CpuBinding, null), aff.cpu_bindings);
    try std.testing.expectEqual(true, aff.prefer_physical);
}

test "AffinityConfig custom values" {
    const aff = AffinityConfig{
        .enabled = true,
        .strategy = .numa_spread,
        .prefer_physical = false,
    };
    try std.testing.expectEqual(true, aff.enabled);
    try std.testing.expectEqual(AffinityConfig.Strategy.numa_spread, aff.strategy);
    try std.testing.expectEqual(false, aff.prefer_physical);
}

test "ClusterConfig defaults" {
    const cluster = ClusterConfig{};
    try std.testing.expectEqual(false, cluster.enabled);
    try std.testing.expectEqual(@as(u16, 0), cluster.node_id);
    try std.testing.expectEqual(@as(u16, 1), cluster.total_instances);
    try std.testing.expectEqual(ClusterConfig.Discovery.static, cluster.discovery);
    try std.testing.expectEqual(ClusterConfig.Transport.tcp, cluster.transport);
    try std.testing.expectEqual(ClusterConfig.Topology.mesh, cluster.topology);
    try std.testing.expectEqual(ClusterConfig.OwnershipStrategy.hash_based, cluster.ownership);
    try std.testing.expectEqual(@as(u32, 1000), cluster.heartbeat_interval_ms);
    try std.testing.expectEqual(@as(u32, 5000), cluster.peer_timeout_ms);
}

test "ClusterConfig custom values" {
    const cluster = ClusterConfig{
        .enabled = true,
        .node_id = 2,
        .total_instances = 5,
        .discovery = .dns,
        .transport = .udp,
        .topology = .ring,
        .ownership = .consistent_hash,
        .heartbeat_interval_ms = 500,
        .peer_timeout_ms = 3000,
    };
    try std.testing.expectEqual(true, cluster.enabled);
    try std.testing.expectEqual(@as(u16, 2), cluster.node_id);
    try std.testing.expectEqual(@as(u16, 5), cluster.total_instances);
    try std.testing.expectEqual(ClusterConfig.Discovery.dns, cluster.discovery);
    try std.testing.expectEqual(ClusterConfig.Transport.udp, cluster.transport);
    try std.testing.expectEqual(ClusterConfig.Topology.ring, cluster.topology);
    try std.testing.expectEqual(ClusterConfig.OwnershipStrategy.consistent_hash, cluster.ownership);
    try std.testing.expectEqual(@as(u32, 500), cluster.heartbeat_interval_ms);
    try std.testing.expectEqual(@as(u32, 3000), cluster.peer_timeout_ms);
}

test "ScalabilityConfig defaults" {
    const scale = ScalabilityConfig{};
    try std.testing.expect(!scale.anyEnabled());
    try std.testing.expect(!scale.wantsNuma());
    try std.testing.expect(!scale.wantsHugePages());
    try std.testing.expect(!scale.wantsAffinity());
    try std.testing.expect(!scale.wantsCluster());
}

test "ScalabilityConfig anyEnabled" {
    // Test each feature individually
    var scale = ScalabilityConfig{};

    scale.numa.enabled = true;
    try std.testing.expect(scale.anyEnabled());
    try std.testing.expect(scale.wantsNuma());
    scale.numa.enabled = false;

    scale.huge_pages.enabled = true;
    try std.testing.expect(scale.anyEnabled());
    try std.testing.expect(scale.wantsHugePages());
    scale.huge_pages.enabled = false;

    scale.affinity.enabled = true;
    try std.testing.expect(scale.anyEnabled());
    try std.testing.expect(scale.wantsAffinity());
    scale.affinity.enabled = false;

    scale.cluster.enabled = true;
    try std.testing.expect(scale.anyEnabled());
    try std.testing.expect(scale.wantsCluster());
}

test "WorldConfig default scalability" {
    const cfg = WorldConfig{};
    try std.testing.expect(!cfg.hasScalabilityFeatures());
    try std.testing.expect(!cfg.wantsNuma());
    try std.testing.expect(!cfg.wantsHugePages());
    try std.testing.expect(!cfg.wantsAffinity());
    try std.testing.expect(!cfg.wantsCluster());
    try std.testing.expectEqual(@as(u16, 0), cfg.clusterNodeId());
}

test "WorldConfig with scalability" {
    const cfg = WorldConfig{
        .scalability = .{
            .numa = .{ .enabled = true, .strategy = .local_strict },
            .huge_pages = .{ .enabled = true, .size = .@"2MB" },
            .affinity = .{ .enabled = true, .strategy = .physical_only },
            .cluster = .{ .enabled = true, .node_id = 3, .total_instances = 8 },
        },
    };
    try std.testing.expect(cfg.hasScalabilityFeatures());
    try std.testing.expect(cfg.wantsNuma());
    try std.testing.expect(cfg.wantsHugePages());
    try std.testing.expect(cfg.wantsAffinity());
    try std.testing.expect(cfg.wantsCluster());
    try std.testing.expectEqual(@as(u16, 3), cfg.clusterNodeId());
}

test "WorldConfigView scalability accessors" {
    const cfg = WorldConfig{
        .scalability = .{
            .numa = .{ .enabled = true },
            .cluster = .{ .enabled = true, .node_id = 5, .total_instances = 10 },
        },
    };
    const view = WorldConfigView.init(cfg);

    try std.testing.expect(view.hasScalabilityFeatures());
    try std.testing.expect(view.wantsNuma());
    try std.testing.expect(!view.wantsHugePages());
    try std.testing.expect(!view.wantsAffinity());
    try std.testing.expect(view.wantsCluster());
    try std.testing.expectEqual(@as(u16, 5), view.clusterNodeId());
}
