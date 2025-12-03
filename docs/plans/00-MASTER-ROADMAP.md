# StaticECS Master Implementation Roadmap

**Status:** Active  
**Created:** 2024-12-02  
**Version:** 1.0  
**Total Effort:** 100-140 hours (~12-18 working days)  
**Project Grade Target:** B+ → A-

---

## Executive Summary

This master roadmap integrates all individual implementation plans into a unified view of the complete StaticECS implementation backlog. It consolidates findings from:

- 5 TRIZ analyses for experimental features
- 2 PrOACT decision processes
- Comprehensive code review identifying 52 issues
- TigerStyle compliance audit

### Quick Statistics

| Metric | Value |
|--------|-------|
| **Total Issues** | 52 |
| **Critical Issues** | 1 |
| **High Priority** | 12 |
| **Medium Priority** | 23 |
| **Low Priority** | 16 |
| **Total Effort** | 100-140 hours |
| **Duration** | 4 weeks / 18 working days |

### Source Plans Summary

| Plan | Location | Effort | Status |
|------|----------|--------|--------|
| Experimental Features | [`experimental-features/99-ROADMAP.md`](experimental-features/99-ROADMAP.md) | 42-55h | Complete |
| TigerStyle Cleanup | [`tigerstyle-cleanup.md`](tigerstyle-cleanup.md) | 8-12h | Complete |
| Benchmarking Completion | [`benchmark-completion.md`](benchmark-completion.md) | 16-28h | Complete |
| Testing/Examples Enhancement | [`testing-examples-enhancement.md`](testing-examples-enhancement.md) | 22-38h | Planning |

---

## Implementation Tracks

### Track A: Critical Safety & Quick Wins (Day 1)

**Effort:** 1-2 hours  
**Priority:** IMMEDIATE  
**Risk:** Low  

These issues must be resolved before any other work proceeds. They represent critical safety gaps and trivial fixes that unlock other tracks.

| ID | Issue | File | Effort | Status |
|----|-------|------|--------|--------|
| CRIT-1 | Thread Safety Contract Not Enforced | [`concurrent_commands.zig:83-118`](../../src/ecs/context/concurrent_commands.zig:83) | 2-4h | [x] |
| H-3 | GenerationPolicy Not Exported | [`config/mod.zig:52`](../../src/ecs/config/mod.zig:52) | 5 min | [x] |
| M-8 | Missing Input Mapper Validation | Various | 15 min | [x] |
| M-9 | [`Resources.remove()`](../../src/ecs/context/resources.zig) Doesn't Zero Memory | `resources.zig` | 15 min | [x] |

**Success Gate:** Zero critical issues remain.

---

### Track B: Experimental Features (Days 2-9)

**Effort:** 42-55 hours  
**Source:** [`experimental-features/99-ROADMAP.md`](experimental-features/99-ROADMAP.md)  
**Risk:** Medium-High (concurrency)  

Promotes experimental scheduler backends to production status.

#### Phase B.1: Quick Wins (4-7 hours)

| Task | File | Effort | Status |
|------|------|--------|--------|
| AdaptiveBackend I/O Metrics | [`adaptive.zig`](../../src/ecs/scheduler/backends/adaptive.zig) | 2-4h | [x] |
| IoUringBatchBackend TigerStyle Refactor | [`io_uring_batch.zig`](../../src/ecs/scheduler/backends/io_uring_batch.zig) | 2-3h | [x] |

**Phase B.1 Gate:** Both success criteria met.

#### Phase B.2: Safety Validation (10-18 hours)

| Task | File | Effort | Status |
|------|------|--------|--------|
| WorkStealing Stress Tests | New: `work_stealing_stress_test.zig` | 6-10h | [ ] |
| WorkStealing MT Execution | [`work_stealing.zig`](../../src/ecs/scheduler/backends/work_stealing.zig) | 4-8h | [ ] |

**Phase B.2 Gate:** 100 consecutive stress test iterations pass under TSan.

#### Phase B.3: Production Readiness (4-6 hours)

| Task | File | Effort | Status |
|------|------|--------|--------|
| IoUring Stress Tests | New test file | 4-6h | [ ] |

**Phase B.3 Gate:** Real I/O tests pass on Linux CI.

#### Phase B.4: Distribution (Conditional, ~3 days)

| Task | File | Effort | Status |
|------|------|--------|--------|
| Cluster Coordination Transport Shim | New: `cluster_transport.zig` | ~24h | [ ] |

**Trigger:** User demand or explicit roadmap decision.

---

### Track C: TigerStyle Compliance (Days 5-7, parallel)

**Effort:** 8-12 hours  
**Source:** [`tigerstyle-cleanup.md`](tigerstyle-cleanup.md)  
**Risk:** Low-Medium  

Ensures codebase compliance with TigerStyle guidelines (≤70 line functions, assertions).

#### Week 1: Low-Risk Refactors (1.5h) ✓ COMPLETE

| Order | Function | File | Lines | Effort | Status |
|-------|----------|------|-------|--------|--------|
| 1 | [`runWorkerLoop()`](../../src/ecs/scheduler/backends/work_stealing.zig:645) | `work_stealing.zig` | 71→70 | 15 min | [x] |
| 2 | [`tick()`](../../src/ecs/scheduler/backends/io_uring_batch.zig:406) | `io_uring_batch.zig` | 76 | 20 min | [x] |
| 3 | [`QueryIteratorBuilder`](../../src/ecs/world.zig:203) | `world.zig` | 84 | 20 min | [x] |
| 4 | [`addEntity()`](../../src/ecs/world/archetype_table.zig:266) | `archetype_table.zig` | 77→31 | 35 min | [x] |

#### Week 2: Medium-Risk Refactors (2.5h) ✓ COMPLETE

| Order | Function | File | Lines | Effort | Status |
|-------|----------|------|-------|--------|--------|
| 5 | [`destroy()`](../../src/ecs/world/entity.zig:402) | `entity.zig` | 89→41 | 50 min | [x] |
| 6 | [`create()`](../../src/ecs/world/entity.zig:379) assertions | `entity.zig` | 7 assertions | 25 min | [x] |
| 7 | [`next()`](../../src/ecs/world/query.zig:341) assertions | `query.zig` | 10+ assertions | 25 min | [x] |
| 8 | [`buildStagesForPhaseByIndex()`](../../src/ecs/scheduler/schedule_build.zig:130) | `schedule_build.zig` | 85→63 | 50 min | [x] |

#### Week 3: Higher-Risk Refactors (3h) ✓ COMPLETE

| Order | Function | File | Lines | Effort | Status |
|-------|----------|------|-------|--------|--------|
| 9 | [`tick()`](../../src/ecs/scheduler/backends/work_stealing.zig:447) | `work_stealing.zig` | 86→58 | 40 min | [x] |
| 10 | [`submitBatch()`](../../src/ecs/scheduler/backends/io_uring_batch.zig:619) | `io_uring_batch.zig` | done in B.1.2 | 50 min | [x] |
| 11 | [`executeFrame()`](../../src/ecs/scheduler/scheduler_runtime.zig:618) | `scheduler_runtime.zig` | 85→36 | 40 min | [x] |
| 12 | [`commitImport()`](../../src/ecs/pipeline/external.zig:388) | `external.zig` | 97→68 | 55 min | [x] |

#### Week 4: Complex Refactors (2h) ✓ COMPLETE

| Order | Function | File | Lines | Effort | Status |
|-------|----------|------|-------|--------|--------|
| 13 | [`main()`](../../src/ecs/benchmark.zig:386) | `benchmark.zig` | 241→48 | 2h | [x] |

**Success Gate:** All functions ≤70 lines.

---

### Track D: Benchmarking Completion (Days 8-12) ✓ COMPLETE

**Effort:** 16-28 hours
**Source:** [`benchmark-completion.md`](benchmark-completion.md)
**Risk:** Low
**Status:** Complete

Creates comprehensive benchmark suite validating performance claims.

#### Phase D.A: Infrastructure (2-4 hours) ✓ COMPLETE

| Task | Files | Effort | Status |
|------|-------|--------|--------|
| Refactor [`main()`](../../src/ecs/benchmark.zig:386) to ≤70 lines | `benchmark.zig` | 1h | [x] |
| Implement statistical measures | [`benchmark/stats.zig`](../../src/ecs/benchmark/stats.zig) | 2h | [x] |
| Add warm-up phase | [`benchmark/runner.zig`](../../src/ecs/benchmark/runner.zig) | 30m | [x] |
| Use [`benchmark()`](../../src/ecs/benchmark.zig:106) helper | `benchmark.zig` | 30m | [x] |

#### Phase D.B: Core Benchmarks (4-8 hours) ✓ COMPLETE

| Task | Files | Effort | Status |
|------|-------|--------|--------|
| Query iteration benchmarks | [`benchmark/query_bench.zig`](../../src/ecs/benchmark/query_bench.zig) | 3h | [x] |
| System execution benchmarks | [`benchmark/system_bench.zig`](../../src/ecs/benchmark/system_bench.zig) | 3h | [x] |
| Scale to 100K/1M entities | [`benchmark/scale_bench.zig`](../../src/ecs/benchmark/scale_bench.zig) | 2h | [x] |

#### Phase D.C: Advanced Benchmarks (4-8 hours) ✓ COMPLETE

| Task | Files | Effort | Status |
|------|-------|--------|--------|
| Multi-threaded benchmarks | [`benchmark/threaded_bench.zig`](../../src/ecs/benchmark/threaded_bench.zig) | 4h | [x] |
| Memory benchmarks | [`benchmark/memory_bench.zig`](../../src/ecs/benchmark/memory_bench.zig) | 2h | [x] |
| Baseline regression system | [`benchmark/baseline.zig`](../../src/ecs/benchmark/baseline.zig) | 2h | [x] |

**Success Gate:** Full benchmark suite with statistical analysis. ✓ ACHIEVED

---

### Track E: Testing & Examples (Days 10-15)

**Effort:** 22-38 hours  
**Source:** [`testing-examples-enhancement.md`](testing-examples-enhancement.md)  
**Risk:** Low  

Improves test coverage and example quality for better developer experience.

#### Phase E.1: Quick Example Fixes (2-4 hours)

| ID | Issue | File | Effort | Status |
|----|-------|------|--------|--------|
| M-14 | Query Misuse in data-pipeline | [`examples/data-pipeline/main.zig:187`](../../examples/data-pipeline/main.zig:187) | 1-2h | [ ] |
| L-13 | Unused Queries in Examples | All examples | 1h | [ ] |
| L-14 | HTTP Server I/O Context Unused | [`examples/http-server/main.zig:126`](../../examples/http-server/main.zig:126) | 30m | [ ] |

#### Phase E.2: Example Enhancements (4-6 hours)

| ID | Issue | Target | Effort | Status |
|----|-------|--------|--------|--------|
| H-5 | No Command Buffer Usage | All examples | 2-4h | [ ] |
| M-15 | No Entity Despawning | [`examples/game-loop/main.zig`](../../examples/game-loop/main.zig) | 1-2h | [ ] |

#### Phase E.3: Core Testing (8-16 hours)

| ID | Issue | Target | Effort | Status |
|----|-------|--------|--------|--------|
| H-7 | [`scheduler_runtime.zig`](../../src/ecs/scheduler/scheduler_runtime.zig:808) Only Has 1 Test | `scheduler_runtime.zig` | 4-8h | [ ] |
| M-13 | Config Submodules Lack Tests | `src/ecs/config/*.zig` | 4-8h | [ ] |

#### Phase E.4: Feature & Advanced Testing (8-12 hours)

| ID | Issue | Target | Effort | Status |
|----|-------|--------|--------|--------|
| H-6 | Missing Add/Remove Component Commands | `command_types.zig` | 4-8h | [ ] |
| M-12 | No Async/Evented Backend Testing | Backend tests | 4-6h | [ ] |
| L-12 | No Platform-Specific Tests | Platform modules | 2-4h | [ ] |

**Success Gate:** Test coverage ≥60% on key modules.

---

### Track F: Documentation & Polish (Days 14-18, parallel)

**Effort:** 8-12 hours  
**Risk:** Very Low  

Ensures documentation matches implementation and provides clear guidance.

| ID | Issue | Effort | Status |
|----|-------|--------|--------|
| M-10 | No TracingSpec Validation | 30 min | [ ] |
| M-11 | TraceSink Forward Declaration Confusion | 1h | [ ] |
| M-19 | Missing Backpressure Documentation | 1-2h | [ ] |
| L-9 | Missing Module Documentation Headers | 2-4h | [ ] |
| L-10 | Benchmark Module Undocumented | 30 min | [ ] |
| - | README updates for new capabilities | 2h | [ ] |
| - | EXPERIMENTAL.md update for promoted features | 1h | [ ] |

**Success Gate:** Documentation matches code 100%.

---

### Track G: Legacy Cleanup & Architecture (Days 16-18)

**Effort:** 6-10 hours  
**Risk:** Low  

Removes technical debt and improves architecture.

| ID | Issue | File | Effort | Status |
|----|-------|------|--------|--------|
| H-9 | [`scheduler_runtime.zig`](../../src/ecs/scheduler/scheduler_runtime.zig) Has 9 Imports | `scheduler_runtime.zig` | 2-4h | [ ] |
| M-22 | [`tickWithDelta()`](../../src/ecs/scheduler/scheduler_runtime.zig) Doesn't Use `delta_time` | `scheduler_runtime.zig` | 30 min | [ ] |
| M-23 | SPSC Queue Only in Hybrid Mode | Pipeline modules | 2h | [ ] |
| L-4 | Deprecated Stage Type Aliases | Config modules | 30 min | [ ] |
| L-5 | Deprecated SIMD Aliases | Config modules | 15 min | [ ] |
| L-6 | `steal_batch` Config Unused | Work stealing config | 1h | [ ] |
| L-11 | Degraded Mode io_uring Needs Logging | `io_uring_batch.zig` | 30 min | [ ] |

**Success Gate:** Zero unused/legacy code.

---

## Parallel Execution Strategy

```
Week 1           Week 2           Week 3           Week 4
┌───────────────┐
│ Track A       │ (Day 1)
│ Critical      │
└───────────────┘
┌────────────────────────────────────────────────────────┐
│ Track B: Experimental Features (Days 2-9)              │
│    Phase 1 → Phase 2 → Phase 3                        │
└────────────────────────────────────────────────────────┘
        ┌──────────────┐
        │ Track C      │ (Days 5-7, parallel with B.Phase2)
        │ TigerStyle   │
        └──────────────┘
                ┌─────────────────────────┐
                │ Track D: Benchmarks     │ (Days 8-12)
                │    A → B → C            │
                └─────────────────────────┘
                        ┌─────────────────────────┐
                        │ Track E: Testing        │ (Days 10-15)
                        │    1 → 2 → 3 → 4        │
                        └─────────────────────────┘
                                ┌────────────────────────┐
                                │ Track F: Documentation │ (Days 14-18)
                                │ Track G: Cleanup       │ (parallel)
                                └────────────────────────┘
```

### Critical Path

```
Track A (Day 1) → Track B.1 → Track B.2 → Track B.3 → Track D → Track E.3 → Release
                            ↘             ↗
                         Track C (parallel)
```

---

## Dependencies Matrix

| Track | Depends On | Unlocks | Can Parallel |
|-------|------------|---------|--------------|
| A | None | All others | No |
| B.Phase1 | A | B.Phase2 | No |
| B.Phase2 | B.Phase1 | B.Phase3 | Track C |
| B.Phase3 | B.Phase2 | B.Phase4 | Track D |
| B.Phase4 | B.Phase3 | Release | Conditional |
| C | A | Track D, G | Track B.Phase2 |
| D.Phase A | A, C (partial) | D.Phase B | No |
| D.Phase B | D.Phase A | D.Phase C | No |
| D.Phase C | D.Phase B | E.Phase3 | No |
| E.Phase1 | A | E.Phase2 | No |
| E.Phase2 | E.Phase1 | E.Phase3 | No |
| E.Phase3 | D completes | E.Phase4 | No |
| E.Phase4 | E.Phase3 | Release | No |
| F | E.Phase2 | Release | Track G |
| G | C | Release | Track F |

---

## Success Criteria

### Per-Track Gates

| Track | Success Criteria |
|-------|------------------|
| **A** | Zero critical issues remain |
| **B** | All GO features elevated to "Production" status |
| **C** | All functions ≤70 lines, ≥2 assertions per function |
| **D** | Full benchmark suite with p50/p75/p90/p99 statistics |
| **E** | Test coverage ≥60% on scheduler, config, and world modules |
| **F** | Documentation matches code 100%, no stale references |
| **G** | Zero unused/legacy code paths |

### Overall Project Goals

- [ ] **Grade Improvement:** B+ → A-
- [ ] **Safety:** Thread safety contracts enforced
- [ ] **Performance:** Benchmark suite validates claims
- [ ] **Quality:** TigerStyle compliant codebase
- [ ] **Stability:** Experimental features promoted to production
- [ ] **DX:** Comprehensive examples and documentation

---

## Risk Register

| Risk | Probability | Impact | Mitigation | Contingency |
|------|-------------|--------|------------|-------------|
| Track B stress tests reveal atomics bugs | Medium | High | Heavy code review, TSan CI | Rollback to blocking backend |
| Track B MT execution causes deadlocks | Low | High | TSan CI, extensive testing | Disable MT, keep single-worker |
| Track C refactors introduce bugs | Low | Medium | All existing tests must pass | Revert problematic refactors |
| Track D timeline slips | Medium | Low | Infrastructure first | Ship partial benchmark suite |
| Track E scope creep | Medium | Medium | Strict checklist adherence | Defer to Phase 5 |
| IoUring kernel compatibility | Low | Medium | Test on multiple kernel versions | Fall back to blocking |
| Cluster shim complexity grows | Low | Medium | Scope to minimal TCP only | Defer entire Phase B.4 |

---

## Timeline Summary

| Week | Days | Tracks | Hours | Cumulative |
|------|------|--------|-------|------------|
| Week 1 | 1-5 | A, B.P1, B.P2, C (start) | 30-40h | 30-40h |
| Week 2 | 6-10 | B.P2 (finish), B.P3, C (finish), D.A, D.B | 30-40h | 60-80h |
| Week 3 | 11-15 | D.C, E.P1, E.P2, E.P3 | 25-35h | 85-115h |
| Week 4 | 16-18 | E.P4, F, G | 15-25h | 100-140h |

**Total Duration:** 4 weeks / 18 working days  
**Total Effort:** 100-140 hours  
**Buffer:** 2 days built into Week 4

---

## Quick Reference: All Issues by Priority

### Critical (IMMEDIATE)

| ID | Issue | Track | Effort |
|----|-------|-------|--------|
| CRIT-1 | Thread Safety Contract Not Enforced | A | 2-4h |

### High Priority

| ID | Issue | Track | Effort |
|----|-------|-------|--------|
| H-1 | Missing Query Iteration Benchmark | D | Included |
| H-2 | Missing System Execution Benchmark | D | Included |
| H-3 | GenerationPolicy Not Exported | A | 5 min |
| H-5 | No Command Buffer Usage in Examples | E | 2-4h |
| H-6 | Missing Add/Remove Component Commands | E | 4-8h |
| H-7 | scheduler_runtime.zig Only Has 1 Test | E | 4-8h |
| H-8 | Missing Multi-Threaded Benchmarks | D | Included |
| H-9 | scheduler_runtime.zig Has 9 Imports | G | 2-4h |
| H-12 | main() at 241 lines | C/D | Included |

### Medium Priority

| ID | Issue | Track | Effort |
|----|-------|-------|--------|
| M-8 | Missing Input Mapper Validation | A | 15 min |
| M-9 | Resources.remove() Doesn't Zero Memory | A | 15 min |
| M-10 | No TracingSpec Validation | F | 30 min |
| M-11 | TraceSink Forward Declaration Confusion | F | 1h |
| M-12 | No Async/Evented Backend Testing | E | 4-6h |
| M-13 | Config Submodules Lack Individual Tests | E | 4-8h |
| M-14 | Example Query Misuse in data-pipeline | E | 1-2h |
| M-15 | No Entity Despawning in Examples | E | 1-2h |
| M-16 | No Statistical Measures | D | Included |
| M-17 | Entity Counts Too Small | D | Included |
| M-18 | No Warm-up Phase | D | Included |
| M-19 | Missing Backpressure Documentation | F | 1-2h |
| M-22 | tickWithDelta() Doesn't Use delta_time | G | 30 min |
| M-23 | SPSC Queue Only in Hybrid Mode | G | 2h |

### Low Priority

| ID | Issue | Track | Effort |
|----|-------|-------|--------|
| L-4 | Deprecated Stage Type Aliases | G | 30 min |
| L-5 | Deprecated SIMD Aliases | G | 15 min |
| L-6 | steal_batch Config Unused | G | 1h |
| L-9 | Missing Module Documentation Headers | F | 2-4h |
| L-10 | Benchmark Module Undocumented | F | 30 min |
| L-11 | Degraded Mode io_uring Needs Logging | G | 30 min |
| L-12 | No Platform-Specific Tests | E | 2-4h |
| L-13 | Unused Queries in Examples | E | 1h |
| L-14 | HTTP Server I/O Context Unused | E | 30m |
| L-15 | benchmark() helper unused | D | Included |

---

## Related Documents

### Planning Documents
- [`experimental-features/99-ROADMAP.md`](experimental-features/99-ROADMAP.md) - Experimental features implementation
- [`tigerstyle-cleanup.md`](tigerstyle-cleanup.md) - TigerStyle compliance plan
- [`benchmark-completion.md`](benchmark-completion.md) - Benchmarking completion plan
- [`testing-examples-enhancement.md`](testing-examples-enhancement.md) - Testing and examples plan

### TRIZ Analyses
- [`experimental-features/01-work-stealing-triz.md`](experimental-features/01-work-stealing-triz.md)
- [`experimental-features/02-io-uring-triz.md`](experimental-features/02-io-uring-triz.md)
- [`experimental-features/03-gpu-executor-triz.md`](experimental-features/03-gpu-executor-triz.md)
- [`experimental-features/04-cluster-triz.md`](experimental-features/04-cluster-triz.md)
- [`experimental-features/05-adaptive-backend-triz.md`](experimental-features/05-adaptive-backend-triz.md)

### PrOACT Decisions
- [`experimental-features/10-prioritization-proact.md`](experimental-features/10-prioritization-proact.md)
- [`experimental-features/11-implementation-proact.md`](experimental-features/11-implementation-proact.md)

### Project Documentation
- [`../CONFIGURATION.md`](../CONFIGURATION.md) - Configuration reference
- [`../EXPERIMENTAL.md`](../EXPERIMENTAL.md) - Experimental features status
- [`../../README.md`](../../README.md) - Project overview

---

## Changelog

| Date | Version | Changes |
|------|---------|---------|
| 2024-12-02 | 1.0 | Initial master roadmap created |

---

*This document should be updated as tracks are completed and issues are resolved.*