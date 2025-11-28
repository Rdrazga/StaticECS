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
