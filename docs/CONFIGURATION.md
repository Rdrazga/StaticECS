# StaticECS Configuration Reference

This document provides a complete reference for all `WorldConfig` options in StaticECS.
Following Tiger Style principles, **all bounds and limits are configurable** - there are no hardcoded limits that cannot be overridden.

## Table of Contents

- [WorldConfig Overview](#worldconfig-overview)
- [Options](#options) - Core limits and bounds
- [Components](#components) - Component type definitions
- [Archetypes](#archetypes) - Entity structure definitions
- [Systems](#systems) - System definitions
- [Resources](#resources) - Global singleton types
- [Phases](#phases) - Execution phase configuration
- [Schedule](#schedule) - Scheduler configuration
- [Pipeline](#pipeline) - Entity flow configuration
- [Coordination](#coordination) - Multi-world configuration
- [Scalability](#scalability) - Performance scaling options
- [Tick](#tick) - Frame timing configuration
- [Policies](#policies) - Runtime error handling
- [Tracing](#tracing) - Debug tracing configuration

---

## WorldConfig Overview

`WorldConfig` is the compile-time configuration that defines your entire ECS world. All structural decisions are resolved at compile time, enabling zero-cost abstractions at runtime.

```zig
const ecs = @import("ecs");

pub const cfg = ecs.WorldConfig{
    .components = .{ ... },
    .archetypes = .{ ... },
    .systems = .{ ... },
    .resources = .{ ... },
    .phases = .{ ... },
    .schedule = .{ ... },
    .tick = .{ ... },
    .options = .{ ... },
    .policies = .{ ... },
    .tracing = .{ ... },
};

const World = ecs.World(cfg);
```

---

## Options

The `Options` struct contains all configurable bounds and limits. Tiger Style compliance requires that no limit is hardcoded - configure based on your application's needs.

### Entity Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `entity_index_bits` | `u5` | `20` | Number of bits for entity index (8-24). Remainder used for generation. |
| `max_entities` | `u32` | `65536` | Hard upper bound on entity count. Must fit in `entity_index_bits`. |

**Entity ID Layout Trade-offs:**

| Configuration | Index Bits | Gen Bits | Max Entities | Max Generations |
|--------------|-----------|----------|--------------|-----------------|
| High Entity Count | 24 | 8 | ~16M | 256 |
| Default (Balanced) | 20 | 12 | ~1M | 4,096 |
| High Turnover | 16 | 16 | ~65K | 65,536 |
| Minimal | 8 | 24 | 255 | ~16M |

```zig
.options = .{
    .entity_index_bits = 16,  // ~65K entities
    .max_entities = 50000,    // Actual limit (must fit in bits)
},
```

### Command Buffer Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `max_commands_per_frame` | `u32` | `1024` | Maximum deferred commands per frame. |
| `max_component_data_size` | `u32` | `256` | Maximum inline bytes for component data in commands. |

Components larger than `max_component_data_size` cannot be used with deferred `setComponent` operations.

```zig
.options = .{
    .max_commands_per_frame = 4096,      // High command throughput
    .max_component_data_size = 512,       // Support larger components
},
```

### Schedule Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `max_phases` | `u8` | `16` | Maximum number of phases in schedule. |
| `max_stages_per_phase` | `u16` | `16` | Maximum stages per phase. |
| `max_systems_per_stage` | `u16` | `32` | Maximum systems per stage. |
| `max_aggregate_errors` | `u16` | `16` | Maximum errors to collect in aggregate mode. |

```zig
.options = .{
    .max_phases = 8,
    .max_stages_per_phase = 8,
    .max_systems_per_stage = 16,
    .max_aggregate_errors = 32,
},
```

### Memory Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `expected_entities_per_archetype` | `u32` | `0` | Pre-allocation hint. 0 = dynamic growth. |
| `layout_mode` | `LayoutMode` | `.multi_archetype` | Entity storage strategy. |

```zig
.options = .{
    .expected_entities_per_archetype = 1000,  // Pre-allocate for 1K entities per archetype
    .layout_mode = .multi_archetype,
},
```

### Debug Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable_debug_asserts` | `bool` | `true` | Enable runtime debug assertions. |
| `core_version` | `?struct{...}` | `null` | Optional version lock against ECS library. |

```zig
.options = .{
    .enable_debug_asserts = true,
    .core_version = .{ .major = 0, .minor = 1, .patch = 0 },
},
```

---

## Components

Define all component types used in your world. Components must be listed before they can be used in archetypes or systems.

```zig
const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };
const Health = struct { current: i32, max: i32 };

pub const cfg = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health },
    },
    // ...
};
```

---

## Archetypes

Archetypes define fixed entity structures. Each archetype has a name and a subset of component types.

```zig
pub const cfg = WorldConfig{
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
            .{ .name = "dynamic", .components = &.{ Position, Velocity } },
            .{ .name = "character", .components = &.{ Position, Velocity, Health } },
        },
    },
    // ...
};
```

### Archetype Transitions

Entities can change archetypes at runtime via `addComponent` and `removeComponent`:

```zig
// Move entity from "static" to "dynamic" archetype by adding Velocity
try world.addComponent(entity, Velocity, .{ .x = 0, .y = 0, .z = 0 });

// Move entity from "dynamic" to "static" archetype by removing Velocity
try world.removeComponent(entity, Velocity);
```

---

## Systems

Systems are functions that process entities. Each system declares its phase, component access, and optional I/O requirements.

```zig
const Phase = ecs.Phase;

fn movementSystem(ctx: *ecs.SystemContext(cfg, World)) !void {
    var query = ctx.world.query(.{
        .include = &.{ Position, Velocity },
    });
    
    while (query.next()) |result| {
        const pos = result.get(Position);
        const vel = result.getConst(Velocity);
        pos.x += vel.x * @floatCast(ctx.delta_time);
        pos.y += vel.y * @floatCast(ctx.delta_time);
    }
}

pub const cfg = WorldConfig{
    .systems = .{
        .systems = &.{
            .{
                .name = "movement",
                .func = ecs.asSystemFn(movementSystem),
                .phase = Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
            },
        },
    },
    // ...
};
```

### SystemDef Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | `[]const u8` | required | System identifier for debugging. |
| `func` | `*const anyopaque` | required | System function pointer (use `asSystemFn`). |
| `phase` | `u8` | `1` | Phase index (into phases array). |
| `asynchrony` | `AsynchronyKind` | `.none` | Async capability hint. |
| `parallelism` | `ParallelismMode` | `.none` | Parallelization strategy. |
| `read_components` | `[]const type` | `&.{}` | Components read by this system. |
| `write_components` | `[]const type` | `&.{}` | Components written by this system. |
| `needs_io` | `bool` | `false` | Whether system requires I/O context. |

---

## Resources

Resources are global singletons accessible to all systems. Define resource types in `ResourcesSpec`.

```zig
const GameTime = struct {
    total_seconds: f64,
    frame_count: u64,
};

const PhysicsConfig = struct {
    gravity: f32,
    time_step: f32,
};

pub const cfg = WorldConfig{
    .resources = .{
        .types = &.{ GameTime, PhysicsConfig },
    },
    // ...
};
```

### Accessing Resources

```zig
fn physicsSystem(ctx: *ecs.SystemContext(cfg, World)) !void {
    // Get mutable resource
    if (ctx.getResource(PhysicsConfig)) |physics| {
        physics.time_step = @floatCast(ctx.delta_time);
    }
    
    // Get const resource
    if (ctx.getResourceConst(GameTime)) |time| {
        // Read-only access
        _ = time.total_seconds;
    }
}
```

---

## Phases

Phases define the execution order of systems. Custom phases allow domain-specific execution sequences.

### Default Phases

If not specified, 5 default phases are used:

| Index | Name | Typical Use |
|-------|------|-------------|
| 0 | `pre_update` | Input processing, state preparation |
| 1 | `update` | Core game logic, physics |
| 2 | `post_update` | Cleanup, synchronization |
| 3 | `render` | Rendering, visual updates |
| 4 | `network` | Network I/O, replication |

```zig
// Use default phases with the Phase enum
.systems = .{
    .systems = &.{
        .{ .name = "input", .phase = Phase.pre_update.index(), ... },
        .{ .name = "physics", .phase = Phase.update.index(), ... },
        .{ .name = "render", .phase = Phase.render.index(), ... },
    },
},
```

### Custom Phases

Define your own phase sequence:

```zig
pub const cfg = WorldConfig{
    .phases = .{
        .phases = &.{
            .{ .name = "input", .order = 0 },
            .{ .name = "ai", .order = 1 },
            .{ .name = "physics", .order = 2 },
            .{ .name = "collision", .order = 3 },
            .{ .name = "render", .order = 4 },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "ai_system", .phase = 1, ... },      // ai phase
            .{ .name = "physics_system", .phase = 2, ... }, // physics phase
        },
    },
    // ...
};
```

---

## Schedule

Configure the scheduler's execution model and parallelism.

```zig
pub const cfg = WorldConfig{
    .schedule = .{
        .execution_model = .blocking_single_thread,
        .max_parallel_tasks = 0,  // Let scheduler decide
        .backend_config = .{ .none = {} },  // Optional backend-specific config
    },
    // ...
};
```

### Execution Models

| Model | Description | Best For |
|-------|-------------|----------|
| `.blocking_single_thread` | Single-threaded, synchronous execution. | Simple apps, debugging |
| `.evented_single_thread` | Single-threaded with async I/O support. | Servers, I/O-heavy apps |
| `.concurrent_threadpool` | Multi-threaded parallel execution. | High-throughput, CPU-bound |
| `.io_uring_batch` | Linux io_uring syscall batching per phase. | High-throughput servers (Linux) |
| `.work_stealing` | Per-core queues with Chase-Lev deque stealing. | CPU-bound parallel workloads |
| `.adaptive_hybrid` | Dynamic backend switching based on metrics. | Mixed/varying workloads |

### Backend Configuration

Each advanced execution model has backend-specific configuration:

#### io_uring Batch Backend (Linux)

```zig
.schedule = .{
    .execution_model = .io_uring_batch,
    .backend_config = .{ .io_uring_batch = .{
        .sq_entries = 256,           // Submission queue depth (power of 2)
        .cq_entries = 512,           // Completion queue depth
        .batch_size = 64,            // Max ops to batch per phase
        .kernel_poll = false,        // Enable SQPOLL for reduced syscalls
        .sq_thread_cpu = null,       // CPU affinity for sq thread
        .sq_thread_idle_ms = 1000,   // Idle timeout when kernel_poll enabled
    }},
},
```

#### Work-Stealing Backend

```zig
.schedule = .{
    .execution_model = .work_stealing,
    .backend_config = .{ .work_stealing = .{
        .worker_count = 0,           // 0 = auto-detect CPU count
        .local_queue_size = 256,     // Per-worker queue capacity (power of 2)
        .steal_batch = 32,           // Tasks to steal at once
        .lifo_slot = true,           // LIFO slot for cache locality
        .spin_count = 100,           // Spins before parking thread
    }},
},
```

#### Adaptive Hybrid Backend

```zig
.schedule = .{
    .execution_model = .adaptive_hybrid,
    .backend_config = .{ .adaptive = .{
        .batch_threshold = 64,       // I/O ops to trigger batch mode
        .imbalance_threshold = 0.3,  // CPU imbalance to trigger work-stealing
        .window_size = 100,          // Metrics window (ticks)
        .switch_cooldown = 10,       // Min ticks between switches
        .initial_backend = null,     // null = auto-detect
    }},
},
```

---

## Pipeline

Configure entity flow control through the ECS. Pipeline mode determines who controls entity lifecycle.

```zig
pub const cfg = WorldConfig{
    .pipeline = .{
        .mode = .internal,  // or .external, .hybrid
        .external = .{ ... },  // Settings when mode == .external
        .hybrid = .{ ... },    // Settings when mode == .hybrid
    },
    // ...
};
```

### Pipeline Modes

| Mode | Description | Best For |
|------|-------------|----------|
| `.internal` | ECS manages entity lifecycle internally. | Games, state machines |
| `.external` | User code manages entities via batch APIs. | Event streams, high-throughput |
| `.hybrid` | Fast-path for simple entities, ECS for complex. | HTTP servers, mixed workloads |

### External Mode Configuration

When using `.external` mode:

```zig
.pipeline = .{
    .mode = .external,
    .external = .{
        .batch_size = 256,           // Max entities per batch operation
        .zero_copy = true,           // Enable zero-copy imports when possible
        .export_buffer_size = 4096,  // Export buffer capacity
        .import_buffer_size = 4096,  // Import buffer capacity
    },
},
```

### Hybrid Mode Configuration

When using `.hybrid` mode:

```zig
.pipeline = .{
    .mode = .hybrid,
    .hybrid = .{
        .fast_path_predicate_type = MyPredicate,  // Type with canFastPath() method
        .fast_path_capacity = 1024,               // Max fast-path entities per tick
        .fallback_on_full = true,                 // Fallback to ECS when queue full
    },
},
```

Custom fast-path predicate:

```zig
const MyPredicate = struct {
    pub fn canFastPath(entity_data: anytype) bool {
        // Return true for entities that can bypass full ECS pipeline
        return entity_data.response_size < 4096;
    }
};
```

---

## Coordination

Configure multi-world coordination for pipeline parallelism. Multiple worlds can process entities at different pipeline stages simultaneously.

```zig
pub const cfg = WorldConfig{
    .coordination = .{
        .role = .standalone,  // .standalone, .accept, .io, .compute, .custom
        .world_id = 0,
        .transfer_queue = .{ ... },
        .routing = .{ ... },
    },
    // ...
};
```

### World Roles

| Role | Description | Optimized For |
|------|-------------|---------------|
| `.standalone` | Default, no coordination. | Simple applications |
| `.accept` | Connection acceptance world. | Low latency, high connection rate |
| `.io` | I/O operations world. | Syscall batching, buffer management |
| `.compute` | CPU-bound processing world. | Cache efficiency, parallelism |
| `.custom` | User-defined behavior. | Custom pipelines |

### Transfer Queue Configuration

```zig
.coordination = .{
    .role = .io,
    .world_id = 1,
    .transfer_queue = .{
        .capacity = 4096,      // Queue capacity (power of 2)
        .batch_size = 64,      // Bulk transfer size
        .spsc = false,         // Enable SPSC optimization if single producer/consumer
    },
    .routing = .{
        .default_target = 2,   // Target world for completed entities
        .component_routes = &.{
            .{ .component_name = "NeedsCompute", .target_world = 2 },
            .{ .component_name = "NeedsIO", .target_world = 1 },
        },
    },
},
```

### Using WorldCoordinator

```zig
const Coordinator = ecs.WorldCoordinator(cfg, 3);  // 3 worlds

var coord = try Coordinator.init(allocator);
defer coord.deinit();

// Run coordination loop
while (running) {
    try coord.tick(delta_time);
}
```

---

## Scalability

Configure hardware-specific optimizations for vertical and horizontal scaling.

```zig
pub const cfg = WorldConfig{
    .scalability = .{
        .numa = .{ ... },
        .huge_pages = .{ ... },
        .affinity = .{ ... },
        .cluster = .{ ... },
    },
    // ...
};
```

### NUMA Configuration

Optimize memory allocation on multi-socket systems:

```zig
.scalability = .{
    .numa = .{
        .enabled = true,
        .strategy = .local_preferred,  // .local_preferred, .local_strict, .interleave, .explicit
        .node_bindings = &.{
            .{ .worker_id = 0, .node_id = 0 },
            .{ .worker_id = 1, .node_id = 1 },
        },
        .interleave = .{
            .page_size = 4096,
            .nodes = null,  // null = all nodes
        },
    },
},
```

| Strategy | Description |
|----------|-------------|
| `.local_preferred` | Allocate from local node, fallback to any. |
| `.local_strict` | Strict local allocation (fail if unavailable). |
| `.interleave` | Interleave across all nodes. |
| `.explicit` | Use explicit node_bindings. |

### Huge Pages Configuration

Reduce TLB misses for large working sets:

```zig
.scalability = .{
    .huge_pages = .{
        .enabled = true,
        .size = .@"2MB",         // .@"2MB" or .@"1GB"
        .fallback = true,        // Fallback to regular pages if unavailable
        .threshold = 2097152,    // Min allocation size to use huge pages (2MB)
    },
},
```

### Thread Affinity Configuration

Pin threads to specific CPUs for cache locality:

```zig
.scalability = .{
    .affinity = .{
        .enabled = true,
        .strategy = .sequential,   // .sequential, .physical_only, .numa_spread, .explicit
        .prefer_physical = true,   // Prefer physical cores over hyperthreads
        .cpu_bindings = &.{
            .{ .thread_id = 0, .cpu_id = 0 },
            .{ .thread_id = 1, .cpu_id = 2 },
        },
    },
},
```

### Cluster Configuration

Enable horizontal scaling across multiple instances:

```zig
.scalability = .{
    .cluster = .{
        .enabled = true,
        .node_id = 0,
        .total_instances = 3,
        .discovery = .static,      // .static, .dns, .multicast, .kubernetes
        .transport = .tcp,         // .tcp, .udp, .rdma
        .topology = .mesh,         // .mesh, .star, .ring
        .ownership = .hash_based,  // .hash_based, .range_based, .consistent_hash
        .peers = &.{
            .{ .host = "10.0.0.1", .port = 9000, .node_id = 0 },
            .{ .host = "10.0.0.2", .port = 9000, .node_id = 1 },
            .{ .host = "10.0.0.3", .port = 9000, .node_id = 2 },
        },
        .heartbeat_interval_ms = 1000,
        .peer_timeout_ms = 5000,
    },
},
```

| Ownership Strategy | Description |
|--------------------|-------------|
| `.hash_based` | Hash entity ID to determine owner. |
| `.range_based` | Range partitioning of entity ID space. |
| `.consistent_hash` | Consistent hashing for dynamic scaling. |

---

## Tick

Configure frame/tick timing behavior.

```zig
pub const cfg = WorldConfig{
    .tick = .{
        .mode = .manual,           // or .fixed_rate
        .target_hz = null,         // Required if mode is .fixed_rate
        .max_frame_delay_ns = null, // Optional frame delay cap
    },
    // ...
};
```

### TickMode Options

| Mode | Description |
|------|-------------|
| `.manual` | Call `executeFrame` explicitly. Full control over timing. |
| `.fixed_rate` | Automatic fixed-rate loop. Requires `target_hz`. |

---

## Policies

Configure runtime error handling behavior.

```zig
pub const cfg = WorldConfig{
    .policies = .{
        .invariants = .default,
        .init = .default,
        .frame = .default,  // or .aggregate
    },
    // ...
};
```

### FramePolicy Options

| Policy | Behavior |
|--------|----------|
| `.default` | Stop on first error, return immediately. |
| `.aggregate` | Run all systems, collect all errors, return aggregate report. |

---

## Tracing

Configure debug tracing and profiling.

```zig
pub const cfg = WorldConfig{
    .tracing = .{
        .level = .off,      // .off, .errors, .systems, .verbose
        .sink = null,       // Optional trace sink for custom handling
    },
    // ...
};
```

### TraceLevel Options

| Level | Events Emitted |
|-------|----------------|
| `.off` | No tracing (zero overhead). |
| `.errors` | Only error events. |
| `.systems` | System start/end events plus errors. |
| `.verbose` | All event types including queries and commands. |

---

## Complete Example

```zig
const std = @import("std");
const ecs = @import("ecs");

// Components
const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };
const Health = struct { current: i32, max: i32 };

// Resources
const GameState = struct { paused: bool, score: u32 };

// Systems
fn movementSystem(ctx: *ecs.SystemContext(cfg, World)) !void {
    var query = ctx.world.query(.{ .include = &.{ Position, Velocity } });
    while (query.next()) |r| {
        const pos = r.get(Position);
        const vel = r.getConst(Velocity);
        pos.x += vel.x * @floatCast(ctx.delta_time);
        pos.y += vel.y * @floatCast(ctx.delta_time);
    }
}

// Configuration
pub const cfg = ecs.WorldConfig{
    .components = .{ .types = &.{ Position, Velocity, Health } },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
            .{ .name = "dynamic", .components = &.{ Position, Velocity } },
            .{ .name = "character", .components = &.{ Position, Velocity, Health } },
        },
    },
    .systems = .{
        .systems = &.{
            .{
                .name = "movement",
                .func = ecs.asSystemFn(movementSystem),
                .phase = ecs.Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
            },
        },
    },
    .resources = .{ .types = &.{GameState} },
    .options = .{
        .max_entities = 10000,
        .entity_index_bits = 16,
        .max_commands_per_frame = 512,
        .enable_debug_asserts = true,
    },
};

const World = ecs.World(cfg);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = try World.init(allocator);
    defer world.deinit();

    // Initialize resources
    _ = world.resources.insert(GameState, .{ .paused = false, .score = 0 });

    // Spawn entities
    const entity = try world.spawn("dynamic", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .x = 1, .y = 0, .z = 0 },
    });
    _ = entity;

    // Main loop
    var last_time = std.time.nanoTimestamp();
    while (true) {
        const now = std.time.nanoTimestamp();
        const delta = @as(f64, @floatFromInt(now - last_time)) / 1e9;
        last_time = now;

        const result = World.Scheduler.executeFrame(&world, delta, 0, null, allocator);
        switch (result) {
            .success => {},
            .single_error => |err| std.log.err("Frame error: {}", .{err}),
            .aggregate_errors => |errs| std.log.err("Multiple errors: {}", .{errs.count}),
        }

        std.time.sleep(16_000_000); // ~60 FPS
    }
}
```

---

## Validation

WorldConfig is validated at compile time. Invalid configurations produce clear `@compileError` messages:

- `entity_index_bits` must be between 8 and 24
- `max_entities` must fit in `entity_index_bits`
- `max_entities` must be greater than 0
- At least one phase must be defined
- Phase count must not exceed `max_phases`
- System phase indices must be valid
- Components in archetypes must be in `ComponentsSpec`
- Components in systems must be in `ComponentsSpec`
- `single_archetype` mode requires exactly one archetype
- `fixed_rate` tick mode requires `target_hz`