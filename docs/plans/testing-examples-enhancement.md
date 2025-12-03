# Testing and Examples Enhancement Plan

> **Status**: Planning  
> **Priority**: High  
> **Estimated Effort**: 22-38 hours (5-7 days)

## Executive Summary

The code review identified testing gaps and example deficiencies that affect onboarding and code quality. This plan addresses 10 issues across testing coverage, example improvements, and a missing feature (add/remove component commands). Completing this plan will significantly improve developer experience and codebase reliability.

---

## 1. Issues Summary

| ID | Issue | Priority | Category | Effort |
|----|-------|----------|----------|--------|
| H-5 | No Command Buffer Usage in Examples | High | Examples | 2-4h |
| H-6 | Missing Add/Remove Component Commands | High | Feature | 4-8h |
| H-7 | [`scheduler_runtime.zig`](src/ecs/scheduler/scheduler_runtime.zig:808) Only Has 1 Test | High | Testing | 4-8h |
| M-12 | No Async/Evented Backend Testing | Medium | Testing | 4-6h |
| M-13 | Config Submodules Lack Individual Tests | Medium | Testing | 4-8h |
| M-14 | Example Query Misuse in data-pipeline | Medium | Examples | 1-2h |
| M-15 | No Entity Despawning in Examples | Medium | Examples | 1-2h |
| L-12 | No Platform-Specific Tests | Low | Testing | 2-4h |
| L-13 | Unused Queries in Examples | Low | Examples | 1h |
| L-14 | HTTP Server I/O Context Unused | Low | Examples | 30m |

---

## 2. Example Improvements

### 2.1 Command Buffer Demonstration (H-5)

**Impact**: Users cannot learn the deferred command pattern, which is essential for safe entity manipulation during iteration.

**Current State**: All 3 examples use direct spawning only.

**Target Files**:
- [`examples/game-loop/main.zig`](examples/game-loop/main.zig)
- [`examples/http-server/main.zig`](examples/http-server/main.zig)
- [`examples/data-pipeline/main.zig`](examples/data-pipeline/main.zig)

**Implementation**:

```zig
// Pattern to demonstrate in each example:
fn systemWithDeferredOps(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    // 1. Acquire command buffer from context
    var cmds = ctx.commands();
    
    // 2. Queue deferred spawn (during iteration)
    var iter = ctx.world.query(SomeQuery);
    while (iter.next()) |result| {
        if (shouldSpawnChild(result)) {
            // Deferred - won't invalidate current iterator
            cmds.spawn("child", .{ ChildComponent{ .parent_id = result.entity } });
        }
        if (shouldDespawn(result)) {
            // Deferred despawn
            cmds.despawn(result.entity);
        }
    }
    
    // 3. Commands auto-flush at end of system, or manually:
    // cmds.flush();
}
```

**Per-Example Tasks**:

| Example | What to Add | Location |
|---------|-------------|----------|
| game-loop | Spawn projectile via command buffer when player attacks | Add new [`attackSystem()`](examples/game-loop/main.zig) |
| http-server | Despawn connection via command buffer on disconnect | Modify [`processSystem()`](examples/http-server/main.zig) |
| data-pipeline | Spawn error entity via command buffer on validation fail | Modify [`validationSystem()`](examples/data-pipeline/main.zig) |

**Checklist**:
- [ ] Add command buffer import to all examples
- [ ] Add [`attackSystem()`](examples/game-loop/main.zig) to game-loop with deferred spawn
- [ ] Add deferred despawn to http-server [`processSystem()`](examples/http-server/main.zig)
- [ ] Add error entity spawn to data-pipeline validation
- [ ] Add comments explaining command buffer lifecycle
- [ ] Verify all examples still compile and run

---

### 2.2 Entity Despawning Demo (M-15)

**Impact**: Users don't see complete entity lifecycle, limiting understanding of cleanup patterns.

**Target File**: [`examples/game-loop/main.zig`](examples/game-loop/main.zig)

**Current State**: The file defines [`MarkedForDeath`](examples/game-loop/main.zig:39) component but despawning logic is basic.

**Implementation**:

```zig
// Enhanced despawn system demonstrating full lifecycle
fn despawnSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const state = ctx.world.resources.get(GameState) orelse return;
    var cmds = ctx.commands();
    
    // Query entities marked for death
    var iter = ctx.world.query(DespawnQuery);
    while (iter.next()) |result| {
        const marker = result.getRead(MarkedForDeath);
        const pos = result.getRead(Position);
        
        // Log before despawn
        std.log.info("Despawning entity at ({d:.1}, {d:.1}): {s}", .{
            pos.x, pos.y, @tagName(marker.reason)
        });
        
        // Option A: Direct despawn (if not iterating)
        // ctx.world.despawnEntity(result.entity);
        
        // Option B: Deferred despawn (safe during iteration)
        cmds.despawn(result.entity);
        
        state.entities_despawned += 1;
    }
}

// Add death marking in update systems
fn healthSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    var iter = ctx.world.query(HealthQuery);
    
    while (iter.next()) |result| {
        var health = result.getWrite(Health);
        
        // Simulate damage
        if (health.current > 0) {
            health.current -= 1;
        }
        
        // Mark for death when health depleted
        if (health.current == 0) {
            // Add MarkedForDeath component
            ctx.world.setComponent(result.entity, MarkedForDeath{
                .reason = .health_depleted,
            });
        }
    }
}
```

**Checklist**:
- [ ] Add `DespawnQuery` for entities with `MarkedForDeath`
- [ ] Implement full [`despawnSystem()`](examples/game-loop/main.zig) with logging
- [ ] Show both direct and deferred despawn patterns
- [ ] Add health depletion logic that marks entities
- [ ] Add out-of-bounds check that marks entities
- [ ] Update game state tracking for despawned count

---

### 2.3 Fix Query Misuse (M-14)

**Target File**: [`examples/data-pipeline/main.zig:187`](examples/data-pipeline/main.zig:187)

**Current Issue**: [`transformSystem()`](examples/data-pipeline/main.zig:182) uses `IngestedRecordQuery` but should use a query specific to validated records.

**Analysis**:
```zig
// Current (line 187):
var iter = ctx.world.query(IngestedRecordQuery);

// Problem: IngestedRecordQuery is for ingestion phase
// transformSystem processes VALIDATED records
```

**Fix**:
```zig
// Add new query for transform phase
const ValidatedRecordQuery = Query(.{
    .read = &.{RawData},
    .write = &.{Record},
});

// Update transformSystem to use correct query
fn transformSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    var iter = ctx.world.query(ValidatedRecordQuery);  // Fixed
    // ...
}
```

**Checklist**:
- [ ] Add `ValidatedRecordQuery` type definition
- [ ] Replace `IngestedRecordQuery` with `ValidatedRecordQuery` in [`transformSystem()`](examples/data-pipeline/main.zig:182)
- [ ] Verify component access matches query spec
- [ ] Run example to confirm fix works

---

### 2.4 Fix Unused Queries (L-13)

**Impact**: Confusing for users; suggests queries that aren't needed.

**Audit Required**: Check all 3 examples for defined-but-unused queries.

**Investigation Steps**:
```bash
# Search for Query definitions
grep -n "Query\(\." examples/*/main.zig

# Search for query() usage
grep -n "\.query(" examples/*/main.zig
```

**Checklist**:
- [ ] Audit [`examples/game-loop/main.zig`](examples/game-loop/main.zig) for unused queries
- [ ] Audit [`examples/http-server/main.zig`](examples/http-server/main.zig) for unused queries
- [ ] Audit [`examples/data-pipeline/main.zig`](examples/data-pipeline/main.zig) for unused queries
- [ ] Remove or use each identified unused query
- [ ] Add comments explaining query purpose

---

### 2.5 Fix HTTP Server I/O Context (L-14)

**Target File**: [`examples/http-server/main.zig:126-129`](examples/http-server/main.zig:126)

**Current Issue**:
```zig
// Line 126-129: Checks I/O context but doesn't use result
if (ctx.hasIo()) {
    // In a real server, we would use io_uring/epoll here
    _ = ctx.hasAsync();  // Result discarded
}
```

**Options**:

**Option A**: Remove the check entirely (simpler)
```zig
fn acceptSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    // Remove I/O context check - not used in this example
    // ...
}
```

**Option B**: Enhance to demonstrate I/O context usage
```zig
fn acceptSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    // Demonstrate async I/O capability detection
    if (ctx.hasIo()) {
        if (ctx.hasAsync()) {
            std.log.debug("Async I/O available (io_uring/epoll)", .{});
        } else {
            std.log.debug("Blocking I/O fallback", .{});
        }
    }
    // ...
}
```

**Recommendation**: Option B - adds educational value.

**Checklist**:
- [ ] Decide on Option A or B
- [ ] Implement chosen fix
- [ ] Add comment explaining I/O context purpose

---

## 3. Unit Test Additions

### 3.1 Scheduler Runtime Tests (H-7)

**Target File**: [`src/ecs/scheduler/scheduler_runtime.zig`](src/ecs/scheduler/scheduler_runtime.zig)

**Current State**: Only 1 test at line 808: [`test "FrameExecutor basic structure"`](src/ecs/scheduler/scheduler_runtime.zig:808)

**Required Test Coverage**:

| Test Name | Purpose | Priority |
|-----------|---------|----------|
| `test "Phase execution ordering"` | Verify phases run in correct order | High |
| `test "System dependency resolution"` | Dependencies execute before dependents | High |
| `test "Frame timing accuracy"` | Frame time stays within bounds | High |
| `test "Tick result aggregation"` | Frame errors bubble up correctly | High |
| `test "Multi-phase transitions"` | Clean state between phases | Medium |
| `test "System skip on error"` | Error handling doesn't corrupt state | Medium |
| `test "Resource access during tick"` | Resources accessible in systems | Medium |
| `test "Empty phase handling"` | Phases with no systems don't crash | Low |

**Implementation Approach**:

```zig
test "Phase execution ordering" {
    const Position = struct { x: f32 };
    var execution_order: [3]u8 = undefined;
    var order_idx: usize = 0;
    
    const Systems = struct {
        fn initSystem(_: anytype) FrameError!void {
            execution_order[order_idx] = 0;
            order_idx += 1;
        }
        fn updateSystem(_: anytype) FrameError!void {
            execution_order[order_idx] = 1;
            order_idx += 1;
        }
        fn renderSystem(_: anytype) FrameError!void {
            execution_order[order_idx] = 2;
            order_idx += 1;
        }
    };
    
    const cfg = WorldConfig{
        .systems = .{
            .systems = &.{
                .{ .name = "init", .func = @ptrCast(&Systems.initSystem), .phase = 0 },
                .{ .name = "update", .func = @ptrCast(&Systems.updateSystem), .phase = 1 },
                .{ .name = "render", .func = @ptrCast(&Systems.renderSystem), .phase = 2 },
            },
            .phases = &.{
                .{ .name = "init", .index = 0 },
                .{ .name = "update", .index = 1 },
                .{ .name = "render", .index = 2 },
            },
        },
        // ...
    };
    
    var world = try World(cfg).init();
    defer world.deinit();
    
    _ = try world.tick();
    
    try std.testing.expectEqual([_]u8{0, 1, 2}, execution_order);
}

test "System dependency resolution" {
    var dep_ran_first = false;
    var main_ran = false;
    
    const Systems = struct {
        fn dependencySystem(_: anytype) FrameError!void {
            dep_ran_first = true;
        }
        fn mainSystem(_: anytype) FrameError!void {
            // Should only run after dependency
            try std.testing.expect(dep_ran_first);
            main_ran = true;
        }
    };
    
    const cfg = WorldConfig{
        .systems = .{
            .systems = &.{
                .{ .name = "main", .func = @ptrCast(&Systems.mainSystem), 
                   .dependencies = &.{"dependency"} },
                .{ .name = "dependency", .func = @ptrCast(&Systems.dependencySystem) },
            },
        },
    };
    
    var world = try World(cfg).init();
    defer world.deinit();
    
    _ = try world.tick();
    
    try std.testing.expect(main_ran);
}

test "Tick result aggregation" {
    const Systems = struct {
        fn failingSystem(_: anytype) FrameError!void {
            return FrameError.SystemError;
        }
    };
    
    const cfg = WorldConfig{
        .systems = .{
            .systems = &.{
                .{ .name = "failing", .func = @ptrCast(&Systems.failingSystem) },
            },
        },
    };
    
    var world = try World(cfg).init();
    defer world.deinit();
    
    const result = world.tick();
    try std.testing.expectError(FrameError.SystemError, result);
}
```

**Checklist**:
- [ ] Add test for phase execution ordering
- [ ] Add test for system dependency resolution
- [ ] Add test for frame timing accuracy
- [ ] Add test for tick result aggregation
- [ ] Add test for error propagation through systems
- [ ] Add test for multi-phase transitions
- [ ] Add test for empty phase handling
- [ ] Add test for resource access during tick

---

### 3.2 Config Submodule Tests (M-13)

**Target Directory**: [`src/ecs/config/`](src/ecs/config/)

**Current State**: 
- [`mod_test.zig`](src/ecs/config/mod_test.zig) has 536 lines of tests
- Individual config files have 0 embedded tests

**Files Needing Tests**:

| File | Current Tests | Gap |
|------|---------------|-----|
| [`backend_config.zig`](src/ecs/config/backend_config.zig) | 0 | Needs default/validation tests |
| [`coordination_config.zig`](src/ecs/config/coordination_config.zig) | 0 | Tested via mod_test |
| [`core_types.zig`](src/ecs/config/core_types.zig) | 0 | Needs type tests |
| [`definition_types.zig`](src/ecs/config/definition_types.zig) | 0 | Needs spec helpers |
| [`pipeline_config.zig`](src/ecs/config/pipeline_config.zig) | 0 | Tested via mod_test |
| [`policy_types.zig`](src/ecs/config/policy_types.zig) | 0 | Needs policy tests |
| [`scalability_config.zig`](src/ecs/config/scalability_config.zig) | 0 | Tested via mod_test |
| [`spec_types.zig`](src/ecs/config/spec_types.zig) | 0 | Needs spec validation |
| [`tracing_types.zig`](src/ecs/config/tracing_types.zig) | 0 | Needs tracing config tests |
| [`validation.zig`](src/ecs/config/validation.zig) | 0 | Needs validation tests |
| [`world_config.zig`](src/ecs/config/world_config.zig) | 0 | Tested via mod_test |
| [`world_config_view.zig`](src/ecs/config/world_config_view.zig) | 0 | Tested via mod_test |

**Strategy**: Expand [`mod_test.zig`](src/ecs/config/mod_test.zig) rather than adding inline tests (keeps tests centralized).

**Test Categories to Add**:

```zig
// 1. Backend Config Tests
test "BackendConfig defaults" {
    const backend = BackendConfig{};
    try std.testing.expectEqual(BackendType.auto, backend.backend_type);
    // ...
}

test "BackendConfig thread validation" {
    // Test that thread counts are validated
}

// 2. Policy Types Tests
test "ErrorPolicy combinations" {
    // Test different error handling modes
}

test "BatchingPolicy defaults" {
    // Test batching configuration
}

// 3. Validation Tests
test "validation rejects invalid component count" {
    const cfg = WorldConfig{
        .options = .{ .max_entities = 0 },  // Invalid
    };
    try std.testing.expectError(ValidationError.InvalidEntityCount, validate(cfg));
}

// 4. Tracing Types Tests
test "TracingConfig defaults" {
    const trace = TracingConfig{};
    try std.testing.expect(!trace.enabled);
    // ...
}
```

**Checklist**:
- [ ] Add backend config default tests
- [ ] Add backend config thread validation tests
- [ ] Add policy types tests
- [ ] Add validation error tests
- [ ] Add tracing config tests
- [ ] Add core types boundary tests
- [ ] Add spec types validation tests
- [ ] Verify test coverage >= 70% for config module

---

### 3.3 Async Backend Tests (M-12)

**Target File**: [`src/ecs/scheduler/backends/io_uring_batch.zig`](src/ecs/scheduler/backends/io_uring_batch.zig)

**Current State**: Tests at line 795+ cover only structural aspects:
- Platform detection
- PendingOp initialization
- PendingOp fromRequest

**Required Test Coverage**:

| Test Name | Purpose | Priority |
|-----------|---------|----------|
| `test "intent queue operations"` | Basic queue functionality | High |
| `test "intent queue stress"` | High-throughput queueing | High |
| `test "fallback behavior on non-Linux"` | Graceful degradation | Medium |
| `test "completion callback invocation"` | Callbacks fire correctly | Medium |
| `test "io_uring op submission"` | SQE submission (Linux only) | Low |

**Implementation Approach**:

```zig
test "intent queue operations" {
    const cfg = config_mod.WorldConfig{};
    const Backend = IoUringBatchBackend(cfg, DummyWorld);
    
    // Test queue initialization
    var queue = Backend.IntentQueue.init();
    try std.testing.expect(!queue.full());
    
    // Test push/pop
    const intent = Backend.IoIntent{
        .op_type = .read,
        .fd = 10,
        // ...
    };
    try queue.push(intent);
    
    const popped = queue.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(i32, 10), popped.?.fd);
}

test "intent queue stress" {
    const cfg = config_mod.WorldConfig{};
    const Backend = IoUringBatchBackend(cfg, DummyWorld);
    
    var queue = Backend.IntentQueue.init();
    
    // Fill queue
    const capacity = queue.capacity();
    for (0..capacity) |i| {
        try queue.push(.{
            .op_type = .write,
            .fd = @intCast(i),
            // ...
        });
    }
    try std.testing.expect(queue.full());
    
    // Verify order preserved
    for (0..capacity) |i| {
        const item = queue.pop();
        try std.testing.expectEqual(@as(i32, @intCast(i)), item.?.fd);
    }
    try std.testing.expect(queue.empty());
}

test "fallback behavior on non-Linux" {
    if (builtin.os.tag == .linux) return;  // Skip on Linux
    
    const cfg = config_mod.WorldConfig{};
    const Backend = IoUringBatchBackend(cfg, DummyWorld);
    
    // On non-Linux, should use blocking fallback
    try std.testing.expect(!Backend.io_uring_available);
    
    // Operations should still work via fallback
    var backend = try Backend.init();
    defer backend.deinit();
    
    // Should not crash, just use blocking I/O
    try std.testing.expect(backend.isOperational());
}
```

**Checklist**:
- [ ] Add intent queue operation tests
- [ ] Add intent queue stress tests
- [ ] Add fallback behavior tests for non-Linux
- [ ] Add completion callback tests
- [ ] Add conditional io_uring op tests (Linux only)
- [ ] Verify all tests pass on both Linux and non-Linux

---

### 3.4 Platform-Specific Tests (L-12)

**Target Modules**:
- [`src/ecs/scalability/numa_allocator.zig`](src/ecs/scalability/numa_allocator.zig)
- [`src/ecs/scalability/huge_page_allocator.zig`](src/ecs/scalability/huge_page_allocator.zig)
- [`src/ecs/scalability/affinity.zig`](src/ecs/scalability/affinity.zig)

**Challenge**: These require specific hardware/OS features that may not be available in CI.

**Strategy**: Three-tier testing approach

**Tier 1: Universal Tests (Always Run)**
```zig
test "NUMA allocator fallback on unsupported platform" {
    // Even without NUMA, should gracefully degrade
    var alloc = NumaAllocator.init(.{ .enabled = true });
    defer alloc.deinit();
    
    // Should work, using standard allocator as fallback
    const mem = try alloc.alloc(1024);
    defer alloc.free(mem);
    try std.testing.expect(mem.len == 1024);
}
```

**Tier 2: Conditional Tests (Skip on Unsupported)**
```zig
test "NUMA node binding" {
    if (!NumaAllocator.isSupported()) {
        return error.SkipZigTest;
    }
    
    // Actual NUMA tests here
}
```

**Tier 3: Manual Tests (Document Procedure)**
```markdown
## Manual Testing: NUMA Features

### Prerequisites
- Linux with numactl package
- Multi-socket machine OR VM with NUMA emulation

### Test Steps
1. Run `numactl --hardware` to verify NUMA availability
2. Execute `zig build test -- --test-filter="numa"` 
3. Verify allocation on correct node with `numastat -p <pid>`
```

**Checklist**:
- [ ] Add graceful fallback tests for NUMA
- [ ] Add graceful fallback tests for huge pages
- [ ] Add graceful fallback tests for affinity
- [ ] Add conditional skip for platform-specific tests
- [ ] Document manual testing procedure in docs/
- [ ] Add CI skip annotations where needed

---

## 4. Feature Implementation (H-6)

### 4.1 Add/Remove Component Commands

**Target Files**:
- [`src/ecs/context/command_types.zig`](src/ecs/context/command_types.zig)
- [`src/ecs/context/command_buffer.zig`](src/ecs/context/command_buffer.zig)

**Current Command Types** (from [`command_types.zig:24`](src/ecs/context/command_types.zig:24)):
```zig
pub fn CommandType(comptime max_data_size: u32) type {
    return union(enum) {
        spawn: SpawnCommandType(max_data_size),
        despawn: EntityHandle,
        set_component: SetComponentCommandType(max_data_size),
        custom: CustomCommand,
    };
}
```

**Missing Commands**:
- `add_component` - Add a new component to an existing entity
- `remove_component` - Remove a component from an entity

**Implementation**:

**Step 1: Add Command Variants**
```zig
// In command_types.zig
pub fn CommandType(comptime max_data_size: u32) type {
    return union(enum) {
        spawn: SpawnCommandType(max_data_size),
        despawn: EntityHandle,
        set_component: SetComponentCommandType(max_data_size),
        add_component: AddComponentCommandType(max_data_size),    // NEW
        remove_component: RemoveComponentCommand,                  // NEW
        custom: CustomCommand,
    };
}

/// Add component command - adds component to existing entity
pub fn AddComponentCommandType(comptime max_data_size: u32) type {
    return struct {
        entity: EntityHandle,
        component_id: u16,
        data: [max_data_size]u8 = .{0} ** max_data_size,
        data_size: usize = 0,
    };
}

/// Remove component command - removes component from entity
pub const RemoveComponentCommand = struct {
    entity: EntityHandle,
    component_id: u16,
};
```

**Step 2: Add Buffer Methods**
```zig
// In command_buffer.zig
pub fn addComponent(
    self: *Self,
    entity: EntityHandle,
    comptime T: type,
    value: T,
) !void {
    const component_id = self.registry.getId(T) orelse return error.UnknownComponent;
    
    var cmd: CommandType = .{
        .add_component = .{
            .entity = entity,
            .component_id = component_id,
        },
    };
    
    // Serialize component data
    const bytes = std.mem.asBytes(&value);
    if (bytes.len > max_data_size) return error.ComponentTooLarge;
    @memcpy(cmd.add_component.data[0..bytes.len], bytes);
    cmd.add_component.data_size = bytes.len;
    
    try self.queue.push(cmd);
}

pub fn removeComponent(
    self: *Self,
    entity: EntityHandle,
    comptime T: type,
) !void {
    const component_id = self.registry.getId(T) orelse return error.UnknownComponent;
    
    try self.queue.push(.{
        .remove_component = .{
            .entity = entity,
            .component_id = component_id,
        },
    });
}
```

**Step 3: Add Execution Handlers**
```zig
// In command_buffer.zig or execution module
fn executeCommand(world: *World, cmd: CommandType) !void {
    switch (cmd) {
        .spawn => |s| try executeSpawn(world, s),
        .despawn => |e| try executeDespawn(world, e),
        .set_component => |s| try executeSetComponent(world, s),
        .add_component => |a| try executeAddComponent(world, a),     // NEW
        .remove_component => |r| try executeRemoveComponent(world, r), // NEW
        .custom => |c| try executeCustomCommand(world, c),
    }
}

fn executeAddComponent(world: *World, cmd: AddComponentCommand) !void {
    // Get entity's current archetype
    // Find or create target archetype with additional component
    // Move entity to new archetype with data
}

fn executeRemoveComponent(world: *World, cmd: RemoveComponentCommand) !void {
    // Get entity's current archetype
    // Find or create target archetype without component
    // Move entity to new archetype (data preserved for other components)
}
```

**Step 4: Add Tests**
```zig
test "addComponent command" {
    var world = try TestWorld.init();
    defer world.deinit();
    
    const entity = try world.spawn("basic", .{ Position{ .x = 0, .y = 0 } });
    
    var cmds = world.commands();
    try cmds.addComponent(entity, Velocity, .{ .dx = 1, .dy = 2 });
    try cmds.flush();
    
    // Verify component was added
    try std.testing.expect(world.hasComponent(entity, Velocity));
    const vel = world.getComponent(entity, Velocity);
    try std.testing.expectEqual(@as(f32, 1), vel.dx);
}

test "removeComponent command" {
    var world = try TestWorld.init();
    defer world.deinit();
    
    const entity = try world.spawn("with_velocity", .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .dx = 1, .dy = 1 },
    });
    
    var cmds = world.commands();
    try cmds.removeComponent(entity, Velocity);
    try cmds.flush();
    
    // Verify component was removed
    try std.testing.expect(!world.hasComponent(entity, Velocity));
    // Position should remain
    try std.testing.expect(world.hasComponent(entity, Position));
}
```

**Checklist**:
- [ ] Add `AddComponentCommandType` to command_types.zig
- [ ] Add `RemoveComponentCommand` to command_types.zig
- [ ] Add `addComponent()` method to CommandBuffer
- [ ] Add `removeComponent()` method to CommandBuffer
- [ ] Implement `executeAddComponent()` handler
- [ ] Implement `executeRemoveComponent()` handler
- [ ] Add archetype migration logic for component changes
- [ ] Add tests for addComponent
- [ ] Add tests for removeComponent
- [ ] Add error handling tests (unknown component, entity not found)
- [ ] Update examples to demonstrate add/remove
- [ ] Update documentation

---

## 5. Implementation Order

### Phase 1: Quick Example Fixes (2-4 hours)

**Goal**: Fix low-hanging fruit, immediate quality improvement.

| Step | Task | Issue | Est. |
|------|------|-------|------|
| 1.1 | Fix query misuse in data-pipeline | M-14 | 1h |
| 1.2 | Audit and fix unused queries | L-13 | 1h |
| 1.3 | Fix HTTP server I/O context | L-14 | 30m |

**Success Criteria**:
- All examples compile without warnings
- No defined-but-unused queries
- I/O context either demonstrates value or is removed

---

### Phase 2: Example Enhancements (4-6 hours)

**Goal**: Demonstrate command buffer and entity lifecycle patterns.

| Step | Task | Issue | Est. |
|------|------|-------|------|
| 2.1 | Add command buffer to game-loop | H-5 | 2h |
| 2.2 | Add command buffer to http-server | H-5 | 1h |
| 2.3 | Add command buffer to data-pipeline | H-5 | 1h |
| 2.4 | Add comprehensive despawn demo | M-15 | 2h |

**Success Criteria**:
- Each example demonstrates deferred operations
- game-loop shows complete spawn→update→despawn lifecycle
- Comments explain command buffer benefits

---

### Phase 3: Core Testing (8-16 hours)

**Goal**: Fill critical testing gaps in scheduler and config.

| Step | Task | Issue | Est. |
|------|------|-------|------|
| 3.1 | Add scheduler_runtime phase tests | H-7 | 2h |
| 3.2 | Add scheduler_runtime dependency tests | H-7 | 2h |
| 3.3 | Add scheduler_runtime error tests | H-7 | 2h |
| 3.4 | Add config module boundary tests | M-13 | 3h |
| 3.5 | Add config validation tests | M-13 | 2h |
| 3.6 | Add async backend tests | M-12 | 4h |

**Success Criteria**:
- scheduler_runtime coverage >= 60%
- Config module coverage >= 70%
- All tests pass on Linux and Windows

---

### Phase 4: Feature + Advanced Testing (8-14 hours)

**Goal**: Implement missing feature and complete platform testing.

| Step | Task | Issue | Est. |
|------|------|-------|------|
| 4.1 | Design add/remove component API | H-6 | 1h |
| 4.2 | Implement command types | H-6 | 2h |
| 4.3 | Implement buffer methods | H-6 | 2h |
| 4.4 | Implement execution handlers | H-6 | 3h |
| 4.5 | Add unit tests | H-6 | 2h |
| 4.6 | Document platform-specific testing | L-12 | 2h |
| 4.7 | Add conditional platform tests | L-12 | 2h |

**Success Criteria**:
- `addComponent()` and `removeComponent()` fully functional
- command_buffer coverage >= 80%
- Platform testing documented and conditionally skipped in CI

---

## 6. Test Coverage Goals

| Module | Current Est. | Target | Notes |
|--------|--------------|--------|-------|
| [`scheduler_runtime.zig`](src/ecs/scheduler/scheduler_runtime.zig) | ~10% | 60% | Only 1 test currently |
| [`config/`](src/ecs/config/) overall | ~30% | 70% | mod_test.zig covers basics |
| [`io_uring_batch.zig`](src/ecs/scheduler/backends/io_uring_batch.zig) | ~40% | 70% | Structural tests only |
| [`command_buffer.zig`](src/ecs/context/command_buffer.zig) | ~50% | 80% | After H-6 implementation |

---

## 7. Timeline Summary

| Phase | Duration | Hours | Deliverables |
|-------|----------|-------|--------------|
| Phase 1 | ½ day | 2-4h | Fixed examples |
| Phase 2 | 1 day | 4-6h | Enhanced examples with command buffer |
| Phase 3 | 2-3 days | 8-16h | Scheduler + config tests |
| Phase 4 | 2-3 days | 8-14h | Add/remove commands + platform tests |
| **Total** | **5-7 days** | **22-38h** | All issues resolved |

---

## 8. Verification Checklist

### Examples
- [ ] All 3 examples compile with `zig build`
- [ ] All 3 examples run successfully
- [ ] Command buffer usage demonstrated in each
- [ ] Entity despawn lifecycle shown in game-loop
- [ ] No unused query definitions
- [ ] No dead code paths

### Testing
- [ ] `zig build test` passes with no failures
- [ ] scheduler_runtime has 6+ test functions
- [ ] Config module tests cover all submodules
- [ ] Async backend tests work on both Linux and non-Linux
- [ ] Platform tests skip gracefully when features unavailable

### Feature (H-6)
- [ ] `addComponent()` documented in API
- [ ] `removeComponent()` documented in API
- [ ] Examples updated to show usage
- [ ] Error cases tested (unknown component, invalid entity)

### Documentation
- [ ] README updated if API changed
- [ ] Platform testing procedure documented
- [ ] Examples README files updated

---

## 9. Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Add/remove component requires archetype migration | High | Design incrementally; may defer complex cases |
| Async tests flaky due to timing | Medium | Use deterministic mock I/O where possible |
| Platform tests cause CI failures | Medium | Use conditional skip; document manual testing |
| Example changes break existing users | Low | Maintain backward compatibility; additive only |

---

## 10. References

- [`src/ecs/context/command_types.zig`](src/ecs/context/command_types.zig) - Current command definitions
- [`src/ecs/context/command_buffer.zig`](src/ecs/context/command_buffer.zig) - Buffer implementation
- [`src/ecs/scheduler/scheduler_runtime.zig`](src/ecs/scheduler/scheduler_runtime.zig) - Scheduler with 1 test
- [`src/ecs/config/mod_test.zig`](src/ecs/config/mod_test.zig) - Existing config tests (536 lines)
- [`src/ecs/scheduler/backends/io_uring_batch.zig`](src/ecs/scheduler/backends/io_uring_batch.zig) - Async backend
- [`examples/game-loop/main.zig`](examples/game-loop/main.zig) - Primary example target
- [`docs/plans/benchmark-completion.md`](docs/plans/benchmark-completion.md) - Format reference