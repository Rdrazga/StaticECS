# Examples Code Review (Phase 5)

**Review Date**: 2025-01-27  
**Reviewer**: Code Review Agent  
**Files Reviewed**: 6 example files (3 examples × main.zig + README.md)

---

## 1. Examples Overview

The StaticECS library provides three example projects demonstrating different use cases:

| Example | Use Case | Key Features |
|---------|----------|--------------|
| [**Data Pipeline**](../../examples/data-pipeline/main.zig:1) | ETL/stream processing | Custom phases, record entities, statistics resources |
| [**Game Loop**](../../examples/game-loop/main.zig:1) | Game development | Default phases, player entities, frame timing |
| [**HTTP Server**](../../examples/http-server/main.zig:1) | Server applications | I/O context, connection entities, request/response |

### Common Patterns Demonstrated

All examples share a consistent structure:
1. Component definitions
2. Resource definitions
3. System functions (before config)
4. WorldConfig declaration
5. Type instantiation (World, Scheduler, Context)
6. Main loop with tick execution

---

## 2. Data Pipeline Example Analysis

**Files**: [`examples/data-pipeline/main.zig`](../../examples/data-pipeline/main.zig:1), [`examples/data-pipeline/README.md`](../../examples/data-pipeline/README.md:1)

### 2.1 Correctness

| Aspect | Status | Notes |
|--------|--------|-------|
| Compiles | ⚠️ Likely | Uses correct imports and config structure |
| API Usage | ✅ Correct | Proper WorldConfig, Scheduler.init(), scheduler.tick() |
| System Signatures | ✅ Correct | Uses `*anyopaque` → Context pattern |
| Resource Access | ✅ Correct | `world.resources.get()` and `getConst()` |

**Issues Found**:

1. **P2**: [`ingestSystem()`](../../examples/data-pipeline/main.zig:52) suppresses spawn errors silently:
   ```zig
   _ = ctx.world.spawn("record", .{ ... }) catch {};  // Line 59-62
   ```
   Should at minimum log or track failed spawns.

2. **P3**: [`outputSystem()`](../../examples/data-pipeline/main.zig:78) uses hard-coded calculation (`/2`) without explanation:
   ```zig
   stats.records_completed += stats.records_ingested / 2;  // Line 82
   ```

### 2.2 Completeness

| Feature | Demonstrated | Notes |
|---------|--------------|-------|
| Custom Phases | ✅ Yes | 5 phases: ingest → validate → transform → output → cleanup |
| Entity Spawn | ✅ Yes | Records spawned with components |
| Resources | ✅ Yes | PipelineStats resource |
| Scheduler Loop | ✅ Yes | 30 ticks at 0.016 delta |
| Query Iteration | ❌ No | **Major gap** - no queries shown |
| Archetype Transitions | ❌ No | README promises this but not demonstrated |
| Error Handling | ⚠️ Partial | Result matching present but minimal |

### 2.3 Tiger_Style Compliance

| Rule | Status | Location |
|------|--------|----------|
| Explicit Bounds | ✅ | `max_entities = 10000`, `max_commands_per_frame = 256` |
| Static Allocation | ✅ | Uses configured limits |
| Assertions | ❌ Missing | No assertions in system functions |
| Naming | ✅ Good | Snake_case, clear names |
| Fixed Loop Limits | ✅ | `for (0..5)` bounded loop |

**Score**: 6/10

### 2.4 Educational Quality

**Strengths**:
- Clear section separators with comments
- Logical code organization
- README explains architecture well

**Weaknesses**:
1. **P1**: README code snippets show API that doesn't exist:
   ```zig
   // README line 92-105 shows:
   var query = ctx.world.query(.{ .include = &.{Record, RawData} });
   while (query.next()) |result| { ... }
   ```
   But actual code has no query usage at all.

2. **P2**: README shows `ctx.getResource()` method that doesn't exist (line 119):
   ```zig
   const stats = ctx.getResource(PipelineStats) orelse return;
   ```
   Actual code uses `ctx.world.resources.get()`.

3. **P2**: Build instructions incorrect:
   ```bash
   # README says:
   zig run examples/data-pipeline/main.zig
   # Should be:
   zig build run-example-pipeline
   ```

### 2.5 README-Code Mismatch Summary

| README Feature | Code Reality |
|----------------|--------------|
| Query iteration with `result.get()/getConst()` | Not demonstrated |
| `ctx.getResource()` shorthand | Must use `ctx.world.resources.get()` |
| Archetype transitions via `addComponent()` | Not shown |
| `RecordTiming` component | Not in code |
| Enrich phase | Code has 5 phases, README shows 6 |

---

## 3. Game Loop Example Analysis

**Files**: [`examples/game-loop/main.zig`](../../examples/game-loop/main.zig:1), [`examples/game-loop/README.md`](../../examples/game-loop/README.md:1)

### 3.1 Correctness

| Aspect | Status | Notes |
|--------|--------|-------|
| Compiles | ✅ Yes | Clean structure |
| API Usage | ✅ Correct | Uses default Phase enum correctly |
| Entity Spawn | ✅ Correct | Player entity spawned properly |
| Phase References | ✅ Correct | `Phase.update.index()`, `Phase.render.index()` |

**Issues Found**:

1. **P3**: Most systems are empty stubs:
   ```zig
   fn movementSystem(ctx_ptr: *anyopaque) FrameError!void {
       _ = ctx_ptr;  // Line 49-51
       // In a real game: update Position based on Velocity
   }
   ```

2. **P3**: [`gameStateSystem()`](../../examples/game-loop/main.zig:64) only updates frame_count, doesn't check `running` flag.

### 3.2 Completeness

| Feature | Demonstrated | Notes |
|---------|--------------|-------|
| Default Phases | ✅ Yes | update, render, post_update |
| Entity Spawn | ✅ Yes | Player with Position, Velocity, Health |
| Multiple Archetypes | ✅ Yes | player, static, projectile |
| Resources | ✅ Yes | GameState |
| Query Iteration | ❌ No | README shows queries but code doesn't |
| Component Mutation | ❌ No | No actual movement logic |
| Command Buffer | ❌ No | Not demonstrated |

### 3.3 Tiger_Style Compliance

| Rule | Status | Notes |
|------|--------|-------|
| Explicit Bounds | ✅ | `max_entities = 1000` |
| Static Allocation | ✅ | Config-based |
| Assertions | ❌ | No assertions |
| Naming | ✅ | Clear, consistent |

**Score**: 5/10

### 3.4 Educational Quality

**Strengths**:
- Clear component definitions
- Good use of default phases
- README explains concepts well

**Weaknesses**:
1. **P1**: README shows full movement system implementation (lines 76-87) that code doesn't have
2. **P2**: README mentions features not in code: Lifetime system, collision, command buffer usage
3. **P2**: Build command incorrect (same as data-pipeline)

### 3.5 README-Code Mismatch Summary

| README Feature | Code Reality |
|----------------|--------------|
| Movement with delta_time | Empty stub |
| Query API `ctx.world.query()` | Not used |
| `result.get(Position)` pattern | Not demonstrated |
| Marker components (Player, Enemy) | Defined but not used in systems |
| Command buffer despawn | Not shown |

---

## 4. HTTP Server Example Analysis

**Files**: [`examples/http-server/main.zig`](../../examples/http-server/main.zig:1), [`examples/http-server/README.md`](../../examples/http-server/README.md:1)

### 4.1 Correctness

| Aspect | Status | Notes |
|--------|--------|-------|
| Compiles | ✅ Likely | Correct structure and imports |
| API Usage | ✅ Correct | Shows `needs_io` flag, IoContext checking |
| Execution Model | ✅ Correct | Sets `execution_model = .blocking_single_thread` |
| Phase Configuration | ✅ Correct | Custom 5-phase pipeline |

**Issues Found**:

1. **P3**: [`acceptSystem()`](../../examples/http-server/main.zig:55) IoContext check is misleading:
   ```zig
   if (ctx.hasIo()) {
       _ = ctx.hasAsync();  // Result ignored, line 60-62
   }
   ```
   Checks for I/O but doesn't actually use it.

2. **P3**: Uses saturating subtraction without comment:
   ```zig
   stats.connections_active -|= 1;  // Line 90
   ```
   Good pattern but should explain why.

### 4.2 Completeness

| Feature | Demonstrated | Notes |
|---------|--------------|-------|
| Custom Phases | ✅ Yes | accept → read → process → write → cleanup |
| I/O Integration | ⚠️ Partial | Shows flags but blocking mode |
| needs_io Flag | ✅ Yes | Correctly marked on I/O systems |
| Connection Entities | ✅ Yes | Demonstrates state machine pattern |
| Archetype Progression | ✅ Yes | connection → active_request → full_request |
| Query Iteration | ❌ No | Not demonstrated |

### 4.3 Tiger_Style Compliance

| Rule | Status | Notes |
|------|--------|-------|
| Explicit Bounds | ✅ | All limits configured |
| Static Allocation | ✅ | Config-based |
| Bounded Numeric Types | ⚠️ | Uses `i32` for fd (could be u32) |
| Naming | ✅ | Clear, consistent |

**Score**: 6/10

### 4.4 Educational Quality

**Strengths**:
- Best demonstration of I/O context pattern
- Shows realistic server architecture design
- README has good state machine diagram

**Weaknesses**:
1. **P1**: README shows query-based state filtering (lines 83-93) not in code
2. **P2**: README shows `ctx.commands.despawn()` usage not demonstrated
3. **P3**: Comment says "Would use .evented_single_thread when std.Io is ready" - good documentation

### 4.5 README-Code Mismatch Summary

| README Feature | Code Reality |
|----------------|--------------|
| State-based filtering with queries | Not implemented |
| Command buffer despawn | Not used |
| Timing component | Mentioned but not used |
| Event queues for logging | Not demonstrated |

---

## 5. Critical Issues (P1) - Must Fix

### 5.1 README API Inconsistencies

All three READMEs show query patterns that don't match the actual implementation:

**README Pattern** (not working):
```zig
var query = ctx.world.query(.{ .include = &.{Position, Velocity} });
while (query.next()) |result| {
    const pos = result.get(Position);
}
```

**Actual API** (from world.zig):
```zig
// Query API exists but isn't demonstrated in examples
// World has query() method but examples don't use it
```

**Recommendation**: Either:
1. Update examples to demonstrate actual query API, OR
2. Update READMEs to match the stub examples

### 5.2 Missing Core Feature Demonstrations

None of the examples demonstrate:
- **Query iteration** - The primary way to access entities
- **Component mutation** - Actually modifying entity data
- **Command buffer usage** - Deferred operations like despawn

These are fundamental ECS operations that users need to see working.

### 5.3 Build Instructions Incorrect

All READMEs say:
```bash
zig run examples/game-loop/main.zig
```

Should be:
```bash
zig build run-example-game  # or run-example-server, run-example-pipeline
```

Per [`build.zig`](../../build.zig:75):
```zig
const run_game_step = b.step("run-example-game", "Run the game loop example");
```

---

## 6. Important Issues (P2) - Should Fix

### 6.1 `ctx.getResource()` Shorthand Doesn't Exist

READMEs consistently show:
```zig
const stats = ctx.getResource(PipelineStats) orelse return;
```

But SystemContext doesn't have this method. Code uses:
```zig
const stats = ctx.world.resources.get(PipelineStats) orelse return;
```

**Recommendation**: Add convenience method to SystemContext:
```zig
pub fn getResource(self: *Self, comptime T: type) ?*T {
    return self.world.resources.get(T);
}
```

### 6.2 Archetype Transition Not Demonstrated

Data pipeline README (lines 88-105) promises archetype transitions but code doesn't show them. This is a key ECS pattern.

### 6.3 Systems Are Mostly Stubs

| Example | Total Systems | Implemented | Stubs |
|---------|--------------|-------------|-------|
| Data Pipeline | 5 | 2 (ingest, cleanup) | 3 |
| Game Loop | 4 | 1 (game_state) | 3 |
| HTTP Server | 5 | 3 (accept, write, cleanup) | 2 |

Examples should have fully working systems to be educational.

### 6.4 Timing Component Mismatch

README mentions `RecordTiming` and `Timing` components that aren't in the actual code.

---

## 7. Minor Issues (P3) - Nice to Fix

### 7.1 Error Suppression in Spawn

[`ingestSystem()`](../../examples/data-pipeline/main.zig:59) silently suppresses spawn errors:
```zig
_ = ctx.world.spawn("record", .{...}) catch {};
```

Better:
```zig
ctx.world.spawn("record", .{...}) catch |err| {
    stats.spawn_failures += 1;
    return;  // or continue if in loop
};
```

### 7.2 Magic Numbers

- Data pipeline: Division by 2 unexplained ([line 82](../../examples/data-pipeline/main.zig:82))
- Game loop: 60 frames / 60 FPS hard-coded ([line 134](../../examples/game-loop/main.zig:134))

### 7.3 Saturating Operations Uncommented

HTTP server uses `-|=` without explaining why ([line 90](../../examples/http-server/main.zig:90)).

### 7.4 Component Field Defaulting

Many components have all fields defaulted:
```zig
const Request = struct {
    method_len: u8 = 0,
    path_len: u8 = 0,
    // All default to 0
};
```

Consider requiring initialization for fields that should always be set.

---

## 8. Missing Example Recommendations

### 8.1 Minimal "Hello ECS" Example

Create a simple example that demonstrates:
- One component type
- One archetype
- One working system with query iteration
- Component mutation
- Command buffer despawn

```zig
// examples/minimal/main.zig - suggested
const std = @import("std");
const ecs = @import("ecs");

const Counter = struct { value: u32 = 0 };

fn countSystem(ctx_ptr: *anyopaque) !void {
    const ctx = getContext(ctx_ptr);
    // Demonstrate actual query iteration here
    var query = ctx.world.query(...);  // Show real syntax
    while (query.next()) |entity| {
        // Show component access
    }
}
```

### 8.2 Query Patterns Example

Demonstrate all query features:
- Include/exclude filters
- Optional components
- Read vs write access
- Entity despawn during iteration (via command buffer)

### 8.3 Multi-World Coordination Example

The coordination module exists but no example shows:
- Creating multiple worlds
- Entity transfer between worlds  
- Lock-free queue usage

### 8.4 Real Async I/O Example

HTTP server shows I/O flags but uses blocking mode. Example showing:
- `.evented_single_thread` execution model
- IoBackend usage
- Async scheduling

---

## 9. Tiger_Style Compliance Score

| Example | Safety | Performance | DX | Overall |
|---------|--------|-------------|-----|---------|
| Data Pipeline | 6/10 | 7/10 | 5/10 | **6/10** |
| Game Loop | 5/10 | 7/10 | 4/10 | **5/10** |
| HTTP Server | 6/10 | 7/10 | 6/10 | **6/10** |

### Scoring Breakdown

**Safety** (assertions, error handling, bounds):
- Missing assertions in all systems (-2)
- Error suppression in spawns (-1)
- Good use of config bounds (+2)

**Performance** (allocation, batching):
- Static allocation from config (+2)
- No unnecessary allocations (+2)
- No performance demonstrations (-1)

**DX** (naming, comments, structure):
- Good section organization (+2)
- Clear naming (+2)
- README/code mismatch (-3)
- Stub systems not educational (-2)

---

## 10. Summary of Required Changes

### Priority 1 (Before Release)
1. Fix build instructions in all READMEs
2. Either implement query iteration in examples OR update READMEs to remove fabricated code
3. Add at least one fully-working system per example that demonstrates component access

### Priority 2 (High Value)
4. Add `getResource()` convenience method to SystemContext
5. Replace stub systems with actual implementations
6. Demonstrate command buffer usage in at least one example
7. Fix `ctx.getResource()` references in READMEs

### Priority 3 (Polish)
8. Add minimal "Hello ECS" example
9. Add assertions to system functions
10. Document magic numbers and saturating operations
11. Create query patterns example

---

## 11. Files Changed Recommendation

| File | Priority | Changes Needed |
|------|----------|----------------|
| `examples/data-pipeline/README.md` | P1 | Fix build command, API examples |
| `examples/game-loop/README.md` | P1 | Fix build command, API examples |
| `examples/http-server/README.md` | P1 | Fix build command, API examples |
| `examples/data-pipeline/main.zig` | P2 | Add query iteration, real systems |
| `examples/game-loop/main.zig` | P2 | Add movement system, queries |
| `examples/http-server/main.zig` | P2 | Add state filtering, despawn |
| `src/ecs/system_context.zig` | P2 | Add `getResource()` helper |
| `examples/minimal/main.zig` | P3 | New file - simple example |

---

## Appendix: Verified API Patterns

Based on source code review, these are the **correct** API patterns:

### World Initialization
```zig
var world = World.init(allocator);
defer world.deinit();
```

### Entity Spawn
```zig
const handle = try world.spawn("archetype_name", .{
    Component1{ .field = value },
    Component2{ .field = value },
});
```

### Resource Access
```zig
// Mutable access
if (ctx.world.resources.get(MyResource)) |res| {
    res.field += 1;
}

// Const access
if (world.resources.getConst(MyResource)) |res| {
    std.debug.print("{}\n", .{res.field});
}
```

### Scheduler Usage
```zig
var scheduler = Scheduler.init(&world, trace_sink, allocator);
const result = scheduler.tick(delta_time);
switch (result) {
    .success => {},
    .single_error => |err| { /* handle */ },
    .aggregate_errors => |errs| { /* handle */ },
}
```

### System Function Pattern
```zig
fn mySystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx: *Context = @ptrCast(@alignCast(ctx_ptr));
    // System logic here
}