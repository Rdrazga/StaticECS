# Experimental Features Implementation Roadmap

**Status:** Complete
**Created:** 2024-11-29
**Methodology:** TRIZ + PrOACT
**Total Effort:** 42-55 hours (Phases 1-4)

## Executive Summary

This roadmap consolidates findings from 5 TRIZ analyses and 2 PrOACT decision processes to provide a complete implementation plan for StaticECS experimental features.

### Go/No-Go Decisions
| Feature | Decision | Rationale |
|---------|----------|-----------|
| WorkStealingBackend | **GO** | Core parallelism feature, correct atomics |
| IoUringBatchBackend | **GO** | Critical for Linux async I/O |
| AdaptiveBackend I/O | **GO** | Enables intelligent scheduling |
| Cluster Coordination | **CONDITIONAL GO** | Minimal shim sufficient |
| GPU Executor | **NO-GO (DEFER)** | PCIe bottleneck, poor ROI |

## Phase Overview

```
Phase 1 (4-7 hours)     Phase 2 (10-18 hours)     Phase 3 (4-6 hours)     Phase 4 (~3 days)
┌─────────────────┐     ┌──────────────────┐      ┌────────────────┐      ┌───────────────┐
│ Quick Wins      │     │ Safety Validation│      │ Production     │      │ Distribution  │
│                 │     │                  │      │ Readiness      │      │               │
│ • AdaptiveI/O   │ ──► │ • WS Stress Tests│ ──► │ • IoUring      │ ──► │ • Cluster     │
│ • IoUring Tiger │     │ • WS MT Execution│      │   Stress Tests │      │   Shim        │
└─────────────────┘     └──────────────────┘      └────────────────┘      └───────────────┘
        │                        │                       │                       │
        ▼                        ▼                       ▼                       ▼
   [Immediate]            [After Stress]           [After MT]            [On Demand]
```

## Detailed Phase Plan

### Phase 1: Quick Wins (4-7 hours)
**Objective:** Complete two low-risk, high-value improvements

#### 1.1 AdaptiveBackend I/O Metrics (2-4 hours)
- **File:** `src/ecs/scheduler/backends/adaptive.zig`
- **TRIZ Solution:** Hybrid comptime+runtime approach
- **Approach:** TDD with incremental commits
- **Testing:** Unit tests for hybrid estimator
- **Review:** Medium
- **Success Criteria:** 
  - [ ] Comptime I/O system counter implemented
  - [ ] Runtime variance weighting implemented
  - [ ] TODO at line 258 resolved
  - [ ] Unit tests pass

#### 1.2 IoUringBatchBackend Tiger Style Refactor (2-3 hours)
- **File:** `src/ecs/scheduler/backends/io_uring_batch.zig`
- **TRIZ Solution:** Segmented operation preparation
- **Approach:** Pure refactoring (no behavior change)
- **Testing:** Existing tests must pass
- **Review:** Light
- **Success Criteria:**
  - [ ] `submitBatch()` split into ≤70 line functions
  - [ All existing tests pass
  - [ ] No new functionality

**Phase 1 Gate:** Both success criteria met before proceeding

---

### Phase 2: Safety Validation (10-18 hours)
**Objective:** Prove WorkStealingBackend is production-safe

#### 2.1 WorkStealingBackend Stress Tests (6-10 hours)
- **File:** New `src/ecs/scheduler/backends/work_stealing_stress_test.zig`
- **TRIZ Solution:** Follow `lock_free_queue_stress_test.zig` patterns
- **Approach:** TDD
- **Testing:** 
  - MPMC stress (multiple producers/consumers)
  - Steal storm (all workers steal simultaneously)
  - Determinism verification (XOR checksum)
- **Review:** Heavy (concurrency correctness critical)
- **CI Requirements:** TSan enabled
- **Success Criteria:**
  - [ ] 100 consecutive iterations pass
  - [ ] No data races under TSan
  - [ ] Deterministic output verified

#### 2.2 WorkStealingBackend MT Execution (4-8 hours)
- **File:** `src/ecs/scheduler/backends/work_stealing.zig`
- **TRIZ Solution:** Spawn actual worker threads, batch stealing
- **Approach:** Staged enable (single-phase → multi-phase)
- **Testing:** Integration tests with real workloads, benchmarks
- **Review:** Heavy (thread safety)
- **Dependencies:** Phase 2.1 stress tests MUST pass
- **Success Criteria:**
  - [ ] `std.Thread.spawn()` implemented
  - [ ] Thread-local deques working
  - [ ] Integration tests pass
  - [ ] Performance benchmark shows improvement

**Phase 2 Gate:** 100 stress test iterations pass before MT execution

---

### Phase 3: Production Readiness (4-6 hours)
**Objective:** Complete IoUring backend validation

#### 3.1 IoUringBatchBackend Stress Tests (4-6 hours)
- **File:** New test file
- **TRIZ Solution:** Cross-platform intent extraction enables mock testing
- **Approach:** Platform-specific tests
- **Testing:** Mock I/O + real I/O on Linux
- **Review:** Medium
- **CI Requirements:** Linux kernel 5.1+, Linux-specific CI
- **Success Criteria:**
  - [ ] Intent queue stress tests pass
  - [ ] Real I/O tests pass on Linux CI
  - [ ] Non-Linux builds compile (placeholder backend)

---

### Phase 4: Distribution (Conditional, ~3 days)
**Objective:** Enable multi-process ECS coordination
**Trigger:** User demand or explicit roadmap decision

#### 4.1 Cluster Coordination Transport Shim (~3 days)
- **Files:** New `src/ecs/scalability/cluster_transport.zig`
- **TRIZ Solution:** Transport trait abstraction + minimal TCP
- **Approach:** Minimal viable TCP transport
- **Testing:** 2-process integration test
- **Review:** Medium
- **Success Criteria:**
  - [ ] Transport trait defined
  - [ ] TCP transport implemented via `std.net.Stream`
  - [ ] Heartbeat integration with `ClusterCoordinator.tick()`
  - [ ] 2-process integration test passes

---

## Deferred Features

### GPU Executor (NO-GO)
**Rationale:** PCIe bottleneck makes GPU slower than CPU for <50k entities
**Break-even:** 50k+ entities with uniform operations
**Effort:** 3-6 developer-months
**Recommendation:** Users needing GPU can integrate wgpu-native with `getComponentSlice()` directly

**Reconsideration Triggers:**
- WebGPU/wgpu-native matures
- Unified memory becomes standard (Apple M-series pattern)
- Multiple users request GPU for specific workloads

---

## Dependencies Graph

```
Phase 1.1 (Adaptive I/O)     Phase 1.2 (IoUring Refactor)
            │                              │
            └──────────┬───────────────────┘
                       │
                       ▼
              [Phase 1 Complete]
                       │
                       ▼
         Phase 2.1 (WS Stress Tests)
                       │
                       │ GATE: 100 iterations pass
                       ▼
         Phase 2.2 (WS MT Execution)
                       │
                       ▼
              [Phase 2 Complete]
                       │
                       ▼
         Phase 3.1 (IoUring Stress)
                       │
                       ▼
              [Phase 3 Complete]
                       │
                       │ CONDITIONAL
                       ▼
         Phase 4.1 (Cluster Shim)
```

---

## Timeline Estimates

| Phase | Effort | Calendar Time (1 dev) | Parallelizable |
|-------|--------|----------------------|----------------|
| Phase 1 | 4-7h | 1 day | Yes (both items) |
| Phase 2 | 10-18h | 2-3 days | No (sequential gate) |
| Phase 3 | 4-6h | 1 day | After Phase 2 |
| Phase 4 | ~24h | 3 days | After Phase 3 |
| **Total** | **42-55h** | **7-9 days** | |

**Notes:**
- Phase 4 is conditional and may not be executed
- Phases 1-3 bring core schedulers to production status
- Timeline assumes dedicated development time

---

## Success Metrics

### Per-Phase Metrics
- **Phase 1:** Code quality improved, Tiger Style compliant
- **Phase 2:** Zero data races, 100 stress test passes
- **Phase 3:** Linux I/O production-ready
- **Phase 4:** Multi-process coordination working

### Overall Metrics
- All GO features elevated from "Experimental" to "Production"
- Documentation updated in `EXPERIMENTAL.md`
- README updated to reflect new capabilities

---

## Risk Register

| Risk | Mitigation | Contingency |
|------|------------|-------------|
| Stress tests reveal atomics bugs | Heavy code review | Rollback to blocking backend |
| MT execution causes deadlocks | TSan CI, extensive testing | Disable MT, keep single-worker |
| IoUring kernel compatibility | Test on multiple kernel versions | Fall back to blocking |
| Cluster shim complexity grows | Scope to minimal TCP only | Defer entire Phase 4 |

---

## Integration with Master Roadmap

This experimental features roadmap is **Track B** in the unified [`00-MASTER-ROADMAP.md`](../00-MASTER-ROADMAP.md).

### Track Dependencies
- **Blocked by:** Track A (Critical Safety & Quick Wins) must complete first
- **Runs parallel to:** Track C (TigerStyle Cleanup) during Phase 2
- **Unlocks:** Track D (Benchmarking) needs Phase 1 complete for IoUring refactor

### Complementary Tracks
The following tracks address related code quality issues:

| Track | Document | Relevance |
|-------|----------|-----------|
| Track C | [`tigerstyle-cleanup.md`](../tigerstyle-cleanup.md) | IoUring `submitBatch()` refactor overlaps with Phase 1.2 |
| Track D | [`benchmark-completion.md`](../benchmark-completion.md) | Multi-threaded benchmarks depend on WorkStealing completion |
| Track E | [`testing-examples-enhancement.md`](../testing-examples-enhancement.md) | Stress tests from Phase 2 expand test coverage |

### Timeline in Context
```
Master Roadmap Week 1-2:
Day 1    │ Track A: Critical fixes
Days 2-4 │ Track B Phase 1: Quick Wins ◄──── You are here
Days 5-9 │ Track B Phase 2-3: Safety + Production
         │ Track C (parallel): TigerStyle
```

See [`00-MASTER-ROADMAP.md`](../00-MASTER-ROADMAP.md) for the complete 4-week implementation schedule.

---

## Related Documents

- [00-MASTER-ROADMAP.md](../00-MASTER-ROADMAP.md) - Unified implementation plan (entry point)
- [01-work-stealing-triz.md](01-work-stealing-triz.md)
- [02-io-uring-triz.md](02-io-uring-triz.md)
- [03-gpu-executor-triz.md](03-gpu-executor-triz.md)
- [04-cluster-triz.md](04-cluster-triz.md)
- [05-adaptive-backend-triz.md](05-adaptive-backend-triz.md)
- [10-prioritization-proact.md](10-prioritization-proact.md)
- [11-implementation-proact.md](11-implementation-proact.md)