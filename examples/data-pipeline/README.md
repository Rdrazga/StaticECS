# Data Pipeline Example

Demonstrates using StaticECS for ETL/stream processing workloads.

## Features Demonstrated

- **Records as Entities**: Each data record is an entity
- **Pipeline Stages**: Custom phases for ingest → validate → transform → enrich → output
- **Archetype Transitions**: Records gain components as they move through stages
- **State Machine**: Record.stage tracks position in pipeline
- **Statistics Resource**: Track throughput, latency, success rates
- **External Service**: Simulated enrichment service integration

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
    ▼           ▼           ▼           ▼           ▼           ▼
┌───────┐  ┌────────┐  ┌─────────┐  ┌────────┐  ┌────────┐  ┌───────┐
│Ingest │→ │Validate│→ │Transform│→ │ Enrich │→ │ Output │→ │Cleanup│
└───────┘  └────────┘  └─────────┘  └────────┘  └────────┘  └───────┘
    │           │           │           │           │           │
    ▼           ▼           ▼           ▼           ▼           ▼
[RawData] [ParsedData] [TransformData] [EnrichData] [Complete]  [Delete]
```

## Entity Lifecycle

```
raw_record (Record, RawData, Timing)
    │
    │ ← validate system adds ParsedData
    ▼
validated_record (Record, RawData, ParsedData, Timing)
    │
    │ ← transform system adds TransformedData
    ▼
transformed_record (Record, RawData, ParsedData, TransformedData, Timing)
    │
    │ ← enrich system adds EnrichedData
    ▼
enriched_record (Record, ..., EnrichedData, Timing)
    │
    │ ← output system marks complete
    ▼
[despawned by cleanup]
```

## Running

From the StaticECS root:

```bash
zig build
zig run examples/data-pipeline/main.zig
```

## Key Concepts

### Custom Pipeline Phases

```zig
.phases = .{
    .phases = &.{
        .{ .name = "ingest", .order = 0 },
        .{ .name = "validate", .order = 1 },
        .{ .name = "transform", .order = 2 },
        .{ .name = "enrich", .order = 3 },
        .{ .name = "output", .order = 4 },
        .{ .name = "cleanup", .order = 5 },
    },
},
```

### Archetype Transitions

Records gain components as they progress:

```zig
fn validateSystem(ctx: *Context) !void {
    // Query records in validation stage
    var query = ctx.world.query(.{ .include = &.{Record, RawData} });
    
    while (query.next()) |result| {
        if (result.getConst(Record).stage != .ingested) continue;
        
        // Parse and add new component
        const parsed = parseRecord(result.getConst(RawData));
        try ctx.world.addComponent(result.entity, ParsedData, parsed);
        
        result.get(Record).stage = .validated;
    }
}
```

### Pipeline Statistics

```zig
const PipelineStats = struct {
    records_ingested: u64 = 0,
    records_completed: u64 = 0,
    records_failed: u64 = 0,
    avg_latency_ns: u64 = 0,
};

fn outputSystem(ctx: *Context) !void {
    const stats = ctx.getResource(PipelineStats) orelse return;
    // Update stats on completion
    stats.records_completed += 1;
}
```

### Timing Tracking

Each record tracks its journey:

```zig
const RecordTiming = struct {
    ingested_at_ns: u64 = 0,
    validated_at_ns: u64 = 0,
    transformed_at_ns: u64 = 0,
    enriched_at_ns: u64 = 0,
    completed_at_ns: u64 = 0,
};

// Calculate end-to-end latency
const latency = timing.completed_at_ns - timing.ingested_at_ns;
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

- **Batch Size**: Configure `PipelineConfig.batch_size` for throughput vs latency
- **Max Entities**: Set `max_entities` to limit memory for in-flight records
- **Entity Index Bits**: Smaller index = more generations for record recycling
- **System Order**: Phases ensure correct processing order