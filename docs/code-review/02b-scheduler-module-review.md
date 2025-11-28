# Scheduler Module Code Review (Phase 2b)

**Review Date:** 2025-11-27  
**Reviewer:** Code Review Agent  
**Module:** [`src/ecs/scheduler/`](src/ecs/scheduler/)  
**Scope:** System execution engine and parallelization backends

---

## 1. Module Overview

### 1.1 Architecture Summary

The Scheduler module is the system execution engine for the ECS framework, built in two layers:

1. **Schedule (comptime)**: Analyzes system dependencies and builds execution order
2. **Executor (runtime)**: Runs systems according to the built schedule

```
Scheduler (scheduler.zig)
    ├── Schedule (schedule_build.zig)
    │   ├── Conflict Analysis
    │   ├── Stage Building (greedy graph coloring)
    │   └── Phase Organization
    │
    ├── Runtime (scheduler_runtime.zig)
    │   ├── SystemExecutor
    │   ├── CommandExecutor
    │   ├── StageExecutor
    │   ├── PhaseExecutor
    │   └── FrameExecutor
    │
    └── Backends (backends/)
        ├── interface.zig      - Backend interface verification
        ├── select.zig         - Comptime backend selection
        ├── blocking.zig       - Single-threaded sequential
        ├── work_stealing.zig  - Multi-threaded with Chase-Lev deque
        ├── io_uring_batch.zig - Linux syscall batching
        └── adaptive.zig       - Runtime backend switching
```

### 1.2 Execution Flow

```
tick(delta_time)
    → Create SystemContext with CommandBuffer
    → For each Phase (config-driven order):
        → For each Stage (conflict-free systems):
            → Execute systems (backend-determined)
            → Process deferred commands
    → Return FrameResult
```

### 1.3 Backend Selection Matrix

| ExecutionModel | Backend | Characteristics |
|----------------|---------|-----------------|
| `blocking_single_thread` | BlockingBackend | Sequential, minimal overhead |
| `evented_single_thread` | BlockingBackend | Sequential with IoContext |
| `concurrent_threadpool` | BlockingBackend | Parallel stages (stub) |
| `io_uring_batch` | IoUringBatchBackend | Linux syscall batching |
| `work_stealing` | WorkStealingBackend | Chase-Lev per-worker queues |
| `adaptive_hybrid` | AdaptiveBackend | Runtime metric-driven switching |

---

## 2. Core Scheduler Analysis

### 2.1 [`scheduler.zig`](src/ecs/scheduler.zig:1) (368 lines)

**Purpose:** Main scheduler type generator and public API

**Strengths:**
- Clean comptime type generation via [`Scheduler(cfg)`](src/ecs/scheduler.zig:74)
- Config validation at comptime ([line 76-78](src/ecs/scheduler.zig:76))
- Proper re-exports of essential types ([lines 48-61](src/ecs/scheduler.zig:48))
- Good introspection API ([lines 193-225](src/ecs/scheduler.zig:193))
- Well-documented module header with usage examples

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 123-127 | [`tick()`](src/ecs/scheduler.zig:123) - No assertions on delta_time bounds | P3 |
| 132-141 | [`tickN()`](src/ecs/scheduler.zig:132) - No explicit bound on count parameter | P2 |
| 152-165 | [`runFixedRate()`](src/ecs/scheduler.zig:152) references `self.trace_sink` which doesn't exist | **P1** |

**Critical Bug - Line 163:**
```zig
return runFixedRateLoop(
    cfg,
    WorldType,
    self.world,
    rate_config,
    self.trace_sink,  // BUG: self.trace_sink doesn't exist, should access via backend
    stop_flag,
);
```

**Tiger_Style Compliance:** 75%
- Functions under 70 lines: ✓
- Static allocation: ✓
- Explicit bounds: Partially (count unbounded in tickN)
- Assertions per function: ✗ (most have 0-1)

---

### 2.2 [`schedule_build.zig`](src/ecs/scheduler/schedule_build.zig:1) (473 lines)

**Purpose:** Comptime schedule construction and conflict analysis

**Strengths:**
- Excellent comptime conflict detection via [`systemsConflict()`](src/ecs/scheduler/schedule_build.zig:23)
- Proper graph coloring for stage building ([lines 130-214](src/ecs/scheduler/schedule_build.zig:130))
- Config-driven bounds with [`StageType(max_systems)`](src/ecs/scheduler/schedule_build.zig:81)
- Clean separation between legacy and config-sized types

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 51 | [`buildConflictMatrix()`](src/ecs/scheduler/schedule_build.zig:50) - No assertion that systems.len <= max supported | P3 |
| 144-150 | Phase system counting loop has no explicit bound check | P3 |
| 167 | Stage search loop `stage_search` lacks explicit iteration bound | P2 |
| 342-358 | [`buildExecutionOrder()`](src/ecs/scheduler/schedule_build.zig:342) - Uses invalid `Sched.phases` iteration | **P1** |

**Critical Bug - Line 347-356:**
```zig
inline for (Sched.phases) |phase| {  // BUG: phases is phase_defs ([]const PhaseDef), not Phase enum
    const phase_stages = Sched.getStagesForPhase(phase);  // getStagesForPhase expects Phase enum
    // ...
}
```

**Tiger_Style Compliance:** 70%
- Functions under 70 lines: Mostly ✓ (buildStagesForPhaseByIndex is ~85 lines)
- Static allocation: ✓
- Config-driven bounds: ✓
- Assertions per function: ✗ (missing in many)

---

### 2.3 [`scheduler_runtime.zig`](src/ecs/scheduler/scheduler_runtime.zig:1) (619 lines)

**Purpose:** Runtime system execution logic

**Strengths:**
- Proper config-based type parameterization throughout
- Good error handling with [`AggregateErrorsType`](src/ecs/scheduler/scheduler_runtime.zig:24)
- IoContext creation based on execution model ([lines 496-522](src/ecs/scheduler/scheduler_runtime.zig:496))
- Clean separation of executors (System, Command, Stage, Phase, Frame)

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 104-137 | [`CommandExecutor.executeCommands()`](src/ecs/scheduler/scheduler_runtime.zig:104) - spawn/set_component handlers are stubs | P2 |
| 239-240 | Fixed-size error arrays use `stage.system_count` directly without bounds check | P3 |
| 253-260 | [`SystemTask.execute`](src/ecs/scheduler/scheduler_runtime.zig:253) callback is empty stub | P2 |
| 524-536 | [`getTimeNs()`](src/ecs/scheduler/scheduler_runtime.zig:524) - Static mutable state is not thread-safe | **P1** |

**Thread Safety Issue - Lines 529-535:**
```zig
fn getTimeNs() u64 {
    const base = struct {
        var value: ?std.time.Instant = null;  // Static mutable - NOT thread safe!
    };
    if (base.value == null) {
        base.value = instant;
    }
    return instant.since(base.value.?);
}
```
This is a **data race** when called from multiple threads concurrently.

**Tiger_Style Compliance:** 65%
- Functions under 70 lines: Mixed ([`executeStageParallel`](src/ecs/scheduler/scheduler_runtime.zig:216) ~90 lines)
- Static allocation: ✓
- Explicit bounds: Partially ✓
- Assertions: ✗ (minimal)

---

## 3. Backend Analysis

### 3.1 [`interface.zig`](src/ecs/scheduler/backends/interface.zig:1) (229 lines)

**Purpose:** Backend interface definition and verification

**Strengths:**
- Thorough comptime interface verification via [`verifyBackendInterface()`](src/ecs/scheduler/backends/interface.zig:75)
- Clear [`BackendStats`](src/ecs/scheduler/backends/interface.zig:38) struct for observability
- Good documentation with interface reference

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 76 | Uses non-generic [`FrameResult`](src/ecs/scheduler/backends/interface.zig:76) instead of config-sized type | P2 |
| 194-207 | Same static mutable thread-safety issue as scheduler_runtime.zig | **P1** |

**Tiger_Style Compliance:** 80%

---

### 3.2 [`select.zig`](src/ecs/scheduler/backends/select.zig:1) (181 lines)

**Purpose:** Comptime backend selection

**Strengths:**
- Clean comptime switch for backend selection ([lines 56-74](src/ecs/scheduler/backends/select.zig:56))
- Platform-aware fallback for io_uring ([line 64-67](src/ecs/scheduler/backends/select.zig:64))
- Good utility functions for backend introspection

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 59-61 | `evented_single_thread` and `concurrent_threadpool` both use BlockingBackend | P3 (design choice) |

**Tiger_Style Compliance:** 90%

---

### 3.3 [`blocking.zig`](src/ecs/scheduler/backends/blocking.zig:1) (490 lines)

**Purpose:** Default single-threaded sequential execution

**Strengths:**
- Complete implementation of backend interface
- Proper statistics tracking ([lines 177-182](src/ecs/scheduler/backends/blocking.zig:177))
- Clean executor hierarchy (System → Command → Stage → Phase)
- Good test coverage ([lines 407-490](src/ecs/scheduler/backends/blocking.zig:407))

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 104-198 | [`tick()`](src/ecs/scheduler/backends/blocking.zig:104) is ~95 lines (exceeds 70) | P3 |
| 305-323 | CommandExecutor silently ignores spawn/set_component | P2 |

**Tiger_Style Compliance:** 75%

---

### 3.4 [`work_stealing.zig`](src/ecs/scheduler/backends/work_stealing.zig:1) (841 lines)

**Purpose:** Multi-threaded work-stealing scheduler

**Strengths:**
- Correct Chase-Lev deque implementation ([lines 80-190](src/ecs/scheduler/backends/work_stealing.zig:80))
- Proper atomic operations with appropriate orderings
- LIFO slot optimization for cache locality ([line 575-577](src/ecs/scheduler/backends/work_stealing.zig:575))
- Random victim selection for stealing ([lines 666-694](src/ecs/scheduler/backends/work_stealing.zig:666))
- Good test coverage for deque operations

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 83-86 | Power-of-2 check could be done with intrinsic | P3 |
| 304 | [`GlobalQueue`](src/ecs/scheduler/backends/work_stealing.zig:303) uses mutex - potential contention point | P2 |
| 411 | Worker thread join sequence doesn't handle join failures | P3 |
| 574 | Round-robin distribution `total_tasks % self.num_workers` on u32 - potential overflow | P3 |
| 615-616 | Worker spins variable is u16 but spin_count is from config | P3 |
| 619-664 | Worker loop lack explicit termination condition beyond tasks_remaining | P2 |
| 673 | RNG seed is truncated `@intCast(worker.rng_state % num)` | P3 |
| 717-729 | [`applyCommands`](src/ecs/scheduler/backends/work_stealing.zig:715) missing custom command handling | P2 |

**Concurrency Issues:**

| Line | Issue | Severity |
|------|-------|----------|
| 594 | Single-threaded in current usage (`runWorkerLoop` only called from main) | P2 (limitation) |
| 618-664 | Shared [`ctx`](src/ecs/scheduler/backends/work_stealing.zig:611) accessed without synchronization if multi-threaded | **P1** |

**Tiger_Style Compliance:** 70%
- [`tick()`](src/ecs/scheduler/backends/work_stealing.zig:419) is ~85 lines
- Good atomic usage in ChaseLevDeque
- Missing assertions in many places

---

### 3.5 [`io_uring_batch.zig`](src/ecs/scheduler/backends/io_uring_batch.zig:1) (535 lines)

**Purpose:** Linux io_uring syscall batching

**Strengths:**
- Proper platform detection with compile-time fallback
- Clean PendingOp structure ([lines 117-163](src/ecs/scheduler/backends/io_uring_batch.zig:117))
- Correct io_uring initialization with config flags ([lines 177-191](src/ecs/scheduler/backends/io_uring_batch.zig:177))
- Graceful fallback via [`IoUringFallbackBackend`](src/ecs/scheduler/backends/io_uring_batch.zig:472)

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 166 | [`init()`](src/ecs/scheduler/backends/io_uring_batch.zig:166) returns `!Self` (error union) but other backends return `Self` | **P1** |
| 360-362 | "TODO: Check if system queued any I/O intents" - I/O batching not actually integrated | P2 |
| 383-387 | Submit on SQ full could loop indefinitely if queue stays full | P2 |
| 391-398 | Prep operations don't properly cast buffer types | P3 |
| 406 | Submit error silently ignored `catch {}` | P2 |
| 417 | `submit_and_wait(1)` error silently ignored | P2 |
| 429 | "TODO: Dispatch completion to appropriate handler" | P2 |

**Incomplete Implementation:**
The io_uring batch backend is structurally complete but **I/O batching is not integrated** with system execution. Systems cannot currently queue I/O operations for batch submission.

**Tiger_Style Compliance:** 65%

---

### 3.6 [`adaptive.zig`](src/ecs/scheduler/backends/adaptive.zig:1) (468 lines)

**Purpose:** Dynamic backend switching based on runtime metrics

**Strengths:**
- Well-designed metrics system with rolling averages ([lines 122-194](src/ecs/scheduler/backends/adaptive.zig:122))
- Cooldown mechanism to prevent oscillation ([line 268](src/ecs/scheduler/backends/adaptive.zig:268))
- Configurable thresholds via [`AdaptiveConfig`](src/ecs/scheduler/backends/adaptive.zig:51)
- Clean mode switching logic ([lines 335-372](src/ecs/scheduler/backends/adaptive.zig:335))

**Issues Found:**

| Line | Issue | Severity |
|------|-------|----------|
| 89 | Window size capped at 256 without explicit documentation | P3 |
| 176 | Division in rolling average could underflow if count is 0 (guarded but implicit) | P3 |
| 258 | `pending_io` always 0 - "TODO: Get from IoContext when available" | P2 |
| 259-260 | Systems executed subtraction could underflow on first tick | P3 |

**Design Note:** The adaptive backend currently only switches between blocking and work_stealing. io_uring is not included due to incomplete integration.

**Tiger_Style Compliance:** 75%

---

## 4. Critical Issues (P1) - Must Fix Immediately

### 4.1 Thread-Unsafe Static Mutable State

**Files:** [`scheduler_runtime.zig:524`](src/ecs/scheduler/scheduler_runtime.zig:524), [`interface.zig:194`](src/ecs/scheduler/backends/interface.zig:194)

**Problem:** `getTimeNs()` uses static mutable state that is not thread-safe:
```zig
const base = struct {
    var value: ?std.time.Instant = null;  // Data race!
};
```

**Fix:** Use `@atomicStore`/`@atomicLoad` or thread-local storage:
```zig
fn getTimeNs() u64 {
    const instant = std.time.Instant.now() catch return 0;
    // Thread-local or use atomic operations
    const base = struct {
        threadlocal var value: ?std.time.Instant = null;
    };
    // ...
}
```

---

### 4.2 Non-Existent Field Access in Scheduler.runFixedRate

**File:** [`scheduler.zig:163`](src/ecs/scheduler.zig:163)

**Problem:** `self.trace_sink` field doesn't exist on Scheduler:
```zig
return runFixedRateLoop(
    cfg, WorldType, self.world, rate_config,
    self.trace_sink,  // BUG: Scheduler has no trace_sink field
    stop_flag,
);
```

**Fix:** Access trace sink through backend:
```zig
return runFixedRateLoop(
    cfg, WorldType, self.world, rate_config,
    self.backend.trace_sink,  // Or add trace_sink field to Scheduler
    stop_flag,
);
```

---

### 4.3 Type Mismatch in buildExecutionOrder

**File:** [`schedule_build.zig:347`](src/ecs/scheduler/schedule_build.zig:347)

**Problem:** Iterates over `Sched.phases` ([]const PhaseDef) but calls `getStagesForPhase` which expects Phase enum:
```zig
inline for (Sched.phases) |phase| {
    const phase_stages = Sched.getStagesForPhase(phase);  // Type mismatch!
```

**Fix:** Use phase index iteration:
```zig
inline for (0..Sched.num_phases) |phase_idx| {
    const phase_stages = Sched.stages_by_phase[phase_idx].getStages();
```

---

### 4.4 Interface Mismatch - IoUringBatchBackend.init Returns Error Union

**File:** [`io_uring_batch.zig:166`](src/ecs/scheduler/backends/io_uring_batch.zig:166)

**Problem:** Other backends return `Self`, but IoUringBatchBackend returns `!Self`:
```zig
pub fn init(allocator: Allocator, trace_sink: ?TraceSink) !Self {  // !Self is inconsistent
```

**Impact:** SelectBackend cannot instantiate this backend uniformly.

**Fix:** Handle io_uring initialization errors internally and use fallback:
```zig
pub fn init(allocator: Allocator, trace_sink: ?TraceSink) Self {
    var self = Self{ ... };
    if (io_uring_available) {
        self.ring = std.os.linux.IoUring.init(...) catch {
            // Fall back to no-op mode
            return self;
        };
    }
    return self;
}
```

---

### 4.5 Shared Context Race in WorkStealingBackend

**File:** [`work_stealing.zig:618-664`](src/ecs/scheduler/backends/work_stealing.zig:618)

**Problem:** If worker threads were actually spawned, they would all share the same `ctx: *SysCtx` without synchronization:
```zig
fn runWorkerLoop(self: *Self, worker_id: u16, ctx: *SysCtx, ...) {
    // All workers would access ctx concurrently
    self.executeTask(t, ctx, ...);  // Races on ctx.commands, ctx.world access
}
```

**Note:** Currently only main thread runs the loop, but this is a latent bug.

**Fix:** Create per-worker contexts with isolated command buffers (already partially implemented in scheduler_runtime.zig's `executeStageParallel`).

---

## 5. Important Issues (P2) - Should Fix Soon

| ID | File:Line | Issue |
|----|-----------|-------|
| P2-1 | [`scheduler.zig:132`](src/ecs/scheduler.zig:132) | `tickN()` count parameter unbounded |
| P2-2 | [`scheduler_runtime.zig:104-137`](src/ecs/scheduler/scheduler_runtime.zig:104) | spawn/set_component command handlers are stubs |
| P2-3 | [`scheduler_runtime.zig:253-260`](src/ecs/scheduler/scheduler_runtime.zig:253) | SystemTask.execute callback is empty |
| P2-4 | [`schedule_build.zig:167`](src/ecs/scheduler/schedule_build.zig:167) | Stage search loop lacks explicit bound |
| P2-5 | [`interface.zig:76`](src/ecs/scheduler/backends/interface.zig:76) | Non-generic FrameResult type |
| P2-6 | [`work_stealing.zig:304`](src/ecs/scheduler/backends/work_stealing.zig:304) | GlobalQueue mutex contention |
| P2-7 | [`work_stealing.zig:619-664`](src/ecs/scheduler/backends/work_stealing.zig:619) | Worker loop termination condition weak |
| P2-8 | [`work_stealing.zig:594`](src/ecs/scheduler/backends/work_stealing.zig:594) | Work stealing is single-threaded |
| P2-9 | [`io_uring_batch.zig:360`](src/ecs/scheduler/backends/io_uring_batch.zig:360) | I/O batching not integrated |
| P2-10 | [`io_uring_batch.zig:383-387`](src/ecs/scheduler/backends/io_uring_batch.zig:383) | Submit loop could be infinite |
| P2-11 | [`io_uring_batch.zig:406,417`](src/ecs/scheduler/backends/io_uring_batch.zig:406) | Errors silently ignored |
| P2-12 | [`adaptive.zig:258`](src/ecs/scheduler/backends/adaptive.zig:258) | pending_io always 0 |

---

## 6. Minor Issues (P3) - Nice to Fix

| ID | File:Line | Issue |
|----|-----------|-------|
| P3-1 | [`scheduler.zig:123`](src/ecs/scheduler.zig:123) | No assertion on delta_time bounds |
| P3-2 | [`schedule_build.zig:51`](src/ecs/scheduler/schedule_build.zig:51) | No systems.len bound assertion |
| P3-3 | [`scheduler_runtime.zig:239-240`](src/ecs/scheduler/scheduler_runtime.zig:239) | Array size from system_count without validation |
| P3-4 | [`work_stealing.zig:83-86`](src/ecs/scheduler/backends/work_stealing.zig:83) | Power-of-2 check could use intrinsic |
| P3-5 | [`work_stealing.zig:411`](src/ecs/scheduler/backends/work_stealing.zig:411) | Thread join failures not handled |
| P3-6 | [`work_stealing.zig:574`](src/ecs/scheduler/backends/work_stealing.zig:574) | Potential u32 overflow in modulo |
| P3-7 | [`work_stealing.zig:673`](src/ecs/scheduler/backends/work_stealing.zig:673) | RNG state truncation |
| P3-8 | [`io_uring_batch.zig:391-398`](src/ecs/scheduler/backends/io_uring_batch.zig:391) | Buffer type casting issues |
| P3-9 | [`adaptive.zig:89`](src/ecs/scheduler/backends/adaptive.zig:89) | Undocumented window_size cap |
| P3-10 | [`adaptive.zig:259-260`](src/ecs/scheduler/backends/adaptive.zig:259) | Potential underflow on first tick |

---

## 7. Concurrency Assessment

### 7.1 Thread Safety Summary

| Component | Thread-Safe | Notes |
|-----------|-------------|-------|
| Schedule (comptime) | N/A | Comptime only |
| FrameExecutor | ✓ | Single-threaded by design |
| BlockingBackend | ✓ | Single-threaded |
| ChaseLevDeque | ✓ | Proper atomics |
| WorkStealingBackend | ⚠️ | Single-threaded currently, latent races |
| IoUringBatchBackend | ✓ | Single-threaded |
| AdaptiveBackend | ✓ | Delegates to sub-backends |
| getTimeNs() | ✗ | Static mutable without sync |

### 7.2 Lock Ordering

Currently no complex lock ordering because:
- BlockingBackend: No locks
- WorkStealingBackend: GlobalQueue.mutex only (single lock)
- IoUringBatchBackend: No locks beyond io_uring

**Risk:** If multi-threaded work stealing is enabled, command buffer access needs synchronization.

### 7.3 Atomic Operations Analysis

**ChaseLevDeque (work_stealing.zig)**:
- `bottom`: modified only by owner, uses `acquire`/`release`/`seq_cst` appropriately
- `top`: modified by stealers via `cmpxchgStrong` with `seq_cst`
- Proper fence usage between buffer writes and index updates

**Assessment:** Chase-Lev implementation is **correct**.

### 7.4 Deadlock Potential

**Low risk** due to:
- Single mutex in WorkStealingBackend (GlobalQueue)
- No nested locking
- Atomic operations preferred over mutexes

---

## 8. Tiger_Style Compliance Score

### Per-File Scores

| File | Functions ≤70 | Static Alloc | Explicit Bounds | Assertions (≥2/fn) | Score |
|------|---------------|--------------|-----------------|---------------------|-------|
| scheduler.zig | 90% | 100% | 80% | 30% | **75%** |
| schedule_build.zig | 70% | 100% | 70% | 30% | **70%** |
| scheduler_runtime.zig | 70% | 100% | 70% | 20% | **65%** |
| interface.zig | 100% | 100% | 90% | 30% | **80%** |
| select.zig | 100% | 100% | 100% | 40% | **90%** |
| blocking.zig | 80% | 100% | 80% | 30% | **75%** |
| work_stealing.zig | 70% | 100% | 70% | 30% | **70%** |
| io_uring_batch.zig | 80% | 100% | 70% | 20% | **65%** |
| adaptive.zig | 85% | 100% | 80% | 30% | **75%** |

### Overall Module Score: **72%**

### Key Compliance Gaps

1. **Assertions** - Most functions have 0-1 assertions, Tiger_Style requires ≥2
2. **Function length** - Several functions exceed 70 lines
3. **Explicit bounds** - Some iteration loops lack explicit max iterations
4. **Error handling** - Several `catch {}` patterns silently ignore errors

---

## 9. Specific Code Citations

### 9.1 Good Patterns to Preserve

1. **Comptime conflict analysis** - [`systemsConflict()`](src/ecs/scheduler/schedule_build.zig:23-46)
2. **Chase-Lev deque** - [`ChaseLevDeque`](src/ecs/scheduler/backends/work_stealing.zig:80-190)
3. **Backend interface verification** - [`verifyBackendInterface()`](src/ecs/scheduler/backends/interface.zig:75-135)
4. **Rolling metrics** - [`Metrics`](src/ecs/scheduler/backends/adaptive.zig:122-194)
5. **Platform-aware selection** - [`SelectBackend()`](src/ecs/scheduler/backends/select.zig:56-74)

### 9.2 Code Requiring Fixes

```zig
// scheduler.zig:163 - Field doesn't exist
self.trace_sink  // Should be self.backend.trace_sink or add field

// schedule_build.zig:347 - Type mismatch
inline for (Sched.phases) |phase| {  // phases is []PhaseDef, not Phase
    Sched.getStagesForPhase(phase);   // Expects Phase enum
}

// scheduler_runtime.zig:529-535 - Thread unsafe
const base = struct {
    var value: ?std.time.Instant = null;  // Static mutable - race condition
};

// io_uring_batch.zig:166 - Interface mismatch
pub fn init(...) !Self {  // Other backends return Self, not !Self
```

---

## 10. Recommendations

### Immediate Actions (P1)
1. Fix thread-unsafe `getTimeNs()` in both locations
2. Correct `runFixedRate()` field access
3. Fix `buildExecutionOrder()` type mismatch
4. Align IoUringBatchBackend.init signature with other backends

### Short-term (P2)
1. Implement spawn/set_component command handlers
2. Add iteration bounds to unbounded loops
3. Integrate I/O batching with system execution
4. Complete work-stealing multi-threading foundation
5. Add error propagation for silently-ignored errors

### Long-term
1. Add comprehensive assertions throughout module
2. Reduce function sizes to ≤70 lines
3. Create per-worker SystemContext for true parallelism
4. Implement io_uring integration with IoContext

---

## 11. Summary

The Scheduler module demonstrates **solid architectural design** with well-structured comptime/runtime separation and a clean backend abstraction. The conflict analysis and schedule building are particularly well-implemented.

**Critical concerns:**
- 5 P1 issues requiring immediate attention
- Thread safety problems in time utilities
- Several incomplete backend features (work stealing parallelism, io_uring integration)

**Strengths:**
- Clean comptime type generation
- Correct Chase-Lev deque implementation
- Good test coverage for data structures
- Proper config-driven parameterization

The module is **functional for single-threaded execution** but requires fixes before multi-threaded backends can be safely enabled.

---

*Review completed: 2025-11-27*