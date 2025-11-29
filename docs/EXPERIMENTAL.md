# Experimental Features

These features are not production-ready. They may change significantly or be removed in future versions.

Use experimental features at your own risk. APIs may change without notice.

---

## GPU Compute Executor

**File:** [`src/ecs/pipeline/executors.zig`](../src/ecs/pipeline/executors.zig)  
**Status:** ⛔ Placeholder - Not Implemented

The GPU compute executor is designed for offloading data-parallel ECS operations to GPU compute shaders. Currently, all operations return `error.GpuUnavailable`.

### What Doesn't Work

- `GpuComputeExecutor.init()` - Always returns `error.GpuUnavailable`
- `dispatch()` - Not implemented
- `sync()` - Not implemented

### Current Behavior

```zig
const GpuExecutor = ecs.GpuComputeExecutor(cfg);
const executor = GpuExecutor.init(.{}) catch |err| {
    // Always reaches here with err == error.GpuUnavailable
    return err;
};
```

### Future Plans

- SPIR-V compute shader generation from component queries
- Vulkan/Metal/WebGPU backend support
- Automatic CPU fallback for unsupported hardware
- GPU↔CPU memory transfer optimization

---

## External Thread Pool

**File:** [`src/ecs/pipeline/executors.zig`](../src/ecs/pipeline/executors.zig)  
**Status:** ⚠️ Incomplete - Tasks Don't Execute

The external thread pool interface allows integrating with OS thread pools or external threading libraries. Task handles are created but work is never dispatched.

### What Works

- `ExternalThreadPool.init()` - Creates pool structure
- `submitTask()` - Returns `TaskHandle` with incrementing ID
- `getTaskStatus()` - Returns the handle's status field
- `getStatus()` - Returns executor status

### What Doesn't Work

- **Submitted tasks are never executed**
- `waitTask()` - No-op, returns immediately
- `cancelTask()` - No-op
- No actual thread management occurs

### Current Behavior

```zig
const Pool = ecs.ExternalThreadPool(cfg);
var pool = Pool.init(.{});

// Creates handle but work is never dispatched
const handle = try pool.submitTask(MyTask, .{ .data = value });
// handle.status == .pending (forever)

pool.waitTask(handle); // Returns immediately, task not executed
```

### Future Plans

- OS thread pool backends (Windows ThreadPool, GCD)
- Integration with external libraries (libuv, tokio FFI)
- Work-stealing coordination with internal scheduler

---

## Batch Worker Pool (formerly SimdWorkerPool)

**File:** [`src/ecs/pipeline/executors.zig`](../src/ecs/pipeline/executors.zig)
**Status:** ⚠️ Sequential Batch Processing (Non-SIMD)

The batch worker pool processes entities in batches for cache-friendly access patterns. Despite the former name (`SimdWorkerPool`), it does NOT use hardware SIMD intrinsics.

> **Renamed in Phase 7.3**: `SimdWorkerPool` → `BatchWorkerPool` for accuracy.
> The old names remain as deprecated aliases for backwards compatibility.

### What Works

- `BatchWorkerPool.init()` - Creates pool structure
- `processArray()` - Processes arrays sequentially per batch
- `processArrays()` - Processes paired arrays sequentially
- `reduce()` - Performs reduction sequentially
- Statistics tracking (items/batches processed)

### What Doesn't Work

- **No actual SIMD intrinsics** (`@Vector`) are used
- No architecture-specific optimizations (SSE, AVX, NEON)
- Performance is identical to scalar processing

### Current Behavior

```zig
const Pool = ecs.BatchWorkerPool(cfg);
var pool = try Pool.init(allocator, .{});

// Batch processing - sequential, not vectorized:
pool.processArray(f32, positions, struct {
    fn process(pos: *f32) void {
        pos.* *= 2.0; // Scalar operation, not vectorized
    }
}.process);
```

### Benefits (Without SIMD)

- Sequential memory access for CPU prefetching
- Reduced function call overhead via batching
- Cache-line friendly access patterns

### Future Plans

- `@Vector(N, T)` batch operations for numeric types
- CPU feature detection (SSE4.2, AVX2, NEON)
- Fallback to scalar for non-vectorizable types
- Benchmark verification of actual speedup

### Migration from SimdWorkerPool

The old names are deprecated but still work:

```zig
// Old (deprecated):
const Pool = ecs.SimdWorkerPool(cfg);

// New (recommended):
const Pool = ecs.BatchWorkerPool(cfg);
```

---

## Cluster Coordination

**File:** [`src/ecs/scalability/cluster.zig`](../src/ecs/scalability/cluster.zig)  
**Status:** ⚠️ Framework Only - No Network Transport

The cluster coordination module provides distributed ECS coordination primitives. Currently, it only works for local multi-world scenarios within a single process. No actual network communication occurs.

### What Works

- `ClusterCoordinator.init()` - Creates coordinator with local state
- `getEntityOwner()` - Calculates ownership (hash/range/consistent-hash)
- `isLocalEntity()` - Checks if entity belongs to this node
- `getState()` - Returns current coordination state
- `getStats()` - Returns coordination statistics
- `getPeerState()` - Returns state for specific peer index
- `countConnectedPeers()` - Counts peers marked connected
- `isHealthy()` - Checks quorum based on connected peers
- `receiveHeartbeat()` - Updates peer timestamp (call from transport)
- `markPeerConnected()` - Manually mark peer connected (testing)

### What Doesn't Work

- **No network transport** - TCP/UDP/RDMA not implemented
- `join()` - Updates local state only, no network connection
- `leave()` - Updates local state only, no departure notification
- `tick()` - Checks timeouts locally, doesn't send/receive
- Remote node discovery - Cannot find nodes automatically

### Current Behavior

```zig
const Cluster = ecs.ClusterCoordinator(cluster_cfg);
var coord = Cluster.init(allocator);

try coord.join(); // Only updates local state!
// coord.state may be .joining or .active depending on config
// But NO actual network connections are established

// For testing, manually simulate peer connections:
coord.markPeerConnected(0);
coord.markPeerConnected(1);
// Now countConnectedPeers() returns 2
```

### Future Plans

- TCP transport backend
- UDP with reliable delivery for real-time
- RDMA for high-performance clusters
- Automatic peer discovery (mDNS, gossip protocol)
- Entity migration protocol over network
- Consistency guarantees and conflict resolution

### Use Case

Currently useful for:
- Single-process multi-world coordination
- Testing cluster logic without network complexity
- Designing distributed architectures before network implementation

---

## Contributing to Experimental Features

If you're interested in helping implement these features:

1. Check [docs/plans/07-placeholder-features.md](plans/07-placeholder-features.md) for detailed implementation plans
2. Open an issue to discuss your approach before starting
3. Keep experimental APIs behind feature flags when possible
4. Add comprehensive tests before promoting to stable

## Reporting Issues

When reporting issues with experimental features:

1. Clearly state you're using an experimental feature
2. Include the exact error messages
3. Note that behavior may be intentionally limited