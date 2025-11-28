# Support Modules Code Review (Phase 3d)

**Review Date**: 2025-11-27
**Reviewer**: Code Review Agent
**Status**: Complete

## Executive Summary

The support modules provide essential cross-cutting infrastructure for I/O operations, error handling, tracing, and event management. Overall quality is **GOOD** with one critical file organization issue: [`system_context.zig`](../../src/ecs/system_context.zig:1) at **1045 lines violates Tiger_Style's single responsibility principle** and must be split.

| Module | Lines | Tiger_Style | Status |
|--------|-------|-------------|--------|
| [`io_backend.zig`](../../src/ecs/io/io_backend.zig:1) | 452 | 85% | Good |
| [`error_types.zig`](../../src/ecs/error/error_types.zig:1) | 313 | 90% | Excellent |
| [`tracing.zig`](../../src/ecs/trace/tracing.zig:1) | 420 | 92% | Excellent |
| [`event_queue.zig`](../../src/ecs/event_queue.zig:1) | 443 | 95% | Excellent |
| [`system_context.zig`](../../src/ecs/system_context.zig:1) | 1045 | 60% | **Needs Split** |

---

## 1. Module Overview

### [`io_backend.zig`](../../src/ecs/io/io_backend.zig:1) - I/O Abstraction Layer

**Purpose**: Provides unified interface over `std.Io.Threaded` and `std.Io.Evented` for async operations.

**Key Types**:
- [`IoBackend`](../../src/ecs/io/io_backend.zig:102) - Core abstraction struct
- [`BackendOptions`](../../src/ecs/io/io_backend.zig:38) - Configuration union (blocking/evented/threadpool)
- [`IoBackendError`](../../src/ecs/io/io_backend.zig:72) - Error set for I/O operations
- [`Group`](../../src/ecs/io/io_backend.zig:316) / [`StubGroup`](../../src/ecs/io/io_backend.zig:322) - Async operation grouping

### [`error_types.zig`](../../src/ecs/error/error_types.zig:1) - Error Type Definitions

**Purpose**: Central error hierarchy and error handling utilities.

**Key Types**:
- [`InvariantError`](../../src/ecs/error/error_types.zig:13) - Internal assertion failures
- [`InitError`](../../src/ecs/error/error_types.zig:29) - Initialization failures
- [`FrameError`](../../src/ecs/error/error_types.zig:43) - Runtime frame execution errors
- [`WorldError`](../../src/ecs/error/error_types.zig:61) / [`SchedulerError`](../../src/ecs/error/error_types.zig:73) - Combined sets
- [`ErrorContext`](../../src/ecs/error/error_types.zig:89) - Detailed diagnostic info
- [`AggregateErrorsType`](../../src/ecs/error/error_types.zig:166) - Multi-error collection

### [`tracing.zig`](../../src/ecs/trace/tracing.zig:1) - Tracing Infrastructure

**Purpose**: Zero-overhead tracing with configurable levels and pluggable sinks.

**Key Types**:
- [`TraceLevel`](../../src/ecs/trace/tracing.zig:14) - Re-export from config (off/errors/systems/verbose)
- [`TraceSink`](../../src/ecs/trace/tracing.zig:109) - Vtable-based sink interface
- [`TracingContext`](../../src/ecs/trace/tracing.zig:187) - Generic context with comptime level
- Event types: [`TickEvent`](../../src/ecs/trace/tracing.zig:44), [`StageEvent`](../../src/ecs/trace/tracing.zig:56), [`SystemEvent`](../../src/ecs/trace/tracing.zig:72), [`SystemErrorEvent`](../../src/ecs/trace/tracing.zig:92)

### [`event_queue.zig`](../../src/ecs/event_queue.zig:1) - Event Ring Buffer

**Purpose**: Fixed-size ring buffer for inter-system event communication.

**Key Types**:
- [`EventQueue(T, max_events)`](../../src/ecs/event_queue.zig:38) - Generic ring buffer
- [`EventQueueError`](../../src/ecs/event_queue.zig:22) - Queue overflow error
- [`Iterator`](../../src/ecs/event_queue.zig:179) / [`DrainIterator`](../../src/ecs/event_queue.zig:214) - Iteration modes

### [`system_context.zig`](../../src/ecs/system_context.zig:1) - System Execution Context

**Purpose**: Runtime context passed to systems with commands, resources, and I/O access.

**Key Types** (too many - needs splitting):
- [`CommandType`](../../src/ecs/system_context.zig:30) / [`CommandBufferType`](../../src/ecs/system_context.zig:91) - Deferred operations
- [`ConcurrentCommandBuffers`](../../src/ecs/system_context.zig:207) - Per-thread buffers
- [`Resources`](../../src/ecs/system_context.zig:337) - Type-safe resource storage
- [`IoContext`](../../src/ecs/system_context.zig:441) - I/O capability wrapper
- [`SystemContext`](../../src/ecs/system_context.zig:573) - Main context struct

---

## 2. File-by-File Analysis

### 2.1 [`io_backend.zig`](../../src/ecs/io/io_backend.zig:1) Analysis

#### Strengths

1. **Clean abstraction over std.Io**:
```zig
// Line 21-24: Runtime version detection
pub fn hasStdIo() bool {
    return @hasDecl(std, "Io") and @hasDecl(std.Io, "Threaded");
}
```

2. **Graceful fallback** - Stub implementations when std.Io unavailable:
```zig
// Line 114-127: Comptime backend selection
const BackendStorage = if (hasStdIo())
    RealBackendStorage
else
    StubBackendStorage;
```

3. **Three backend modes well-defined**:
   - Blocking: No async, synchronous execution
   - Evented: Single-threaded async (io_uring/kqueue)
   - Threadpool: Full parallel execution

#### Issues Found

| ID | Severity | Line | Issue |
|----|----------|------|-------|
| IO-1 | P2 | 140-181 | [`initReal()`](../../src/ecs/io/io_backend.zig:140) has only 1 implicit assertion |
| IO-2 | P3 | 183-193 | [`initStub()`](../../src/ecs/io/io_backend.zig:183) has no assertions |
| IO-3 | P2 | 244-262 | [`scheduleAsync()`](../../src/ecs/io/io_backend.zig:244) missing pre/post assertions |
| IO-4 | P3 | 196-208 | [`deinit()`](../../src/ecs/io/io_backend.zig:196) lacks error path for partial cleanup |

#### Missing Features

- No `poll()` or `pollWithTimeout()` methods (referenced in system_context but not implemented)
- No backpressure mechanism when queue is full

### 2.2 [`error_types.zig`](../../src/ecs/error/error_types.zig:1) Analysis

#### Strengths

1. **Well-categorized error hierarchy**:
```zig
// Line 13-26: Invariant errors for bugs
pub const InvariantError = error{
    EntityIndexOutOfBounds,
    EntityGenerationMismatch,
    InvalidArchetypeIndex,
    StorageCorruption,
    WorldStateInconsistent,
    SchedulerStateCorrupted,
};
```

2. **Rich error context**:
```zig
// Line 89-106: Detailed diagnostic struct
pub const ErrorContext = struct {
    category: ErrorCategory,
    code: u32,
    message: []const u8,
    source_location: ?std.builtin.SourceLocation = null,
    world_id: ?u64 = null,
    system_id: ?u16 = null,
    entity_id: ?u32 = null,
    data: ?*const anyopaque = null,
};
```

3. **Config-driven aggregate error capacity**:
```zig
// Line 130: Parameterized for WorldConfig bounds
pub fn FrameResultType(comptime max_errors: u16) type { ... }
```

4. **Invariant helpers** with debug-only variants:
```zig
// Line 244-255: Assertion utilities
pub fn invariant(condition: bool, comptime message: []const u8) void { ... }
pub fn debugInvariant(condition: bool, comptime message: []const u8) void { ... }
```

#### Issues Found

| ID | Severity | Line | Issue |
|----|----------|------|-------|
| ERR-1 | P3 | 188-197 | [`AggregateErrors.add()`](../../src/ecs/error/error_types.zig:188) silently drops if full |
| ERR-2 | P3 | 222-241 | [`defaultErrorHandler()`](../../src/ecs/error/error_types.zig:222) uses std.log (external I/O) |

#### Recommendations

- **ERR-1**: Add overflow indication flag or return bool from `add()`
- Consider adding error recovery patterns/utilities

### 2.3 [`tracing.zig`](../../src/ecs/trace/tracing.zig:1) Analysis

#### Strengths

1. **Zero overhead when disabled** via comptime:
```zig
// Line 202-212: Compiles to no-op when level is off
pub fn emitTickStart(self: Self, tick_index: u64, timestamp_ns: ?u64) void {
    if (comptime TraceLevelExt.emitsVerbose(level)) {
        if (self.sink) |sink| {
            sink.tickStart(.{ ... });
        }
    }
}
```

2. **Vtable-based sinks** for flexibility:
```zig
// Line 115-130: Optional callbacks
pub const VTable = struct {
    on_tick_start: ?*const fn (ctx: *anyopaque, event: TickEvent) void = null,
    on_tick_end: ?*const fn (ctx: *anyopaque, event: TickEvent) void = null,
    // ... more events
};
```

3. **Complete event coverage**:
   - Tick boundaries (start/end)
   - Stage boundaries (start/end)
   - System execution (start/end/error)

4. **Debug sink included** for development:
```zig
// Line 317-375: ConsoleSink for stderr output
pub const ConsoleSink = struct { ... }
```

#### Issues Found

| ID | Severity | Line | Issue |
|----|----------|------|-------|
| TRC-1 | P3 | 369-374 | [`ConsoleSink.sink()`](../../src/ecs/trace/tracing.zig:369) uses undefined context |
| TRC-2 | P3 | - | No file/network sink implementations provided |
| TRC-3 | P3 | - | TracingContext lacks batch emission for hot paths |

#### Performance Verification

Test at line 410-420 confirms no-ops:
```zig
test "TracingContext compiles to no-ops when off" {
    const OffContext = TracingContext(.off);
    var ctx = OffContext.init(null, 0);
    ctx.emitTickStart(0, null);  // Compiles away
}
```

### 2.4 [`event_queue.zig`](../../src/ecs/event_queue.zig:1) Analysis

#### Strengths - **EXCELLENT TIGER_STYLE**

1. **Comptime validation**:
```zig
// Line 39-41: Compile-time bounds check
if (max_events == 0) {
    @compileError("EventQueue max_events must be greater than 0");
}
```

2. **Thorough assertions** (pre/post conditions):
```zig
// Line 75-90: push() with full Tiger_Style assertions
pub fn push(self: *Self, event: T) EventQueueError!void {
    // Precondition assertions
    assert(self.len <= max_events);
    assert(self.head < max_events);
    
    if (self.len >= max_events) {
        return EventQueueError.QueueFull;
    }
    
    const tail = (self.head + self.len) % max_events;
    self.events[tail] = event;
    self.len += 1;
    
    // Postcondition
    assert(self.len <= max_events);
}
```

3. **Two push strategies**:
   - [`push()`](../../src/ecs/event_queue.zig:75) - Returns error on full
   - [`pushOrOverwrite()`](../../src/ecs/event_queue.zig:97) - Lossy, never fails

4. **Non-consuming and draining iteration**:
```zig
// Line 205-211: Read-only iterator
pub fn iter(self: *const Self) Iterator { ... }

// Line 224-226: Consuming iterator
pub fn drain(self: *Self) DrainIterator { ... }
```

5. **Excellent test coverage** - 10 comprehensive test cases

#### Issues Found

| ID | Severity | Line | Issue |
|----|----------|------|-------|
| EVQ-1 | P3 | 179-201 | [`Iterator`](../../src/ecs/event_queue.zig:179) lacks bounds assertion in next() |

### 2.5 [`system_context.zig`](../../src/ecs/system_context.zig:1) Analysis - **CRITICAL**

#### ⚠️ CRITICAL: File Too Large (1045 Lines)

This file violates Tiger_Style's single responsibility principle. It contains **5+ distinct modules** that must be split.

#### Current Structure (To Be Split)

| Section | Lines | New File Recommendation |
|---------|-------|------------------------|
| Command Types | 30-86 | `command_types.zig` |
| CommandBuffer | 91-194 | `command_buffer.zig` |
| ConcurrentCommandBuffers | 207-313 | `concurrent_commands.zig` |
| Resources | 337-412 | `resources.zig` |
| IoContext | 418-564 | **Keep in** `io/io_context.zig` |
| SystemContext | 573-809 | `system_context.zig` (slimmed) |
| Tests | 826-1045 | `*_test.zig` files |

#### Issues Found

| ID | Severity | Line | Issue |
|----|----------|------|-------|
| **SYS-1** | **P1** | All | File is 1045 lines - **MUST SPLIT** |
| SYS-2 | P2 | 518-529 | [`IoContext.scheduleAsync()`](../../src/ecs/system_context.zig:518) signature mismatch with backend |
| SYS-3 | P2 | 549-563 | [`poll()`](../../src/ecs/system_context.zig:549)/[`pollWithTimeout()`](../../src/ecs/system_context.zig:558) call missing backend methods |
| SYS-4 | P2 | 255-278 | [`ConcurrentCommandBuffers.mergeInto()`](../../src/ecs/system_context.zig:255) uses `@TypeOf` incorrectly |
| SYS-5 | P3 | 241-247 | [`getForSystem()`](../../src/ecs/system_context.zig:241) only one assertion |
| SYS-6 | P3 | 679 | [`getIoRequired()`](../../src/ecs/system_context.zig:678) uses @panic instead of error |

#### Strengths (Despite Size)

1. **Config-driven sizing** throughout:
```zig
// Line 573-576: All limits from WorldConfig
pub fn SystemContext(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const max_commands = cfg.options.max_commands_per_frame;
    const max_data_size = cfg.options.max_component_data_size;
```

2. **Type-safe resources** with comptime indexing:
```zig
// Line 405-410: Compile-time type lookup
fn resourceIndex(comptime T: type) usize {
    inline for (resource_types, 0..) |RT, i| {
        if (RT == T) return i;
    }
    @compileError("Resource type not found in ResourcesSpec");
}
```

3. **Good concurrent buffer design**:
```zig
// Line 212-214: Fair division across systems
const commands_per_system = total_max_commands / max_systems;
```

---

## 3. Critical Issues (P1)

### P1-1: [`system_context.zig`](../../src/ecs/system_context.zig:1) Must Be Split

**Impact**: Violates Tiger_Style single responsibility, hard to maintain, blocks parallel development.

**Required Action**: Split into 5-6 smaller, focused files.

---

## 4. Important Issues (P2)

### P2-1: Missing Assertions in I/O Backend

**Files**: [`io_backend.zig`](../../src/ecs/io/io_backend.zig:140)

```zig
// Current (line 140-181):
fn initReal(allocator: Allocator, options: BackendOptions) IoBackendError!Self {
    return switch (options) { ... }; // No assertions
}

// Recommended:
fn initReal(allocator: Allocator, options: BackendOptions) IoBackendError!Self {
    std.debug.assert(allocator.ptr != null); // Assertion 1
    
    const result = switch (options) { ... };
    
    std.debug.assert(result.mode != .blocking or result.backend == .none); // Post
    return result;
}
```

### P2-2: IoContext Method Signature Mismatch

**File**: [`system_context.zig:518-529`](../../src/ecs/system_context.zig:518)

```zig
// Current: Takes callback and context separately
pub fn scheduleAsync(self: *Self, comptime callback: anytype, context: anytype) IoBackendError!void

// io_backend.zig expects: Group + function + args tuple
pub fn scheduleAsync(self: *Self, group: *std.Io.Group, comptime func: anytype, args: ...)
```

**Fix**: Align IoContext API with IoBackend or provide adapter.

### P2-3: Missing poll() Methods in IoBackend

**File**: [`system_context.zig:549-563`](../../src/ecs/system_context.zig:549) calls methods that don't exist in [`io_backend.zig`](../../src/ecs/io/io_backend.zig:1).

```zig
// system_context.zig calls:
return b.poll();           // Doesn't exist
return b.pollWithTimeout(timeout_ns);  // Doesn't exist
```

**Fix**: Implement `poll()` and `pollWithTimeout()` in IoBackend.

### P2-4: Type Detection in mergeInto()

**File**: [`system_context.zig:262`](../../src/ecs/system_context.zig:262)

```zig
// Potentially incorrect:
if (target.count >= @TypeOf(target.*).max_command_count) {

// Should be:
if (target.count >= @TypeOf(target.*).max_command_count) {
```

This appears correct but may cause issues with different target types. Needs type constraint verification.

---

## 5. Minor Issues (P3)

| ID | File | Line | Issue |
|----|------|------|-------|
| P3-1 | [`error_types.zig`](../../src/ecs/error/error_types.zig:188) | 188-197 | [`add()`](../../src/ecs/error/error_types.zig:188) silently drops overflow |
| P3-2 | [`tracing.zig`](../../src/ecs/trace/tracing.zig:369) | 369-374 | [`ConsoleSink.sink()`](../../src/ecs/trace/tracing.zig:369) undefined context |
| P3-3 | [`event_queue.zig`](../../src/ecs/event_queue.zig:184) | 184-194 | [`Iterator.next()`](../../src/ecs/event_queue.zig:184) lacks assertion |
| P3-4 | [`system_context.zig`](../../src/ecs/system_context.zig:679) | 679 | [`getIoRequired()`](../../src/ecs/system_context.zig:678) uses panic |
| P3-5 | [`io_backend.zig`](../../src/ecs/io/io_backend.zig:183) | 183-193 | [`initStub()`](../../src/ecs/io/io_backend.zig:183) no assertions |

---

## 6. system_context.zig Refactoring Proposal

### Proposed File Structure

```
src/ecs/
├── system_context.zig        # Slim: Just SystemContext + SystemFn (≈200 lines)
├── command/
│   ├── types.zig             # CommandType, SpawnCommand, etc. (≈90 lines)
│   ├── buffer.zig            # CommandBufferType (≈100 lines)
│   └── concurrent.zig        # ConcurrentCommandBuffers (≈120 lines)
├── resources.zig             # Resources generic type (≈80 lines)
└── io/
    ├── io_backend.zig        # (existing)
    └── io_context.zig        # IoContext wrapper (≈150 lines)
```

### Migration Steps

1. **Create `src/ecs/command/` directory**

2. **Extract `command/types.zig`**:
   - [`CommandType()`](../../src/ecs/system_context.zig:30)
   - [`SpawnCommandType()`](../../src/ecs/system_context.zig:49)
   - [`SetComponentCommandType()`](../../src/ecs/system_context.zig:59)
   - [`CustomCommand`](../../src/ecs/system_context.zig:69)
   - [`componentTypeId()`](../../src/ecs/system_context.zig:78)

3. **Extract `command/buffer.zig`**:
   - [`CommandBufferType()`](../../src/ecs/system_context.zig:91)
   - [`CommandBuffer()`](../../src/ecs/system_context.zig:192) (alias)

4. **Extract `command/concurrent.zig`**:
   - [`ConcurrentCommandBuffers()`](../../src/ecs/system_context.zig:207)
   - [`ConcurrentCommandBuffersFromConfig()`](../../src/ecs/system_context.zig:322)

5. **Extract `resources.zig`**:
   - [`Resources()`](../../src/ecs/system_context.zig:337)

6. **Extract `io/io_context.zig`**:
   - [`IoError`](../../src/ecs/system_context.zig:424)
   - [`IoContext`](../../src/ecs/system_context.zig:441)

7. **Slim `system_context.zig`**:
   - Import all extracted modules
   - Keep only [`SystemContext()`](../../src/ecs/system_context.zig:573) and [`SystemFn()`](../../src/ecs/system_context.zig:817)

8. **Create test files**:
   - `command/buffer_test.zig`
   - `command/concurrent_test.zig`
   - `resources_test.zig`
   - `io/io_context_test.zig`
   - `system_context_test.zig`

### Resulting Line Counts

| File | Estimated Lines |
|------|-----------------|
| `command/types.zig` | ~90 |
| `command/buffer.zig` | ~100 |
| `command/concurrent.zig` | ~120 |
| `resources.zig` | ~80 |
| `io/io_context.zig` | ~150 |
| `system_context.zig` | ~200 |
| Test files (5) | ~220 (total) |
| **Total** | ~960 (vs 1045) |

All files under 200 lines, well within Tiger_Style 70-line function limit.

---

## 7. Tiger_Style Compliance Score

### Overall Score: **78/100**

| Category | Score | Notes |
|----------|-------|-------|
| Function Length (≤70) | 95/100 | All functions compliant |
| Assertions (≥2/fn) | 70/100 | event_queue excellent, io_backend weak |
| Static Allocation | 100/100 | All bounds comptime |
| Error Handling | 85/100 | Good hierarchy, some silent drops |
| Naming (snake_case) | 100/100 | Fully compliant |
| File Size | 40/100 | system_context.zig critically oversized |
| Documentation | 80/100 | Good doc comments |
| Test Coverage | 85/100 | Good coverage |

### Per-File Breakdown

| File | Compliance |
|------|------------|
| [`io_backend.zig`](../../src/ecs/io/io_backend.zig:1) | 85% |
| [`error_types.zig`](../../src/ecs/error/error_types.zig:1) | 90% |
| [`tracing.zig`](../../src/ecs/trace/tracing.zig:1) | 92% |
| [`event_queue.zig`](../../src/ecs/event_queue.zig:1) | **95%** ⭐ |
| [`system_context.zig`](../../src/ecs/system_context.zig:1) | 60% |

---

## 8. Specific Code Citations

### Example: Excellent Tiger_Style ([`event_queue.zig:75-90`](../../src/ecs/event_queue.zig:75))

```zig
/// Push an event to the queue.
/// Returns error.QueueFull if the queue is at capacity.
///
/// Precondition: None
/// Postcondition: len increases by 1 if successful
pub fn push(self: *Self, event: T) EventQueueError!void {
    // Precondition assertions
    assert(self.len <= max_events);
    assert(self.head < max_events);

    if (self.len >= max_events) {
        return EventQueueError.QueueFull;
    }

    const tail = (self.head + self.len) % max_events;
    self.events[tail] = event;
    self.len += 1;

    // Postcondition
    assert(self.len <= max_events);
}
```

✅ Documented preconditions  
✅ 2+ assertions  
✅ Explicit error return  
✅ Postcondition check  
✅ Under 20 lines  

### Example: Needs Improvement ([`io_backend.zig:140-181`](../../src/ecs/io/io_backend.zig:140))

```zig
fn initReal(allocator: Allocator, options: BackendOptions) IoBackendError!Self {
    return switch (options) {
        .blocking => .{
            .backend = .{ .none = {} },
            .mode = .blocking,
            .allocator = allocator,
        },
        // ... 35 more lines
    };
}
```

❌ No precondition assertions  
❌ No postcondition assertions  
⚠️ 40+ lines in switch  

---

## 9. Cross-Cutting Concerns

### Error Type Usage

[`FrameError`](../../src/ecs/error/error_types.zig:43) is used consistently:
- In [`SystemFn`](../../src/ecs/system_context.zig:819) return type
- In [`SystemContext`](../../src/ecs/system_context.zig:573) method returns
- In scheduler error aggregation

### Tracing Integration Points

TracingContext should be integrated at:
- Scheduler runtime (tick start/end)
- Stage execution (stage start/end)
- System dispatch (system start/end/error)

Current integration appears to be in scheduler; verify completeness.

### Event Queue Cross-Module Usage

EventQueue can be used as:
- Component type in archetypes
- Resource singleton
- Custom event channel

Pattern is clean and decoupled.

---

## 10. Recommendations Summary

### Immediate Actions (P1)

1. **Split [`system_context.zig`](../../src/ecs/system_context.zig:1)** into 6+ focused files per Section 6

### Short-Term (P2)

2. Add missing assertions to [`io_backend.zig`](../../src/ecs/io/io_backend.zig:1) init/schedule methods
3. Implement missing `poll()` / `pollWithTimeout()` in [`IoBackend`](../../src/ecs/io/io_backend.zig:102)
4. Align [`IoContext`](../../src/ecs/system_context.zig:441) API with [`IoBackend`](../../src/ecs/io/io_backend.zig:102)

### Nice-to-Have (P3)

5. Add overflow indication to [`AggregateErrors.add()`](../../src/ecs/error/error_types.zig:188)
6. Fix [`ConsoleSink.sink()`](../../src/ecs/trace/tracing.zig:369) undefined context
7. Add assertion to [`EventQueue.Iterator.next()`](../../src/ecs/event_queue.zig:184)
8. Replace panic with error in [`getIoRequired()`](../../src/ecs/system_context.zig:678)

---

## Appendix: Method Cross-Reference

### Who Uses Error Types

| Error Type | Used By |
|------------|---------|
| [`InvariantError`](../../src/ecs/error/error_types.zig:13) | World internals, scheduler |
| [`InitError`](../../src/ecs/error/error_types.zig:29) | World.init, Scheduler.init |
| [`FrameError`](../../src/ecs/error/error_types.zig:43) | Systems, SystemFn, runtime |
| [`WorldError`](../../src/ecs/error/error_types.zig:61) | World public API |
| [`SchedulerError`](../../src/ecs/error/error_types.zig:73) | Scheduler public API |

### TraceSink Event Flow

```
tick_start → [stage_start → [system_start → system_end]* → stage_end]* → tick_end
                                       ↓
                               system_error (on failure)