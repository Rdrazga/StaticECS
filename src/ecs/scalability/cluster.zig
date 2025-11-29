//! Cluster Coordination Primitives
//!
//! **EXPERIMENTAL**: Framework only - no network transport.
//!
//! Provides horizontal scaling support through cluster coordination,
//! entity ownership calculation, and shared state interfaces.
//!
//! Status: Currently provides in-memory coordination for single-process
//! multi-world scenarios. Actual network transport (TCP/UDP/RDMA)
//! is not yet implemented.
//!
//! What works:
//! - Local multi-world coordination within a single process
//! - Entity ownership calculation (hash-based, range-based, consistent-hash)
//! - Transfer queue structures for cross-world entity migration
//! - Statistics tracking for coordination operations
//! - Peer state management and timeout detection
//!
//! What doesn't work:
//! - Network transport (no TCP/UDP/RDMA implementation)
//! - Remote node discovery
//! - Cross-process or cross-machine communication
//! - Actual heartbeat message send/receive
//!
//! The `join()`, `leave()`, and `tick()` methods update local state only.
//! They do not establish network connections or send messages.
//!
//! See: [`docs/EXPERIMENTAL.md`](../../../docs/EXPERIMENTAL.md) for status tracking.
//!
//! Tiger Style: Configurable discovery, transport-agnostic, compiles out when disabled.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const ClusterConfig = config.ClusterConfig;

/// Entity ownership calculator.
/// Determines which cluster node owns a specific entity based on configured strategy.
pub fn EntityOwnership(comptime cfg: ClusterConfig) type {
    return struct {
        const Self = @This();

        /// Get the owner node for an entity ID.
        pub fn getOwner(entity_id: u32) u16 {
            if (comptime !cfg.enabled or cfg.total_instances <= 1) {
                return 0;
            }

            return switch (cfg.ownership) {
                .hash_based => hashBasedOwner(entity_id, cfg.total_instances),
                .range_based => rangeBasedOwner(entity_id, cfg.total_instances),
                .consistent_hash => consistentHashOwner(entity_id, cfg.total_instances),
            };
        }

        /// Check if this node owns the given entity.
        pub fn isLocalEntity(entity_id: u32) bool {
            return getOwner(entity_id) == cfg.node_id;
        }

        /// Get the entity ID range owned by this node (for range-based).
        pub fn getLocalRange() struct { start: u32, end: u32 } {
            if (comptime !cfg.enabled or cfg.total_instances <= 1) {
                return .{ .start = 0, .end = std.math.maxInt(u32) };
            }

            const chunk_size = std.math.maxInt(u32) / cfg.total_instances;
            const start = chunk_size * cfg.node_id;
            const end = if (cfg.node_id == cfg.total_instances - 1)
                std.math.maxInt(u32)
            else
                start + chunk_size - 1;

            return .{ .start = start, .end = end };
        }

        fn hashBasedOwner(entity_id: u32, total: u16) u16 {
            // Simple modulo hash
            return @intCast(entity_id % total);
        }

        fn rangeBasedOwner(entity_id: u32, total: u16) u16 {
            // Range partitioning
            const chunk_size = std.math.maxInt(u32) / total;
            const owner = entity_id / chunk_size;
            return @min(@as(u16, @intCast(owner)), total - 1);
        }

        fn consistentHashOwner(entity_id: u32, total: u16) u16 {
            // Consistent hashing using virtual nodes
            // Each physical node has multiple virtual nodes on the ring
            const VIRTUAL_NODES = 100;
            const hash = hashU32(entity_id);

            // Find the closest virtual node
            var closest: u16 = 0;
            var closest_dist: u32 = std.math.maxInt(u32);

            var node: u16 = 0;
            while (node < total) : (node += 1) {
                var vnode: u32 = 0;
                while (vnode < VIRTUAL_NODES) : (vnode += 1) {
                    const vnode_hash = hashU32(@as(u32, node) * VIRTUAL_NODES + vnode);
                    const dist = ringDistance(hash, vnode_hash);
                    if (dist < closest_dist) {
                        closest_dist = dist;
                        closest = node;
                    }
                }
            }

            return closest;
        }

        fn hashU32(value: u32) u32 {
            // FNV-1a hash
            var h: u32 = 2166136261;
            const bytes = std.mem.asBytes(&value);
            for (bytes) |b| {
                h ^= b;
                h *%= 16777619;
            }
            return h;
        }

        fn ringDistance(a: u32, b: u32) u32 {
            // Distance on a circular ring
            const direct = if (a > b) a - b else b - a;
            const wrap = std.math.maxInt(u32) - direct;
            return @min(direct, wrap);
        }
    };
}

/// Cluster state for a node.
pub const ClusterState = enum {
    /// Node is initializing, not yet connected.
    initializing,
    /// Node is attempting to join the cluster.
    joining,
    /// Node is active and participating in the cluster.
    active,
    /// Node is partitioned from some peers.
    partitioned,
    /// Node is gracefully leaving the cluster.
    leaving,
    /// Node has left the cluster.
    stopped,
};

/// Peer connection state.
pub const PeerState = enum {
    /// Not connected to this peer.
    disconnected,
    /// Attempting to connect.
    connecting,
    /// Connected and healthy.
    connected,
    /// Connection failed or peer unresponsive.
    failed,
};

/// Cluster statistics.
pub const ClusterStats = struct {
    /// Messages sent to peers.
    messages_sent: u64 = 0,
    /// Messages received from peers.
    messages_received: u64 = 0,
    /// Entities migrated to other nodes.
    entities_sent: u64 = 0,
    /// Entities received from other nodes.
    entities_received: u64 = 0,
    /// Number of failover events.
    failovers: u64 = 0,
    /// Bytes sent.
    bytes_sent: u64 = 0,
    /// Bytes received.
    bytes_received: u64 = 0,
    /// Current number of connected peers.
    connected_peers: u16 = 0,
};

/// **EXPERIMENTAL**: Distributed cluster coordination.
///
/// Status: Framework only - no network transport.
/// Currently provides in-memory coordination for single-process
/// multi-world scenarios. Actual network transport (TCP/UDP/RDMA)
/// not yet implemented.
///
/// What works:
/// - `init()` - Creates coordinator with local state
/// - `getEntityOwner()` - Calculates ownership based on config strategy
/// - `isLocalEntity()` - Checks if entity belongs to this node
/// - `getState()` - Returns current coordination state
/// - `getStats()` - Returns coordination statistics
/// - `getPeerState()` - Returns state for specific peer index
/// - `countConnectedPeers()` - Counts peers marked connected
/// - `isHealthy()` - Checks quorum based on connected peers
/// - `receiveHeartbeat()` - Updates peer timestamp (call externally)
/// - `markPeerConnected()` - Manually mark peer as connected (testing)
///
/// What doesn't work:
/// - `join()` - Updates local state only, no network connection
/// - `leave()` - Updates local state only, no departure notification
/// - `tick()` - Checks timeouts but doesn't send/receive messages
/// - Network transport - No TCP/UDP/RDMA socket code exists
/// - Remote discovery - Cannot find nodes automatically
///
/// To use for testing or single-process coordination:
/// ```
/// var coord = ClusterCoordinator(cfg).init(allocator);
/// // Manually simulate peer connections for testing:
/// coord.markPeerConnected(0);
/// coord.markPeerConnected(1);
/// try coord.join();
/// // Now coord.state == .active if quorum met
/// ```
///
/// See: [`docs/EXPERIMENTAL.md`](../../../docs/EXPERIMENTAL.md) for status tracking.
pub fn ClusterCoordinator(comptime cfg: ClusterConfig) type {
    return struct {
        const Self = @This();

        /// This node's ID.
        node_id: u16,
        /// Current cluster state.
        state: ClusterState,
        /// Statistics.
        stats: ClusterStats,
        /// Peer connection states.
        peer_states: [cfg.peers.len]PeerState,
        /// Last heartbeat times (milliseconds since epoch).
        last_heartbeats: [cfg.peers.len]i64,
        /// Allocator for dynamic operations.
        allocator: std.mem.Allocator,

        /// Entity ownership calculator.
        pub const Ownership = EntityOwnership(cfg);

        /// Initialize the cluster coordinator.
        pub fn init(allocator: std.mem.Allocator) Self {
            const self = Self{
                .node_id = cfg.node_id,
                .state = .initializing,
                .stats = .{},
                .peer_states = [_]PeerState{.disconnected} ** cfg.peers.len,
                .last_heartbeats = [_]i64{0} ** cfg.peers.len,
                .allocator = allocator,
            };

            return self;
        }

        /// Deinitialize and cleanup.
        pub fn deinit(self: *Self) void {
            self.state = .stopped;
        }

        /// Attempt to join the cluster.
        ///
        /// FRAMEWORK ONLY: No network transport implementation.
        /// This method updates local state but does not establish actual
        /// network connections. Peer discovery and heartbeat protocols
        /// require a transport layer implementation.
        ///
        /// See: TODO - cluster_transport.zig for transport abstraction
        pub fn join(self: *Self) !void {
            if (comptime !cfg.enabled) return;
            if (cfg.peers.len == 0) {
                // No peers, we're the only node
                self.state = .active;
                return;
            }

            self.state = .joining;

            // Attempt to connect to all configured peers
            for (self.peer_states, 0..) |_, i| {
                self.peer_states[i] = .connecting;
                // Actual connection would be established here via TCP/UDP
                // For now, mark as disconnected until tick() handles connection
            }

            // Check if we have quorum
            if (self.countConnectedPeers() == 0 and cfg.peers.len > 0) {
                // No connections yet, still joining
                return;
            }

            self.state = .active;
        }

        /// Leave the cluster gracefully.
        ///
        /// FRAMEWORK ONLY: No network transport implementation.
        /// This method updates local state but does not send departure
        /// notifications to peers. Requires transport layer implementation.
        pub fn leave(self: *Self) !void {
            if (comptime !cfg.enabled) return;

            self.state = .leaving;

            // Notify peers of departure
            // In a real implementation, send leave messages

            self.state = .stopped;
        }

        /// Process cluster tick (heartbeats, message processing).
        ///
        /// FRAMEWORK ONLY: No network transport implementation.
        /// This method checks local peer state timeouts but does not
        /// send/receive actual heartbeat messages. The timeout logic
        /// works correctly once `receiveHeartbeat()` is called externally
        /// by a transport implementation.
        pub fn tick(self: *Self) !void {
            if (comptime !cfg.enabled) return;
            if (self.state == .stopped) return;

            const now = std.time.milliTimestamp();

            // Check peer health
            for (self.last_heartbeats, 0..) |last_hb, i| {
                if (last_hb > 0 and now - last_hb > cfg.peer_timeout_ms) {
                    // Peer timed out
                    if (self.peer_states[i] == .connected) {
                        self.peer_states[i] = .failed;
                        self.stats.failovers += 1;
                    }
                }
            }

            // Update connected peer count
            self.stats.connected_peers = self.countConnectedPeers();

            // Check for partition
            const total_peers = cfg.peers.len;
            if (total_peers > 0 and self.stats.connected_peers == 0) {
                if (self.state == .active) {
                    self.state = .partitioned;
                }
            } else if (self.state == .partitioned and self.stats.connected_peers > 0) {
                self.state = .active;
            }
        }

        /// Get the owner node for an entity.
        pub fn getEntityOwner(entity_id: u32) u16 {
            return Ownership.getOwner(entity_id);
        }

        /// Check if entity is owned by this node.
        pub fn isLocalEntity(entity_id: u32) bool {
            return Ownership.isLocalEntity(entity_id);
        }

        /// Get current cluster state.
        pub fn getState(self: *const Self) ClusterState {
            return self.state;
        }

        /// Get cluster statistics.
        pub fn getStats(self: *const Self) ClusterStats {
            return self.stats;
        }

        /// Get peer state by index.
        pub fn getPeerState(self: *const Self, peer_idx: usize) ?PeerState {
            if (peer_idx >= cfg.peers.len) return null;
            return self.peer_states[peer_idx];
        }

        /// Count connected peers.
        pub fn countConnectedPeers(self: *const Self) u16 {
            var count: u16 = 0;
            for (self.peer_states) |state| {
                if (state == .connected) count += 1;
            }
            return count;
        }

        /// Check if cluster is healthy (has quorum).
        pub fn isHealthy(self: *const Self) bool {
            if (comptime !cfg.enabled) return true;
            if (cfg.peers.len == 0) return true;

            // Quorum = majority of nodes
            const quorum = cfg.peers.len / 2 + 1;
            // Include ourselves (+1)
            return self.countConnectedPeers() + 1 >= quorum;
        }

        /// Reset statistics.
        pub fn resetStats(self: *Self) void {
            self.stats = .{};
        }

        /// Simulate receiving a heartbeat from a peer.
        pub fn receiveHeartbeat(self: *Self, peer_idx: usize) void {
            if (peer_idx >= cfg.peers.len) return;

            self.last_heartbeats[peer_idx] = std.time.milliTimestamp();
            self.peer_states[peer_idx] = .connected;
            self.stats.messages_received += 1;
        }

        /// Mark a peer as connected (for testing/simulation).
        pub fn markPeerConnected(self: *Self, peer_idx: usize) void {
            if (peer_idx >= cfg.peers.len) return;
            self.peer_states[peer_idx] = .connected;
            self.last_heartbeats[peer_idx] = std.time.milliTimestamp();
        }
    };
}

/// Shared state backend interface.
/// Abstract interface for distributed shared state (Redis, etcd, etc.).
pub const SharedStateBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, key: []const u8) ?[]const u8,
        set: *const fn (ptr: *anyopaque, key: []const u8, value: []const u8) bool,
        delete: *const fn (ptr: *anyopaque, key: []const u8) bool,
        exists: *const fn (ptr: *anyopaque, key: []const u8) bool,
    };

    /// Get a value by key.
    pub fn get(self: SharedStateBackend, key: []const u8) ?[]const u8 {
        return self.vtable.get(self.ptr, key);
    }

    /// Set a key-value pair.
    pub fn set(self: SharedStateBackend, key: []const u8, value: []const u8) bool {
        return self.vtable.set(self.ptr, key, value);
    }

    /// Delete a key.
    pub fn delete(self: SharedStateBackend, key: []const u8) bool {
        return self.vtable.delete(self.ptr, key);
    }

    /// Check if a key exists.
    pub fn exists(self: SharedStateBackend, key: []const u8) bool {
        return self.vtable.exists(self.ptr, key);
    }
};

/// In-memory shared state backend (for testing/single-node).
pub const InMemoryBackend = struct {
    const Self = @This();

    data: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .data = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all stored values
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    pub fn backend(self: *Self) SharedStateBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = SharedStateBackend.VTable{
        .get = get,
        .set = set,
        .delete = delete,
        .exists = exists,
    };

    fn get(ptr: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.data.get(key);
    }

    fn set(ptr: *anyopaque, key: []const u8, value: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Duplicate key and value
        const key_copy = self.allocator.dupe(u8, key) catch return false;
        const value_copy = self.allocator.dupe(u8, value) catch {
            self.allocator.free(key_copy);
            return false;
        };

        // Remove old value if exists
        if (self.data.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        self.data.put(key_copy, value_copy) catch {
            self.allocator.free(key_copy);
            self.allocator.free(value_copy);
            return false;
        };

        return true;
    }

    fn delete(ptr: *anyopaque, key: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.data.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
            return true;
        }
        return false;
    }

    fn exists(ptr: *anyopaque, key: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.data.contains(key);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "EntityOwnership hash-based" {
    const TestConfig = ClusterConfig{
        .enabled = true,
        .node_id = 0,
        .total_instances = 4,
        .ownership = .hash_based,
    };
    const Ownership = EntityOwnership(TestConfig);

    // Different entities should distribute across nodes
    const owner0 = Ownership.getOwner(0);
    const owner1 = Ownership.getOwner(1);
    const owner2 = Ownership.getOwner(2);
    const owner3 = Ownership.getOwner(3);

    try std.testing.expect(owner0 < 4);
    try std.testing.expect(owner1 < 4);
    try std.testing.expect(owner2 < 4);
    try std.testing.expect(owner3 < 4);
}

test "EntityOwnership disabled" {
    const TestConfig = ClusterConfig{
        .enabled = false,
    };
    const Ownership = EntityOwnership(TestConfig);

    // When disabled, always returns node 0
    try std.testing.expectEqual(@as(u16, 0), Ownership.getOwner(12345));
}

test "EntityOwnership single instance" {
    const TestConfig = ClusterConfig{
        .enabled = true,
        .node_id = 0,
        .total_instances = 1,
        .ownership = .hash_based,
    };
    const Ownership = EntityOwnership(TestConfig);

    // Single instance owns everything
    try std.testing.expectEqual(@as(u16, 0), Ownership.getOwner(0));
    try std.testing.expectEqual(@as(u16, 0), Ownership.getOwner(12345));
}

test "EntityOwnership isLocalEntity" {
    const TestConfig = ClusterConfig{
        .enabled = true,
        .node_id = 2,
        .total_instances = 4,
        .ownership = .hash_based,
    };
    const Ownership = EntityOwnership(TestConfig);

    // Entity 2 maps to node 2 with hash_based (2 % 4 = 2)
    try std.testing.expect(Ownership.isLocalEntity(2));
    try std.testing.expect(Ownership.isLocalEntity(6)); // 6 % 4 = 2
}

test "ClusterCoordinator init" {
    const TestConfig = ClusterConfig{
        .enabled = true,
        .node_id = 0,
        .total_instances = 1,
    };

    var coordinator = ClusterCoordinator(TestConfig).init(std.testing.allocator);
    defer coordinator.deinit();

    try std.testing.expectEqual(ClusterState.initializing, coordinator.getState());
    try std.testing.expectEqual(@as(u16, 0), coordinator.node_id);
}

test "ClusterCoordinator join single node" {
    const TestConfig = ClusterConfig{
        .enabled = true,
        .node_id = 0,
        .total_instances = 1,
    };

    var coordinator = ClusterCoordinator(TestConfig).init(std.testing.allocator);
    defer coordinator.deinit();

    try coordinator.join();
    try std.testing.expectEqual(ClusterState.active, coordinator.getState());
}

test "ClusterCoordinator disabled is always healthy" {
    const TestConfig = ClusterConfig{
        .enabled = false,
    };

    var coordinator = ClusterCoordinator(TestConfig).init(std.testing.allocator);
    defer coordinator.deinit();

    try std.testing.expect(coordinator.isHealthy());
}

test "ClusterCoordinator stats" {
    const TestConfig = ClusterConfig{
        .enabled = true,
        .node_id = 0,
        .total_instances = 1,
    };

    var coordinator = ClusterCoordinator(TestConfig).init(std.testing.allocator);
    defer coordinator.deinit();

    const stats = coordinator.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.messages_sent);
    try std.testing.expectEqual(@as(u64, 0), stats.entities_sent);
}

test "InMemoryBackend basic operations" {
    var backend_impl = InMemoryBackend.init(std.testing.allocator);
    defer backend_impl.deinit();

    const backend = backend_impl.backend();

    // Set and get
    try std.testing.expect(backend.set("key1", "value1"));
    const value = backend.get("key1");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("value1", value.?);

    // Exists
    try std.testing.expect(backend.exists("key1"));
    try std.testing.expect(!backend.exists("nonexistent"));

    // Delete
    try std.testing.expect(backend.delete("key1"));
    try std.testing.expect(!backend.exists("key1"));
}

test "InMemoryBackend overwrite" {
    var backend_impl = InMemoryBackend.init(std.testing.allocator);
    defer backend_impl.deinit();

    const backend = backend_impl.backend();

    try std.testing.expect(backend.set("key", "value1"));
    try std.testing.expect(backend.set("key", "value2"));

    const value = backend.get("key");
    try std.testing.expectEqualStrings("value2", value.?);
}

test "ClusterConfig strategies are distinct" {
    try std.testing.expect(@intFromEnum(ClusterConfig.OwnershipStrategy.hash_based) != @intFromEnum(ClusterConfig.OwnershipStrategy.range_based));
    try std.testing.expect(@intFromEnum(ClusterConfig.OwnershipStrategy.consistent_hash) != @intFromEnum(ClusterConfig.OwnershipStrategy.hash_based));
}

test "ClusterState and PeerState enums" {
    // Ensure all states are distinct
    try std.testing.expect(@intFromEnum(ClusterState.initializing) != @intFromEnum(ClusterState.active));
    try std.testing.expect(@intFromEnum(PeerState.disconnected) != @intFromEnum(PeerState.connected));
}
