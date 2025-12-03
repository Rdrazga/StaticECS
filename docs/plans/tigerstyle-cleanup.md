# TigerStyle Compliance Cleanup Plan

**Status**: Complete
**Created**: 2024-12-02
**Estimated Total Effort**: 8-12 hours
**Priority**: Medium (code quality / maintainability)

---

## Overview

This plan addresses TigerStyle compliance issues identified during code review. The primary focus is on:
- Functions exceeding the 70-line limit
- Missing or insufficient assertions
- Control flow centralization opportunities

### TigerStyle Quick Reference

| Rule | Requirement |
|------|-------------|
| Function Length | ≤70 lines |
| Assertions | ≥2 per function (pre/post conditions) |
| Control Flow | Centralize in parent functions |
| Pure Functions | Keep as "leaves" (no side effects) |
| Error Handling | Explicit handling for all paths |

---

## Phase 1: Function Length Violations

### High Priority (Critical Path / Benchmark)

#### 1.1 [`benchmark.zig:main()`](../../src/ecs/benchmark.zig:386) ✓ COMPLETE
- [x] **File**: `src/ecs/benchmark.zig`
- [x] **Function**: `main()` (lines 386-627)
- [x] **Current Lines**: 241→48
- [x] **Target**: ≤70 lines

**Refactoring Plan**:
```
main() - orchestrator only (≤50 lines)
├── runEntityBenchmarks() - entity creation/destruction (~40 lines)
├── runComponentBenchmarks() - component add/remove (~40 lines)
├── runArchetypeBenchmarks() - archetype iteration (~40 lines)
├── runQueryBenchmarks() - query performance (~40 lines)
└── printResults() - formatted output (~30 lines)
```

**Implementation Steps**:
- [x] Extract entity benchmark loop into `runEntityBenchmarks()`
- [x] Extract component benchmark loop into `runComponentBenchmarks()`
- [x] Extract archetype benchmark loop into `runArchetypeBenchmarks()`
- [x] Extract query benchmarks into `runQueryBenchmarks()`
- [x] Extract results formatting into `printResults()`
- [x] Add assertions for benchmark configuration validity
- [x] Verify all benchmarks produce identical results

**Effort**: 1.5-2 hours ✓ COMPLETE

---

### Medium Priority (Core Functionality)

#### 2.1 [`external.zig:commitImport()`](../../src/ecs/pipeline/external.zig:388) ✓ COMPLETE
- [x] **File**: `src/ecs/pipeline/external.zig`
- [x] **Function**: `commitImport()` (lines 388-485)
- [x] **Current Lines**: 97→68
- [x] **Target**: ≤70 lines

**Refactoring Plan**:
```
commitImport() - control flow only (~55 lines)
├── createEntityWithComponents() - entity + component setup (~30 lines)
└── rollbackEntity() - cleanup on failure (~20 lines)
```

**Implementation Steps**:
- [x] Extract entity creation logic into `createEntityWithComponents()`
- [x] Extract rollback/cleanup into `rollbackEntity()`
- [x] Add pre-condition assertions for import state validity
- [x] Add post-condition assertions for entity integrity
- [x] Ensure atomic rollback behavior is preserved

**Effort**: 45-60 minutes ✓ COMPLETE

---

#### 2.2 [`entity.zig:destroy()`](../../src/ecs/world/entity.zig:402) ✓ COMPLETE
- [x] **File**: `src/ecs/world/entity.zig`
- [x] **Function**: `destroy()` (lines 402-491)
- [x] **Current Lines**: 89→41
- [x] **Target**: ≤70 lines

**Refactoring Plan**:
```
destroy() - main destruction logic (~50 lines)
├── handleGenerationPolicy() - generation increment logic (~25 lines)
└── cleanupEntitySlot() - slot recycling (~20 lines)
```

**Implementation Steps**:
- [x] Extract generation policy handling into `handleGenerationPolicy()`
- [x] Extract slot cleanup into `cleanupEntitySlot()`
- [x] Add assertion: entity must exist before destruction
- [x] Add assertion: generation must increment correctly
- [x] Verify entity recycling still works correctly

**Effort**: 45-60 minutes ✓ COMPLETE

---

#### 2.3 [`schedule_build.zig:buildStagesForPhaseByIndex()`](../../src/ecs/scheduler/schedule_build.zig:130) ✓ COMPLETE
- [x] **File**: `src/ecs/scheduler/schedule_build.zig`
- [x] **Function**: `buildStagesForPhaseByIndex()` (lines 130-214)
- [x] **Current Lines**: 85→63
- [x] **Target**: ≤70 lines

**Refactoring Plan**:
```
buildStagesForPhaseByIndex() - stage building coordinator (~45 lines)
├── findBestStage() - stage selection logic (~25 lines)
└── buildStageStructures() - structure creation (~20 lines)
```

**Implementation Steps**:
- [x] Extract stage selection into `findBestStage()`
- [x] Extract structure building into `buildStageStructures()`
- [x] Add assertion: phase index must be valid
- [x] Add assertion: output stages must be non-empty
- [x] Test with various system dependency configurations

**Effort**: 45-60 minutes ✓ COMPLETE

---

#### 2.4 [`work_stealing.zig:tick()`](../../src/ecs/scheduler/backends/work_stealing.zig:447) ✓ COMPLETE
- [x] **File**: `src/ecs/scheduler/backends/work_stealing.zig`
- [x] **Function**: `tick()` (lines 447-533)
- [x] **Current Lines**: 86→58
- [x] **Target**: ≤70 lines

**Refactoring Plan**:
```
tick() - tick orchestration (~50 lines)
└── iteratePhases() - phase iteration helper (~30 lines)
```

**Implementation Steps**:
- [x] Extract phase iteration into `iteratePhases()`
- [x] Add assertion: scheduler must be initialized
- [x] Add assertion: phase count must match configuration
- [x] Verify work stealing behavior remains correct

**Effort**: 30-45 minutes ✓ COMPLETE

---

#### 2.5 [`io_uring_batch.zig:submitBatch()`](../../src/ecs/scheduler/backends/io_uring_batch.zig:619) ✓ COMPLETE
- [x] **File**: `src/ecs/scheduler/backends/io_uring_batch.zig`
- [x] **Function**: `submitBatch()` (lines 619-701)
- [x] **Current Lines**: 82 (refactored in B.1.2)
- [x] **Target**: ≤70 lines

**Refactoring Plan**:
```
submitBatch() - batch submission coordinator (~40 lines)
├── submitReadOps() - read operation handling (~20 lines)
├── submitWriteOps() - write operation handling (~20 lines)
└── submitOtherOps() - misc operation handling (~15 lines)
```

**Implementation Steps**:
- [x] Extract read submissions into `submitReadOps()`
- [x] Extract write submissions into `submitWriteOps()`
- [x] Extract other operations into `submitOtherOps()`
- [x] Add assertion: batch size within ring buffer limits
- [x] Add assertion: all ops must have valid file descriptors

**Effort**: 45-60 minutes ✓ COMPLETE

---

#### 2.6 [`archetype_table.zig:addEntity()`](../../src/ecs/world/archetype_table.zig:266) ✓ COMPLETE
- [x] **File**: `src/ecs/world/archetype_table.zig`
- [x] **Function**: `addEntity()` (lines 266-343)
- [x] **Current Lines**: 77→31
- [x] **Target**: ≤70 lines

**Refactoring Plan**:
```
addEntity() - entity addition coordinator (~45 lines)
├── handleDynamicCapacity() - dynamic resize logic (~20 lines)
└── handleFixedCapacity() - fixed capacity logic (~15 lines)
```

**Implementation Steps**:
- [x] Extract dynamic capacity mode into `handleDynamicCapacity()`
- [x] Extract fixed capacity mode into `handleFixedCapacity()`
- [x] Add assertion: entity ID must be valid
- [x] Add assertion: capacity not exceeded in fixed mode

**Effort**: 30-45 minutes ✓ COMPLETE

---

#### 2.7 [`scheduler_runtime.zig:executeFrame()`](../../src/ecs/scheduler/scheduler_runtime.zig:618) ✓ COMPLETE
- [x] **File**: `src/ecs/scheduler/scheduler_runtime.zig`
- [x] **Function**: `executeFrame()` (line 618)
- [x] **Current Lines**: 85→36
- [x] **Target**: ≤70 lines

**Notes**: Well-structured but over limit. Consider extracting error handling or phase transitions.

**Implementation Steps**:
- [x] Review for logical extraction points
- [x] Extract error recovery logic if present
- [x] Add assertions for frame state validity
- [x] Minimal refactor to reach target

**Effort**: 30-45 minutes ✓ COMPLETE

---

### Low Priority (Minor Violations)

#### 3.1 [`world.zig:QueryIteratorBuilder`](../../src/ecs/world.zig:203) ✓ COMPLETE
- [x] **File**: `src/ecs/world.zig`
- [x] **Structure**: `QueryIteratorBuilder` (lines 203-287)
- [x] **Current Lines**: 84 (methods all ≤70)
- [x] **Target**: Consider extraction

**Notes**: This is a builder pattern - may be acceptable if complexity is inherent. Review for unnecessary duplication.

**Implementation Steps**:
- [x] Review for extraction opportunities
- [x] Consider splitting builder methods if applicable
- [x] Add assertions if missing

**Effort**: 15-30 minutes ✓ COMPLETE

---

#### 3.2 [`work_stealing.zig:runWorkerLoop()`](../../src/ecs/scheduler/backends/work_stealing.zig:645) ✓ COMPLETE
- [x] **File**: `src/ecs/scheduler/backends/work_stealing.zig`
- [x] **Function**: `runWorkerLoop()` (line 645)
- [x] **Current Lines**: 71→70
- [x] **Target**: ≤70 lines (1 line over)

**Notes**: Minimal violation. Single line extraction or comment consolidation.

**Implementation Steps**:
- [x] Review for single extraction or inline optimization
- [x] Consolidate comments if verbose
- [x] No major refactor needed

**Effort**: 15 minutes ✓ COMPLETE

---

#### 3.3 [`io_uring_batch.zig:tick()`](../../src/ecs/scheduler/backends/io_uring_batch.zig:406) ✓ COMPLETE
- [x] **File**: `src/ecs/scheduler/backends/io_uring_batch.zig`
- [x] **Function**: `tick()` (line 406)
- [x] **Current Lines**: 76 (refactored in B.1.2)
- [x] **Target**: ≤70 lines

**Notes**: Slightly over. Extract completion handling or similar.

**Implementation Steps**:
- [x] Extract completion processing if applicable
- [x] Review for minor extraction opportunity

**Effort**: 20-30 minutes ✓ COMPLETE

---

## Phase 2: Assertion Gaps

### 2.1 [`entity.zig:create()`](../../src/ecs/world/entity.zig:379) ✓ COMPLETE
- [x] **File**: `src/ecs/world/entity.zig`
- [x] **Function**: `create()` (lines 379-398)

**Required Assertions** (7 added):
- [x] Pre-condition: Entity pool not exhausted
- [x] Pre-condition: Generation overflow check
- [x] Post-condition: Returned entity ID is valid
- [x] Post-condition: Entity slot properly initialized
- [x] Invariant: Free list integrity maintained

**Effort**: 20-30 minutes ✓ COMPLETE

---

### 2.2 [`query.zig:next()`](../../src/ecs/world/query.zig:341) ✓ COMPLETE
- [x] **File**: `src/ecs/world/query.zig`
- [x] **Function**: `next()` (lines 341-376)

**Required Assertions** (10+ added):
- [x] Pre-condition: Iterator not exhausted
- [x] Pre-condition: Query state valid
- [x] Post-condition: Returned components match query filter
- [x] Post-condition: Entity returned is alive
- [x] Invariant: Iteration index properly advanced

**Effort**: 20-30 minutes ✓ COMPLETE

---

## Phase 3: Implementation Order

Prioritized by risk level (lower risk first), impact on other refactors, and estimated effort:

### Week 1: Low-Risk Refactors ✓ COMPLETE
| Order | File | Risk | Depends On | Effort | Status |
|-------|------|------|------------|--------|--------|
| 1 | `work_stealing.zig:runWorkerLoop()` | Very Low | None | 15 min | [x] |
| 2 | `io_uring_batch.zig:tick()` | Low | None | 20 min | [x] |
| 3 | `world.zig:QueryIteratorBuilder` | Low | None | 20 min | [x] |
| 4 | `archetype_table.zig:addEntity()` | Low | None | 35 min | [x] |

### Week 2: Medium-Risk Refactors ✓ COMPLETE
| Order | File | Risk | Depends On | Effort | Status |
|-------|------|------|------------|--------|--------|
| 5 | `entity.zig:destroy()` | Medium | None | 50 min | [x] |
| 6 | `entity.zig:create()` (assertions) | Medium | #5 | 25 min | [x] |
| 7 | `query.zig:next()` (assertions) | Medium | None | 25 min | [x] |
| 8 | `schedule_build.zig:buildStagesForPhaseByIndex()` | Medium | None | 50 min | [x] |

### Week 3: Higher-Risk Refactors ✓ COMPLETE
| Order | File | Risk | Depends On | Effort | Status |
|-------|------|------|------------|--------|--------|
| 9 | `work_stealing.zig:tick()` | Medium | #1 | 40 min | [x] |
| 10 | `io_uring_batch.zig:submitBatch()` | Medium | #3 | 50 min | [x] |
| 11 | `scheduler_runtime.zig:executeFrame()` | Medium | #9 | 40 min | [x] |
| 12 | `external.zig:commitImport()` | Medium-High | #5, #6 | 55 min | [x] |

### Week 4: Complex Refactors ✓ COMPLETE
| Order | File | Risk | Depends On | Effort | Status |
|-------|------|------|------------|--------|--------|
| 13 | `benchmark.zig:main()` | Low | All above | 2 hrs | [x] |

---

## Phase 4: Testing Requirements

### For Each Refactor

- [ ] **Pre-refactor**: Run full test suite, record baseline
  ```bash
  zig build test
  ```

- [ ] **Post-refactor**: All existing tests must pass
  ```bash
  zig build test
  ```

- [ ] **Behavior verification**: No functional changes
  - Compare benchmark outputs before/after
  - Verify error handling paths unchanged

### Recommended Additional Tests

| File | New Test Coverage |
|------|-------------------|
| `benchmark.zig` | Test each extracted function independently |
| `entity.zig` | Test generation policy edge cases |
| `external.zig` | Test rollback scenarios |
| `schedule_build.zig` | Test stage building with various dependencies |
| `work_stealing.zig` | Test phase iteration edge cases |

---

## Phase 5: Refactoring Guidelines

### Control Flow Pattern
```zig
// CORRECT: Control in parent, pure leaves
fn parentFunction(args: Args) !Result {
    // Pre-conditions
    std.debug.assert(args.isValid());
    
    // Control flow decisions HERE
    if (condition_a) {
        return pureHelper1(args.subset);
    } else {
        return pureHelper2(args.other);
    }
}

fn pureHelper1(data: Data) Result {
    // No side effects, no branching on external state
    // Post-condition assertions
    const result = compute(data);
    std.debug.assert(result.isValid());
    return result;
}
```

### Assertion Pattern
```zig
fn processEntity(entity: Entity, table: *Table) !void {
    // Pre-conditions (≥1)
    std.debug.assert(entity.isAlive());
    std.debug.assert(table.hasCapacity());
    
    // Implementation...
    const slot = try table.allocSlot();
    
    // Post-conditions (≥1)
    std.debug.assert(slot.entity == entity);
    std.debug.assert(table.count > 0);
}
```

### Error Handling Pattern
```zig
fn riskyOperation() !Value {
    const resource = acquireResource() catch |err| {
        // Explicit handling for THIS error
        logError(err);
        return err;
    };
    defer releaseResource(resource);
    
    // Never silently ignore errors
    return processResource(resource);
}
```

---

## Progress Tracking

### Summary Checklist

**Phase 1: Function Length (11 items)**
- [ ] 1.1 `benchmark.zig:main()` - HIGH
- [ ] 2.1 `external.zig:commitImport()` - MEDIUM
- [ ] 2.2 `entity.zig:destroy()` - MEDIUM
- [ ] 2.3 `schedule_build.zig:buildStagesForPhaseByIndex()` - MEDIUM
- [ ] 2.4 `work_stealing.zig:tick()` - MEDIUM
- [ ] 2.5 `io_uring_batch.zig:submitBatch()` - MEDIUM
- [ ] 2.6 `archetype_table.zig:addEntity()` - MEDIUM
- [ ] 2.7 `scheduler_runtime.zig:executeFrame()` - MEDIUM
- [ ] 3.1 `world.zig:QueryIteratorBuilder` - LOW
- [ ] 3.2 `work_stealing.zig:runWorkerLoop()` - LOW
- [ ] 3.3 `io_uring_batch.zig:tick()` - LOW

**Phase 2: Assertions (2 items)**
- [ ] 2.1 `entity.zig:create()` assertions
- [ ] 2.2 `query.zig:next()` assertions

**Testing Gates**
- [ ] Baseline test suite passing
- [ ] All refactors maintain test pass status
- [ ] Benchmark outputs unchanged
- [ ] No new warnings introduced

---

## Appendix: Effort Summary

| Category | Items | Min Hours | Max Hours |
|----------|-------|-----------|-----------|
| High Priority | 1 | 1.5 | 2.0 |
| Medium Priority | 7 | 4.5 | 6.5 |
| Low Priority | 3 | 0.75 | 1.25 |
| Assertions | 2 | 0.67 | 1.0 |
| Testing Overhead | - | 0.5 | 1.0 |
| **TOTAL** | **13** | **~8** | **~12** |

---

## Notes

- All refactors are **pure refactoring** - no behavior changes
- Run `zig build test` after each file modification
- Consider creating a branch per major refactor for easier rollback
- Update this document as items are completed