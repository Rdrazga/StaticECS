//! Scalability configuration types for StaticECS (Phase 7).
//!
//! This module defines vertical and horizontal scaling configurations:
//! - NUMA-aware memory allocation
//! - Huge page allocation
//! - Thread CPU affinity
//! - Cluster coordination

// ============================================================================
// NUMA Configuration
// ============================================================================

/// NUMA memory allocation configuration.
/// Enables NUMA-aware memory allocation for optimal memory bandwidth.
/// Tiger Style: All bounds configurable, graceful fallback on unsupported platforms.
pub const NumaConfig = struct {
    /// Enable NUMA-aware allocation.
    enabled: bool = false,

    /// Memory allocation strategy.
    strategy: Strategy = .local_preferred,

    /// Specific node bindings (or null for auto).
    /// Maps worker IDs to NUMA nodes for explicit control.
    node_bindings: ?[]const NodeBinding = null,

    /// Interleave settings (for .interleave strategy).
    interleave: InterleaveConfig = .{},

    pub const Strategy = enum {
        /// Allocate from local node, fall back to any.
        local_preferred,
        /// Strict local allocation (fail if unavailable).
        local_strict,
        /// Interleave across all nodes for distributed access.
        interleave,
        /// Bind to specific nodes via node_bindings.
        explicit,
    };

    pub const NodeBinding = struct {
        /// Worker or thread identifier.
        worker_id: u16,
        /// NUMA node to bind allocations to.
        node_id: u8,
    };

    pub const InterleaveConfig = struct {
        /// Page size for interleaving (default: 4KB).
        page_size: usize = 4096,
        /// Nodes to interleave across (null = all available).
        nodes: ?[]const u8 = null,
    };
};

// ============================================================================
// Huge Page Configuration
// ============================================================================

/// Huge page allocation configuration.
/// Enables huge pages to reduce TLB misses for large allocations.
/// Tiger Style: Configurable thresholds, automatic fallback.
pub const HugePageConfig = struct {
    /// Enable huge pages for large allocations.
    enabled: bool = false,

    /// Page size to request.
    size: PageSize = .@"2MB",

    /// Fallback to regular pages if huge pages unavailable.
    fallback: bool = true,

    /// Minimum allocation size to use huge pages (bytes).
    /// Allocations below this threshold use regular pages.
    threshold: usize = 2 * 1024 * 1024, // 2MB

    pub const PageSize = enum(usize) {
        @"2MB" = 2 * 1024 * 1024,
        @"1GB" = 1024 * 1024 * 1024,
    };
};

// ============================================================================
// Affinity Configuration
// ============================================================================

/// Thread CPU affinity configuration.
/// Controls thread-to-CPU pinning for cache locality and predictable latency.
/// Tiger Style: Strategy-based configuration with explicit overrides.
pub const AffinityConfig = struct {
    /// Enable thread-to-CPU pinning.
    enabled: bool = false,

    /// Affinity strategy for automatic assignment.
    strategy: Strategy = .sequential,

    /// Explicit CPU assignments (for .explicit strategy).
    cpu_bindings: ?[]const CpuBinding = null,

    /// Prefer physical cores over hyperthreads.
    prefer_physical: bool = true,

    pub const Strategy = enum {
        /// Pin threads to sequential CPUs (0, 1, 2, ...).
        sequential,
        /// Pin threads to physical cores only (skip hyperthreads).
        physical_only,
        /// Spread across NUMA nodes evenly.
        numa_spread,
        /// Use explicit CPU assignments from cpu_bindings.
        explicit,
    };

    pub const CpuBinding = struct {
        /// Thread identifier (worker index).
        thread_id: u16,
        /// CPU to pin to.
        cpu_id: u16,
    };
};

// ============================================================================
// Cluster Configuration
// ============================================================================

/// Cluster coordination configuration.
/// Enables horizontal scaling across multiple instances.
/// Tiger Style: Optional feature, compiles to nothing when disabled.
pub const ClusterConfig = struct {
    /// Enable cluster mode.
    enabled: bool = false,

    /// This instance's node ID (unique within cluster).
    node_id: u16 = 0,

    /// Total instance count in cluster (for static partitioning).
    total_instances: u16 = 1,

    /// Discovery mechanism for finding peers.
    discovery: Discovery = .static,

    /// Communication transport.
    transport: Transport = .tcp,

    /// Cluster topology.
    topology: Topology = .mesh,

    /// Peer addresses (for static discovery).
    peers: []const PeerAddress = &.{},

    /// Entity ownership strategy.
    ownership: OwnershipStrategy = .hash_based,

    /// Heartbeat interval in milliseconds.
    heartbeat_interval_ms: u32 = 1000,

    /// Peer timeout in milliseconds (consider dead after this).
    peer_timeout_ms: u32 = 5000,

    pub const Discovery = enum {
        /// Static peer list from configuration.
        static,
        /// DNS-based discovery (SRV records).
        dns,
        /// Multicast discovery on local network.
        multicast,
        /// Kubernetes service discovery.
        kubernetes,
    };

    pub const Transport = enum {
        /// TCP connections.
        tcp,
        /// UDP datagrams (for low-latency).
        udp,
        /// RDMA for high-performance clusters.
        rdma,
    };

    pub const Topology = enum {
        /// Full mesh - all nodes connected to all.
        mesh,
        /// Star - all nodes connect to leader.
        star,
        /// Ring - each node has two neighbors.
        ring,
    };

    pub const PeerAddress = struct {
        /// Host address (IP or hostname).
        host: []const u8,
        /// Port number.
        port: u16,
        /// Node ID of this peer.
        node_id: u16,
    };

    pub const OwnershipStrategy = enum {
        /// Hash-based entity distribution.
        hash_based,
        /// Range-based partitioning.
        range_based,
        /// Consistent hashing for dynamic scaling.
        consistent_hash,
    };
};

// ============================================================================
// Combined Scalability Configuration
// ============================================================================

/// Combined scalability configuration.
/// Groups all vertical and horizontal scaling options.
/// Tiger Style: Zero overhead when all features disabled.
pub const ScalabilityConfig = struct {
    /// NUMA-aware memory allocation.
    numa: NumaConfig = .{},

    /// Huge page allocation.
    huge_pages: HugePageConfig = .{},

    /// Thread CPU affinity.
    affinity: AffinityConfig = .{},

    /// Cluster coordination.
    cluster: ClusterConfig = .{},

    /// Returns true if any scalability feature is enabled.
    pub fn anyEnabled(self: ScalabilityConfig) bool {
        return self.numa.enabled or
            self.huge_pages.enabled or
            self.affinity.enabled or
            self.cluster.enabled;
    }

    /// Returns true if NUMA features are requested.
    pub fn wantsNuma(self: ScalabilityConfig) bool {
        return self.numa.enabled;
    }

    /// Returns true if huge pages are requested.
    pub fn wantsHugePages(self: ScalabilityConfig) bool {
        return self.huge_pages.enabled;
    }

    /// Returns true if thread affinity is requested.
    pub fn wantsAffinity(self: ScalabilityConfig) bool {
        return self.affinity.enabled;
    }

    /// Returns true if cluster mode is requested.
    pub fn wantsCluster(self: ScalabilityConfig) bool {
        return self.cluster.enabled;
    }
};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "ScalabilityConfig defaults - all disabled" {
    // By default, all scalability features should be disabled
    const cfg = ScalabilityConfig{};

    try std.testing.expect(!cfg.anyEnabled());
    try std.testing.expect(!cfg.wantsNuma());
    try std.testing.expect(!cfg.wantsHugePages());
    try std.testing.expect(!cfg.wantsAffinity());
    try std.testing.expect(!cfg.wantsCluster());
}

test "ScalabilityConfig anyEnabled detection" {
    // Test that anyEnabled correctly detects when features are enabled
    const numa_cfg = ScalabilityConfig{
        .numa = .{ .enabled = true },
    };
    try std.testing.expect(numa_cfg.anyEnabled());
    try std.testing.expect(numa_cfg.wantsNuma());

    const huge_cfg = ScalabilityConfig{
        .huge_pages = .{ .enabled = true },
    };
    try std.testing.expect(huge_cfg.anyEnabled());
    try std.testing.expect(huge_cfg.wantsHugePages());

    const affinity_cfg = ScalabilityConfig{
        .affinity = .{ .enabled = true },
    };
    try std.testing.expect(affinity_cfg.anyEnabled());
    try std.testing.expect(affinity_cfg.wantsAffinity());

    const cluster_cfg = ScalabilityConfig{
        .cluster = .{ .enabled = true },
    };
    try std.testing.expect(cluster_cfg.anyEnabled());
    try std.testing.expect(cluster_cfg.wantsCluster());
}

test "NumaConfig strategies" {
    // Test different NUMA allocation strategies
    const local_preferred = NumaConfig{
        .enabled = true,
        .strategy = .local_preferred,
    };
    try std.testing.expect(local_preferred.enabled);
    try std.testing.expectEqual(NumaConfig.Strategy.local_preferred, local_preferred.strategy);

    const local_strict = NumaConfig{
        .enabled = true,
        .strategy = .local_strict,
    };
    try std.testing.expectEqual(NumaConfig.Strategy.local_strict, local_strict.strategy);

    const interleave = NumaConfig{
        .enabled = true,
        .strategy = .interleave,
    };
    try std.testing.expectEqual(NumaConfig.Strategy.interleave, interleave.strategy);

    const explicit = NumaConfig{
        .enabled = true,
        .strategy = .explicit,
        .node_bindings = &[_]NumaConfig.NodeBinding{
            .{ .worker_id = 0, .node_id = 0 },
            .{ .worker_id = 1, .node_id = 1 },
        },
    };
    try std.testing.expectEqual(NumaConfig.Strategy.explicit, explicit.strategy);
    try std.testing.expect(explicit.node_bindings != null);
    try std.testing.expectEqual(@as(usize, 2), explicit.node_bindings.?.len);
}

test "NumaConfig interleave settings" {
    // Test interleave configuration
    const cfg = NumaConfig{
        .enabled = true,
        .strategy = .interleave,
        .interleave = .{
            .page_size = 2 * 1024 * 1024, // 2MB pages
            .nodes = &[_]u8{ 0, 1, 2, 3 },
        },
    };

    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), cfg.interleave.page_size);
    try std.testing.expect(cfg.interleave.nodes != null);
    try std.testing.expectEqual(@as(usize, 4), cfg.interleave.nodes.?.len);
}

test "HugePageConfig defaults" {
    // Verify huge page defaults
    const cfg = HugePageConfig{};

    try std.testing.expect(!cfg.enabled);
    try std.testing.expectEqual(HugePageConfig.PageSize.@"2MB", cfg.size);
    try std.testing.expect(cfg.fallback); // Should fallback by default
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), cfg.threshold);
}

test "HugePageConfig page sizes" {
    // Test different page size configurations
    const cfg_2mb = HugePageConfig{
        .enabled = true,
        .size = .@"2MB",
    };
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), @intFromEnum(cfg_2mb.size));

    const cfg_1gb = HugePageConfig{
        .enabled = true,
        .size = .@"1GB",
    };
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), @intFromEnum(cfg_1gb.size));
}

test "HugePageConfig threshold validation" {
    // Test custom threshold
    const cfg = HugePageConfig{
        .enabled = true,
        .threshold = 64 * 1024 * 1024, // 64MB threshold
        .fallback = false,
    };

    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), cfg.threshold);
    try std.testing.expect(!cfg.fallback);
}

test "AffinityConfig strategies" {
    // Test different affinity strategies
    const sequential = AffinityConfig{
        .enabled = true,
        .strategy = .sequential,
    };
    try std.testing.expectEqual(AffinityConfig.Strategy.sequential, sequential.strategy);

    const physical_only = AffinityConfig{
        .enabled = true,
        .strategy = .physical_only,
    };
    try std.testing.expectEqual(AffinityConfig.Strategy.physical_only, physical_only.strategy);

    const numa_spread = AffinityConfig{
        .enabled = true,
        .strategy = .numa_spread,
    };
    try std.testing.expectEqual(AffinityConfig.Strategy.numa_spread, numa_spread.strategy);

    const explicit = AffinityConfig{
        .enabled = true,
        .strategy = .explicit,
        .cpu_bindings = &[_]AffinityConfig.CpuBinding{
            .{ .thread_id = 0, .cpu_id = 2 },
            .{ .thread_id = 1, .cpu_id = 4 },
        },
    };
    try std.testing.expectEqual(AffinityConfig.Strategy.explicit, explicit.strategy);
    try std.testing.expect(explicit.cpu_bindings != null);
    try std.testing.expectEqual(@as(usize, 2), explicit.cpu_bindings.?.len);
}

test "AffinityConfig prefer_physical default" {
    // Default should prefer physical cores
    const cfg = AffinityConfig{};
    try std.testing.expect(cfg.prefer_physical);
}

test "ClusterConfig defaults" {
    // Verify cluster defaults
    const cfg = ClusterConfig{};

    try std.testing.expect(!cfg.enabled);
    try std.testing.expectEqual(@as(u16, 0), cfg.node_id);
    try std.testing.expectEqual(@as(u16, 1), cfg.total_instances);
    try std.testing.expectEqual(ClusterConfig.Discovery.static, cfg.discovery);
    try std.testing.expectEqual(ClusterConfig.Transport.tcp, cfg.transport);
    try std.testing.expectEqual(ClusterConfig.Topology.mesh, cfg.topology);
    try std.testing.expectEqual(ClusterConfig.OwnershipStrategy.hash_based, cfg.ownership);
    try std.testing.expectEqual(@as(u32, 1000), cfg.heartbeat_interval_ms);
    try std.testing.expectEqual(@as(u32, 5000), cfg.peer_timeout_ms);
}

test "ClusterConfig discovery mechanisms" {
    // Test different discovery mechanisms
    const static_cfg = ClusterConfig{
        .enabled = true,
        .discovery = .static,
        .peers = &[_]ClusterConfig.PeerAddress{
            .{ .host = "192.168.1.1", .port = 9000, .node_id = 1 },
            .{ .host = "192.168.1.2", .port = 9000, .node_id = 2 },
        },
    };
    try std.testing.expectEqual(@as(usize, 2), static_cfg.peers.len);

    const dns_cfg = ClusterConfig{
        .enabled = true,
        .discovery = .dns,
    };
    try std.testing.expectEqual(ClusterConfig.Discovery.dns, dns_cfg.discovery);

    const multicast_cfg = ClusterConfig{
        .enabled = true,
        .discovery = .multicast,
    };
    try std.testing.expectEqual(ClusterConfig.Discovery.multicast, multicast_cfg.discovery);

    const k8s_cfg = ClusterConfig{
        .enabled = true,
        .discovery = .kubernetes,
    };
    try std.testing.expectEqual(ClusterConfig.Discovery.kubernetes, k8s_cfg.discovery);
}

test "ClusterConfig transports" {
    // Test different transport options
    const tcp_cfg = ClusterConfig{ .transport = .tcp };
    try std.testing.expectEqual(ClusterConfig.Transport.tcp, tcp_cfg.transport);

    const udp_cfg = ClusterConfig{ .transport = .udp };
    try std.testing.expectEqual(ClusterConfig.Transport.udp, udp_cfg.transport);

    const rdma_cfg = ClusterConfig{ .transport = .rdma };
    try std.testing.expectEqual(ClusterConfig.Transport.rdma, rdma_cfg.transport);
}

test "ClusterConfig topologies" {
    // Test different cluster topologies
    const mesh_cfg = ClusterConfig{ .topology = .mesh };
    try std.testing.expectEqual(ClusterConfig.Topology.mesh, mesh_cfg.topology);

    const star_cfg = ClusterConfig{ .topology = .star };
    try std.testing.expectEqual(ClusterConfig.Topology.star, star_cfg.topology);

    const ring_cfg = ClusterConfig{ .topology = .ring };
    try std.testing.expectEqual(ClusterConfig.Topology.ring, ring_cfg.topology);
}

test "ClusterConfig ownership strategies" {
    // Test different ownership strategies
    const hash_cfg = ClusterConfig{ .ownership = .hash_based };
    try std.testing.expectEqual(ClusterConfig.OwnershipStrategy.hash_based, hash_cfg.ownership);

    const range_cfg = ClusterConfig{ .ownership = .range_based };
    try std.testing.expectEqual(ClusterConfig.OwnershipStrategy.range_based, range_cfg.ownership);

    const consistent_cfg = ClusterConfig{ .ownership = .consistent_hash };
    try std.testing.expectEqual(ClusterConfig.OwnershipStrategy.consistent_hash, consistent_cfg.ownership);
}
