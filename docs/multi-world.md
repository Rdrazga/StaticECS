# Multi-World Coordination

StaticECS supports running multiple ECS worlds that can coordinate and transfer entities between them using lock-free queues.

## Overview

Multi-world architectures enable sophisticated entity processing pipelines where different worlds specialize in different tasks. This is particularly useful for:

- **Server pipelines**: Accept → I/O → Compute stages for high-throughput request handling
- **Game scenes**: Separate worlds for menu, gameplay, loading screens
- **Physics zones**: Different simulation spaces with varying update frequencies
- **LOD management**: Worlds with different levels of detail and update rates
- **Server sharding**: Distribute entities across worlds for scalability

## Architecture

The coordination system uses a pipeline architecture where entities flow between specialized worlds:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   World 0   │ ──► │   World 1   │ ──► │   World 2   │
│   (Accept)  │     │    (I/O)    │     │  (Compute)  │
└─────────────┘     └─────────────┘     └─────────────┘
      │                   ▲                   │
      └───────────────────┴───────────────────┘
             Lock-free Transfer Queues
```

Each arrow represents a lock-free queue that enables zero-latency entity transfers between worlds without mutex contention.

---

## Configuration

### World Roles

Configure each world with a specific role via [`WorldCoordinationConfig`](../src/ecs/config/coordination_config.zig:94):

```zig
const ecs = @import("ecs");

pub const cfg = ecs.WorldConfig{
    .components = .{ .types = &.{ Position, Velocity, RequestData } },
    .coordination = .{
        .role = .io,              // This world handles I/O operations
        .world_id = 1,            // Unique ID within coordinator
        .transfer_queue = .{
            .capacity = 4096,     // Queue capacity (power of 2)
            .batch_size = 64,     // Batch transfer size
            .spsc = false,        // MPMC mode for multiple producers
        },
        .routing = .{
            .default_target = 2,  // Entities route to world 2 by default
        },
    },
};
```

### Available World Roles

| Role | Description | Optimization Focus |
|------|-------------|-------------------|
| [`standalone`](../src/ecs/config/coordination_config.zig:19) | Default single-world mode (no coordination) | General purpose |
| [`accept`](../src/ecs/config/coordination_config.zig:24) | Connection acceptance | Low latency, high connection rate |
| [`io`](../src/ecs/config/coordination_config.zig:29) | Read/write operations | Syscall batching, io_uring |
| [`compute`](../src/ecs/config/coordination_config.zig:34) | CPU-bound processing | Cache efficiency, work-stealing |
| [`custom`](../src/ecs/config/coordination_config.zig:38) | User-defined role | No built-in optimizations |

### Transfer Queue Configuration

The [`TransferQueueConfig`](../src/ecs/config/coordination_config.zig:47) controls entity transfer behavior:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `capacity` | `u32` | `4096` | Queue capacity (must be power of 2) |
| `batch_size` | `u32` | `64` | Batch size for bulk transfers |
| `spsc` | `bool` | `false` | Enable SPSC optimization (single producer/consumer) |

```zig
.transfer_queue = .{
    .capacity = 8192,      // Higher capacity for burst handling
    .batch_size = 128,     // Larger batches for throughput
    .spsc = true,          // Enable when only one producer/consumer pair
},
```

### Routing Configuration

The [`RoutingConfig`](../src/ecs/config/coordination_config.zig:77) determines where entities go after processing:

```zig
.routing = .{
    .default_target = 2,           // Default destination world
    .component_routes = &.{        // Component-based routing rules
        .{ .component_name = "ErrorMarker", .target_world = 3 },
        .{ .component_name = "Priority", .target_world = 1 },
    },
},
```

---

## WorldCoordinator

The [`WorldCoordinator`](../src/ecs/coordination/coordinator.zig:137) manages transfer queues between worlds.

### Creating a Coordinator

```zig
const ecs = @import("ecs");
const std = @import("std");

// Define shared component types
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };

// Configure worlds with same component schema
const cfg = ecs.WorldConfig{
    .components = .{ .types = &.{ Position, Velocity } },
    .coordination = .{
        .role = .standalone,
        .transfer_queue = .{ .capacity = 1024 },
    },
};

// Create coordinator for 3 worlds
const Coordinator = ecs.WorldCoordinator(cfg, 3);
var coordinator = Coordinator.init(std.testing.allocator);
defer coordinator.deinit();
```

### Coordinator API

| Method | Description |
|--------|-------------|
| [`init(allocator)`](../src/ecs/coordination/coordinator.zig:171) | Initialize coordinator with transfer queues |
| [`start()`](../src/ecs/coordination/coordinator.zig:195) | Mark coordinator as running |
| [`stop()`](../src/ecs/coordination/coordinator.zig:200) | Stop coordinator |
| [`isRunning()`](../src/ecs/coordination/coordinator.zig:205) | Check running state |
| [`queueTransfer(src, dst, transfer)`](../src/ecs/coordination/coordinator.zig:211) | Queue entity for transfer |
| [`popTransferFor(world_id)`](../src/ecs/coordination/coordinator.zig:236) | Pop pending transfer for a world |
| [`popTransferBatchFor(world_id, out)`](../src/ecs/coordination/coordinator.zig:254) | Batch pop transfers |
| [`pendingTransfersFor(world_id)`](../src/ecs/coordination/coordinator.zig:275) | Count pending transfers |
| [`getStats()`](../src/ecs/coordination/coordinator.zig:307) | Get coordinator statistics |

### Basic Usage

```zig
// Start the coordinator
coordinator.start();

// Create a transfer packet
var transfer = Coordinator.createTransfer(0, 1);  // world 0 → world 1

// Pack component data
_ = transfer.packComponent(Position, .{ .x = 10.0, .y = 20.0 });
_ = transfer.packComponent(Velocity, .{ .dx = 1.0, .dy = 0.5 });

// Queue the transfer
if (coordinator.queueTransfer(0, 1, transfer)) {
    // Transfer queued successfully
} else {
    // Queue full - handle back-pressure
}

// In target world's tick, pop and process transfers
while (coordinator.popTransferFor(1)) |incoming| {
    // Unpack components and create entity in target world
    if (incoming.unpackComponent(Position)) |pos| {
        // Use position data
        _ = pos;
    }
}
```

---

## Entity Transfers

### Transfer Marker Component

Mark entities for transfer using [`TransferMarker`](../src/ecs/coordination/transfer.zig:38):

```zig
const TransferMarker = ecs.TransferMarker;

fn systemThatMarksForTransfer(ctx_ptr: *anyopaque) !void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{RequestComplete},
    });
    
    while (query.next()) |result| {
        const entity = result.entity;
        
        // Mark entity for transfer to world 1
        ctx.commands.setComponent(entity, TransferMarker{
            .target_world = 1,
            .priority = true,           // Process first
            .destroy_on_transfer = true, // Remove from source world
        });
    }
}
```

### EntityTransfer Type

The [`EntityTransfer`](../src/ecs/coordination/transfer.zig:76) type is generated at comptime from your `WorldConfig`:

```zig
const Transfer = ecs.EntityTransfer(cfg);

// Create transfer for world 0 → world 2
var transfer = Transfer.init(0, 2);

// Set transfer flags
transfer.flags = .{
    .destroy_on_arrive = true,   // Destroy in source after transfer
    .priority = false,            // Normal priority
    .full_transfer = true,        // Transfer all components
};

// Pack components (order-independent due to fixed offsets)
_ = transfer.packComponent(Position, .{ .x = 5.0, .y = 10.0 });
_ = transfer.packComponent(Velocity, .{ .dx = 1.0, .dy = 0.0 });

// Check component presence
if (transfer.hasComponent(Position)) {
    // Position was packed
}

// Unpack on receiving side
if (transfer.unpackComponent(Position)) |pos| {
    std.debug.print("Received position: ({}, {})\n", .{ pos.x, pos.y });
}

// Reset for reuse (keeps source/target)
transfer.reset();
```

---

## Lock-Free Queues

Coordination uses bounded lock-free queues for thread-safe entity transfers.

### MPMC Queue

[`LockFreeQueue`](../src/ecs/coordination/lock_free_queue.zig:34) supports multiple producers and consumers:

```zig
const LockFreeQueue = ecs.LockFreeQueue;

// Create queue with capacity 256 (must be power of 2)
const Queue = LockFreeQueue(u32, 256);
var queue = Queue.init();

// Push (thread-safe, multiple producers allowed)
if (queue.push(42)) {
    // Success
} else {
    // Queue full
}

// Pop (thread-safe, multiple consumers allowed)
if (queue.pop()) |value| {
    std.debug.print("Got: {}\n", .{value});
}

// Batch operations for efficiency
const items = [_]u32{ 1, 2, 3, 4, 5 };
const pushed = queue.pushBatch(&items);

var out: [10]u32 = undefined;
const popped = queue.popBatch(&out);
```

### SPSC Queue

[`SPSCQueue`](../src/ecs/coordination/lock_free_queue.zig:235) is optimized for single-producer single-consumer patterns:

```zig
const SPSCQueue = ecs.SPSCQueue;

// More efficient when only one thread produces and one consumes
const Queue = SPSCQueue(u32, 256);
var queue = Queue.init();

// Producer thread only
_ = queue.push(100);

// Consumer thread only
if (queue.pop()) |value| {
    _ = value;
}
```

**When to use SPSC**: Pipeline architectures where each world pair has exactly one source and one destination (e.g., Accept → I/O → Compute chain).

---

## Pipeline Helper

Use [`createPipelineConfigs()`](../src/ecs/coordination/coordinator.zig:334) to quickly set up a standard 3-world pipeline:

```zig
const configs = ecs.createPipelineConfigs(base_cfg);

// configs.accept - World 0: Accept connections, routes to world 1
// configs.io     - World 1: Handle I/O, routes to world 2  
// configs.compute - World 2: CPU processing, routes back to world 1

const AcceptWorld = ecs.World(configs.accept);
const IoWorld = ecs.World(configs.io);
const ComputeWorld = ecs.World(configs.compute);
```

---

## Complete Example: Server Pipeline

```zig
const std = @import("std");
const ecs = @import("ecs");

// Components
const Connection = struct { fd: i32, state: enum { reading, processing, writing } };
const RequestData = struct { buffer: [4096]u8, len: usize };
const ResponseData = struct { buffer: [4096]u8, len: usize, status: u16 };

// Base configuration
const base_cfg = ecs.WorldConfig{
    .components = .{ .types = &.{ Connection, RequestData, ResponseData } },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "connection", .components = &.{ Connection, RequestData, ResponseData } },
        },
    },
};

// Create pipeline configs
const configs = ecs.createPipelineConfigs(base_cfg);

const AcceptWorld = ecs.World(configs.accept);
const IoWorld = ecs.World(configs.io);
const ComputeWorld = ecs.World(configs.compute);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize worlds
    var accept_world = AcceptWorld.init(alloc);
    defer accept_world.deinit();
    
    var io_world = IoWorld.init(alloc);
    defer io_world.deinit();
    
    var compute_world = ComputeWorld.init(alloc);
    defer compute_world.deinit();

    // Initialize coordinator
    const Coordinator = ecs.WorldCoordinator(base_cfg, 3);
    var coordinator = Coordinator.init(alloc);
    defer coordinator.deinit();
    
    coordinator.start();

    // Main loop
    while (coordinator.isRunning()) {
        // Process accept world
        processAcceptWorld(&accept_world, &coordinator);
        
        // Process I/O world  
        processIoWorld(&io_world, &coordinator);
        
        // Process compute world
        processComputeWorld(&compute_world, &coordinator);
        
        // Small sleep to prevent busy loop
        std.time.sleep(1_000_000); // 1ms
    }
}

fn processAcceptWorld(world: *AcceptWorld, coordinator: anytype) void {
    // Accept new connections and transfer to I/O world
    _ = world;
    _ = coordinator;
    // ... implementation
}

fn processIoWorld(world: *IoWorld, coordinator: anytype) void {
    // Handle reads, transfer to compute
    // Handle writes from compute results
    _ = world;
    _ = coordinator;
    // ... implementation
}

fn processComputeWorld(world: *ComputeWorld, coordinator: anytype) void {
    // Process requests, transfer responses back to I/O
    _ = world;
    _ = coordinator;
    // ... implementation
}
```

---

## Statistics and Monitoring

The coordinator tracks statistics via [`CoordinatorStats`](../src/ecs/coordination/coordinator.zig:73):

```zig
// Get statistics snapshot (thread-safe)
const stats = coordinator.getStats();

std.debug.print("Ticks: {}\n", .{stats.ticks});
std.debug.print("Transfers sent from world 0: {}\n", .{stats.transfers_sent[0]});
std.debug.print("Transfers received by world 1: {}\n", .{stats.transfers_received[1]});
std.debug.print("Queue full events: {}\n", .{stats.queue_full_count});
std.debug.print("Total tick time: {}ns\n", .{stats.total_tick_time_ns});

// Reset statistics
coordinator.resetStats();
```

---

## Best Practices

### Schema Compatibility

**Keep world schemas compatible** for transfers. All worlds in a coordinator should share the same component types to enable seamless entity transfers:

```zig
// Good: Same components in all worlds
const shared_components = &.{ Position, Velocity, Health };

const world1_cfg = ecs.WorldConfig{
    .components = .{ .types = shared_components },
    .coordination = .{ .role = .accept, .world_id = 0 },
};

const world2_cfg = ecs.WorldConfig{
    .components = .{ .types = shared_components },
    .coordination = .{ .role = .compute, .world_id = 1 },
};
```

### Batch Transfers

**Batch transfers for efficiency** - reduce per-operation overhead:

```zig
// Instead of individual pops
while (coordinator.popTransferFor(1)) |t| { ... }

// Use batch pop when processing many transfers
var buffer: [64]Transfer = undefined;
const count = coordinator.popTransferBatchFor(1, &buffer);
for (buffer[0..count]) |transfer| {
    // Process transfers in batch
    _ = transfer;
}
```

### Back-Pressure Handling

**Handle queue full conditions** gracefully:

```zig
if (!coordinator.queueTransfer(src, dst, transfer)) {
    // Queue full - implement back-pressure strategy:
    // 1. Retry with exponential backoff
    // 2. Drop low-priority entities
    // 3. Store locally and retry next tick
    // 4. Signal upstream to slow down
}
```

### SPSC Optimization

**Use SPSC mode** when your pipeline has single producer/consumer pairs:

```zig
// Enable for linear pipelines (A → B → C)
.transfer_queue = .{
    .spsc = true,  // More efficient atomics
},
```

### Sizing Transfer Queues

**Size queues appropriately** for your workload:

| Workload | Recommended Capacity | Batch Size |
|----------|---------------------|------------|
| Low throughput | 256-1024 | 16-32 |
| Medium throughput | 2048-4096 | 64 |
| High throughput | 8192-16384 | 128-256 |
| Burst handling | 16384+ | 256 |

---

## Thread Safety

The coordination system is designed for thread-safe operation:

| Component | Thread Safety |
|-----------|--------------|
| [`LockFreeQueue`](../src/ecs/coordination/lock_free_queue.zig:34) | Multiple producers/consumers |
| [`SPSCQueue`](../src/ecs/coordination/lock_free_queue.zig:235) | Single producer, single consumer |
| [`CoordinatorStats`](../src/ecs/coordination/coordinator.zig:73) | Atomic counters |
| [`WorldCoordinator`](../src/ecs/coordination/coordinator.zig:137) | Thread-safe queuing |

Worlds themselves should typically be accessed from a single thread, with coordination queues handling cross-thread communication.

---

## Related Documentation

- **[Configuration Reference](CONFIGURATION.md#coordination)** - CoordinationConfig details
- **[Execution Models](execution-models.md)** - Threading and async options
- **[Quick Start](quick-start.md)** - Basic StaticECS usage

---

## Limitations

- Maximum 8 worlds per coordinator (compile-time limit)
- Transfer queue capacity must be power of 2
- Component schemas should match across coordinated worlds
- No automatic entity ID remapping (entities get new IDs in target world)