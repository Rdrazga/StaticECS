# Backpressure in StaticECS

This document describes how StaticECS applies backpressure to prevent resource exhaustion and maintain system stability under load.

## Overview

StaticECS applies backpressure at multiple levels to protect system resources:

1. **Entity Capacity** - Maximum entities per world/archetype
2. **Queue Capacity** - Bounded queues for transfers, commands, events
3. **Buffer Capacity** - Import/export buffers with fixed sizes
4. **Error Aggregation** - Bounded error collection to prevent memory growth

All limits are **compile-time configurable** per Tiger Style requirements - no hardcoded bounds exist that cannot be overridden.

## Backpressure Mechanisms

### 1. Entity Capacity

When entity capacity is exhausted, spawn operations fail immediately.

**Configuration:**
```zig
.options = .{
    .max_entities = 65536,              // Hard world limit
    .expected_entities_per_archetype = 1000,  // Per-archetype hint
    .capacity_mode = .fixed,            // Pre-allocate, fail on overflow
},
```

**Behavior:**
- `world.spawn()` returns `error.CapacityExhausted` when full
- Entity manager returns `null` from `create()` when exhausted
- Archetype tables return `error.CapacityExhausted` on overflow

**Capacity Modes:**
| Mode | Behavior | Tiger Style |
|------|----------|-------------|
| `.fixed` | Pre-allocated arrays, fail-fast on overflow | ✅ Compliant |
| `.dynamic` | ArrayList growth, may allocate at runtime | ⚠️ Not recommended |

**Monitoring:**
```zig
// Check remaining capacity before batch operations
if (world.entityCount() + batch_size > cfg.options.max_entities) {
    // Apply backpressure: reject batch, slow producer, etc.
}
```

### 2. Transfer Queue Capacity

Multi-world coordination uses bounded lock-free queues for entity transfers.

**Configuration:**
```zig
.coordination = .{
    .transfer_queue = .{
        .capacity = 4096,     // Must be power of 2
        .batch_size = 64,     // Max transfers per batch
        .spsc = false,        // true = single-producer/single-consumer optimization
    },
},
```

**Behavior:**
- `queueTransfer()` returns `false` when queue is full
- `queue_full_count` metric tracks rejected transfers
- No data loss - caller must handle the rejection

**Handling Queue Full:**
```zig
const transfer = coordinator.createTransfer(entity, target_world);
if (!coordinator.queueTransfer(source_world, target_world, transfer)) {
    // Queue full - apply backpressure
    // Options: retry, block, drop oldest, signal producer
    stats.backpressure_events += 1;
}
```

**Monitoring:**
```zig
const stats = coordinator.getStats();
if (stats.queue_full_count > threshold) {
    // Too many rejected transfers - slow down producers
}
```

### 3. Command Buffer Capacity

Deferred commands (spawn, despawn, addComponent) use fixed-size buffers.

**Configuration:**
```zig
.options = .{
    .max_commands_per_frame = 1024,    // Commands per buffer
    .max_component_data_size = 256,    // Inline component bytes
},
```

**Behavior:**
- `commands.spawn()` returns `false` when buffer full
- Commands are NOT silently dropped - callers must check return value
- Component data exceeding `max_component_data_size` fails at compile time

**Handling Buffer Full:**
```zig
fn systemWithCommands(ctx: *SystemContext) !void {
    for (entities_to_spawn) |data| {
        if (!ctx.commands.spawn("archetype", data)) {
            // Buffer full - cannot defer more commands
            // Options: flush early, track overflow, fail frame
            return error.CommandBufferFull;
        }
    }
}
```

### 4. Event Queue Capacity

Event queues have bounded capacity with configurable overflow behavior.

**Configuration:**
```zig
// Event queue type with capacity
const DamageEvents = EventQueue(DamageEvent, 1024);
```

**Behavior Options:**
| Method | On Full | Use Case |
|--------|---------|----------|
| `push()` | Returns `error.QueueFull` | Critical events |
| `pushOrOverwrite()` | Overwrites oldest | Non-critical, latest-wins |

**Handling:**
```zig
// Critical events - fail if full
if (events.push(damage_event)) |_| {
    // Success
} else |err| switch (err) {
    error.QueueFull => {
        // Apply backpressure to damage sources
        stats.events_dropped += 1;
    },
}

// Non-critical - accept overflow
events.pushOrOverwrite(status_effect);  // Always succeeds
```

### 5. Hybrid Pipeline Fast-Path

Hybrid mode queues have explicit backpressure configuration.

**Configuration:**
```zig
.pipeline = .{
    .mode = .hybrid,
    .hybrid = .{
        .fast_path_capacity = 1024,     // Fast-path queue size
        .fallback_on_full = true,       // Fallback to ECS when queue full
    },
},
```

**Behavior with `fallback_on_full = true`:**
- Fast-path queue full → route through full ECS pipeline
- No data loss, but slower processing for overflow entities
- Graceful degradation under load

**Behavior with `fallback_on_full = false`:**
- Fast-path queue full → reject entity (returns error)
- Caller must handle rejection explicitly
- Use when fast-path-only processing is required

### 6. Error Aggregation Overflow

Aggregate error mode collects multiple errors per frame with bounded storage.

**Configuration:**
```zig
.options = .{
    .max_aggregate_errors = 16,  // Max errors to store
},
```

**Behavior:**
- First N errors stored with full details
- Additional errors increment `overflow_count`
- `hasOverflow()` indicates lost error details

**Checking Overflow:**
```zig
const result = world.tick();
if (result.errors.hasOverflow()) {
    // Some error details were lost
    log.warn("Dropped {} error details", .{result.errors.getOverflowCount()});
}
```

## Backpressure Patterns

### Pattern 1: Reject and Retry
```zig
fn produceEntities(source: *Source, coordinator: *Coordinator) void {
    while (source.hasData()) {
        const entity = source.next();
        if (!coordinator.queueTransfer(entity)) {
            // Rejected - put back for retry
            source.unget(entity);
            // Apply exponential backoff
            std.time.sleep(backoff_ns);
            backoff_ns = @min(backoff_ns * 2, max_backoff);
        } else {
            backoff_ns = min_backoff;  // Reset on success
        }
    }
}
```

### Pattern 2: Admission Control
```zig
fn handleRequest(request: Request, world: *World) !Response {
    // Check capacity before accepting work
    const current_load = world.entityCount();
    const max_load = cfg.options.max_entities;
    
    if (current_load > max_load * 0.9) {  // 90% threshold
        return error.ServiceUnavailable;  // HTTP 503
    }
    
    // Accept request and process
    const entity = try world.spawn("request", .{ .data = request });
    return processEntity(entity);
}
```

### Pattern 3: Load Shedding
```zig
fn processWithLoadShedding(items: []Item, pipeline: *Pipeline) Stats {
    var stats = Stats{};
    
    for (items) |item| {
        if (pipeline.fast_path.isFull()) {
            // Shed load: skip non-critical items
            if (!item.is_critical) {
                stats.shed_count += 1;
                continue;
            }
        }
        
        _ = pipeline.process(item) catch {
            stats.error_count += 1;
        };
        stats.processed_count += 1;
    }
    
    return stats;
}
```

## Configuration Guidelines

### High-Throughput Server
```zig
const cfg = WorldConfig{
    .options = .{
        .max_entities = 100_000,
        .max_commands_per_frame = 4096,
    },
    .coordination = .{
        .transfer_queue = .{
            .capacity = 8192,
            .batch_size = 128,
        },
    },
    .pipeline = .{
        .mode = .hybrid,
        .hybrid = .{
            .fast_path_capacity = 4096,
            .fallback_on_full = true,  // Graceful degradation
        },
    },
};
```

### Strict Resource Bounds
```zig
const cfg = WorldConfig{
    .options = .{
        .max_entities = 10_000,
        .capacity_mode = .fixed,
        .max_commands_per_frame = 512,
    },
    .pipeline = .{
        .mode = .hybrid,
        .hybrid = .{
            .fast_path_capacity = 1024,
            .fallback_on_full = false,  // Fail-fast on overflow
        },
    },
};
```

## Monitoring Backpressure

Key metrics to monitor:

| Metric | Source | Indicates |
|--------|--------|-----------|
| `queue_full_count` | `Coordinator.getStats()` | Transfer queue backpressure |
| `overflow_count` | `AggregateErrors.getOverflowCount()` | Error capacity exceeded |
| Entity count ratio | `world.entityCount() / max_entities` | Entity capacity pressure |
| Command buffer fill | Custom tracking | Command throughput limits |

```zig
fn reportBackpressureMetrics(world: *World, coordinator: *Coordinator) void {
    const coord_stats = coordinator.getStats();
    const entity_ratio = @as(f32, @floatFromInt(world.entityCount())) / 
                        @as(f32, @floatFromInt(cfg.options.max_entities));
    
    metrics.gauge("ecs.entity_capacity_ratio", entity_ratio);
    metrics.counter("ecs.queue_full_total", coord_stats.queue_full_count);
}
```

## Related Documentation

- [Configuration Reference](CONFIGURATION.md) - All configurable bounds
- [Multi-World Coordination](multi-world.md) - Transfer queue details
- [Execution Models](execution-models.md) - Backend-specific backpressure