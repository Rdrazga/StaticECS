# Data Pipeline Example

Demonstrates using StaticECS for ETL/stream processing workloads.

## Features Demonstrated

- **Records as Entities**: Each data record is an entity
- **Pipeline Stages**: Custom phases for ingest → validate → transform → output → cleanup
- **Archetype Transitions**: Records can gain components as they move through stages
- **State Machine**: `Record.stage` tracks position in pipeline
- **Statistics Resource**: Track throughput and success rates

## Structure

```
data-pipeline/
├── README.md    # This file
└── main.zig     # Complete example
```

## Pipeline Architecture

```
                        ┌─────────────────────────────────────┐
                        │         Data Pipeline ECS           │
                        └─────────────────────────────────────┘
                                        │
    ┌───────────┬───────────┬───────────┼───────────┬───────────┐
    ▼           ▼           ▼           ▼           ▼           │
┌───────┐  ┌────────┐  ┌─────────┐  ┌────────┐  ┌───────┐       │
│Ingest │→ │Validate│→ │Transform│→ │ Output │→ │Cleanup│       │
└───────┘  └────────┘  └─────────┘  └────────┘  └───────┘       │
    │           │           │           │           │           │
    ▼           ▼           ▼           ▼           ▼           │
[RawData] [ParsedData] [TransformData] [Complete]  [Stats]      │
                                                                │
                           5 Custom Phases ─────────────────────┘
```

## Entity Lifecycle

```
raw_record (Record, RawData)
    │
    │ ← validate system (stub - would add ParsedData)
    ▼
validated_record (Record, RawData, ParsedData)
    │
    │ ← transform system (stub - would add TransformedData)
    ▼
transformed_record (Record, RawData, ParsedData, TransformedData)
    │
    │ ← output system updates stats
    ▼
[stats updated, would despawn by cleanup]
```

## Running

From the StaticECS root:

```bash
zig build run-example-pipeline
```

## Key Concepts

### Custom Pipeline Phases

The example defines 5 custom phases for ordered execution:

```zig
.phases = .{
    .phases = &.{
        .{ .name = "ingest", .order = 0 },
        .{ .name = "validate", .order = 1 },
        .{ .name = "transform", .order = 2 },
        .{ .name = "output", .order = 3 },
        .{ .name = "cleanup", .order = 4 },
    },
},
```

### Resource Access Pattern

Systems access shared resources via `ctx.world.resources`:

```zig
fn ingestSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;
    
    // Batch ingestion every 3 ticks
    if (@mod(ctx.tick, 3) == 0) {
        for (0..5) |i| {
            _ = ctx.world.spawn("record", .{
                Record{ .id = ctx.tick * 10 + i, .stage = .ingested },
                RawData{ .data_len = 100, .timestamp_ns = ctx.time_ns },
            }) catch {};
            stats.records_ingested += 1;
        }
    }
}
```

### Pipeline Statistics

```zig
const PipelineStats = struct {
    records_ingested: u64 = 0,
    records_completed: u64 = 0,
    records_failed: u64 = 0,
    tick_count: u64 = 0,
};

fn outputSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;
    // Update completion stats
    stats.records_completed += stats.records_ingested / 2;
}
```

> **Note**: The validate, transform, and output systems in this example are stubs.
> A real pipeline would implement full record processing logic.

### System Context Helper

Systems receive an opaque pointer that must be cast to the typed context:

```zig
const Context = ecs.SystemContext(cfg, World);

fn getContext(ctx_ptr: *anyopaque) *Context {
    return @ptrCast(@alignCast(ctx_ptr));
}
```

## Extending

Ideas for building a real data pipeline:

1. **Real Data Sources**: Kafka, files, databases
2. **Error Handling**: Dead letter queue archetype
3. **Parallel Processing**: Use `concurrent_threadpool` model
4. **Backpressure**: Throttle ingestion based on in-flight count
5. **Checkpointing**: Persist record state for recovery
6. **Metrics**: Export to Prometheus/StatsD
7. **Schema Registry**: Validate against schemas

## Comparison with Traditional Pipelines

| Aspect | Traditional | ECS-Based |
|--------|-------------|-----------|
| Record state | Transforms in-place | Component accumulation |
| Stage tracking | External metadata | Record.stage component |
| Parallelism | Thread per stage | System-level parallelism |
| Error handling | Try/catch, logs | Failed archetype |
| Monitoring | Scattered metrics | Centralized resources |
| Dead letters | Separate queue | Failed_record archetype |

## Performance Considerations

- **Batch Size**: Configure batch ingestion rate for throughput vs latency
- **Max Entities**: Set `max_entities` to limit memory for in-flight records
- **Entity Index Bits**: Smaller index = more generations for record recycling
- **System Order**: Phases ensure correct processing order