# StaticECS

**Experimental General-Purpose Entity Component System for Zig**

Built with the use of Kilo Code and Claude 4.5 Opus

StaticECS is a compile-time configurable ECS framework that leverages Zig's comptime capabilities with the goals to generate highly optimized, zero-overhead entity component systems tailored to exact application needs.

## Project Goals:
This project is an attempt to leverage modern AI and Kilo Code to develop a pre-deisgned by a human ECS,
Using comptimes and dead code elimination to allow it to work both as a general purpose single thread ECS in games, data pipelines, and simulations
As well as provide abstractions to extreme performance multi-core systems and state management, to be used as a new "concept" of designing synchronous and asynchronous processes.

## Feature Status (being verfied and tested)

### Ready
- [x] Core ECS (World, Entity, Archetype, Query)
- [x] Blocking and evented execution backends
- [x] Work-stealing parallel scheduler
- [x] Command buffers and deferred operations
- [x] Multi-world coordination with lock-free transfers
- [x] Entity ownership calculation strategies

### Experimental or Not Implemented
- [ ] **GPU compute executor** - Placeholder only, returns `error.GpuUnavailable`
- [ ] **SIMD worker pool** - Sequential fallback, no actual SIMD intrinsics
- [ ] **Cluster coordination** - Framework only, no network transport
- [ ] **External thread pool** - Incomplete, tasks don't execute

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
zig build benchmark
```

## Project Status

This is an experimental project exploring the boundaries of compile-time ECS architecture. The framework demonstrates:

- Comptime type generation for zero-cost abstractions
- Platform-specific optimizations (io_uring, NUMA, huge pages)
- Optional adaptive runtime backend selection

## License

MIT
