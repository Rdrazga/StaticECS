# Feature Prioritization PrOACT Decision

**Status:** Complete
**Decision:** Experimental Feature Prioritization
**Scope:** All experimental features
**Date:** 2024-11-29

## Summary

**Recommended Priority Order:**
1. AdaptiveBackend I/O (2-4h) - Quick win, enables better scheduling decisions
2. IoUringBatchBackend Tiger Style refactor (2-3h) - Code quality, low risk
3. WorkStealingBackend stress testing (6-10h) - Required for correctness
4. WorkStealingBackend MT execution (4-8h) - High impact after testing
5. IoUringBatchBackend stress tests (4-6h) - Production readiness
6. Cluster Coordination minimal shim (~3 days) - Conditional, enables distribution

**Deferred:** GPU Executor (3-6 months, NO-GO due to PCIe bottleneck)

**Total Effort:** ~40-55 hours (excluding GPU Executor)

---

## 1. Problem Statement

### Decision Context

StaticECS contains five experimental features in various states of completion. With limited development resources, we must determine the optimal sequence for completing these features to maximize value delivered to users while managing risk.

### Decision Scope

| Constraint | Description |
|-----------|-------------|
| Time | Limited developer hours available |
| Dependencies | Some features depend on others |
| Risk | Some features carry higher implementation risk |
| Platform | Some features are platform-specific (Linux) |

### Key Stakeholders

| Stakeholder | Interest |
|-------------|----------|
| ECS Users | Production-ready, performant scheduler backends |
| Library Maintainers | Code quality, maintainability, test coverage |
| Server Operators | Scalability, distributed coordination |
| Game Developers | Low-latency, parallel execution |

### TRIZ Analysis Summary

| Feature | TRIZ Result | Effort | Go/No-Go |
|---------|-------------|--------|----------|
| WorkStealingBackend | Needs stress testing first, then MT execution | P0: 6-10h stress, P1: 4-8h MT | **GO** |
| IoUringBatchBackend | Tiger Style refactor, stress tests, intent extraction | P0: 2-3h, P1: 4-6h | **GO** |
| GPU Executor | PCIe bottleneck makes it slower for <50k entities | 3-6 months | **NO-GO (Defer)** |
| Cluster Coordination | Minimal shim approach with Transport trait | ~3 days MVP | **CONDITIONAL GO** |
| AdaptiveBackend I/O | Hybrid comptime+runtime approach | 2-4 hours | **GO** |

---

## 2. Objectives

### Must-Have Objectives

| Objective | Description | Measurement |
|-----------|-------------|-------------|
| Correctness | Features must not introduce bugs or race conditions | All stress tests pass |
| Tiger Style Compliance | Code must follow project standards (≤70 lines/function) | No style violations |
| Test Coverage | Features must have adequate test coverage | Unit + integration + stress tests |
| Documentation | Features must be documented for users | Updated docs/ files |

### Weighted Objectives for Prioritization

| Objective | Description | Weight |
|-----------|-------------|--------|
| Impact on Production Readiness | Does this feature enable production deployment? | 0.25 |
| Effort Required | How much time investment is needed? (inverted) | 0.20 |
| Risk Level | What's the risk of implementation issues? (inverted) | 0.20 |
| User Demand/Benefit | How much do users want/need this? | 0.15 |
| Dependencies Blocked | Does this unblock other work? | 0.10 |
| Project Goal Alignment | How well does this fit project vision? | 0.10 |
| **Total** | | **1.00** |

---

## 3. Alternatives

### Alternative A: Risk-First Sequencing
**Philosophy:** Complete all testing before adding new features

**Sequence:**
1. WorkStealingBackend stress tests (6-10h)
2. IoUringBatchBackend Tiger Style + stress tests (6-9h)
3. AdaptiveBackend I/O (2-4h)
4. WorkStealingBackend MT execution (4-8h)
5. Cluster coordination (3 days)

**Rationale:** Ensures correctness foundation before building more complexity.

### Alternative B: Quick-Wins First
**Philosophy:** Complete smallest efforts first for momentum

**Sequence:**
1. AdaptiveBackend I/O (2-4h)
2. IoUringBatchBackend Tiger Style refactor (2-3h)
3. IoUringBatchBackend stress tests (4-6h)
4. WorkStealingBackend stress tests (6-10h)
5. WorkStealingBackend MT execution (4-8h)
6. Cluster coordination (3 days)

**Rationale:** Delivers value quickly, builds confidence, maintains momentum.

### Alternative C: Value-Driven Sequencing
**Philosophy:** Maximum impact features first

**Sequence:**
1. WorkStealingBackend stress + MT execution (10-18h combined)
2. AdaptiveBackend I/O (2-4h)
3. Cluster coordination (3 days)
4. IoUringBatchBackend refactor + tests (6-9h)

**Rationale:** Multi-threaded execution has highest user impact.

### Alternative D: Foundation-First Sequencing
**Philosophy:** Enable dependent features first

**Sequence:**
1. WorkStealingBackend stress tests (6-10h) - foundation for MT
2. AdaptiveBackend I/O (2-4h) - enables adaptive switching
3. WorkStealingBackend MT execution (4-8h) - requires stress tests
4. IoUringBatchBackend refactor + tests (6-9h)
5. Cluster coordination (3 days)

**Rationale:** Respects dependencies, builds incrementally.

### Alternative E: Hybrid Balance
**Philosophy:** Balance quick wins, risk mitigation, and impact

**Sequence:**
1. AdaptiveBackend I/O (2-4h) - quick win
2. IoUringBatchBackend Tiger Style refactor (2-3h) - code quality
3. WorkStealingBackend stress tests (6-10h) - risk mitigation
4. WorkStealingBackend MT execution (4-8h) - high impact
5. IoUringBatchBackend stress tests (4-6h) - production readiness
6. Cluster coordination (3 days) - enables distribution

**Rationale:** Interleaves effort sizes, addresses risk early while maintaining momentum.

---

## 4. Consequences Analysis

### Alternative A: Risk-First

| Metric | Assessment |
|--------|------------|
| Total Timeline | Medium (~25-35h before new features) |
| Risk Profile | Low - validates correctness first |
| Intermediate Deliverables | Few - mostly test infrastructure |
| User Value Over Time | Delayed - no user-visible changes early |
| Developer Morale | Lower - test-heavy start |

**Uncertainty:** Stress tests may reveal issues requiring additional fixes.

### Alternative B: Quick-Wins First

| Metric | Assessment |
|--------|------------|
| Total Timeline | Same total, but value delivered earlier |
| Risk Profile | Medium - some features may need rework |
| Intermediate Deliverables | High - small features ship early |
| User Value Over Time | Good - incremental improvements |
| Developer Morale | Higher - visible progress |

**Uncertainty:** May need to revisit code if tests reveal issues.

### Alternative C: Value-Driven

| Metric | Assessment |
|--------|------------|
| Total Timeline | Longer initial wait for first deliverable |
| Risk Profile | High - big features without full testing |
| Intermediate Deliverables | Low early, high later |
| User Value Over Time | Delayed but significant |
| Developer Morale | Medium - big project first |

**Uncertainty:** MT execution without stress testing is risky.

### Alternative D: Foundation-First

| Metric | Assessment |
|--------|------------|
| Total Timeline | Respects dependencies, steady progress |
| Risk Profile | Low-Medium - proper ordering |
| Intermediate Deliverables | Medium - some early, some later |
| User Value Over Time | Steady progression |
| Developer Morale | Medium - logical progression |

**Uncertainty:** Rigid sequencing may miss parallelization opportunities.

### Alternative E: Hybrid Balance

| Metric | Assessment |
|--------|------------|
| Total Timeline | Optimized - quick wins + foundation building |
| Risk Profile | Low - stress tests before MT execution |
| Intermediate Deliverables | High - mix of quick and substantial |
| User Value Over Time | Excellent - continuous value delivery |
| Developer Morale | High - variety and visible progress |

**Uncertainty:** Interleaved work requires context switching.

---

## 5. Tradeoffs Analysis

### Speed vs Thoroughness

| Approach | Speed | Thoroughness | Best When |
|----------|-------|--------------|-----------|
| Skip stress tests | Fast | Low | Prototyping only |
| Stress tests first | Slow start | High | Production systems |
| Parallel testing | Balanced | High | Multiple developers |

**Recommendation:** Stress tests cannot be skipped for work-stealing (race conditions).

### Quick Wins vs Big Impact

| Feature | Effort | Impact | Value/Effort |
|---------|--------|--------|--------------|
| AdaptiveBackend I/O | 2-4h | Medium | **High** |
| IoUring Tiger Style | 2-3h | Low-Medium | **High** |
| WorkStealing stress | 6-10h | High (enables MT) | Medium |
| WorkStealing MT | 4-8h | High | Medium-High |
| IoUring stress | 4-6h | Medium | Medium |
| Cluster shim | 3 days | Medium-High | Low-Medium |

**Recommendation:** Do AdaptiveBackend and IoUring Tiger Style first (highest value/effort).

### Safety vs Features

| Risk Tolerance | Approach |
|---------------|----------|
| Low (production-critical) | Complete all testing before MT execution |
| Medium (staging OK) | Interleave testing and features |
| High (experimental OK) | Features first, test later |

**Recommendation:** StaticECS targets production - safety first.

### Individual vs Team Allocation

| Scenario | Recommended Approach |
|----------|---------------------|
| Single developer | Alternative E (Hybrid) - maintains variety |
| Two developers | Split: one on testing, one on quick wins |
| Team | Parallelize independent features |

---

## 6. Decision Matrix

### Scoring Criteria (1-5 scale, 5 = best)

| Criterion | Weight | Description |
|-----------|--------|-------------|
| Production Impact | 0.25 | Enables production use |
| Effort (inverted) | 0.20 | Lower effort = higher score |
| Risk (inverted) | 0.20 | Lower risk = higher score |
| User Demand | 0.15 | User-requested or needed |
| Unblocks Work | 0.10 | Enables other features |
| Goal Alignment | 0.10 | Fits project vision |

### Feature Scores

| Feature | Prod Impact | Effort | Risk | User Demand | Unblocks | Goals | **Weighted** |
|---------|-------------|--------|------|-------------|----------|-------|--------------|
| AdaptiveBackend I/O | 4 | 5 | 5 | 3 | 3 | 4 | **4.10** |
| IoUring Tiger Style | 3 | 5 | 5 | 2 | 3 | 5 | **3.75** |
| WorkStealing Stress | 5 | 3 | 3 | 4 | 5 | 4 | **4.00** |
| WorkStealing MT | 5 | 3 | 3 | 5 | 2 | 5 | **4.05** |
| IoUring Stress | 4 | 4 | 4 | 3 | 2 | 4 | **3.60** |
| Cluster Shim | 3 | 2 | 3 | 3 | 4 | 4 | **3.05** |
| GPU Executor | 2 | 1 | 1 | 2 | 1 | 3 | **1.60** |

**Score Calculation:**
`Weighted = (ProdImpact × 0.25) + (Effort × 0.20) + (Risk × 0.20) + (UserDemand × 0.15) + (Unblocks × 0.10) + (Goals × 0.10)`

### Priority Ranking by Score

1. **AdaptiveBackend I/O** - 4.10 (quick win, high value/effort)
2. **WorkStealing MT Execution** - 4.05 (high impact, but requires testing)
3. **WorkStealing Stress Tests** - 4.00 (blocks MT, critical for safety)
4. **IoUring Tiger Style** - 3.75 (code quality, quick)
5. **IoUring Stress Tests** - 3.60 (production readiness)
6. **Cluster Shim** - 3.05 (conditional, longer effort)
7. **GPU Executor** - 1.60 (NO-GO, fundamental blockers)

### Dependency-Adjusted Order

Since WorkStealing MT (rank 2) depends on Stress Tests (rank 3), adjust:

1. AdaptiveBackend I/O (independent)
2. IoUring Tiger Style (independent)
3. WorkStealing Stress Tests (required for #4)
4. WorkStealing MT Execution (depends on #3)
5. IoUring Stress Tests (independent)
6. Cluster Shim (conditional)

---

## 7. Final Recommendation

### Selected Alternative: **E - Hybrid Balance**

### Rationale

The hybrid approach best satisfies our objectives because:

1. **Quick wins first** (AdaptiveBackend, IoUring refactor) - delivers immediate value
2. **Risk mitigation** (stress tests before MT) - ensures correctness
3. **High impact delivery** (MT execution) - after proper validation
4. **Production readiness** (IoUring stress) - enables Linux optimization
5. **Future capability** (Cluster shim) - conditional on user demand

### Implementation Phases

#### Phase 1: Quick Wins & Foundation (4-7 hours)
**Goal:** Immediate improvements, set up for larger work

| Task | Effort | Success Criteria |
|------|--------|------------------|
| AdaptiveBackend I/O metrics | 2-4h | `pending_io` uses comptime+runtime estimation |
| IoUring Tiger Style refactor | 2-3h | All functions ≤70 lines, tests pass |

**Deliverables:**
- Better adaptive scheduling decisions
- Cleaner io_uring code
- Foundation for stress testing

#### Phase 2: Safety Validation (10-18 hours)
**Goal:** Verify correctness under contention

| Task | Effort | Success Criteria |
|------|--------|------------------|
| WorkStealing stress tests | 6-10h | MPMC, steal storm, determinism tests pass |
| WorkStealing MT execution | 4-8h | Parallel phase execution, linear speedup |

**Deliverables:**
- Production-safe work-stealing scheduler
- True parallel ECS execution
- Benchmark results vs blocking backend

#### Phase 3: Production Readiness (4-6 hours)
**Goal:** Complete io_uring for production

| Task | Effort | Success Criteria |
|------|--------|------------------|
| IoUring stress tests | 4-6h | Queue overflow, completion storm, fallback tests pass |

**Deliverables:**
- Production-ready io_uring batching on Linux
- Verified graceful degradation

#### Phase 4: Distribution (Conditional, ~3 days)
**Goal:** Enable multi-process coordination

| Task | Effort | Success Criteria |
|------|--------|------------------|
| Cluster coordination shim | 3 days | TCP transport, remote world registration |

**Prerequisites:**
- User demand for distributed ECS
- Phases 1-3 complete

**Deliverables:**
- Basic multi-process entity transfer
- Foundation for future cluster features

### Deferred Work

| Feature | Reason | Reconsider When |
|---------|--------|-----------------|
| GPU Executor | PCIe bottleneck, 3-6 month effort, <50k entities slower | Particle systems >50k entities, WebGPU maturity |
| Batch stealing | Lower priority than MT execution | After MT is stable |
| Adaptive spin | Lower priority than core features | After Phase 3 |
| Pre-registered io_uring buffers | Optimization, not essential | After stress tests pass |

### Total Effort Estimate

| Phase | Effort Range | Cumulative |
|-------|--------------|------------|
| Phase 1 | 4-7h | 4-7h |
| Phase 2 | 10-18h | 14-25h |
| Phase 3 | 4-6h | 18-31h |
| Phase 4 | ~24h (3 days) | 42-55h |

**Total (excluding GPU):** 42-55 hours
**Total (Phases 1-3 only):** 18-31 hours

### Success Metrics

| Metric | Target |
|--------|--------|
| Code coverage | >80% for modified backends |
| Stress test pass rate | 100% |
| Performance regression | 0% degradation from baseline |
| Tiger Style violations | 0 |
| Documentation coverage | 100% of public APIs |

---

## References

- [00-OVERVIEW.md](00-OVERVIEW.md) - Parent planning document
- [01-work-stealing-triz.md](01-work-stealing-triz.md) - WorkStealing analysis
- [02-io-uring-triz.md](02-io-uring-triz.md) - IoUring analysis
- [03-gpu-executor-triz.md](03-gpu-executor-triz.md) - GPU Executor analysis (NO-GO)
- [04-cluster-triz.md](04-cluster-triz.md) - Cluster coordination analysis
- [05-adaptive-backend-triz.md](05-adaptive-backend-triz.md) - Adaptive backend analysis
- [99-ROADMAP.md](99-ROADMAP.md) - Implementation roadmap