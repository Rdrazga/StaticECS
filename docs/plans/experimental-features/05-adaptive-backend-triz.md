# AdaptiveBackend I/O Metrics TRIZ Analysis

**Status:** Complete
**Feature:** AdaptiveBackend I/O Metrics Completion
**Module:** [`scheduler/backends/adaptive.zig`](../../../src/ecs/scheduler/backends/adaptive.zig)
**Effort Estimate:** Small (2-4 hours)

## Current State

The [`AdaptiveBackend`](../../../src/ecs/scheduler/backends/adaptive.zig:81) dynamically switches between blocking and work-stealing execution strategies based on runtime metrics. Currently, it tracks:

- **Tick duration** (nanoseconds per tick)
- **Systems executed** (count per tick)
- **Tick duration variance** (for CPU imbalance detection)
- **Pending I/O** - currently hardcoded to 0 (the TODO at [line 258](../../../src/ecs/scheduler/backends/adaptive.zig:258))

The TODO:
```zig
.pending_io = 0, // TODO: Get from IoContext when available
```

## TRIZ Analysis

### 1. Define the Problem

#### Technical System Description

The AdaptiveBackend monitors workload characteristics to select the optimal execution strategy:
- **Blocking backend**: Lowest overhead, best for light loads or I/O-bound work
- **Work-stealing backend**: Best for CPU-bound parallel workloads with task imbalance

The [`shouldSwitch()`](../../../src/ecs/scheduler/backends/adaptive.zig:335) function uses:
1. `pending_io_avg` - Rolling average of pending I/O operations
2. `imbalance_ratio` - Coefficient of variation of tick durations

Currently, `pending_io` is always 0, making I/O-based switching decisions impossible.

#### Ideal Final Result (IFR)

The **Ideal Final Result** is a system where:
1. The scheduler **automatically knows** I/O load without explicit tracking overhead
2. I/O-heavy workloads **self-identify** and trigger appropriate backend selection
3. **Zero cost** when I/O metrics aren't needed (blocking mode)
4. **No configuration required** - the system self-tunes
5. **Accurate predictions** without measuring individual I/O operations

### 2. Identify Technical Contradictions

| Improving Parameter | Worsening Parameter | Contradiction |
|---------------------|---------------------|---------------|
| **Measurement Accuracy** (precise I/O count) | **Overhead** (tracking cost) | More accurate tracking requires more instrumentation |
| **Responsiveness** (fast backend switching) | **Stability** (avoid thrashing) | Quick reactions cause oscillation |
| **Generality** (one solution for all workloads) | **Optimization** (specialized strategies) | General solutions aren't optimal for specific cases |
| **Simplicity** (easy implementation) | **Intelligence** (smart decisions) | Smart systems require complex logic |
| **Low Latency** (minimal tracking overhead) | **Information Quality** (complete I/O picture) | Getting complete picture requires polling/tracking |

### 3. Apply TRIZ Inventive Principles

#### Principle #1: Segmentation
**Application:** Categorize systems by their declared I/O characteristics at comptime.

Systems can declare `needs_io = true`. Count I/O-needing systems per tick:
```zig
// Comptime: Count systems that declared needs_io
const io_system_count = countIoSystems(Schedule);
// Runtime: Use this as a static bound on potential I/O load
```

**Benefit:** Zero runtime overhead - comptime classification.

#### Principle #2: Extraction (Taking Out)
**Application:** Extract I/O metrics from *existing* infrastructure rather than adding new tracking.

The [`IoContext`](../../../src/ecs/context/io_context.zig:39) already tracks:
- `supports_async` - whether async is available
- `supports_concurrency` - whether parallelism is available

We can extract an operation counter at the IoContext level when `scheduleAsync()`/`scheduleConcurrent()` are called.

#### Principle #10: Preliminary Action
**Application:** Pre-classify workloads at schedule build time.

During [`Schedule`](../../../src/ecs/scheduler/schedule_build.zig) construction:
- Analyze which systems declare I/O requirements
- Group I/O systems together in phases
- Pre-compute "I/O intensity" metric per phase

#### Principle #15: Dynamics (Dynamization)
**Application:** Make the I/O metric calculation dynamic based on observed patterns.

Instead of tracking actual I/O operations:
- Track timing ratios: I/O systems time / total tick time
- If I/O systems dominate tick duration → high I/O load
- Self-adjusting without explicit operation counting

#### Principle #23: Feedback
**Application:** Use completion timing as implicit I/O metric.

Observe tick duration patterns:
- **High variance** + long average → I/O blocking (waiting for I/O)
- **Low variance** + consistent timing → CPU-bound work
- Use timing feedback to infer I/O load without direct measurement

#### Principle #25: Self-service
**Application:** Systems self-report their I/O nature through declaration.

```zig
const MySystem = struct {
    pub const needs_io = true;  // Self-declaration
    pub fn run(ctx: *SystemContext) void { ... }
};
```

The scheduler aggregates these declarations to estimate I/O intensity.

#### Principle #35: Parameter Changes
**Application:** Allow runtime sensitivity adjustment.

The [`AdaptiveConfig`](../../../src/ecs/config/backend_config.zig:78) already supports:
- `batch_threshold: u32 = 64` - I/O threshold for batching
- `imbalance_threshold: f32 = 0.3` - CPU imbalance threshold

Add optional sensitivity mode for applications to hint at their workload type.

#### Principle #16: Partial or Excessive Actions
**Application:** Measure a sample rather than all operations.

Instead of counting every I/O operation:
- Track every Nth tick's I/O characteristics
- Extrapolate for intermediate ticks
- Reduces overhead while maintaining trend accuracy

### 4. Resource Analysis

#### Available Resources

| Resource | Location | Usage |
|----------|----------|-------|
| System I/O declarations | Comptime system metadata | Pre-classification |
| Tick timing | [`adaptive.zig:252`](../../../src/ecs/scheduler/backends/adaptive.zig:252) | Already captured |
| IoContext reference | [`SystemContext.io`](../../../src/ecs/system_context.zig:111) | Exists but not used for metrics |
| Phase execution timing | [`scheduler_runtime.zig`](../../../src/ecs/scheduler/scheduler_runtime.zig) | Per-phase granularity |
| IoBackend mode | [`io_backend.zig:109`](../../../src/ecs/io/io_backend.zig:109) | blocking/evented/threadpool |
| Systems executed count | [`adaptive.zig:259`](../../../src/ecs/scheduler/backends/adaptive.zig:259) | Already tracked |

#### Underutilized Resources

1. **System metadata** - `needs_io` declarations exist but aren't aggregated
2. **Phase boundaries** - Could track I/O systems per phase
3. **IoContext creation** - `fromBackend()` could initialize counters
4. **Group operations** - `scheduleAsync()`/`waitGroup()` calls could be counted

### 5. Proposed Solutions

#### Solution 1: Heuristic I/O Estimation (Recommended)

**Approach:** Use system declarations and timing patterns to estimate I/O load.

```zig
// In AdaptiveBackend.tick():
const sample = Sample{
    .timestamp = end_time,
    .tick_duration_ns = tick_duration,
    .pending_io = self.estimateIoLoad(world),
    .systems_executed = @intCast(systems_this_tick),
};

fn estimateIoLoad(self: *Self, world: *WorldType) u32 {
    // Count systems that executed with I/O context
    var io_systems: u32 = 0;
    // For each phase, check if any I/O systems ran
    // This is a comptime-known bound based on Schedule
    inline for (Sched.phases) |phase| {
        inline for (phase.systems) |sys| {
            if (@hasDecl(sys, "needs_io") and sys.needs_io) {
                io_systems += 1;
            }
        }
    }
    return io_systems;
}
```

**Pros:**
- Zero runtime overhead (comptime analysis)
- No changes to IoBackend/IoContext
- Works immediately

**Cons:**
- Approximation, not actual I/O count
- Doesn't detect dynamic I/O patterns

#### Solution 2: IoContext Operation Counter

**Approach:** Add an atomic counter to IoContext that tracks scheduled operations.

```zig
// In io_context.zig
pub const IoContext = struct {
    // ... existing fields ...
    
    /// Atomic counter for pending operations (for metrics).
    pending_ops: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    
    pub fn scheduleAsync(self: *Self, group: *Group, comptime func: anytype, args: anytype) void {
        _ = self.pending_ops.fetchAdd(1, .monotonic);
        // ... existing scheduling logic ...
    }
    
    pub fn waitGroup(self: *Self, group: *Group) void {
        // Decrement after wait
        defer _ = self.pending_ops.fetchSub(1, .monotonic);
        // ... existing wait logic ...
    }
    
    pub fn getPendingOps(self: *const Self) u32 {
        return self.pending_ops.load(.monotonic);
    }
};
```

Then in [`adaptive.zig`](../../../src/ecs/scheduler/backends/adaptive.zig:258):
```zig
.pending_io = if (world.getIoContext()) |io| io.getPendingOps() else 0,
```

**Pros:**
- Accurate actual operation count
- Minimal overhead (atomic add/sub)
- Reflects real I/O behavior

**Cons:**
- Requires IoContext modification
- Counts Group waits, not individual operations
- Group-based counting may not reflect actual I/O ops

#### Solution 3: Timing-Based Inference

**Approach:** Infer I/O load from tick timing characteristics.

```zig
fn estimateIoLoad(self: *Self) u32 {
    // High tick duration variance suggests I/O blocking
    // Convert variance ratio to estimated I/O "units"
    const variance_ratio = self.metrics.getImbalanceRatio();
    
    // If variance is high (> 0.5), infer I/O activity
    // Scale to a 0-100 range for the threshold comparison
    if (variance_ratio > 0.5) {
        return @intFromFloat(@min(100.0, variance_ratio * 100.0));
    }
    return 0;
}
```

**Pros:**
- Zero explicit tracking overhead
- Adapts to actual behavior
- No API changes required

**Cons:**
- Indirect measurement
- Can't distinguish I/O variance from other causes
- Requires tuning

### 6. Implementation Recommendations

#### Recommended Solution: Hybrid Approach (Solutions 1 + 3)

Combine comptime system analysis with runtime timing inference:

**Step 1:** Add comptime I/O system counting to AdaptiveBackend

```zig
// At line 255-261, replace:
const sample = Sample{
    .timestamp = end_time,
    .tick_duration_ns = tick_duration,
    .pending_io = self.estimateIoLoad(),
    .systems_executed = @intCast(self.getCurrentBackendStats().systems_executed -
        (if (self.tick_count > 0) self.stats.systems_executed else 0)),
};

// Add helper function:
fn estimateIoLoad(self: *const Self) u32 {
    // Comptime: count declared I/O systems
    const declared_io_systems = comptime countDeclaredIoSystems();
    
    // Runtime: weight by timing variance
    // High variance suggests active I/O blocking
    const variance_weight = @min(1.0, self.metrics.getImbalanceRatio() * 2.0);
    
    return @intFromFloat(@as(f32, @floatFromInt(declared_io_systems)) * variance_weight);
}

fn countDeclaredIoSystems() u32 {
    var count: u32 = 0;
    const Sched = @import("../schedule_build.zig").Schedule(cfg);
    inline for (Sched.phases) |phase| {
        inline for (phase.systems) |sys| {
            if (@hasDecl(@TypeOf(sys), "needs_io") and @TypeOf(sys).needs_io) {
                count += 1;
            }
        }
    }
    return count;
}
```

**Step 2:** Adjust switching thresholds

The `shouldSwitch()` function already handles `pending_io`, but the logic should be refined:

```zig
fn shouldSwitch(self: *Self) ?Mode {
    if (self.metrics.sample_count < window_size / 2) {
        return null;
    }

    const pending_io = self.metrics.pending_io_avg;
    const imbalance = self.metrics.getImbalanceRatio();

    // High I/O load: prefer blocking (lower overhead)
    // Rationale: I/O-bound work doesn't benefit from work-stealing
    if (pending_io > @as(f32, @floatFromInt(adaptive_cfg.batch_threshold))) {
        if (self.current_mode != .blocking) {
            return .blocking;
        }
    }

    // High CPU imbalance with low I/O: work-stealing helps
    if (imbalance > adaptive_cfg.imbalance_threshold and 
        pending_io < @as(f32, @floatFromInt(adaptive_cfg.batch_threshold)) / 2.0) {
        if (self.current_mode != .work_stealing) {
            return .work_stealing;
        }
    }

    // Light load: prefer blocking (lowest overhead)
    if (pending_io < @as(f32, @floatFromInt(adaptive_cfg.batch_threshold)) / 4.0 and
        imbalance < adaptive_cfg.imbalance_threshold / 2.0) {
        if (self.current_mode != .blocking) {
            return .blocking;
        }
    }

    return null;
}
```

#### Testing Strategy

1. **Unit tests** for `estimateIoLoad()` with mock Schedule configurations
2. **Integration tests** with mixed I/O/CPU workloads
3. **Benchmark** to verify zero overhead in comptime path
4. **Fuzz testing** for switching stability under random loads

#### Configuration Recommendations

For different workload types:

| Workload | `batch_threshold` | `imbalance_threshold` | Rationale |
|----------|-------------------|-----------------------|-----------|
| CPU-heavy | 100+ | 0.2 | High I/O threshold, sensitive to imbalance |
| I/O-heavy | 32 | 0.5 | Low I/O threshold, tolerate imbalance |
| Mixed | 64 (default) | 0.3 (default) | Balanced defaults |
| Latency-sensitive | 16 | 0.15 | Quick switching |
| Throughput-focused | 128 | 0.4 | Stable, less switching |

## Summary

The recommended approach uses **comptime system analysis** combined with **runtime timing inference** to estimate I/O load without explicit operation tracking. This achieves:

- ✅ Zero runtime overhead for metrics collection
- ✅ No changes to IoBackend or IoContext
- ✅ Respects system `needs_io` declarations
- ✅ Self-tuning based on observed variance
- ✅ Backward compatible

**Implementation effort:** 2-4 hours
- Update `estimateIoLoad()` function
- Add comptime system counting helper
- Refine `shouldSwitch()` logic
- Add unit tests

## References

- [00-OVERVIEW.md](00-OVERVIEW.md) - Parent planning document
- [`AdaptiveBackend`](../../../src/ecs/scheduler/backends/adaptive.zig:81) - Implementation
- [`AdaptiveConfig`](../../../src/ecs/config/backend_config.zig:78) - Configuration
- [`IoContext`](../../../src/ecs/context/io_context.zig:39) - I/O wrapper
- [`IoBackend`](../../../src/ecs/io/io_backend.zig:102) - I/O backend abstraction