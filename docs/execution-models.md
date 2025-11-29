# Execution Models Guide

StaticECS supports six execution models that control how systems are scheduled and executed. This guide explains each model, when to use them, and how to configure them.

## Overview

| Model | Threading | Async I/O | Best For |
|-------|-----------|-----------|----------|
| `blocking_single_thread` | Single | No | Games, simple apps |
| `evented_single_thread` | Single | Yes | Servers, I/O-heavy apps |
| `concurrent_threadpool` | Multi | Yes | High-throughput, CPU-bound |
| `io_uring_batch` | Single | Yes (batched) | High-throughput Linux servers |
| `work_stealing` | Multi | Yes | CPU-bound parallel workloads |
| `adaptive_hybrid` | Dynamic | Yes | Mixed/varying workloads |

## Configuration

Set the execution model in `WorldConfig.schedule`:

```zig
pub const cfg = ecs.WorldConfig{
    .schedule = .{
        .execution_model = .blocking_single_thread,  // Default
        // .execution_model = .evented_single_thread,
        // .execution_model = .concurrent_threadpool,
        .max_parallel_tasks = 0,  // Let scheduler decide (or specify count)
    },
    // ...
};
```

---

## Blocking Single Thread

**Default model.** All systems execute synchronously on the calling thread.

### Characteristics

- Sequential execution of all systems
- No I/O context available
- Simplest mental model
- Deterministic execution order
- Zero threading overhead

### When to Use

- Game loops with simple logic
- Applications without I/O requirements
- Debugging and development
- Small entity counts
- Maximum determinism required

### Configuration

```zig
.schedule = .{
    .execution_model = .blocking_single_thread,
},
```

### System Implementation

Systems in blocking mode are straightforward:

```zig
const FrameError = ecs.FrameError;
const World = ecs.World(cfg);
const Context = ecs.SystemContext(cfg, World);

// Helper to cast opaque pointer
fn getContext(ctx_ptr: *anyopaque) *Context {
    return @ptrCast(@alignCast(ctx_ptr));
}

fn mySystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    // ctx.io is null - don't use I/O operations
    
    var query = ctx.world.query(.{ .include = &.{Position} });
    while (query.next()) |result| {
        // Process synchronously
        _ = result;
    }
}
```

### Frame Execution

```zig
// Create scheduler and execute frame - blocks until complete
const Scheduler = ecs.Scheduler(cfg);
var scheduler = Scheduler.init(&world, null, allocator);
defer scheduler.deinit();

const result = scheduler.tick(delta_time);
// All systems have finished when this returns
```

---

## Evented Single Thread

Single-threaded with async I/O support. Systems can perform non-blocking I/O operations.

### Characteristics

- Single thread with event loop
- `io.async()` available for non-blocking ops
- No concurrent execution (still sequential)
- I/O operations can yield to event loop
- Lower latency for I/O-bound workloads

### When to Use

- HTTP servers
- WebSocket applications
- File I/O-heavy applications
- Database query systems
- Network game servers (single thread)

### Configuration

```zig
.schedule = .{
    .execution_model = .evented_single_thread,
},
```

### System Implementation

Systems can opt-in to I/O access:

```zig
pub const cfg = ecs.WorldConfig{
    .systems = .{
        .systems = &.{
            .{
                .name = "network",
                .func = ecs.asSystemFn(networkSystem),
                .phase = Phase.network.index(),
                .needs_io = true,  // Enable I/O context
            },
        },
    },
    // ...
};

fn networkSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    // IoContext available when needs_io = true
    if (ctx.hasIo()) {
        const io = ctx.getIo();
        
        // Check capabilities
        if (io.hasAsync()) {
            // Can use async operations
            // io.async() - schedules without requiring concurrency
            _ = io;
        }
        
        if (io.hasConcurrency()) {
            // Can use concurrent operations (false in evented model)
        }
    }
}
```

### Async vs Concurrent

Following Zig 0.16 philosophy:

- **Asynchrony**: Tasks may complete out of order
- **Concurrency**: Multiple tasks execute simultaneously

In evented mode:
- `io.async()` - Available (tasks can yield)
- `io.asyncConcurrent()` - Returns error (no parallelism)

```zig
fn serverSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const io = ctx.getIo() orelse return;
    
    // OK: Async without concurrency requirement
    // io.async(handleRequest, .{request, io});
    _ = io;
    
    // Would fail: Concurrent async not supported
    // io.asyncConcurrent(handleRequest, .{request, io}) catch |err| {
    //     // err == error.ConcurrencyUnavailable
    // };
}
```

---

## Concurrent Threadpool

Multi-threaded execution with full async support. Non-conflicting systems run in parallel.

### Characteristics

- Thread pool for parallel execution
- Systems without conflicts run concurrently
- Full async I/O support
- `io.asyncConcurrent()` available
- Maximum throughput for CPU-bound work

### When to Use

- High-performance game engines
- Large entity counts (>10K)
- CPU-bound simulation
- Multi-core scaling required
- High-throughput servers

### Configuration

```zig
.schedule = .{
    .execution_model = .concurrent_threadpool,
    .max_parallel_tasks = 4,  // Or 0 to auto-detect
},
```

### Conflict Detection

The scheduler automatically detects system conflicts based on component access:

```zig
.systems = &.{
    .{
        .name = "movement",
        .write_components = &.{Position},
        .read_components = &.{Velocity},
    },
    .{
        .name = "rendering",
        .read_components = &.{Position, Sprite},  // Read-only Position
        // No conflict with movement - can run in parallel
    },
    .{
        .name = "physics",
        .write_components = &.{Position, Velocity},
        // Conflicts with movement - different stages
    },
},
```

**Conflict rules:**
- Write-Write on same component → Conflict
- Write-Read on same component → Conflict
- Read-Read on same component → No conflict

### System Implementation

```zig
fn parallelSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const io = ctx.getIo() orelse return;
    
    // Full concurrency available
    if (io.hasConcurrency()) {
        // Can use asyncConcurrent for true parallel ops
        // try io.asyncConcurrent(heavyComputation, .{data, io});
        _ = io;
    }
}
```

### Thread Safety Considerations

When using concurrent execution:

1. **Don't share mutable state between systems** unless using atomic operations
2. **Use command buffer for entity mutations** - commands are merged safely
3. **Resources are not automatically synchronized** - use resources carefully
4. **Keep hot paths lock-free** - the ECS handles component access

---

## Execution Model Comparison

### Performance Characteristics

| Aspect | Blocking | Evented | Concurrent | io_uring | Work-Stealing | Adaptive |
|--------|----------|---------|------------|----------|---------------|----------|
| Latency | Lowest | Low | Variable | Low | Variable | Varies |
| Throughput | Limited | Medium | High | Highest | High | Optimized |
| Memory | Minimal | Event loop | Thread stacks | Ring buffers | Per-worker queues | Combined |
| Determinism | Guaranteed | Frame-level | Requires care | Frame-level | Requires care | Varies |

### I/O Capabilities

| Capability | Blocking | Evented | Concurrent | io_uring | Work-Stealing | Adaptive |
|------------|----------|---------|------------|----------|---------------|----------|
| `hasIo()` | `false` | `true` | `true` | `true` | `true` | `true` |
| `hasAsync()` | `false` | `true` | `true` | `true` | `true` | `true` |
| `hasConcurrency()` | `false` | `false` | `true` | `false` | `true` | Varies |
| Batch syscalls | No | No | No | Yes | No | When batching |
| Work stealing | No | No | No | No | Yes | When parallel |

### Platform Support

| Model | Linux | macOS | Windows | FreeBSD |
|-------|-------|-------|---------|---------|
| `blocking_single_thread` | ✅ | ✅ | ✅ | ✅ |
| `evented_single_thread` | ✅ | ✅ | ✅ | ✅ |
| `concurrent_threadpool` | ✅ | ✅ | ✅ | ✅ |
| `io_uring_batch` | ✅ | ❌ | ❌ | ❌ |
| `work_stealing` | ✅ | ✅ | ✅ | ✅ |
| `adaptive_hybrid` | ✅*** | ✅* | ✅* | ✅* |

\* Adaptive without io_uring falls back to blocking/work-stealing only
\*\*\* Full adaptive with io_uring batching

### Migration Between Models

Code written for blocking mode works in other models:

```zig
// This system works in all execution models
fn universalSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{ .include = &.{Position} });
    while (query.next()) |result| {
        const pos = result.get(Position);
        pos.x += 1;
    }
}
```

I/O-aware systems should check capabilities:

```zig
fn adaptiveSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    if (ctx.hasIo()) {
        const io = ctx.getIo();
        if (io.hasConcurrency()) {
            // Use parallel approach
            _ = io;
        } else if (io.hasAsync()) {
            // Use async approach
        }
    } else {
        // Fallback to synchronous
    }
}
```

---

## io_uring Batch Mode

Linux-only mode that batches syscalls per scheduler phase using io_uring.

### Characteristics

- Single-threaded execution
- io_uring submission/completion queues
- Syscalls collected per phase, submitted as batch
- Completions processed before next phase
- Reduced syscall overhead

### When to Use

- Linux kernel 5.1+
- High-throughput servers (many concurrent connections)
- I/O-bound workloads with many syscalls per frame
- Network servers, file servers
- When syscall overhead is a bottleneck

### Configuration

```zig
.schedule = .{
    .execution_model = .io_uring_batch,
    .backend_config = .{ .io_uring_batch = .{
        .sq_entries = 256,        // Submission queue depth
        .cq_entries = 512,        // Completion queue depth
        .batch_size = 64,         // Max ops per batch
        .kernel_poll = false,     // SQPOLL for reduced syscalls
        .sq_thread_cpu = null,    // CPU affinity
    }},
},
```

### How it Works

```
┌─────────────────────────────────────────────────────────────┐
│                    io_uring Batch Phase                      │
│                                                              │
│  1. Collect I/O intents from all systems                    │
│  2. Submit batch to io_uring SQ                             │
│  3. Execute non-I/O systems while waiting                   │
│  4. Process completions from CQ                             │
│  5. Dispatch results to systems                             │
│  6. Move to next phase                                      │
└─────────────────────────────────────────────────────────────┘
```

### Platform Support

- **Linux (x86_64, aarch64)**: Full support via io_uring
- **Other platforms**: Compile error (use `SelectBackend` for fallback)

---

## Work-Stealing Mode

Multi-threaded execution with per-worker queues and task stealing.

### Characteristics

- Per-core local work queues (Chase-Lev deque)
- Idle workers steal from busy workers
- LIFO slot optimization for cache locality
- Automatic load balancing
- Minimal lock contention

### When to Use

- CPU-bound parallel workloads
- Many independent systems
- Variable-cost systems (some fast, some slow)
- Multi-core scaling required
- When system work is imbalanced

### Configuration

```zig
.schedule = .{
    .execution_model = .work_stealing,
    .backend_config = .{ .work_stealing = .{
        .worker_count = 0,        // 0 = auto-detect CPU count
        .local_queue_size = 256,  // Per-worker queue size
        .steal_batch = 32,        // Tasks to steal at once
        .lifo_slot = true,        // Producer cache optimization
        .spin_count = 100,        // Spins before parking
    }},
},
```

### How it Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Work-Stealing Scheduler                   │
│                                                              │
│  Worker 0      Worker 1      Worker 2      Worker 3         │
│  ┌──────┐      ┌──────┐      ┌──────┐      ┌──────┐        │
│  │ [T1] │      │ [T2] │      │ [ ]  │ ←── │ [T3] │        │
│  │ [T4] │      │ [T5] │  steal│ [ ]  │     │ [T6] │        │
│  │ [T7] │      │ [ ]  │      │ [ ]  │     │ [T8] │        │
│  └──────┘      └──────┘      └──────┘      └──────┘        │
│                                                              │
│  • Each worker has local deque                              │
│  • Push/pop from bottom (LIFO, cache-friendly)              │
│  • Steal from top of others (FIFO)                          │
│  • LIFO slot holds most recent task for immediate reuse     │
└─────────────────────────────────────────────────────────────┘
```

### Thread Safety

Work-stealing handles all parallelism internally:
- Component access is still conflict-checked
- Systems with conflicts run in separate stages
- Use command buffer for entity mutations

---

## Adaptive Hybrid Mode

Dynamic backend that switches strategies based on runtime metrics.

### Characteristics

- Monitors I/O and CPU load
- Switches between backends as workload changes
- Rolling metric windows
- Cooldown to prevent oscillation
- Best of multiple strategies

### When to Use

- Workloads that vary over time
- Mixed I/O and CPU patterns
- Unknown workload characteristics
- When you want automatic optimization
- Production servers with varying load

### Configuration

```zig
.schedule = .{
    .execution_model = .adaptive_hybrid,
    .backend_config = .{ .adaptive = .{
        .batch_threshold = 64,       // I/O ops to trigger batching
        .imbalance_threshold = 0.3,  // CPU imbalance to trigger stealing
        .window_size = 100,          // Metrics window (ticks)
        .switch_cooldown = 10,       // Min ticks between switches
        .initial_backend = null,     // null = auto-detect
    }},
},
```

### How it Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Adaptive Backend Logic                    │
│                                                              │
│  Each tick:                                                  │
│  1. Collect metrics (I/O ops, CPU times, worker loads)      │
│  2. Update rolling averages (window_size ticks)             │
│  3. Check thresholds:                                       │
│     • High pending I/O → switch to io_uring batch           │
│     • High CPU imbalance → switch to work-stealing          │
│     • Light load → switch to blocking (lowest overhead)     │
│  4. Apply cooldown to prevent oscillation                   │
│                                                              │
│  Metric: pending_io >= batch_threshold → io_uring           │
│  Metric: cpu_imbalance >= 0.3 → work_stealing               │
│  Otherwise → blocking                                       │
└─────────────────────────────────────────────────────────────┘
```

### Backend Priorities

1. **io_uring batch**: When I/O load is high (Linux only)
2. **Work-stealing**: When CPU imbalance detected
3. **Blocking**: Default, lowest overhead for light loads

---

## Stage Organization

All execution models use the same stage organization:

```
Phase: pre_update
├── Stage 0: [input_system, ai_decision_system]  ← No conflicts, parallel-ready
├── Stage 1: [animation_system]                  ← Depends on previous
Phase: update
├── Stage 0: [movement_system, combat_system]    ← No conflicts
├── Stage 1: [physics_system]                    ← Conflicts with movement
Phase: post_update
├── Stage 0: [cleanup_system]
```

In blocking mode: Systems run sequentially in stage order
In concurrent mode: Non-conflicting systems in same stage run in parallel

---

## Zig 0.16 std.Io Integration

StaticECS uses Zig 0.16-dev's `std.Io` for async I/O operations. The IoBackend abstraction layer automatically detects and uses `std.Io` when available.

### Platform Support

| Platform | Backend | Notes |
|----------|---------|-------|
| Linux (x86_64, aarch64) | `std.Io.Evented` (io_uring) | Full evented support |
| macOS (x86_64, aarch64) | `std.Io.Evented` (kqueue) | Full evented support |
| FreeBSD | `std.Io.Evented` (kqueue) | Full evented support |
| Windows | `std.Io.Threaded` | Threaded backend only |
| Other | `std.Io.Threaded` | Threaded fallback |

### Using std.Io in Systems

```zig
fn networkSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const io = ctx.getIo() orelse return;
    
    // Access the underlying std.Io instance
    if (io.getRawIo()) |raw_io| {
        // Use std.Io directly for advanced operations
        // See Zig std.Io documentation for full API
        _ = raw_io;
    }
    
    // Capability checks
    if (io.hasAsync()) {
        // Can schedule async operations
    }
    if (io.hasConcurrency()) {
        // Can run operations truly in parallel
    }
}
```

### IoContext API

```zig
pub const IoContext = struct {
    // Check I/O capabilities
    pub fn hasAsync(self: *const IoContext) bool;
    pub fn hasConcurrency(self: *const IoContext) bool;
    
    // Get the raw std.Io pointer (platform-specific)
    pub fn getRawIo(self: *IoContext) ?*anyopaque;
    
    // Get required (panics if unavailable)
    pub fn getIoRequired(self: *IoContext) *anyopaque;
};
```

---

## Best Practices

### Start with Blocking

```zig
// Development: Use blocking for predictability
.schedule = .{ .execution_model = .blocking_single_thread },
```

### Profile Before Parallelizing

Don't assume concurrent is faster. Measure:

```zig
// Use benchmarks to compare (Zig 0.16 time API)
const start = try std.time.Instant.now();
_ = Scheduler.executeFrame(&world, dt, tick, null, alloc);
const end = try std.time.Instant.now();
const elapsed_ns = end.since(start);
```

### Declare All Component Access

Accurate conflict detection requires complete declarations:

```zig
// Good: Complete access declaration
.{
    .name = "transform",
    .read_components = &.{ Parent, LocalPosition },
    .write_components = &.{WorldPosition},
}

// Bad: Missing declarations prevent parallel execution
.{
    .name = "transform",
    // No read/write declared - scheduler assumes conflicts
}
```

### Isolate I/O Systems

Keep I/O operations in dedicated phases:

```zig
.phases = .{
    .phases = &.{
        .{ .name = "input", .order = 0 },
        .{ .name = "update", .order = 1 },     // CPU-bound
        .{ .name = "network", .order = 2 },    // I/O-bound
        .{ .name = "render", .order = 3 },     // GPU-bound
    },
},
```

### Use Resources for Cross-System Communication

Instead of shared mutable state:

```zig
const NetworkStats = struct {
    bytes_sent: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),
};

// Insert as resource
world.resources.insert(NetworkStats, .{
    .bytes_sent = std.atomic.Value(u64).init(0),
    .bytes_received = std.atomic.Value(u64).init(0),
});

// Access with atomic operations
fn networkStatsSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    if (ctx.getResource(NetworkStats)) |stats| {
        _ = stats.bytes_sent.fetchAdd(1024, .seq_cst);
    }
}