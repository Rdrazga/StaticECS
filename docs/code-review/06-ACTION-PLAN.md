# StaticECS Code Review - Action Plan

**Created:** 2025-11-27  
**Based On:** Code Review Phases 1-5  
**Total Estimated Effort:** ~120 hours (3-4 weeks full-time)

---

## Overview

This action plan organizes fixes from all code reviews into a prioritized, phased approach. Each phase builds on the previous, ensuring critical safety issues are addressed before feature improvements.

---

## Phase 1: Critical Memory & Data Safety (Week 1)

**Goal:** Fix all bugs that can cause memory corruption, data corruption, or crashes.  
**Effort:** 16-20 hours  
**Blocking:** All other phases

### 1.1 NUMA Allocator Memory Corruption (P1-NUMA)

**File:** [`src/ecs/scalability/numa_allocator.zig:123-133`](../src/ecs/scalability/numa_allocator.zig:123)  
**Effort:** 2 hours  
**Assigned:** TBD

**Problem:** `free()` calls `munmap()` on all buffers, but `alloc()` can fallback to the backing allocator. This corrupts the heap.

**Current Code:**
```zig
fn free(ctx: *anyopaque, buf: []u8, ...) void {
    if (comptime !cfg.enabled or builtin.os.tag != .linux) {
        self.backing_allocator.rawFree(buf, ...);  // Correct path
        return;
    }
    numaFree(buf.ptr, buf.len);  // BUG: May be backing allocator memory!
}
```

**Fix:**
```zig
const AllocationSource = enum { backing, numa_mmap };

// Option 1: Track per-allocation (precise but memory overhead)
// Add header or separate tracking structure

// Option 2: Size threshold (like huge_page_allocator) 
fn free(ctx: *anyopaque, buf: []u8, ...) void {
    if (comptime !cfg.enabled or builtin.os.tag != .linux) {
        self.backing_allocator.rawFree(buf, ...);
        return;
    }
    // Only NUMA allocations go through mmap, which requires page-aligned sizes
    const page_size = std.mem.page_size;
    if (buf.len >= page_size and std.mem.isAligned(@intFromPtr(buf.ptr), page_size)) {
        numaFree(buf.ptr, buf.len);
    } else {
        self.backing_allocator.rawFree(buf, ...);
    }
}
```

**Test to Add:**
```zig
test "NumaAllocator: small allocation uses backing allocator" {
    var numa = NumaAllocator.init(testing.allocator, .{});
    const small = try numa.alloc(64);  // Below page size
    defer numa.free(small);  // Should not crash
    try testing.expect(small.len == 64);
}
```

---

### 1.2 Entity Transfer Pack/Unpack Order Mismatch (P1-TRANSFER)

**File:** [`src/ecs/coordination/transfer.zig:139-188`](../src/ecs/coordination/transfer.zig:139)  
**Effort:** 4 hours  
**Assigned:** TBD

**Problem:** `packComponent()` appends at current offset (call order), but `unpackComponent()` calculates offset based on component index order.

**Current Bug Scenario:**
```zig
// Pack C then A (out of index order)
transfer.packComponent(C, c_value);  // Written at offset 0
transfer.packComponent(A, a_value);  // Written at offset sizeof(C)

// Unpack A - calculates offset as 0 (A has lower index)
transfer.unpackComponent(A);  // WRONG: Returns C's data!
```

**Fix Option A - Enforce Index-Order Packing:**
```zig
pub fn packComponent(self: *Self, comptime T: type, value: T) bool {
    const comp_idx = comptime getComponentIndex(T);
    if (comp_idx == null) return false;
    
    // Assert: must pack in index order
    if (self.last_packed_index) |last| {
        if (comp_idx.? <= last) {
            std.debug.assert(false);  // Out of order packing
            return false;
        }
    }
    self.last_packed_index = comp_idx;
    
    // ... existing pack logic
}
```

**Fix Option B - Use Fixed Offsets (Recommended):**
```zig
fn getComponentOffset(comptime T: type) usize {
    comptime var offset: usize = 0;
    inline for (cfg.components.types) |CompT| {
        if (CompT == T) return offset;
        offset += @sizeOf(CompT);
    }
    unreachable;
}

pub fn packComponent(self: *Self, comptime T: type, value: T) bool {
    const offset = comptime getComponentOffset(T);
    const size = @sizeOf(T);
    
    // Write at fixed offset
    @memcpy(self.data[offset..][0..size], std.mem.asBytes(&value));
    self.component_mask |= (@as(ComponentMask, 1) << @intCast(getComponentIndex(T).?));
    return true;
}

pub fn unpackComponent(self: *const Self, comptime T: type) ?T {
    const comp_idx = comptime getComponentIndex(T);
    if ((self.component_mask & (@as(ComponentMask, 1) << @intCast(comp_idx.?))) == 0) {
        return null;
    }
    
    const offset = comptime getComponentOffset(T);
    return std.mem.bytesToValue(T, self.data[offset..][0..@sizeOf(T)]);
}
```

**Tests to Add:**
```zig
test "Transfer: out-of-order pack/unpack" {
    var transfer = EntityTransfer.init(0, 1);
    
    // Pack C first, then A (out of index order if A < C)
    try testing.expect(transfer.packComponent(CompC, .{ .z = 99 }));
    try testing.expect(transfer.packComponent(CompA, .{ .x = 42 }));
    
    // Unpack should get correct values
    const a = transfer.unpackComponent(CompA).?;
    const c = transfer.unpackComponent(CompC).?;
    try testing.expectEqual(@as(i32, 42), a.x);
    try testing.expectEqual(@as(i32, 99), c.z);
}
```

---

### 1.3 Despawn Metadata Update Bug (P1-DESPAWN)

**File:** [`src/ecs/world.zig:253-264`](../src/ecs/world.zig:253)  
**Effort:** 2 hours  
**Assigned:** TBD

**Problem:** After swap-remove, finds the moved entity via O(n) linear search instead of using `moved_id.index` directly.

**Current Code:**
```zig
if (moved_entity) |moved_id| {
    for (&self.entities.metadata) |*m| {  // O(n) scan - WRONG
        if (m.alive and m.archetype_index == i) {
            const last_row = table.len();
            if (m.archetype_row == last_row) {
                m.archetype_row = meta.archetype_row;
                break;
            }
        }
    }
    _ = moved_id;  // moved_id ignored!
}
```

**Fix:**
```zig
if (moved_entity) |moved_id| {
    // Direct O(1) lookup using the moved entity's index
    const moved_index = moved_id.index;
    var moved_meta = &self.entities.metadata[moved_index];
    
    std.debug.assert(moved_meta.alive);
    std.debug.assert(moved_meta.archetype_index == i);
    
    // Update to point to the vacated row
    moved_meta.archetype_row = meta.archetype_row;
}
```

**Test to Add:**
```zig
test "World: despawn swap-remove metadata correctness" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();
    
    // Spawn 3 entities
    const e1 = try world.spawn("test", .{ .x = 1 });
    const e2 = try world.spawn("test", .{ .x = 2 });
    const e3 = try world.spawn("test", .{ .x = 3 });
    
    // Despawn middle entity - e3 should swap into e2's slot
    world.despawn(e2);
    
    // e3 should still be accessible with correct data
    const comp = world.getComponent(e3, TestComp).?;
    try testing.expectEqual(@as(i32, 3), comp.x);
    
    // e2 should be invalid
    try testing.expect(!world.isAlive(e2));
}
```

---

### 1.4 Thread-Unsafe Static Time Base (P1-TIME)

**Files:** 
- [`src/ecs/scheduler/scheduler_runtime.zig:524-536`](../src/ecs/scheduler/scheduler_runtime.zig:524)
- [`src/ecs/scheduler/backends/interface.zig:194-207`](../src/ecs/scheduler/backends/interface.zig:194)

**Effort:** 1 hour  
**Assigned:** TBD

**Problem:** Static mutable state without synchronization causes data race.

**Current Code:**
```zig
fn getTimeNs() u64 {
    const base = struct {
        var value: ?std.time.Instant = null;  // DATA RACE!
    };
    if (base.value == null) {
        base.value = instant;
    }
    return instant.since(base.value.?);
}
```

**Fix - Thread-Local Storage:**
```zig
fn getTimeNs() u64 {
    const instant = std.time.Instant.now() catch return 0;
    const base = struct {
        threadlocal var value: ?std.time.Instant = null;
    };
    if (base.value == null) {
        base.value = instant;
    }
    return instant.since(base.value.?);
}
```

**Alternative Fix - Atomic Initialization:**
```zig
fn getTimeNs() u64 {
    const instant = std.time.Instant.now() catch return 0;
    const base = struct {
        var initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var value: std.time.Instant = undefined;
    };
    
    if (!base.initialized.load(.acquire)) {
        // First call initializes (benign race - all threads get similar base)
        base.value = instant;
        base.initialized.store(true, .release);
    }
    return instant.since(base.value);
}
```

---

### 1.5 Non-Existent Field Access (P1-TRACE)

**File:** [`src/ecs/scheduler.zig:163`](../src/ecs/scheduler.zig:163)  
**Effort:** 30 minutes  
**Assigned:** TBD

**Problem:** `self.trace_sink` doesn't exist on Scheduler type.

**Current Code:**
```zig
return runFixedRateLoop(
    cfg, WorldType, self.world, rate_config,
    self.trace_sink,  // FIELD DOESN'T EXIST
    stop_flag,
);
```

**Fix Options:**

1. **Add field to Scheduler:**
```zig
pub fn Scheduler(comptime cfg: WorldConfig, comptime WorldType: type) type {
    return struct {
        world: *WorldType,
        backend: BackendType,
        trace_sink: ?TraceSink = null,  // Add field
        // ...
    };
}
```

2. **Access via backend (if stored there):**
```zig
return runFixedRateLoop(
    cfg, WorldType, self.world, rate_config,
    self.backend.trace_sink,
    stop_flag,
);
```

3. **Pass null if optional:**
```zig
return runFixedRateLoop(
    cfg, WorldType, self.world, rate_config,
    null,  // No tracing for fixed rate
    stop_flag,
);
```

---

### 1.6 Phase Iteration Type Mismatch (P1-PHASE)

**File:** [`src/ecs/scheduler/schedule_build.zig:347-356`](../src/ecs/scheduler/schedule_build.zig:347)  
**Effort:** 1 hour  
**Assigned:** TBD

**Problem:** Iterates `Sched.phases` ([]const PhaseDef) but calls `getStagesForPhase()` which expects Phase enum.

**Fix:**
```zig
// Option 1: Use phase indices
pub fn buildExecutionOrder(comptime Sched: type) [max_systems]SystemInfo {
    var order: [max_systems]SystemInfo = undefined;
    var idx: usize = 0;
    
    inline for (0..Sched.phase_count) |phase_idx| {
        const phase_stages = Sched.getStagesForPhaseIndex(phase_idx);
        for (phase_stages) |stage| {
            // ...
        }
    }
    return order;
}

// Option 2: Fix getStagesForPhase to accept PhaseDef
pub fn getStagesForPhase(phase_def: PhaseDef) []const Stage {
    // Implementation using phase_def
}
```

---

### Phase 1 Checklist

- [ ] P1-NUMA: Fix NUMA allocator free tracking
- [ ] P1-TRANSFER: Fix transfer pack/unpack ordering
- [ ] P1-DESPAWN: Fix despawn metadata O(1) update
- [ ] P1-TIME: Fix thread-unsafe getTimeNs
- [ ] P1-TRACE: Fix non-existent trace_sink field
- [ ] P1-PHASE: Fix phase iteration type mismatch
- [ ] Add regression tests for each fix
- [ ] Run full test suite
- [ ] Code review all changes

---

## Phase 2: Thread Safety & Major Validation (Week 2-3)

**Goal:** Fix thread safety issues and add missing validation.  
**Effort:** 24-30 hours  
**Depends On:** Phase 1 complete

### 2.1 Work-Stealing Race Condition (P1-RACE)

**File:** [`src/ecs/scheduler/backends/work_stealing.zig:618-664`](../src/ecs/scheduler/backends/work_stealing.zig:618)  
**Effort:** 2 hours

**Problem:** Shared `ctx` accessed without synchronization in worker loop.

**Fix:** Use atomic operations or proper synchronization for shared state.

---

### 2.2 IoUring Init Interface Mismatch (P1-IOURING)

**File:** [`src/ecs/scheduler/backends/io_uring_batch.zig:166`](../src/ecs/scheduler/backends/io_uring_batch.zig:166)  
**Effort:** 30 minutes

**Problem:** `init()` returns `!Self` while other backends return `Self`.

**Fix:** Align interface across all backends.

---

### 2.3 Backend Configuration Validation

**File:** [`src/ecs/config.zig:1116+`](../src/ecs/config.zig:1116)  
**Effort:** 2 hours

**Add Validations:**
```zig
// In validateWorldConfig:

// IoUring power-of-2 requirements
if (cfg.schedule.execution_model == .io_uring_batch) {
    if (cfg.schedule.backend_config == .io_uring_batch) {
        const io_cfg = cfg.schedule.backend_config.io_uring_batch;
        if (!std.math.isPowerOfTwo(io_cfg.sq_entries)) {
            @compileError("io_uring sq_entries must be power of 2");
        }
        if (!std.math.isPowerOfTwo(io_cfg.cq_entries)) {
            @compileError("io_uring cq_entries must be power of 2");
        }
    }
}

// Work-stealing local queue size
if (cfg.schedule.execution_model == .work_stealing) {
    if (cfg.schedule.backend_config == .work_stealing) {
        const ws_cfg = cfg.schedule.backend_config.work_stealing;
        if (!std.math.isPowerOfTwo(ws_cfg.local_queue_size)) {
            @compileError("work_stealing local_queue_size must be power of 2");
        }
    }
}

// Execution model / backend config mismatch
if (cfg.schedule.execution_model == .io_uring_batch and
    cfg.schedule.backend_config != .io_uring_batch and
    cfg.schedule.backend_config != .none) {
    @compileError("io_uring_batch execution model requires matching backend_config");
}
```

---

### 2.4 Optional Component Handling (P1-OPTIONAL)

**File:** [`src/ecs/world.zig:402-425`](../src/ecs/world.zig:402)  
**Effort:** 2 hours

**Problem:** `QueryIterator.buildResult()` ignores optional components.

**Fix:** Add handling for optional components like `ArchetypeQueryIterator` in query.zig.

---

### 2.5 Unsafe Optional Unwraps (P1-UNWRAP)

**File:** [`src/ecs/world/query.zig:241,246,252`](../src/ecs/world/query.zig:241)  
**Effort:** 1 hour

**Problem:** `.?` unwraps can panic on invalid state.

**Fix:** Replace with assertions or proper error handling:
```zig
// Before:
result.entity_id = self.table.getEntityId(self.current_row).?;

// After:
std.debug.assert(self.current_row < self.table.len());
result.entity_id = self.table.getEntityId(self.current_row) orelse unreachable;
```

---

### 2.6 Silent Error in commitImport (P1-COMMIT)

**File:** [`src/ecs/pipeline/external.zig:334-337`](../src/ecs/pipeline/external.zig:334)  
**Effort:** 1 hour

**Problem:** Silently swallows setComponent errors, creating incomplete entities.

**Fix:**
```zig
var failed_components: u32 = 0;
inline for (ComponentTypes, 0..) |T, i| {
    if ((record.mask & (@as(u64, 1) << i)) != 0) {
        self.world.setComponent(entity, value) catch {
            failed_components += 1;
        };
    }
}

if (failed_components > 0) {
    self.stats.partial_entities += 1;
    // Option: despawn partial entity or return error
    return error.PartialEntityCreation;
}
```

---

### 2.7 Implement processViaEcs (P1-HYBRID)

**File:** [`src/ecs/pipeline/hybrid.zig:323-334`](../src/ecs/pipeline/hybrid.zig:323)  
**Effort:** 4 hours

**Problem:** ECS fallback path is stub, doesn't actually create entities.

**Fix:** Implement full entity creation from InputData.

---

### 2.8 Add Upper Bound Validations

**File:** [`src/ecs/config.zig:825-867`](../src/ecs/config.zig:825)  
**Effort:** 1 hour

**Add Validations:**
```zig
// In validateWorldConfig:
if (cfg.options.max_commands_per_frame > 1_000_000) {
    @compileError("max_commands_per_frame exceeds safe limit (1M)");
}
if (cfg.options.max_component_data_size > 65536) {
    @compileError("max_component_data_size exceeds 64KB limit");
}
if (cfg.options.max_stages_per_phase > 256) {
    @compileError("max_stages_per_phase exceeds safe limit (256)");
}
```

---

### Phase 2 Checklist

- [ ] P1-RACE: Fix work-stealing race condition
- [ ] P1-IOURING: Fix init() interface mismatch
- [ ] Add backend config validation
- [ ] P1-OPTIONAL: Fix optional component handling
- [ ] P1-UNWRAP: Fix unsafe unwraps
- [ ] P1-COMMIT: Fix silent commitImport errors
- [ ] P1-HYBRID: Implement processViaEcs
- [ ] Add upper bound validations
- [ ] Code review all changes

---

## Phase 3: Test Coverage & Assertions (Week 4-6)

**Goal:** Achieve 60%+ test coverage, add Tiger_Style assertions.  
**Effort:** 40-50 hours  
**Depends On:** Phase 2 complete

### 3.1 Priority Tests for P1 Bugs

Add tests that would have caught original bugs:

| Bug | Test File | Test Name |
|-----|-----------|-----------|
| P1-NUMA | `numa_allocator_test.zig` | "small allocation uses backing allocator" |
| P1-TRANSFER | `transfer_test.zig` | "out of order pack/unpack roundtrip" |
| P1-DESPAWN | `world_test.zig` | "despawn swap-remove metadata correctness" |
| P1-TIME | `scheduler_test.zig` | "concurrent getTimeNs thread safety" |

---

### 3.2 New Test Files Required

| Module | Test File | Priority |
|--------|-----------|----------|
| Coordination | `coordination/lock_free_queue_test.zig` | P1 |
| Coordination | `coordination/transfer_test.zig` | P1 |
| Coordination | `coordination/coordinator_test.zig` | P2 |
| Pipeline | `pipeline/external_test.zig` | P2 |
| Pipeline | `pipeline/hybrid_test.zig` | P2 |
| Scalability | `scalability/numa_allocator_test.zig` | P1 |
| World | `world/query_test.zig` | P2 |

---

### 3.3 Assertion Pass

Add ≥2 assertions to these high-priority functions:

| File | Functions |
|------|-----------|
| `world.zig` | `getComponent`, `setComponent`, `hasComponent`, `addComponent` |
| `entity.zig` | `create`, `destroy` |
| `archetype_table.zig` | `addEntity`, `removeEntityByRow`, `getComponent` |
| `query.zig` | `matchesArchetype`, `next`, `getRead`, `getWrite` |
| `lock_free_queue.zig` | `push`, `pop` |
| `transfer.zig` | `packComponent`, `unpackComponent` |

**Assertion Pattern:**
```zig
pub fn someFunction(self: *Self, param: ParamType) ReturnType {
    // Preconditions
    std.debug.assert(param >= 0);
    std.debug.assert(self.state == .ready);
    
    // Implementation
    const result = ...;
    
    // Postconditions
    std.debug.assert(result != null or self.error_state);
    std.debug.assert(self.invariant_holds());
    
    return result;
}
```

---

### 3.4 Target Coverage

| Module | Current | Target | Gap |
|--------|---------|--------|-----|
| World | 70% | 90% | +20% |
| Scheduler | 35% | 70% | +35% |
| Coordination | 0% | 70% | +70% |
| Pipeline | 0% | 60% | +60% |
| Scalability | 0% | 50% | +50% |

---

### Phase 3 Checklist

- [ ] Create `lock_free_queue_test.zig` with MPMC stress tests
- [ ] Create `transfer_test.zig` with roundtrip tests
- [ ] Create `numa_allocator_test.zig`
- [ ] Add assertions to world.zig functions
- [ ] Add assertions to entity.zig functions
- [ ] Add assertions to query.zig functions
- [ ] Run coverage report
- [ ] Achieve 60% overall coverage

---

## Phase 4: Structural Refactoring (Week 5-7)

**Goal:** Split oversized files, improve maintainability.  
**Effort:** 20-24 hours  
**Can Start:** After Phase 1, parallel with Phase 2-3

### 4.1 Split config.zig (1735 → ~300 each)

**New Structure:**
```
src/ecs/config/
├── mod.zig                    # Public API, re-exports all (~50 lines)
├── core_types.zig             # Phase, TickMode, LayoutMode (~120 lines)
├── policy_types.zig           # RuntimePolicy, InvariantPolicy (~50 lines)
├── tracing_types.zig          # TracingSpec, TraceLevel (~40 lines)
├── definition_types.zig       # ArchetypeDef, SystemDef, asSystemFn (~150 lines)
├── backend_config.zig         # BackendConfig, IoUringBatchConfig (~100 lines)
├── pipeline_config.zig        # PipelineMode, PipelineConfig (~100 lines)
├── scalability_config.zig     # NumaConfig, HugePageConfig, ClusterConfig (~250 lines)
├── coordination_config.zig    # WorldCoordinationConfig, TransferQueueConfig (~100 lines)
├── world_config.zig           # Main WorldConfig struct (~200 lines)
├── validation.zig             # All validate* functions (~250 lines)
└── tests/                     # Test files
```

**Migration Steps:**
1. Create directory structure
2. Move types to appropriate files
3. Update imports in consuming files
4. Run tests after each file move
5. Update `src/ecs.zig` exports

---

### 4.2 Split system_context.zig (1045 → ~200 each)

**New Structure:**
```
src/ecs/
├── system_context.zig         # Main SystemContext (~200 lines)
├── command_buffer.zig         # CommandType, CommandBufferType (~150 lines)
├── concurrent_commands.zig    # ConcurrentCommandBuffers (~120 lines)
├── resources.zig              # Resources type (~100 lines)
└── io/
    └── io_context.zig         # IoContext type (~150 lines)
```

---

### Phase 4 Checklist

- [ ] Create config/ directory
- [ ] Move core_types.zig
- [ ] Move policy_types.zig
- [ ] Move remaining config types
- [ ] Create validation.zig
- [ ] Update all imports
- [ ] Split system_context.zig
- [ ] Move command types
- [ ] Move IoContext
- [ ] Run full test suite

---

## Phase 5: Documentation & Examples (Ongoing)

**Goal:** Fix documentation mismatches, improve examples.  
**Effort:** 10-16 hours  
**Can Start:** After Phase 2

### 5.1 Fix README-Code Mismatches

| Example | Issue | Fix |
|---------|-------|-----|
| data-pipeline | Query API shown but not used | Add working query example |
| game-loop | Movement system is stub | Implement actual movement |
| http-server | Command buffer not demonstrated | Add despawn command usage |

### 5.2 Fix Build Instructions

All READMEs need:
```bash
# Wrong:
zig run examples/game-loop/main.zig

# Correct:
zig build run-example-game
zig build run-example-pipeline  
zig build run-example-server
```

### 5.3 Add ctx.getResource() Convenience Method

```zig
// In system_context.zig
pub fn getResource(self: *Self, comptime T: type) ?*T {
    return self.world.resources.get(T);
}

pub fn getResourceConst(self: *const Self, comptime T: type) ?*const T {
    return self.world.resources.getConst(T);
}
```

### 5.4 Version Synchronization

Sync these files to same version:
- `README.md` line 58
- `build.zig.zon` line 3  
- `src/ecs/version.zig` lines 71-76

---

### Phase 5 Checklist

- [ ] Update data-pipeline example with query
- [ ] Update game-loop with working systems
- [ ] Update http-server with commands
- [ ] Fix all README build instructions
- [ ] Add getResource() to SystemContext
- [ ] Synchronize version numbers
- [ ] Review all docs for accuracy

---

## Summary Timeline

```
Week 1     Week 2     Week 3     Week 4     Week 5     Week 6     Week 7     Week 8
  │          │          │          │          │          │          │          │
  ├──────────┤          │          │          │          │          │          │
  │ Phase 1  │          │          │          │          │          │          │
  │ Critical │          │          │          │          │          │          │
  │ Memory   │          │          │          │          │          │          │
  │          │          │          │          │          │          │          │
  │          ├──────────┴──────────┤          │          │          │          │
  │          │     Phase 2         │          │          │          │          │
  │          │   Thread Safety     │          │          │          │          │
  │          │   Validation        │          │          │          │          │
  │          │          │          │          │          │          │          │
  │          │          │          ├──────────┴──────────┴──────────┤          │
  │          │          │          │         Phase 3                │          │
  │          │          │          │    Test Coverage               │          │
  │          │          │          │    Assertions                  │          │
  │          │          │          │          │          │          │          │
  │          │          ├──────────┴──────────┴──────────┴──────────┤          │
  │          │          │              Phase 4                      │          │
  │          │          │         File Refactoring                  │          │
  │          │          │                                           │          │
  │          │          │          │          │          │          ├──────────┤
  │          │          │          │          │          │          │ Phase 5  │
  │          │          │          │          │          │          │ Docs     │
  │          │          │          │          │          │          │          │
  ▼          ▼          ▼          ▼          ▼          ▼          ▼          ▼
Alpha      Beta       Beta       Beta      Beta        RC         RC        Release
Stable    (50%)     (60%)      (70%)    (80%)     (90%)       Candidate
```

---

## Issue Tracking Reference

### P1 Issues by Phase

| ID | Description | Phase | Status |
|----|-------------|-------|--------|
| P1-NUMA | NUMA allocator memory corruption | 1 | ⬜ Todo |
| P1-TRANSFER | Transfer pack/unpack order | 1 | ⬜ Todo |
| P1-DESPAWN | Despawn metadata bug | 1 | ⬜ Todo |
| P1-TIME | Thread-unsafe getTimeNs | 1 | ⬜ Todo |
| P1-TRACE | Non-existent trace_sink | 1 | ⬜ Todo |
| P1-PHASE | Phase iteration mismatch | 1 | ⬜ Todo |
| P1-RACE | Work-stealing race | 2 | ⬜ Todo |
| P1-IOURING | Init interface mismatch | 2 | ⬜ Todo |
| P1-OPTIONAL | Optional component handling | 2 | ⬜ Todo |
| P1-UNWRAP | Unsafe unwraps | 2 | ⬜ Todo |
| P1-COMMIT | Silent commitImport error | 2 | ⬜ Todo |
| P1-HYBRID | processViaEcs stub | 2 | ⬜ Todo |
| P1-CONFIG | config.zig 1735 lines | 4 | ⬜ Todo |
| P1-SYSCTX | system_context.zig 1045 lines | 4 | ⬜ Todo |

### Legend
- ⬜ Todo
- 🟡 In Progress  
- ✅ Complete
- ❌ Blocked

---

*Generated by Kilo Code Review System - 2025-11-27*