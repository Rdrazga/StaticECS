# Implementation Approach PrOACT Decision

**Status:** Complete
**Decision:** Implementation Approach Selection
**Scope:** How to implement experimental features (methodology, testing, review)
**Date:** 2024-11-29

## Summary

**Implementation Strategy per Feature:**

| Feature | Approach | Testing | Review Depth | Key Consideration |
|---------|----------|---------|--------------|-------------------|
| AdaptiveBackend I/O | TDD + Incremental | Unit tests | Medium | Core scheduler logic |
| IoUring Tiger Style | Pure Refactor | Existing tests | Light | No behavior change |
| WorkStealing Stress | Follow patterns | MT stress tests | Heavy | Concurrency critical |
| WorkStealing MT | Staged enable | Integration tests | Heavy | Thread safety |
| IoUring Stress | Platform-specific | Mock + real I/O | Medium | Linux CI required |
| Cluster Shim | Minimal viable | 2-process test | Medium | Transport abstraction |

**Key Decisions:**
- All features use incremental commits (no big-bang)
- Stress tests follow [`lock_free_queue_stress_test.zig`](../../../src/ecs/coordination/lock_free_queue_stress_test.zig) patterns
- Code review required before merge for all phases
- CI must pass on all platforms before merge

---

## 1. Problem Statement

### Decision Context

With the priority order established in [10-prioritization-proact.md](10-prioritization-proact.md), we now need to decide **HOW** to implement each feature effectively. This includes:

- Development methodology (TDD vs test-after, solo vs pair)
- Testing strategy (unit, integration, stress)
- Code review requirements
- Documentation needs
- CI/CD considerations

### Decision Scope

| Constraint | Description |
|------------|-------------|
| Tiger Style | All code must comply with Tiger_Style (≤70 lines/function, assertions) |
| Platform | Some features are Linux-only (io_uring) |
| Concurrency | Work-stealing requires rigorous thread-safety validation |
| Quality | Production-grade code with full test coverage |

### Key Stakeholders

| Stakeholder | Primary Concern |
|-------------|-----------------|
| Developers | Clear implementation guidance, reasonable workload |
| Maintainers | Code quality, maintainability, test coverage |
| Users | Working, stable features |
| CI System | Reproducible builds, fast feedback |

---

## 2. Objectives

### Must-Have Objectives

| Objective | Description | Measurement |
|-----------|-------------|-------------|
| Correctness | Code works as specified | All tests pass |
| Tiger Style | Functions ≤70 lines, exhaustive assertions | Linter/review |
| Test Coverage | Adequate tests for all paths | Unit + stress tests |
| Documentation | Users can understand usage | Updated docs/ |
| CI Green | All platforms pass | GitHub Actions |

### Weighted Objectives for Approach Selection

| Objective | Description | Weight |
|-----------|-------------|--------|
| Code Quality | Clean, maintainable, Tiger Style | 0.25 |
| Risk Mitigation | Early failure discovery | 0.25 |
| Knowledge Sharing | No single points of failure | 0.15 |
| Maintainability | Easy to modify later | 0.15 |
| Timeline Efficiency | Reasonable completion time | 0.20 |
| **Total** | | **1.00** |

---

## 3. Alternatives

### Alternative A: Test-Driven Development (TDD)

**Process:**
1. Write failing tests first
2. Implement minimal code to pass
3. Refactor for quality
4. Repeat

**Pros:** Ensures testability, catches issues early, documentation via tests
**Cons:** Slower initial progress, requires test infrastructure upfront
**Best For:** New functionality, complex logic

### Alternative B: Test-After Development

**Process:**
1. Implement feature
2. Write tests for implemented code
3. Fix issues found by tests

**Pros:** Faster initial coding, more flexibility during exploration
**Cons:** Risk of untestable code, tests may miss edge cases
**Best For:** Pure refactoring, exploratory work

### Alternative C: Pair Programming

**Process:**
1. Two developers work on same feature
2. Driver codes, navigator reviews in real-time
3. Switch roles periodically

**Pros:** Immediate review, knowledge sharing, fewer bugs
**Cons:** 2x developer time, requires schedule coordination
**Best For:** Critical concurrency code, complex algorithms

### Alternative D: Solo Development + Formal Review

**Process:**
1. Single developer implements
2. PR with detailed description
3. Formal code review before merge

**Pros:** Efficient use of time, documented review trail
**Cons:** Review delay, reviewer may miss context
**Best For:** Well-understood changes, refactoring

### Alternative E: Incremental Commits

**Process:**
1. Break feature into small, reviewable chunks
2. Each commit is self-contained and tested
3. Merge frequently (multiple PRs if needed)

**Pros:** Easy review, fast feedback, bisectable history
**Cons:** Requires upfront planning, overhead for small changes
**Best For:** All changes (recommended default)

---

## 4. Feature-Specific Approach Decisions

### 4.1 AdaptiveBackend I/O Metrics

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Methodology | TDD | New functionality needs test coverage |
| Testing | Unit tests for hybrid estimator | Core logic must be verified |
| Review | Medium depth | Changes core scheduler behavior |
| Commits | 3-4 incremental | 1: Test infrastructure, 2: Comptime estimator, 3: Runtime fallback, 4: Integration |

**Implementation Details:**

```
Commit 1: Add test harness for pending_io estimation
  - Create test cases for I/O intent detection
  - Mock I/O context for testing

Commit 2: Implement comptime estimation
  - Analyze schedule for I/O intent users
  - Provide compile-time I/O likelihood hints

Commit 3: Implement runtime fallback
  - Track actual I/O queue depth when available
  - Hybrid: prefer runtime, fall back to comptime

Commit 4: Integration and documentation
  - Update EXPERIMENTAL.md
  - Add example usage
```

**Testing Strategy:**

| Test Type | Description | Location |
|-----------|-------------|----------|
| Unit | Estimator logic correctness | `backends_test.zig` |
| Integration | End-to-end with mock I/O | `integration_test.zig` |
| Documentation | Updated usage example | `docs/EXPERIMENTAL.md` |

**Risk Mitigation:**
- Fail-fast: If hybrid approach is too complex, fall back to pure runtime
- Gate: MT execution blocked until I/O estimation is stable

---

### 4.2 IoUringBatchBackend Tiger Style Refactor

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Methodology | Test-After | Pure refactoring, existing tests validate |
| Testing | Existing test pass | No behavior change |
| Review | Light | Mechanical refactoring |
| Commits | 2-3 incremental | 1: Extract helpers, 2: Reduce function lengths, 3: Cleanup |

**Implementation Details:**

```
Commit 1: Extract I/O operation helpers
  - submitRead(), submitWrite(), submitAccept()
  - Keep original functions as thin wrappers

Commit 2: Reduce function lengths
  - Split functions exceeding 70 lines
  - Maintain existing behavior exactly

Commit 3: Add/update doc comments
  - Tiger Style documentation
  - Intent explanations
```

**Validation:**
```bash
# All existing tests must pass unchanged
zig build test --test-filter="io_uring"

# No functional changes - benchmark should be identical
zig build benchmark
```

**Risk Mitigation:**
- If any test fails, revert and investigate
- Diff should show only code movement, not logic changes

---

### 4.3 WorkStealingBackend Stress Tests

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Methodology | TDD | Tests ARE the deliverable |
| Testing | Heavy multi-threaded | Concurrency correctness |
| Review | Heavy | Critical for thread safety |
| Commits | 4-5 incremental | One per test category |

**Implementation Details - Follow [`lock_free_queue_stress_test.zig`](../../../src/ecs/coordination/lock_free_queue_stress_test.zig) patterns:**

```
Commit 1: Test infrastructure
  - StressConfig struct
  - TestState with atomic counters
  - Checksum verification helpers

Commit 2: MPMC deque stress test
  - Multiple pushers, multiple stealers
  - XOR checksum verification
  - No lost or duplicated tasks

Commit 3: Steal storm test
  - Many workers, few tasks
  - Verify no deadlock under contention
  - Track steal success/failure rates

Commit 4: Determinism test
  - Same input, same output across runs
  - Verify work-stealing doesn't corrupt state

Commit 5: Edge cases
  - Single task, many workers
  - Full queue boundary
  - Empty queue boundary
```

**Test Coverage Matrix:**

| Scenario | Producers | Consumers | Operations | Expected Outcome |
|----------|-----------|-----------|------------|------------------|
| MPMC High | 8 threads | 8 threads | 100k/thread | Checksum match |
| Steal Storm | 1 thread | 16 threads | 10k total | No deadlock |
| Single Task | 1 thread | 8 threads | 1 task | Task executes once |
| Boundary | 4 threads | 4 threads | Queue size | No overflow |

**Review Checklist:**
- [ ] All atomic operations use correct memory ordering
- [ ] No ABA problem possible
- [ ] Checksum verification is truly thread-safe
- [ ] Test duration is reasonable (<30s per test)
- [ ] Random seed is logged for reproducibility

---

### 4.4 WorkStealingBackend MT Execution

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Methodology | Staged enable | Gradual risk reduction |
| Testing | Integration tests | Real workload verification |
| Review | Heavy | Thread safety critical |
| Prerequisites | Stress tests pass | Proven correctness required |

**Implementation Details - Staged Approach:**

```
Stage 1: Single-phase parallelism
  - Enable thread spawning for ONE phase only
  - Verify phase completion before next phase starts
  - Collect timing metrics

Stage 2: Multi-phase with barriers
  - Enable all phases to run in parallel
  - Explicit barrier between phases
  - Verify no cross-phase data races

Stage 3: Performance validation
  - Benchmark vs blocking backend
  - Expect near-linear speedup for independent systems
  - Document actual speedup achieved

Stage 4: Documentation
  - Update execution-models.md
  - Add thread count tuning guidance
  - Document when NOT to use work-stealing
```

**Integration Test Requirements:**

| Test | Description | Success Criteria |
|------|-------------|------------------|
| Phase Isolation | Phases don't interleave | Barrier verification |
| System Order | Dependencies respected | DAG verification |
| Entity Safety | No concurrent mutation | Assertion pass |
| Speedup | Performance improvement | >2x on 4-core for parallel systems |

**Gate Requirements:**
- All stress tests from 4.3 must pass
- No segfaults or data races in 1000 iterations
- Memory usage stable (no leaks)

---

### 4.5 IoUringBatchBackend Stress Tests

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Methodology | Platform-specific | Linux CI required |
| Testing | Mock + real I/O | Comprehensive coverage |
| Review | Medium | I/O edge cases important |
| Platform | Linux-only in CI | io_uring requirement |

**Implementation Details:**

```
Commit 1: Mock I/O test infrastructure
  - Fake fd handling
  - Simulated completions
  - Queue overflow simulation

Commit 2: Queue overflow stress
  - Submit more than sq_entries
  - Verify graceful handling
  - No lost operations

Commit 3: Completion storm test
  - Many operations complete simultaneously
  - Verify ordered processing
  - No missed completions

Commit 4: Fallback verification
  - Force io_uring init failure
  - Verify blocking backend used
  - No functionality loss

Commit 5: Real I/O test (Linux CI only)
  - Actual file read/write
  - Socket accept/connect
  - End-to-end correctness
```

**CI Configuration:**

```yaml
# .github/workflows/io_uring_stress.yml
jobs:
  io_uring_stress:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Zig
        uses: goto-bus-stop/setup-zig@v2
      - name: Run io_uring stress tests
        run: zig build test --test-filter="io_uring_stress"
```

---

### 4.6 Cluster Coordination Shim

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Methodology | Minimal viable | Avoid over-engineering |
| Testing | 2-process integration | Prove basic transport |
| Review | Medium | New network code |
| Scope | TCP transport only | Simplest viable option |

**Implementation Details:**

```
Commit 1: Transport trait definition
  - send(peer_id, data) -> !void
  - recv(buffer) -> ?Message
  - getPeers() -> []PeerId

Commit 2: TCP transport implementation
  - Blocking TCP socket wrapper
  - Simple framing (length prefix)
  - Connection management

Commit 3: Coordinator network integration
  - Use Transport trait in Coordinator
  - Replace stub join/leave with real calls
  - Heartbeat over network

Commit 4: 2-process test
  - Spawn child process
  - Register worlds across processes
  - Entity transfer test

Commit 5: Documentation
  - Update cluster.zig header
  - Add network configuration guide
  - Document limitations
```

**Minimal Viable Transport:**

```zig
pub const Transport = struct {
    const Self = @This();

    /// Send message to peer (blocking)
    pub fn send(self: *Self, peer_id: u16, data: []const u8) !void {
        // Length-prefixed TCP send
    }

    /// Receive next message (blocking with timeout)
    pub fn recv(self: *Self, buffer: []u8, timeout_ms: u32) ?Message {
        // Poll + read
    }
};
```

**Integration Test:**

```zig
test "2-process entity transfer" {
    // Process A: Create entity, transfer to B
    // Process B: Receive entity, verify components
    // Both: Clean shutdown
}
```

---

## 5. Consequences Analysis

### Skip Formal Review Consequences

| Scenario | Consequence | Severity | Mitigation |
|----------|-------------|----------|------------|
| Skip review on AdaptiveBackend | Subtle scheduler bugs | High | Always review scheduler changes |
| Skip review on IoUring refactor | Low risk (pure refactor) | Low | Tests catch regressions |
| Skip review on WorkStealing stress | Tests may have flaws | Medium | Peer review stress test design |
| Skip review on WorkStealing MT | Race conditions | Critical | MANDATORY heavy review |
| Skip review on IoUring stress | Platform-specific bugs | Medium | Linux CI catches issues |
| Skip review on Cluster shim | Protocol bugs | Medium | Integration test validation |

### Inadequate Testing Consequences

| Scenario | Consequence | Detection | Severity |
|----------|-------------|-----------|----------|
| No stress tests for work-stealing | Production race conditions | User reports | Critical |
| No mock I/O tests | Platform-specific failures | CI failures | High |
| No 2-process cluster test | Integration failure | User reports | Medium |

### Parallelization Consequences

| Scenario | Pro | Con | Recommendation |
|----------|-----|-----|----------------|
| Parallel Phase 1 work | Faster completion | Merge conflicts | OK - Independent files |
| Parallel stress test + MT | Risk | MT needs stress tests | NOT recommended |
| Parallel IoUring + Cluster | No dependency | Context switching | OK if different devs |

---

## 6. Tradeoffs Analysis

### Thoroughness vs Speed

| Approach | Thoroughness | Speed | When to Use |
|----------|--------------|-------|-------------|
| TDD + Heavy Review | Very High | Slow | Concurrency code |
| Test-After + Light Review | Medium | Fast | Pure refactoring |
| Stress Tests | Very High | Medium | Production backends |

**Recommendation:** Use TDD for new functionality, Test-After only for pure refactoring.

### Documentation Overhead vs Knowledge Transfer

| Level | Overhead | Knowledge Transfer | When to Use |
|-------|----------|-------------------|-------------|
| Inline comments only | Low | Low | Self-explanatory code |
| Doc comments + examples | Medium | Medium | Public APIs |
| Design docs + comments | High | High | Complex algorithms |

**Recommendation:**
- AdaptiveBackend: Medium (doc comments)
- WorkStealing: High (concurrency requires explanation)
- IoUring refactor: Low (no new concepts)
- Cluster shim: Medium (new transport layer)

### Serial vs Parallel Development

| Constraint | Recommendation |
|------------|----------------|
| Single developer | Execute in priority order |
| Two developers | Split: One on Phase 1-2, one on Phase 3 |
| Resource contention | Never parallel stress tests |

---

## 7. Process Recommendations

### Code Review Requirements

| Phase | Feature | Review Type | Reviewer Requirements |
|-------|---------|-------------|----------------------|
| 1 | AdaptiveBackend I/O | Medium | Scheduler knowledge |
| 1 | IoUring Tiger Style | Light | Any developer |
| 2 | WorkStealing Stress | Heavy | Concurrency expert |
| 2 | WorkStealing MT | Heavy | Concurrency expert |
| 3 | IoUring Stress | Medium | Linux/I/O knowledge |
| 4 | Cluster Shim | Medium | Network knowledge |

### Review Checklist Template

```markdown
## Review Checklist

### Tiger Style
- [ ] All functions ≤70 lines
- [ ] Exhaustive assertions (pre/post conditions)
- [ ] No dynamic allocation post-init (or approved exception)
- [ ] Explicit error handling

### Concurrency (if applicable)
- [ ] Correct memory ordering for atomics
- [ ] No data races possible
- [ ] Deadlock-free design
- [ ] ABA problem addressed

### Testing
- [ ] Unit tests for new functions
- [ ] Edge cases covered
- [ ] Error paths tested
- [ ] CI passes on all platforms

### Documentation
- [ ] Doc comments on public items
- [ ] EXPERIMENTAL.md updated if needed
- [ ] Examples provided if new API
```

### Documentation Requirements

| Feature | Required Documentation |
|---------|------------------------|
| AdaptiveBackend I/O | Update EXPERIMENTAL.md status |
| IoUring Tiger Style | None (refactor only) |
| WorkStealing Stress | Test design doc in tests/ |
| WorkStealing MT | Update execution-models.md |
| IoUring Stress | Test design doc |
| Cluster Shim | Update cluster.zig header, EXPERIMENTAL.md |

### CI/CD Recommendations

```yaml
# Required CI jobs per phase
Phase 1:
  - zig-test-all-platforms
  - zig-lint (function length check)

Phase 2:
  - zig-test-all-platforms
  - zig-stress-test-extended (10 minutes)
  - memory-sanitizer-check

Phase 3:
  - zig-test-linux-io-uring
  - zig-stress-test-io-uring

Phase 4:
  - zig-test-all-platforms
  - zig-integration-multiprocess
```

### Branch Strategy

| Phase | Branch Name | Merge Strategy |
|-------|-------------|----------------|
| 1 | `feature/adaptive-io-metrics` | Squash merge |
| 1 | `refactor/io-uring-tiger-style` | Squash merge |
| 2 | `feature/work-stealing-stress` | Squash merge |
| 2 | `feature/work-stealing-mt` | Merge commit (preserve history) |
| 3 | `feature/io-uring-stress` | Squash merge |
| 4 | `feature/cluster-tcp-shim` | Merge commit |

---

## 8. Risk Mitigation Strategies

### Risk Register

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Race condition in work-stealing | Medium | Critical | Stress tests, TSan in CI |
| io_uring not available on CI | Low | Medium | Docker with modern kernel |
| Cluster shim scope creep | Medium | High | Strict minimal viable scope |
| Tiger Style violations | Low | Low | Automated linting |
| Test flakiness | Medium | Medium | Determinstic seeds, retry logic |

### Fail-Fast Gates

| Gate | Check Before Proceeding |
|------|------------------------|
| G1 | Phase 1 complete before Phase 2 |
| G2 | Work-stealing stress tests pass (100 iterations) |
| G3 | Work-stealing MT tests pass on all platforms |
| G4 | io_uring stress tests pass on Linux CI |
| G5 | 2-process cluster test passes |

### Rollback Plan

| Failure Point | Rollback Action |
|---------------|-----------------|
| AdaptiveBackend breaks scheduler | Revert, fall back to blocking |
| WorkStealing MT unstable | Disable MT, keep stress tests |
| IoUring stress reveals bugs | Keep as Linux-only experimental |
| Cluster shim too complex | Mark as deferred, document learnings |

---

## 9. Dependencies Checklist

### Phase 1 Dependencies
- [x] Baseline scheduler tests pass
- [ ] Tiger Style linting automated
- [ ] EXPERIMENTAL.md structure confirmed

### Phase 2 Dependencies
- [ ] Phase 1 complete
- [ ] [`lock_free_queue_stress_test.zig`](../../../src/ecs/coordination/lock_free_queue_stress_test.zig) patterns documented
- [ ] TSan available in CI

### Phase 3 Dependencies
- [ ] Linux CI runner with kernel 5.1+
- [ ] Mock I/O infrastructure
- [ ] io_uring fallback logic verified

### Phase 4 Dependencies
- [ ] Phases 1-3 complete
- [ ] Transport trait design approved
- [ ] Multi-process test infrastructure

---

## 10. Implementation Checklist

### Pre-Implementation
- [ ] Read relevant TRIZ analysis document
- [ ] Review existing code in target files
- [ ] Identify Tiger Style violations to address
- [ ] Set up local test environment

### During Implementation
- [ ] Write tests before implementation (TDD features)
- [ ] Commit incrementally (1 concept per commit)
- [ ] Run full test suite before each commit
- [ ] Update documentation as you go

### Pre-Merge
- [ ] All tests pass locally
- [ ] CI passes on all platforms
- [ ] Code review approved
- [ ] Documentation updated
- [ ] EXPERIMENTAL.md status updated

### Post-Merge
- [ ] Verify CI still green on main
- [ ] Tag if milestone reached
- [ ] Communicate status to stakeholders

---

## References

- [00-OVERVIEW.md](00-OVERVIEW.md) - Feature overview
- [10-prioritization-proact.md](10-prioritization-proact.md) - Priority order decision
- [01-work-stealing-triz.md](01-work-stealing-triz.md) - Work-stealing analysis
- [02-io-uring-triz.md](02-io-uring-triz.md) - IoUring analysis
- [05-adaptive-backend-triz.md](05-adaptive-backend-triz.md) - Adaptive backend analysis
- [04-cluster-triz.md](04-cluster-triz.md) - Cluster coordination analysis
- [`lock_free_queue_stress_test.zig`](../../../src/ecs/coordination/lock_free_queue_stress_test.zig) - Stress test patterns