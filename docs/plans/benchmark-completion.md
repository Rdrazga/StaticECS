# Benchmark Completion Plan

> **Status**: Complete
> **Priority**: High
> **Estimated Effort**: 16-28 hours (3-5 days)
> **Completed**: 2024-12-02

## Executive Summary

The existing benchmark module at [`src/ecs/benchmark.zig`](src/ecs/benchmark.zig) provides basic entity spawn/despawn and component access benchmarks but lacks coverage for query iteration, system execution, and multi-threaded operations. This plan addresses 8 identified issues to create a comprehensive benchmarking suite that validates StaticECS's "maximize performance" claims.

---

## 1. Current State Analysis

### 1.1 Existing Benchmarks

| Benchmark | Entity Count | Iterations | Coverage |
|-----------|-------------|------------|----------|
| `entity_spawn` | 10,000 | 10,000 | Entity creation |
| `entity_despawn` | 10,000 | 10,000 | Entity deletion |
| `component_access` | 100 | 100,000 | Read operations |
| `component_mutation` | 100 | 100,000 | Write operations |
| `hasComponent_check` | 100 | 100,000 | Component queries |
| `isAlive_check` | 100 | 100,000 | Entity validation |
| `full_entity_spawn` | 5,000 | 5,000 | Multi-component entities |

### 1.2 Current Infrastructure

- **[`BenchResult`](src/ecs/benchmark.zig:80)**: Basic result struct with min/max/total
- **[`benchmark()`](src/ecs/benchmark.zig:106)**: Helper function (unused in [`main()`](src/ecs/benchmark.zig:386))
- **[`BenchConfig`](src/ecs/benchmark.zig:56)**: Test configuration with 4 components, 4 archetypes

### 1.3 Identified Gaps

| ID | Issue | Location | Impact |
|----|-------|----------|--------|
| H-1 | Missing Query Iteration Benchmark | N/A | Cannot validate query performance claims |
| H-2 | Missing System Execution Benchmark | N/A | Cannot validate system dispatch overhead |
| H-8 | Missing Multi-Threaded Benchmarks | N/A | Cannot validate thread scaling |
| H-12 | [`main()`](src/ecs/benchmark.zig:386) at 241 lines | Lines 386-627 | TigerStyle violation (≤70 lines) |
| M-16 | No Statistical Measures | [`BenchResult`](src/ecs/benchmark.zig:80) | No percentiles, stddev |
| M-17 | Entity Counts Too Small | Various | Max 10K, need 100K/1M for cache pressure |
| M-18 | No Warm-up Phase | [`main()`](src/ecs/benchmark.zig:386) | Cold cache skews results |
| L-15 | [`benchmark()`](src/ecs/benchmark.zig:106) helper unused | [`main()`](src/ecs/benchmark.zig:386) | Code duplication |

---

## 2. Requirements

### 2.1 Functional Requirements

1. **Query Iteration Benchmarks**
   - Single component queries
   - Multi-component queries (2, 4, 8 components)
   - With/without exclusion filters
   - Sparse vs dense archetype scenarios

2. **System Execution Benchmarks**
   - Single system dispatch overhead
   - System chain execution (5, 10, 20 systems)
   - Dependency resolution overhead
   - Phase transition overhead

3. **Multi-Threaded Benchmarks**
   - Work-stealing backend performance
   - Blocking backend comparison
   - Thread scaling (1, 2, 4, 8 threads)
   - False sharing detection

4. **Memory Benchmarks**
   - Archetype table memory usage
   - Entity density (entities per cache line)
   - Component padding overhead

### 2.2 Non-Functional Requirements

1. **Statistical Rigor**
   - Warm-up phase before measurement
   - Percentiles: p50, p75, p90, p99
   - Standard deviation calculation
   - Outlier detection (min/max flagging)

2. **Scale Requirements**
   - Entity tiers: 1K, 10K, 100K, 1M
   - Must exceed L3 cache to measure memory-bound behavior
   - Archetype variations: 1, 10, 100 archetypes

3. **TigerStyle Compliance**
   - Functions ≤70 lines
   - Explicit resource limits
   - Comprehensive assertions

### 2.3 Reference: TigerBeetle Methodology

Following TigerBeetle's benchmark approach:
- Multiple runs with warmup
- Report percentiles, not just averages
- Test at scale exceeding production expectations
- Measure memory bandwidth saturation
- Track regressions against baseline

---

## 3. Design

### 3.1 Enhanced `BenchResult` Structure

```zig
const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    
    // Statistical measures
    min_ns: u64,
    max_ns: u64,
    p50_ns: u64,
    p75_ns: u64,
    p90_ns: u64,
    p99_ns: u64,
    stddev_ns: f64,
    
    // Metadata
    entities_processed: u64,
    bytes_processed: u64,
    
    fn entitiesPerSecond(self: BenchResult) u64 { ... }
    fn throughputMBps(self: BenchResult) f64 { ... }
};
```

### 3.2 Benchmark Runner Architecture

```
┌─────────────────────────────────────────────────┐
│                 BenchmarkSuite                   │
├─────────────────────────────────────────────────┤
│ - warmup_iterations: u32                        │
│ - measurement_iterations: u32                   │
│ - entity_tiers: []u64                           │
│ - thread_counts: []u32                          │
├─────────────────────────────────────────────────┤
│ + runAll() → []BenchResult                      │
│ + runCategory(category) → []BenchResult         │
│ + printReport(results)                          │
│ + compareBaseline(results, baseline)            │
└─────────────────────────────────────────────────┘
         │
         ├── EntityBenchmarks
         │    ├── benchSpawn()
         │    ├── benchDespawn()
         │    └── benchBulkOperations()
         │
         ├── QueryBenchmarks
         │    ├── benchSingleComponent()
         │    ├── benchMultiComponent()
         │    └── benchWithFilters()
         │
         ├── SystemBenchmarks
         │    ├── benchSingleDispatch()
         │    ├── benchSystemChain()
         │    └── benchDependencyResolution()
         │
         ├── ThreadedBenchmarks
         │    ├── benchWorkStealing()
         │    ├── benchBlocking()
         │    └── benchScaling()
         │
         └── MemoryBenchmarks
              ├── benchMemoryUsage()
              └── benchCacheEfficiency()
```

### 3.3 File Structure

```
src/ecs/
├── benchmark.zig              # Main entry, orchestration
└── benchmark/
    ├── mod.zig               # Module exports
    ├── runner.zig            # BenchmarkSuite runner
    ├── stats.zig             # Statistical calculations
    ├── entity_bench.zig      # Entity spawn/despawn
    ├── query_bench.zig       # Query iteration (NEW)
    ├── system_bench.zig      # System execution (NEW)
    ├── threaded_bench.zig    # Multi-threaded (NEW)
    └── memory_bench.zig      # Memory usage (NEW)
```

---

## 4. Implementation Plan

### Phase A: Infrastructure (2-4 hours)

**Goal**: Establish foundation for statistical benchmarking

| Task | Issue | Files | Est. | Status |
|------|-------|-------|------|--------|
| A.1 | Refactor `main()` to ≤70 lines | [`benchmark.zig`](src/ecs/benchmark.zig:386) | 1h | [x] Complete (241→48 lines) |
| A.2 | Implement statistical measures | [`benchmark/stats.zig`](src/ecs/benchmark/stats.zig) | 2h | [x] Complete (6 functions, 9 tests) |
| A.3 | Add warm-up phase | [`benchmark/runner.zig`](src/ecs/benchmark/runner.zig) | 30m | [x] Complete (3 structs, 9 tests) |
| A.4 | Use `benchmark()` helper | [`benchmark.zig`](src/ecs/benchmark.zig:386) | 30m | [x] Complete |

**A.1 Refactor Strategy**:
```zig
// Current: 241-line main()
// Target: ≤70 lines via extraction

pub fn main() !void {
    var suite = BenchmarkSuite.init(allocator, .{
        .warmup_iterations = 100,
        .measurement_iterations = 1000,
        .entity_tiers = &.{ 1_000, 10_000, 100_000 },
    });
    defer suite.deinit();
    
    const results = try suite.runAll();
    suite.printReport(results);
}
```

**A.2 Statistical Implementation**:
```zig
pub fn calculateStats(samples: []const u64) Stats {
    std.sort.sort(u64, samples, {}, std.sort.asc(u64));
    
    return .{
        .p50 = percentile(samples, 50),
        .p75 = percentile(samples, 75),
        .p90 = percentile(samples, 90),
        .p99 = percentile(samples, 99),
        .stddev = standardDeviation(samples),
        .mean = mean(samples),
    };
}
```

**Deliverables**:
- [x] `benchmark/runner.zig` with `BenchmarkSuite`
- [x] `benchmark/stats.zig` with percentile/stddev functions
- [x] Refactored [`main()`](src/ecs/benchmark.zig:386) - reduced from 241 to 48 lines
- [x] Warm-up phase integrated

---

### Phase B: Core Benchmarks (4-8 hours)

**Goal**: Implement missing query and system benchmarks

| Task | Issue | Files | Est. | Status |
|------|-------|-------|------|--------|
| B.1 | Query iteration benchmarks | [`benchmark/query_bench.zig`](src/ecs/benchmark/query_bench.zig) | 3h | [x] Complete (7 functions, 8 tests) |
| B.2 | System execution benchmarks | [`benchmark/system_bench.zig`](src/ecs/benchmark/system_bench.zig) | 3h | [x] Complete (7 functions) |
| B.3 | Scale to 100K/1M entities | [`benchmark/scale_bench.zig`](src/ecs/benchmark/scale_bench.zig) | 2h | [x] Complete (5 functions, 4 tier configs) |

**B.1 Query Benchmarks**:

```zig
// Single component iteration
pub fn benchSingleComponentQuery(suite: *BenchmarkSuite) BenchResult {
    // Setup: spawn N entities with Position
    // Measure: iterate query, sum positions
    // Metric: entities/second, ns/entity
}

// Multi-component iteration
pub fn benchMultiComponentQuery(
    suite: *BenchmarkSuite,
    comptime component_count: u8,  // 2, 4, or 8
) BenchResult {
    // Setup: spawn N entities with component_count components
    // Measure: iterate query accessing all components
    // Metric: entities/second, cache misses
}

// With exclusion filters
pub fn benchQueryWithExclusion(suite: *BenchmarkSuite) BenchResult {
    // Setup: mixed archetype population
    // Measure: query with Without(Enemy) filter
    // Metric: filter overhead ns
}
```

**B.2 System Benchmarks**:

```zig
// Single dispatch
pub fn benchSingleSystemDispatch(suite: *BenchmarkSuite) BenchResult {
    // Setup: world with movement system
    // Measure: single tick() call
    // Metric: dispatch overhead ns
}

// System chain
pub fn benchSystemChain(
    suite: *BenchmarkSuite,
    system_count: u8,  // 5, 10, or 20
) BenchResult {
    // Setup: chain of N systems with dependencies
    // Measure: full tick with dependency resolution
    // Metric: systems/second, resolution overhead
}
```

**B.3 Scale Changes**:

```zig
// Entity tiers for cache pressure testing
const ENTITY_TIERS = [_]u64{
    1_000,      // L1 cache
    10_000,     // L2 cache  
    100_000,    // L3 cache
    1_000_000,  // Main memory
};

// Config update
const LargeBenchConfig = WorldConfig{
    .options = .{
        .max_entities = 1_048_576,  // 1M entities
        // ...
    },
};
```

**Deliverables**:
- [x] `benchmark/query_bench.zig` with 4+ query benchmarks
- [x] `benchmark/system_bench.zig` with 3+ system benchmarks
- [x] All benchmarks support 1K-1M entity tiers
- [x] Updated [`BenchConfig`](src/ecs/benchmark.zig:56) for large scale

---

### Phase C: Advanced Benchmarks (4-8 hours)

**Goal**: Multi-threaded and memory benchmarks

| Task | Issue | Files | Est. | Status |
|------|-------|-------|------|--------|
| C.1 | Multi-threaded benchmarks | [`benchmark/threaded_bench.zig`](src/ecs/benchmark/threaded_bench.zig) | 4h | [x] Complete (4 functions, 11 tests) |
| C.2 | Memory benchmarks | [`benchmark/memory_bench.zig`](src/ecs/benchmark/memory_bench.zig) | 2h | [x] Complete (5 functions) |
| C.3 | Baseline regression system | [`benchmark/baseline.zig`](src/ecs/benchmark/baseline.zig) | 2h | [x] Complete (12 tests) |

**C.1 Threaded Benchmarks**:

```zig
// Work-stealing benchmark
pub fn benchWorkStealing(
    suite: *BenchmarkSuite,
    thread_count: u8,
) BenchResult {
    // Config: work_stealing backend, N threads
    // Measure: parallel system execution
    // Metric: scaling factor, thread efficiency %
}

// Scaling efficiency
pub fn benchThreadScaling(suite: *BenchmarkSuite) []BenchResult {
    var results: [4]BenchResult = undefined;
    for ([_]u8{ 1, 2, 4, 8 }, 0..) |threads, i| {
        results[i] = benchWorkStealing(suite, threads);
    }
    return results;
}

// Efficiency calculation
fn calculateEfficiency(single_thread_time: u64, multi_time: u64, threads: u8) f64 {
    const ideal = single_thread_time / threads;
    return @as(f64, @floatFromInt(ideal)) / @as(f64, @floatFromInt(multi_time));
}
```

**C.2 Memory Benchmarks**:

```zig
pub fn benchMemoryUsage(suite: *BenchmarkSuite, entity_count: u64) MemoryResult {
    const before = getMemoryUsage();
    // Spawn entity_count entities
    const after = getMemoryUsage();
    
    return .{
        .total_bytes = after - before,
        .bytes_per_entity = (after - before) / entity_count,
        .overhead_percent = calculateOverhead(entity_count),
    };
}

pub fn benchCacheEfficiency(suite: *BenchmarkSuite) CacheResult {
    // Measure sequential vs random access patterns
    // Report cache miss rates (via perf counters if available)
}
```

**C.3 Baseline System**:

```zig
const Baseline = struct {
    results: []BenchResult,
    timestamp: i64,
    commit_hash: [40]u8,
    
    pub fn save(self: Baseline, path: []const u8) !void { ... }
    pub fn load(path: []const u8) !Baseline { ... }
    pub fn compare(current: []BenchResult, baseline: Baseline) Report { ... }
};
```

**Deliverables**:
- [x] `benchmark/threaded_bench.zig` with scaling tests
- [x] `benchmark/memory_bench.zig` with usage tracking
- [x] `benchmark/baseline.zig` for regression detection
- [ ] CI integration script (optional, deferred)

---

## 5. Metrics & Success Criteria

### 5.1 Primary Metrics

| Category | Metric | Unit | Target |
|----------|--------|------|--------|
| Entity | Spawn throughput | entities/sec | >1M |
| Query | Iteration speed | entities/sec | >10M |
| System | Dispatch overhead | ns/system | <1000 |
| Threading | Scaling efficiency | % | >75% at 4 threads |
| Memory | Bytes per entity | bytes | <100 (sparse) |

### 5.2 Statistical Requirements

- All benchmarks report: mean, p50, p75, p90, p99, stddev
- Warm-up phase: minimum 100 iterations discarded
- Measurement phase: minimum 1000 iterations
- Outlier detection: flag results >3σ from mean

### 5.3 Scale Validation

| Entity Count | Purpose |
|--------------|---------|
| 1,000 | L1 cache (warm) |
| 10,000 | L2 cache |
| 100,000 | L3 cache |
| 1,000,000 | Memory-bound |

### 5.4 Completion Checklist

- [x] **Infrastructure**
  - [x] `main()` refactored to ≤70 lines
  - [x] Statistical measures (p50/p75/p99/stddev)
  - [x] Warm-up phase implemented
  - [x] `benchmark()` helper used throughout

- [x] **Core Benchmarks**
  - [x] Query iteration (single component)
  - [x] Query iteration (multi-component: 2, 4, 8)
  - [x] Query with exclusion filters
  - [x] System single dispatch
  - [x] System chain (5, 10, 20 systems)
  - [x] Entity counts scaled to 100K/1M

- [x] **Advanced Benchmarks**
  - [x] Work-stealing thread scaling
  - [x] Blocking backend comparison
  - [x] Memory usage per entity
  - [x] Cache efficiency measurement

- [ ] **Documentation** (deferred to Track F)
  - [ ] README updated with benchmark instructions
  - [ ] Results format documented
  - [ ] Baseline comparison documented

---

## 6. Timeline

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| **Phase A**: Infrastructure | 1 day | None |
| **Phase B**: Core Benchmarks | 1-2 days | Phase A |
| **Phase C**: Advanced Benchmarks | 1-2 days | Phase B |
| **Documentation** | 0.5 days | Phase C |
| **Total** | **3-5 days** | |

### Effort Breakdown

| Issue ID | Issue | Effort | Phase |
|----------|-------|--------|-------|
| H-12 | Refactor `main()` (TigerStyle) | 1-2h | A |
| M-16 | Statistical measures | 4-8h | A |
| M-18 | Warm-up phase | 1h | A |
| L-15 | Use `benchmark()` helper | 30m | A |
| H-1 | Query iteration benchmarks | 2-4h | B |
| H-2 | System execution benchmarks | 2-4h | B |
| M-17 | Scale to 100K/1M | 2-4h | B |
| H-8 | Multi-threaded benchmarks | 4-8h | C |

**Total Estimated**: 16-28 hours

---

## 7. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Platform timing inconsistencies | Results vary | Use `std.time.Instant`, document platform |
| Cache effects skew results | Unreliable data | Multiple runs, warm-up phase |
| Thread contention overhead | False conclusions | Isolate benchmark threads |
| Large entity counts OOM | Cannot scale | Configurable max, chunked tests |

---

## 8. Future Considerations

1. **zBench Integration**: Consider adopting zBench library for automated iterations and pretty-printing
2. **Tracy Profiling**: Add Tracy markers for hotspot analysis
3. **CI Regression Gate**: Block PRs that regress >10% on key metrics
4. **Cross-Platform Matrix**: Test on Linux, Windows, macOS

---

## Appendix A: Issue Reference

| ID | Issue | Priority | Effort | Phase |
|----|-------|----------|--------|-------|
| H-1 | Missing Query Iteration Benchmark | High | 2-4h | B |
| H-2 | Missing System Execution Benchmark | High | 2-4h | B |
| H-8 | Missing Multi-Threaded Benchmarks | High | 4-8h | C |
| H-12 | benchmark `main()` at 241 lines (TigerStyle) | High | 1-2h | A |
| M-16 | No Statistical Measures (p50/p75/p99, stddev) | Medium | 4-8h | A |
| M-17 | Entity Counts Too Small (max 10K, need 100K/1M) | Medium | 2-4h | B |
| M-18 | No Warm-up Phase | Medium | 1h | A |
| L-15 | Benchmark Helper Function Not Used | Low | 30m | A |

---

## Appendix B: Example Output Format

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                         StaticECS Benchmark Suite                            ║
║                         Running in ReleaseFast mode                          ║
╚══════════════════════════════════════════════════════════════════════════════╝

Configuration: warmup=100, iterations=1000, threads=4

┌─────────────────────────────────────────────────────────────────────────────┐
│ Entity Benchmarks (100,000 entities)                                        │
├────────────────────────┬─────────┬─────────┬─────────┬─────────┬───────────┤
│ Benchmark              │ p50     │ p99     │ stddev  │ ops/sec │ entities/s│
├────────────────────────┼─────────┼─────────┼─────────┼─────────┼───────────┤
│ entity_spawn           │     42ns│    128ns│    18ns │   23.8M │     23.8M │
│ entity_despawn         │     38ns│    112ns│    15ns │   26.3M │     26.3M │
└────────────────────────┴─────────┴─────────┴─────────┴─────────┴───────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ Query Benchmarks (100,000 entities)                                         │
├────────────────────────┬─────────┬─────────┬─────────┬─────────┬───────────┤
│ Benchmark              │ p50     │ p99     │ stddev  │ ops/sec │ entities/s│
├────────────────────────┼─────────┼─────────┼─────────┼─────────┼───────────┤
│ query_1_component      │      8ns│     24ns│     3ns │  125.0M │    125.0M │
│ query_4_component      │     22ns│     58ns│     8ns │   45.5M │     45.5M │
│ query_with_filter      │     12ns│     32ns│     5ns │   83.3M │     83.3M │
└────────────────────────┴─────────┴─────────┴─────────┴─────────┴───────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ Thread Scaling                                                               │
├────────────┬───────────┬───────────┬────────────┐
│ Threads    │ Time (ms) │ Speedup   │ Efficiency │
├────────────┼───────────┼───────────┼────────────┤
│ 1          │     100.0 │     1.00x │      100%  │
│ 2          │      52.0 │     1.92x │       96%  │
│ 4          │      28.0 │     3.57x │       89%  │
│ 8          │      16.5 │     6.06x │       76%  │
└────────────┴───────────┴───────────┴────────────┘

Baseline comparison: baseline.json (2024-01-15)
  ✓ entity_spawn: -2.1% (improved)
  ✓ query_1_component: +0.3% (within tolerance)
  ⚠ query_4_component: +5.2% (regression warning)