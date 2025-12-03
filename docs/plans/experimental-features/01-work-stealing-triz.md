# WorkStealingBackend TRIZ Analysis

**Status:** Complete
**Feature:** WorkStealingBackend
**Module:** [`scheduler/backends/work_stealing.zig`](../../../src/ecs/scheduler/backends/work_stealing.zig)
**Last Updated:** 2024-11-29

## Current State

The WorkStealingBackend implements a Chase-Lev work-stealing deque with the following characteristics:
- **Atomics**: Correct memory ordering (seq_cst for contended operations, acquire/release for ownership)
- **Per-worker state**: Local queues, LIFO slot, command buffers, xorshift64 RNG
- **Task model**: One task per system per phase
- **Stealing**: Random victim selection, single-task steal (batch reserved for future)
- **Command safety**: Per-worker command buffers merged deterministically post-phase

## TRIZ Analysis

### 1. Problem Statement

#### Technical System Description

The WorkStealingBackend is designed to efficiently parallelize ECS system execution across multiple CPU cores. The current implementation:

1. **Creates tasks** for each system in a phase
2. **Distributes tasks** round-robin to worker local queues
3. **Executes** using Chase-Lev deque pop (LIFO) for cache locality
4. **Steals** from random victims when local queue is empty
5. **Merges** per-worker command buffers in deterministic order

#### Current Technical Limitations

| Limitation | Impact | Code Location |
|-----------|--------|---------------|
| Single-threaded execution | Only worker[0] runs; no parallel threads spawned | [`runWorkerLoop()`](../../../src/ecs/scheduler/backends/work_stealing.zig:645) called only for worker 0 |
| Single-task stealing | `steal_batch` config unused; one task per steal | [`trySteal()`](../../../src/ecs/scheduler/backends/work_stealing.zig:727) line 746 |
| No stress tests | Correctness under contention unverified | Missing concurrent test coverage |
| Fixed task granularity | No entity-range partitioning implemented | [`Task.entity_start/end`](../../../src/ecs/scheduler/backends/work_stealing.zig:251-253) unused |
| Spinlock fairness | Starvation possible under high contention | Documented in header comments, no mitigation |

#### User Pain Points

1. **Performance**: Single-threaded mode negates parallelism benefits
2. **Reliability**: Lack of stress testing creates production risk
3. **Tuning**: `steal_batch` and entity partitioning configs have no effect
4. **Observability**: No per-worker metrics exposed beyond aggregate stats

### 2. Ideal Final Result (IFR)

The **perfect work-stealing scheduler** would:

- **Automatically scale** to available CPU cores with zero configuration
- **Perfectly balance** work across all workers with zero idle time
- **Guarantee fairness** - no worker starvation under any workload
- **Maintain determinism** - identical results regardless of scheduling
- **Zero overhead** - no synchronization cost beyond essential atomics
- **Self-optimizing** - adapt stealing strategy to workload characteristics
- **Complete observability** - per-worker metrics, steal frequencies, latencies

### 3. Technical Contradictions

| # | Improving Parameter | Worsening Parameter | Contradiction Description |
|---|---------------------|---------------------|---------------------------|
| 1 | **Throughput** (parallel execution) | **Fairness** (equal work distribution) | Aggressive stealing improves throughput but can starve victim queues |
| 2 | **Latency** (quick task acquisition) | **CPU Usage** (idle power consumption) | Higher `spin_count` reduces latency but wastes cycles when idle |
| 3 | **Simplicity** (single-steal) | **Efficiency** (amortized steal cost) | Single-task stealing is simpler but batch-stealing amortizes synchronization |
| 4 | **Determinism** (reproducible output) | **Performance** (parallel merging) | Sequential command merging ensures determinism but serializes post-phase work |
| 5 | **Cache Locality** (LIFO slot) | **Work Balance** (even distribution) | LIFO slot keeps hot tasks local but may create queue imbalances |
| 6 | **Correctness** (stress testing) | **Development Speed** (time to implement) | Comprehensive stress tests require significant effort but catch race conditions |

### 4. Inventive Principles Analysis

#### Principle #1: Segmentation
**Application**: Partition systems by execution cost (lightweight vs. heavyweight)
- Lightweight systems: Execute directly without task overhead
- Heavyweight systems: Partition by entity ranges for parallel execution
- **Solution**: Implement [`Task.entity_start/end`](../../../src/ecs/scheduler/backends/work_stealing.zig:251-253) for entity-batch parallelism

#### Principle #2: Extraction
**Application**: Extract stealing frequency metrics separately from execution
- Currently: Stealing stats aggregated in [`BackendStats.tasks_stolen`](../../../src/ecs/scheduler/backends/interface.zig:48)
- **Solution**: Per-worker steal attempt/success counters for debugging contention

#### Principle #3: Local Quality
**Application**: Different spin strategies per worker based on role
- Worker 0 (main thread): No spinning, immediate work or return
- Other workers: Progressive backoff (spin → yield → park)
- **Solution**: Role-aware spin logic in [`runWorkerLoop()`](../../../src/ecs/scheduler/backends/work_stealing.zig:645)

#### Principle #4: Asymmetry
**Application**: Asymmetric queue sizes based on expected work distribution
- First N workers: Larger queues for initial distribution
- Overflow workers: Smaller queues, steal-heavy operation
- **Solution**: Tiered `local_queue_size` allocation

#### Principle #5: Merging
**Application**: Merge multiple steal attempts into batch acquisition
- Current: Single steal per victim visit
- **Solution**: Implement `steal_batch` - steal up to N tasks in one atomic operation
- Reference: Reserved at [`trySteal()`](../../../src/ecs/scheduler/backends/work_stealing.zig:746)

#### Principle #6: Universality
**Application**: Unified task type for both system and entity-batch work
- Current: [`Task`](../../../src/ecs/scheduler/backends/work_stealing.zig:247) struct already supports entity ranges
- **Solution**: Single task representation handles both granularities

#### Principle #7: Nesting
**Application**: Hierarchical stealing (local → neighbor → global)
- Level 1: Own LIFO slot (cache-hot)
- Level 2: Own local queue (cache-warm)
- Level 3: Neighbor queues (NUMA-aware if possible)
- Level 4: Global injection queue (cold)
- Current implementation follows this pattern ✓

#### Principle #10: Preliminary Action
**Application**: Pre-partition work before phase execution
- Current: Round-robin distribution at phase start
- **Solution**: Cost-aware distribution using system execution time estimates

#### Principle #15: Dynamics
**Application**: Dynamic stealing aggressiveness based on queue depths
- Empty local queue: Aggressive stealing (try all victims)
- Partial local queue: Conservative (skip if victim < threshold)
- **Solution**: Adaptive victim threshold in [`trySteal()`](../../../src/ecs/scheduler/backends/work_stealing.zig:727)

#### Principle #16: Partial Action
**Application**: Partial task execution for preemption
- Save progress, migrate remaining work to other workers
- **Solution**: Checkpointing for long-running entity batches (future consideration)

#### Principle #23: Feedback
**Application**: Self-adjusting spin counts based on steal success rate
- High success rate: Reduce spinning (less wasted cycles)
- Low success rate: Increase spinning (work is available)
- **Solution**: Exponential backoff with adaptive reset

#### Principle #25: Self-service
**Application**: Workers self-manage their command buffers
- Current: Per-worker command buffers ✓
- **Solution**: Workers also self-report metrics to shared atomic counters

#### Principle #35: Parameter Changes
**Application**: Transform queue operations under contention
- Normal load: Lock-free CAS operations
- High contention: Backoff to reduce cache-line bouncing
- **Solution**: Contention-aware atomic operations with exponential backoff

### 5. Resources Analysis

#### Available Resources

| Resource Type | Resource | Current Usage | Potential |
|--------------|----------|---------------|-----------|
| **System** | CPU cores | Detected but unused | Spawn actual worker threads |
| **System** | LIFO slot | Implemented | Working as designed |
| **System** | Global queue | Overflow storage | Could batch-inject for fairness |
| **Information** | Worker RNG state | Victim selection | Could track steal success patterns |
| **Information** | tasks_executed/stolen | Aggregated stats | Per-worker metrics dashboard |
| **Time** | Spin iterations | Fixed `spin_count` | Adaptive based on success rate |
| **Space** | Command buffers | Per-worker allocation | Already optimized |

#### Underutilized Resources

1. **Thread spawning infrastructure**: [`deinit()`](../../../src/ecs/scheduler/backends/work_stealing.zig:433) handles thread joining but threads never spawned
2. **Entity range partitioning**: Task struct supports ranges but never populated
3. **steal_batch config**: Parsed but unused in stealing logic
4. **Worker statistics**: Per-worker counters exist but not exposed via `getStats()`
5. **Stress test patterns**: [`lock_free_queue_stress_test.zig`](../../../src/ecs/coordination/lock_free_queue_stress_test.zig) provides template

### 6. Solution Concepts

#### Solution 1: Multi-threaded Phase Execution
**Contradiction Resolved**: #1 (Throughput vs. Fairness)
**Principles Applied**: #1 (Segmentation), #25 (Self-service)

**Description**: Spawn actual worker threads for parallel phase execution.

```zig
// In executePhaseParallel(), spawn N-1 worker threads
for (1..self.num_workers) |worker_id| {
    self.workers[worker_id].thread = try Thread.spawn(
        .{}, runWorkerLoop, .{ self, worker_id, ctx, policy, errors }
    );
}
// Main thread runs as worker 0
self.runWorkerLoop(0, ctx, policy, errors);
// Join all workers before phase complete
```

**Expected Outcome**: Linear speedup for parallel-safe systems
**Effort**: Medium (4-8 hours)

#### Solution 2: Batch Stealing Implementation
**Contradiction Resolved**: #3 (Simplicity vs. Efficiency)
**Principles Applied**: #5 (Merging)

**Description**: Implement the reserved `steal_batch` configuration.

```zig
fn trySteal(self: *Self, worker_id: u16) ?Task {
    // Steal up to steal_batch tasks from victim
    var stolen: u8 = 0;
    while (stolen < steal_batch) {
        if (victim.local_queue.steal()) |task| {
            if (stolen == 0) {
                // First task returned immediately
                first_task = task;
            } else {
                // Additional tasks pushed to own queue
                _ = self.workers[worker_id].local_queue.push(task);
            }
            stolen += 1;
        } else break;
    }
    return if (stolen > 0) first_task else null;
}
```

**Expected Outcome**: Reduced synchronization overhead, fewer steal operations
**Effort**: Low (2-4 hours)

#### Solution 3: Comprehensive Stress Testing
**Contradiction Resolved**: #6 (Correctness vs. Development Speed)
**Principles Applied**: #23 (Feedback)

**Description**: Create work-stealing-specific stress tests following [`lock_free_queue_stress_test.zig`](../../../src/ecs/coordination/lock_free_queue_stress_test.zig) patterns.

Test scenarios:
1. **MPMC Deque**: Multiple pushers/stealers on single deque
2. **Steal Storm**: All workers stealing simultaneously
3. **ABA Detection**: Verify sequence number prevents corruption
4. **Determinism**: Same tasks produce same command order across runs

**Expected Outcome**: Verified correctness under high contention
**Effort**: Medium-High (6-10 hours)

#### Solution 4: Adaptive Spin Strategy
**Contradiction Resolved**: #2 (Latency vs. CPU Usage)
**Principles Applied**: #15 (Dynamics), #23 (Feedback), #35 (Parameter Changes)

**Description**: Self-adjusting spin count based on recent steal success rate.

```zig
const Worker = struct {
    // ... existing fields ...
    steal_successes: u32 = 0,
    steal_attempts: u32 = 0,
    
    fn adaptiveSpinCount(self: *Worker) u16 {
        const rate = if (self.steal_attempts > 100) 
            @as(f32, @floatFromInt(self.steal_successes)) / 
            @as(f32, @floatFromInt(self.steal_attempts))
        else 0.5;
        
        // High success rate: less spinning (work is plentiful)
        // Low success rate: more spinning (work is scarce)
        return if (rate > 0.8) 50 
               else if (rate > 0.5) 100
               else if (rate > 0.2) 200
               else 400;
    }
};
```

**Expected Outcome**: Optimal CPU usage across varying workloads
**Effort**: Low (2-4 hours)

#### Solution 5: Per-Worker Metrics Exposure
**Contradiction Resolved**: Observability gap
**Principles Applied**: #2 (Extraction), #25 (Self-service)

**Description**: Expose per-worker statistics for debugging and tuning.

```zig
pub const WorkerStats = struct {
    tasks_executed: u64,
    tasks_stolen: u64,
    steal_attempts: u64,
    spin_yields: u64,
    commands_produced: u32,
};

pub fn getWorkerStats(self: *const Self, worker_id: u16) ?WorkerStats {
    if (worker_id >= self.num_workers) return null;
    const worker = &self.workers[worker_id];
    return .{
        .tasks_executed = worker.tasks_executed,
        .tasks_stolen = worker.tasks_stolen,
        // ... additional metrics ...
    };
}
```

**Expected Outcome**: Visibility into work distribution and contention patterns
**Effort**: Low (1-2 hours)

### 7. Implementation Recommendations

#### Priority Order

| Priority | Solution | Effort | Impact | Risk |
|----------|----------|--------|--------|------|
| **P0** | #3: Stress Testing | 6-10h | Critical | High (blocking correctness) |
| **P1** | #1: Multi-threaded Execution | 4-8h | High | Medium (race potential) |
| **P2** | #5: Per-Worker Metrics | 1-2h | Medium | Low |
| **P3** | #2: Batch Stealing | 2-4h | Medium | Low |
| **P4** | #4: Adaptive Spin | 2-4h | Low-Medium | Low |

#### Testing Requirements

1. **Unit Tests** (existing, passing):
   - [`ChaseLevDeque - basic operations`](../../../src/ecs/scheduler/backends/work_stealing.zig:832)
   - [`ChaseLevDeque - steal operations`](../../../src/ecs/scheduler/backends/work_stealing.zig:847)
   - [`ChaseLevDeque - capacity limit`](../../../src/ecs/scheduler/backends/work_stealing.zig:862)

2. **Stress Tests** (to be created):
   - `test "stress: ChaseLevDeque MPMC - 4 pushers, 4 stealers"`
   - `test "stress: WorkStealingBackend - parallel phase with 8 workers"`
   - `test "stress: determinism - 100 runs produce identical command order"`
   - `test "stress: steal storm - all workers emptied simultaneously"`

3. **Integration Tests**:
   - Execute `multi_system_config` with actual multi-threading
   - Verify `BackendStats.tasks_stolen > 0` when stealing occurs
   - Benchmark vs. `BlockingBackend` for parallel-safe systems

#### Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Race conditions in multi-threaded mode | Stress testing before enabling |
| Command buffer overflow | Already handled in [`mergeWorkerCommands()`](../../../src/ecs/scheduler/backends/work_stealing.zig:783) |
| Deadlock on phase barrier | No barriers used; cooperative completion via `tasks_remaining` |
| Performance regression | Benchmark gates before production use |

## References

- [00-OVERVIEW.md](00-OVERVIEW.md) - Parent planning document
- [99-ROADMAP.md](99-ROADMAP.md) - Feature completion roadmap
- [`lock_free_queue_stress_test.zig`](../../../src/ecs/coordination/lock_free_queue_stress_test.zig) - Stress test patterns
- [`interface.zig`](../../../src/ecs/scheduler/backends/interface.zig) - Backend interface requirements
- [`backends_test.zig`](../../../src/ecs/scheduler/backends/backends_test.zig) - Existing backend tests