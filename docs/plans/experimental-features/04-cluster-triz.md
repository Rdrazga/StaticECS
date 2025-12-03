# Cluster Coordination TRIZ Analysis

**Status:** Complete
**Feature:** Cluster Coordination Network Transport
**Module:** `scalability/cluster.zig`
**Date:** 2024-11-29

## Current State Analysis

### What Works (Local Coordination)

The cluster coordination framework provides complete **single-process multi-world coordination**:

| Component | Location | Status | Description |
|-----------|----------|--------|-------------|
| [`EntityOwnership`](../../../src/ecs/scalability/cluster.zig:39) | cluster.zig | ✅ Functional | Hash/range/consistent-hash ownership calculation |
| [`ClusterCoordinator`](../../../src/ecs/scalability/cluster.zig:220) | cluster.zig | ⚠️ Framework | State machine, no network transport |
| [`SharedStateBackend`](../../../src/ecs/scalability/cluster.zig:416) | cluster.zig | ✅ Interface | Abstract interface for distributed state |
| [`InMemoryBackend`](../../../src/ecs/scalability/cluster.zig:451) | cluster.zig | ✅ Functional | In-memory implementation for testing |
| [`EntityTransfer`](../../../src/ecs/coordination/transfer.zig:80) | transfer.zig | ✅ Functional | Comptime-generated serialization with alignment |
| [`LockFreeQueue`](../../../src/ecs/coordination/lock_free_queue.zig:34) | lock_free_queue.zig | ✅ Functional | MPMC queue for inter-world communication |
| [`WorldCoordinator`](../../../src/ecs/coordination/coordinator.zig:291) | coordinator.zig | ✅ Functional | N×N queue matrix for local worlds |

### What Doesn't Work (Distributed)

- **No network transport**: No TCP/UDP/RDMA socket implementation
- **No remote discovery**: Cannot find nodes automatically
- **No heartbeat protocol**: `tick()` checks timeouts but sends nothing
- **No cross-process communication**: Limited to single process

---

## 1. Problem Statement

### Technical System Description

Cluster coordination in StaticECS enables horizontal scaling through:
- **Entity ownership calculation**: Determining which node owns an entity
- **Transfer queues**: Message-passing between worlds
- **State synchronization**: Shared state backends
- **Health monitoring**: Peer state tracking with timeouts

The framework assumes a transport layer exists but provides none.

### Core Challenges

1. **No network transport exists for distributed ECS**
   - All coordination currently in-memory only
   - `join()`, `leave()`, `tick()` update local state only

2. **Scale coordination patterns beyond single process**
   - `WorldCoordinator` N×N queue matrix works in-process
   - No mechanism to bridge to remote processes

3. **Maintain consistency guarantees across network**
   - `EntityTransfer` serialization is ready
   - No protocol for at-least-once / exactly-once delivery

4. **Handle partial failures gracefully**
   - `PeerState` tracking exists (failed, connected, etc.)
   - No actual failure detection mechanism

---

## 2. Ideal Final Result (IFR)

The **perfect cluster coordination** would have these properties:

| Property | Description | Priority |
|----------|-------------|----------|
| **Seamless multi-machine coordination** | ECS worlds on different machines coordinate as if local | High |
| **Transparent local→remote transfer** | `EntityTransfer` works identically for local and remote | High |
| **Automatic partition management** | Entities automatically move to correct owner node | Medium |
| **Zero networking complexity for simple cases** | Single-node deployments have no network overhead | High |
| **Compile-time configuration** | Network transport compiles out when disabled | High |
| **Self-healing cluster** | Automatic node discovery, failover, rebalancing | Low |
| **Pluggable consistency levels** | Strong, eventual, causal consistency options | Medium |

### Alignment with StaticECS Philosophy

> *"Compile into exactly the right system"*

- Network transport should be an **optional layer** that compiles out completely when not needed
- Configuration should determine what network code exists at runtime
- No hidden allocations or runtime costs for single-node deployments

---

## 3. Technical Contradictions

### Primary Contradictions

| Improving Parameter | Worsening Parameter | Contradiction Description |
|---------------------|---------------------|--------------------------|
| **Consistency** | **Latency** | Strong consistency requires acknowledgments and synchronization, increasing latency |
| **Simplicity** | **Distributed Capabilities** | Simple API hides complex distributed systems concerns (ordering, failures, partitions) |
| **Performance** | **Reliability** | Fast fire-and-forget messaging loses reliability; reliable messaging adds overhead |
| **Generality** | **Efficiency** | Generic serialization (JSON, protobuf) is flexible but slow; specialized is fast but rigid |
| **Availability** | **Consistency** | CAP theorem: cannot have both under network partition |

### CAP Theorem Implications

For StaticECS cluster coordination:

| Scenario | Choice | Rationale |
|----------|--------|-----------|
| Game servers | AP (Availability + Partition tolerance) | Prefer stale data over unavailability |
| Financial systems | CP (Consistency + Partition tolerance) | Prefer unavailability over inconsistency |
| Default | Configurable | Let users choose via `ClusterConfig` |

---

## 4. Inventive Principles Analysis

### TRIZ Principle #1: Segmentation
**Divide a system into independent parts**

**Application**: Partition worlds by responsibility
- Each world handles specific entity types
- Ownership strategies already support this (hash, range, consistent-hash)
- Network transport sends only to relevant owners

**Solution Concept**: Zone-based partitioning
```
World 0 (Zone A)  ←→  World 1 (Zone B)  ←→  World 2 (Zone C)
   [Players]            [NPCs]              [Items]
```

---

### TRIZ Principle #2: Extraction
**Extract the disturbing part from an object**

**Application**: Networked transfer as separate layer
- Current: Transfer and coordination tightly coupled
- Better: Transport abstraction layer that `WorldCoordinator` uses

**Solution Concept**: Transport trait/interface
```zig
pub const Transport = struct {
    vtable: *const VTable,
    
    const VTable = struct {
        send: *const fn(peer: PeerId, data: []const u8) SendError!void,
        recv: *const fn(buffer: []u8) RecvError!usize,
        connect: *const fn(addr: Address) ConnectError!PeerId,
    };
    
    // Implementations: LocalQueue, TCP, UDP, RDMA, ZeroMQ...
};
```

---

### TRIZ Principle #3: Local Quality
**Change an object's structure from uniform to non-uniform**

**Application**: Different consistency per world type
- Some worlds need strong consistency (authoritative state)
- Other worlds tolerate eventual consistency (visual effects)

**Solution Concept**: Per-world consistency config
```zig
pub const WorldConsistency = enum {
    strong,      // Full sync, ordered delivery
    causal,      // Causally ordered
    eventual,    // Fire and forget
};

pub const WorldConfig = struct {
    // ... existing fields ...
    consistency: WorldConsistency = .eventual,
};
```

---

### TRIZ Principle #4: Asymmetry
**Change from symmetrical to asymmetrical form**

**Application**: Master/worker patterns instead of peer-to-peer
- One coordinator node for ordering decisions
- Worker nodes execute but don't coordinate

**Solution Concept**: Coordinator election
- Leader handles entity ownership disputes
- Followers only communicate with leader
- Simpler protocol than full mesh

---

### TRIZ Principle #6: Universality
**Make a part perform multiple functions**

**Application**: Unified local/remote transfer API
- `EntityTransfer` already serializes consistently
- Same `queueTransfer()` API for local or remote

**Solution Concept**: Transparent transport selection
```zig
pub fn queueTransfer(source: u8, target: u8, transfer: Transfer) bool {
    if (isLocalWorld(target)) {
        return queues[source][target].push(transfer);
    } else {
        return network.send(getNodeForWorld(target), serialize(transfer));
    }
}
```

---

### TRIZ Principle #7: Nesting (Matryoshka)
**Place one object inside another**

**Application**: Clusters of clusters (hierarchical)
- Local cluster: worlds within a process
- Regional cluster: processes on same machine
- Global cluster: machines across network

**Solution Concept**: Hierarchical coordination
```
Global Coordinator
    ├── Region 1 (Machine A)
    │   ├── World 0
    │   └── World 1
    └── Region 2 (Machine B)
        ├── World 2
        └── World 3
```

---

### TRIZ Principle #24: Intermediary
**Use an intermediate object to transfer or carry out an action**

**Application**: Message broker/relay pattern
- Instead of N×N connections, use central broker
- Kafka, Redis Streams, NATS, ZeroMQ patterns

**Solution Concept**: Broker-based transport
```
World 0 → Broker → World 2
World 1 ↗        ↘ World 3
```

Benefits: Decoupling, buffering, persistence, ordering

---

### TRIZ Principle #25: Self-Service
**Make an object service itself**

**Application**: Auto-discovery, self-healing clusters
- Nodes announce themselves via multicast/gossip
- Failed nodes automatically removed
- Rebalancing without manual intervention

**Solution Concept**: Gossip protocol
- Each node periodically broadcasts state
- Merge received states (CRDTs)
- Eventually consistent membership view

---

### TRIZ Principle #26: Copying
**Use simple, inexpensive copies instead of expensive originals**

**Application**: Replicated read-only state
- Components that rarely change can be replicated
- Read from local replica, write to owner
- Reduces cross-network queries

**Solution Concept**: Component replication strategy
```zig
pub const ReplicationPolicy = enum {
    owner_only,      // Only owner has data
    read_replicas,   // Replicate to all nodes
    sharded,         // Partition by entity ID
};
```

---

### TRIZ Principle #35: Parameter Changes
**Change an object's physical state or concentration**

**Application**: Configurable consistency levels
- Per-operation consistency choice
- Trade latency for consistency as needed

**Solution Concept**: Operation-level consistency
```zig
pub const SendOptions = struct {
    consistency: enum { fire_and_forget, ack_required, ordered } = .fire_and_forget,
    timeout_ms: u32 = 1000,
    retries: u8 = 3,
};
```

---

## 5. Resources Analysis

### Available Resources

#### System Resources (Already Implemented)
| Resource | Location | Reusability |
|----------|----------|-------------|
| `EntityTransfer` serialization | transfer.zig | ✅ Network-ready |
| Comptime component offsets | transfer.zig | ✅ Zero-copy potential |
| `LockFreeQueue` patterns | lock_free_queue.zig | ✅ Reference for network buffers |
| `SharedStateBackend` interface | cluster.zig | ✅ Distributed state abstraction |
| Ownership calculation | cluster.zig | ✅ No changes needed |
| Peer state tracking | cluster.zig | ✅ Foundation exists |

#### Environmental Resources (Zig Standard Library)
| Resource | Usage |
|----------|-------|
| `std.net.Stream` | TCP connections |
| `std.net.Address` | Address parsing |
| `std.posix.socket` | Low-level sockets |
| `std.Thread` | Background I/O |
| `std.io.poll` | Select-based I/O |

#### External Resources (Third-Party Options)
| Resource | Type | Pros | Cons |
|----------|------|------|------|
| **ZeroMQ** | Messaging library | Battle-tested, patterns | C dependency |
| **liburing** | io_uring wrapper | High performance | Linux only |
| **QUIC** | UDP+reliability | Modern, multiplexed | Complex |
| **Custom UDP** | Raw sockets | Full control | Lots of work |
| **TCP** | Stream sockets | Simple, reliable | Head-of-line blocking |

### Underutilized Resources

1. **Comptime packet layout**: `EntityTransfer` computes offsets at compile time - could generate network packet parsers
2. **Existing seqlock pattern**: `Seqlock` in coordinator.zig could be used for shared network state
3. **SPSC queue**: Optimized for known producer/consumer - perfect for per-connection buffers

---

## 6. Solution Concepts

### Approach A: Minimal Shim (LOW effort)

**Philosophy**: Add just enough to bridge processes

**Implementation**:
1. Add TCP transport that uses existing `EntityTransfer` serialization
2. `WorldCoordinator` gains `addRemoteWorld(address)` method
3. Remote worlds appear in queue matrix, but actually send over network

**Scope**:
- TCP client/server in ~300 lines
- Configuration for peer addresses
- No discovery, no auto-failover

**Effort**: 2-3 days

**Limitations**:
- Manual peer configuration
- No HA, no rebalancing
- TCP head-of-line blocking

---

### Approach B: UDP + Reliability Layer (MEDIUM effort)

**Philosophy**: Build reliability on UDP for better performance

**Implementation**:
1. Custom UDP protocol with sequence numbers
2. Selective ACKs for reliability
3. Batching for efficiency
4. Optional delivery guarantees

**Scope**:
- UDP transport with reliability
- Configurable delivery modes
- Simple peer management

**Effort**: 1-2 weeks

**Limitations**:
- More complex than TCP
- Still needs external discovery

---

### Approach C: Full Distributed System (HIGH effort)

**Philosophy**: Complete distributed ECS with all features

**Implementation**:
1. ZeroMQ or similar for transport
2. Gossip-based membership
3. Consistent hashing with virtual nodes
4. Automatic rebalancing
5. Multi-level consistency

**Scope**:
- Full distributed systems concerns
- External dependency (ZeroMQ)
- Comprehensive testing needed

**Effort**: 1-2 months

**Limitations**:
- Significant complexity
- External dependencies
- Maintenance burden

---

### Approach D: Defer to External (ZERO implementation effort)

**Philosophy**: Document how to integrate with existing solutions

**Implementation**:
1. Document `SharedStateBackend` implementations for Redis, etcd
2. Show how to use external message queues (Kafka, NATS)
3. Provide examples but no built-in transport

**Scope**:
- Documentation only
- Example integrations
- User brings their own networking

**Effort**: 1-2 days documentation

**Limitations**:
- Not "batteries included"
- Each user reinvents integration

---

## 7. Implementation Recommendations

### Go/No-Go Decision: **CONDITIONAL GO - Approach A (Minimal Shim)**

#### Rationale

| Factor | Assessment |
|--------|------------|
| **User Value** | Medium - Most ECS users don't need distributed |
| **Implementation Cost** | Low for Approach A |
| **Maintenance Burden** | Low if kept simple |
| **Existing Foundation** | Strong - serialization, queues ready |
| **Risk** | Low - can be marked experimental |
| **Alternative** | Users can implement their own using `SharedStateBackend` |

#### Recommendation

**Implement Approach A (Minimal Shim)** with these constraints:

1. **Keep it simple**: TCP only, manual peer configuration
2. **Mark experimental**: Clear warnings in docs
3. **Design for replacement**: Transport trait allows future upgrades
4. **No external deps**: Pure Zig implementation
5. **Compile-out when disabled**: Zero cost for single-node

### MVP Scope

#### Phase 1: Transport Abstraction (Day 1)
- [ ] Define `Transport` interface in new `cluster_transport.zig`
- [ ] Create `LocalTransport` that wraps existing queue matrix
- [ ] Refactor `WorldCoordinator` to use transport abstraction

#### Phase 2: TCP Transport (Days 2-3)
- [ ] Implement `TcpTransport` with basic connect/send/recv
- [ ] Add peer configuration to `ClusterConfig`
- [ ] Wire `ClusterCoordinator.tick()` to send heartbeats
- [ ] Implement `join()` to establish connections

#### Phase 3: Integration & Testing (Day 4)
- [ ] Integration test with 2 processes
- [ ] Benchmark local vs. TCP overhead
- [ ] Update documentation

### Technology Selection

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Transport | TCP via `std.net.Stream` | Simple, reliable, no deps |
| Serialization | Existing `EntityTransfer` | Already comptime-optimized |
| Threading | Single I/O thread | Avoid complexity |
| Discovery | Manual config | MVP simplicity |
| Consistency | Fire-and-forget | Matches local queues |

### Estimated Effort

| Phase | Duration | Risk |
|-------|----------|------|
| Phase 1: Abstraction | 0.5 days | Low |
| Phase 2: TCP | 1.5 days | Medium |
| Phase 3: Integration | 1 day | Medium |
| **Total** | **3 days** | **Medium** |

### Future Enhancements (Post-MVP)

1. **UDP transport**: For latency-sensitive use cases
2. **Auto-discovery**: Multicast announcement
3. **Consistency options**: ACK modes, ordering
4. **Compression**: For large transfers
5. **Encryption**: TLS wrapper

---

## 8. Key Inventive Solutions Summary

| TRIZ Principle | Application | Implementation |
|----------------|-------------|----------------|
| **#2 Extraction** | Separate transport layer | `Transport` trait abstraction |
| **#6 Universality** | Unified local/remote API | Same `queueTransfer()` for both |
| **#3 Local Quality** | Per-world consistency | Configuration option |
| **#26 Copying** | Existing serialization | Reuse `EntityTransfer` as-is |

---

## References

- [00-OVERVIEW.md](00-OVERVIEW.md) - Parent planning document
- [cluster.zig](../../../src/ecs/scalability/cluster.zig) - Cluster framework
- [transfer.zig](../../../src/ecs/coordination/transfer.zig) - Entity serialization
- [coordinator.zig](../../../src/ecs/coordination/coordinator.zig) - Local coordination
- [lock_free_queue.zig](../../../src/ecs/coordination/lock_free_queue.zig) - Queue implementation