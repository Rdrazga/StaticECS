# StaticECS

**Experimental General-Purpose Entity Component System for Zig**

Built with the use of Kilo Code and Claude 4.5 Opus

StaticECS is a compile-time configurable ECS framework that leverages Zig's comptime capabilities with the goals to generate highly optimized, zero-overhead entity component systems tailored to exact application needs.

## Features

- **Full Comptime Configuration** - Define components, archetypes, systems, and all bounds at compile time
- **Zero Runtime Overhead** - Type generation and validation happens entirely at compile time
- **Tiger Style Architecture** - All limits configurable, no hidden allocations, fail-fast error handling
- **Six Execution Models** - From simple blocking to io_uring batching and work-stealing parallelism
- **Multi-World Coordination** - Pipeline parallelism with lock-free entity transfers
- **Advanced Scalability** - NUMA-aware allocation, huge pages, thread affinity, cluster support

## Quick Example

```zig
const ecs = @import("ecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

pub const cfg = ecs.WorldConfig{
    .components = .{ .types = &.{ Position, Velocity } },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "dynamic", .components = &.{ Position, Velocity } },
        },
    },
    .options = .{ .max_entities = 10000 },
};

const World = ecs.World(cfg);

pub fn main() !void {
    var world = World.init(allocator);
    defer world.deinit();
    
    _ = try world.spawn("dynamic", .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .x = 1, .y = 0.5 },
    });
}
```

## Feature Status

### Production Ready
- ✅ Core ECS (World, Entity, Archetype, Query)
- ✅ Blocking and evented execution backends
- ✅ Work-stealing parallel scheduler
- ✅ Command buffers and deferred operations
- ✅ Multi-world coordination with lock-free transfers
- ✅ Entity ownership calculation strategies

### Experimental
- ⚠️ **GPU compute executor** - Placeholder only, returns `error.GpuUnavailable`
- ⚠️ **SIMD worker pool** - Sequential fallback, no actual SIMD intrinsics
- ⚠️ **Cluster coordination** - Framework only, no network transport
- ⚠️ **External thread pool** - Incomplete, tasks don't execute

For details on experimental features, see [docs/EXPERIMENTAL.md](docs/EXPERIMENTAL.md).

## Documentation

- [Quick Start Guide](docs/quick-start.md)
- [Configuration Reference](docs/CONFIGURATION.md)
- [System Authoring Guide](docs/systems.md)
- [Execution Models Guide](docs/execution-models.md)
- [Experimental Features](docs/EXPERIMENTAL.md)

## Version

**0.2.0** - Review and Improve cycle 2

## Requirements

- Zig 0.16.x (development builds supported)

## Build

```bash
zig build
zig build test
```

## Project Status

This is an experimental project exploring the boundaries of compile-time ECS architecture. The framework demonstrates:

- Comptime type generation for zero-cost abstractions
- Lock-free coordination primitives
- Platform-specific optimizations (io_uring, NUMA, huge pages)
- Adaptive runtime backend selection

## License

MIT
