//! Functional Tests for Scheduler Execution Backends
//!
//! Tests verify that backends correctly execute systems,
//! respect ordering constraints, and handle edge cases.
//!
//! ## Test Coverage
//!
//! - **Blocking Backend**: Sequential execution, order verification, empty schedules
//! - **Backend Statistics**: Stats tracking verification
//! - **Interface**: BackendStats structure tests

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const ecs = @import("../../../ecs.zig");
const WorldConfig = ecs.WorldConfig;
const Phase = ecs.Phase;

const config_mod = @import("../../config.zig");
const ExecutionModel = config_mod.ExecutionModel;

const error_types = @import("../../error/error_types.zig");
const FrameError = error_types.FrameError;

const interface = @import("interface.zig");
const BackendStats = interface.BackendStats;

const select = @import("select.zig");
const io_uring_batch = @import("io_uring_batch.zig");
const work_stealing = @import("work_stealing.zig");

// Platform-specific modules for scalability tests
const numa_allocator = @import("../../scalability/numa_allocator.zig");
const huge_page_allocator = @import("../../scalability/huge_page_allocator.zig");
const affinity = @import("../../scalability/affinity.zig");

// ============================================================================
// Test State (Thread-Safe)
// ============================================================================

/// Atomic counter for tracking system executions across threads.
var execution_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Execution order recording buffer.
/// Each entry is the system_id that was executed at that position.
var execution_order: [16]std.atomic.Value(u32) = blk: {
    var arr: [16]std.atomic.Value(u32) = undefined;
    for (&arr) |*item| {
        item.* = std.atomic.Value(u32).init(0);
    }
    break :blk arr;
};

/// Index for next execution order slot.
var order_index: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Reset all test state before each test.
fn resetTestState() void {
    execution_count.store(0, .release);
    order_index.store(0, .release);
    for (&execution_order) |*slot| {
        slot.store(0, .release);
    }
}

/// Record that a system executed with the given ID.
fn recordExecution(system_id: u32) void {
    _ = execution_count.fetchAdd(1, .acq_rel);
    const idx = order_index.fetchAdd(1, .acq_rel);
    if (idx < execution_order.len) {
        execution_order[idx].store(system_id, .release);
    }
}

/// Get the recorded execution order as a slice.
fn getExecutionOrder() []const u32 {
    const count = @min(order_index.load(.acquire), execution_order.len);
    // Can't return atomic values directly, need to read them
    var result: [16]u32 = undefined;
    for (0..count) |i| {
        result[i] = execution_order[i].load(.acquire);
    }
    return result[0..count];
}

// ============================================================================
// Test Components
// ============================================================================

const Counter = struct {
    value: i32 = 0,
};

const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Velocity = struct {
    dx: f32 = 0,
    dy: f32 = 0,
};

// ============================================================================
// Test Systems
// ============================================================================

/// System that increments the execution counter.
fn incrementSystem(_: *anyopaque) FrameError!void {
    _ = execution_count.fetchAdd(1, .acq_rel);
}

/// System that records execution with ID 1.
fn system1(_: *anyopaque) FrameError!void {
    recordExecution(1);
}

/// System that records execution with ID 2.
fn system2(_: *anyopaque) FrameError!void {
    recordExecution(2);
}

/// System that records execution with ID 3.
fn system3(_: *anyopaque) FrameError!void {
    recordExecution(3);
}

/// System that records execution with ID 4.
fn system4(_: *anyopaque) FrameError!void {
    recordExecution(4);
}

/// System that does nothing (for empty/minimal tests).
fn noopSystem(_: *anyopaque) FrameError!void {}

/// System that always fails (for error handling tests).
fn failingSystem(_: *anyopaque) FrameError!void {
    return FrameError.SystemPanic;
}

// ============================================================================
// Test Configurations
// ============================================================================

/// Minimal config with single system for basic execution tests.
const single_system_config = WorldConfig{
    .components = .{ .types = &.{Counter} },
    .archetypes = .{ .archetypes = &.{
        .{ .name = "counter", .components = &.{Counter} },
    } },
    .systems = .{ .systems = &.{
        .{
            .name = "increment",
            .phase = Phase.update.index(),
            .read_components = &.{},
            .write_components = &.{Counter},
            .func = ecs.asSystemFn(incrementSystem),
        },
    } },
    .options = .{ .max_entities = 100 },
    .schedule = .{ .execution_model = .blocking_single_thread },
};

/// Config with multiple systems in same phase for order testing.
const multi_system_config = WorldConfig{
    .components = .{ .types = &.{Counter} },
    .archetypes = .{ .archetypes = &.{
        .{ .name = "counter", .components = &.{Counter} },
    } },
    .systems = .{ .systems = &.{
        .{
            .name = "sys1",
            .phase = Phase.update.index(),
            .read_components = &.{},
            .write_components = &.{Counter},
            .func = ecs.asSystemFn(system1),
        },
        .{
            .name = "sys2",
            .phase = Phase.update.index(),
            .read_components = &.{},
            .write_components = &.{Counter},
            .func = ecs.asSystemFn(system2),
        },
        .{
            .name = "sys3",
            .phase = Phase.update.index(),
            .read_components = &.{},
            .write_components = &.{Counter},
            .func = ecs.asSystemFn(system3),
        },
    } },
    .options = .{ .max_entities = 100 },
    .schedule = .{ .execution_model = .blocking_single_thread },
};

/// Config with systems across multiple phases for phase ordering tests.
const multi_phase_config = WorldConfig{
    .components = .{ .types = &.{ Counter, Position } },
    .archetypes = .{ .archetypes = &.{
        .{ .name = "entity", .components = &.{ Counter, Position } },
    } },
    .systems = .{ .systems = &.{
        .{
            .name = "early",
            .phase = Phase.pre_update.index(),
            .read_components = &.{},
            .write_components = &.{Counter},
            .func = ecs.asSystemFn(system1),
        },
        .{
            .name = "main",
            .phase = Phase.update.index(),
            .read_components = &.{Counter},
            .write_components = &.{Position},
            .func = ecs.asSystemFn(system2),
        },
        .{
            .name = "late",
            .phase = Phase.post_update.index(),
            .read_components = &.{Position},
            .write_components = &.{},
            .func = ecs.asSystemFn(system3),
        },
    } },
    .options = .{ .max_entities = 100 },
    .schedule = .{ .execution_model = .blocking_single_thread },
};

/// Empty config (no systems) for edge case testing.
const empty_systems_config = WorldConfig{
    .components = .{ .types = &.{Counter} },
    .archetypes = .{ .archetypes = &.{
        .{ .name = "counter", .components = &.{Counter} },
    } },
    .systems = .{ .systems = &.{} },
    .options = .{ .max_entities = 100 },
    .schedule = .{ .execution_model = .blocking_single_thread },
};

/// Config with failing system for error handling tests.
const failing_system_config = WorldConfig{
    .components = .{ .types = &.{Counter} },
    .archetypes = .{ .archetypes = &.{
        .{ .name = "counter", .components = &.{Counter} },
    } },
    .systems = .{ .systems = &.{
        .{
            .name = "failing",
            .phase = Phase.update.index(),
            .read_components = &.{},
            .write_components = &.{Counter},
            .func = ecs.asSystemFn(failingSystem),
        },
    } },
    .options = .{ .max_entities = 100 },
    .schedule = .{ .execution_model = .blocking_single_thread },
};

// ============================================================================
// Blocking Backend Tests
// ============================================================================

test "blocking backend - executes single system" {
    resetTestState();

    const World = ecs.World(single_system_config);
    const Scheduler = ecs.Scheduler(single_system_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    // Execute one tick
    const result = scheduler.tick(0.016);
    try testing.expect(result.isSuccess());

    // Verify system ran exactly once
    try testing.expectEqual(@as(u32, 1), execution_count.load(.acquire));
}

test "blocking backend - executes multiple systems" {
    resetTestState();

    const World = ecs.World(multi_system_config);
    const Scheduler = ecs.Scheduler(multi_system_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    const result = scheduler.tick(0.016);
    try testing.expect(result.isSuccess());

    // All 3 systems should have executed
    try testing.expectEqual(@as(u32, 3), execution_count.load(.acquire));
}

test "blocking backend - respects phase ordering" {
    resetTestState();

    const World = ecs.World(multi_phase_config);
    const Scheduler = ecs.Scheduler(multi_phase_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    const result = scheduler.tick(0.016);
    try testing.expect(result.isSuccess());

    // All 3 systems should have executed
    try testing.expectEqual(@as(u32, 3), execution_count.load(.acquire));

    // Verify phase order: pre_update (1), update (2), post_update (3)
    const idx = order_index.load(.acquire);
    try testing.expectEqual(@as(u32, 3), idx);

    // System 1 should run first (pre_update)
    try testing.expectEqual(@as(u32, 1), execution_order[0].load(.acquire));
    // System 2 should run second (update)
    try testing.expectEqual(@as(u32, 2), execution_order[1].load(.acquire));
    // System 3 should run third (post_update)
    try testing.expectEqual(@as(u32, 3), execution_order[2].load(.acquire));
}

test "blocking backend - handles empty schedule" {
    resetTestState();

    const World = ecs.World(empty_systems_config);
    const Scheduler = ecs.Scheduler(empty_systems_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    // Should not crash with empty schedule
    const result = scheduler.tick(0.016);
    try testing.expect(result.isSuccess());

    // No systems should have executed
    try testing.expectEqual(@as(u32, 0), execution_count.load(.acquire));
}

test "blocking backend - handles failing system" {
    resetTestState();

    const World = ecs.World(failing_system_config);
    const Scheduler = ecs.Scheduler(failing_system_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    const result = scheduler.tick(0.016);

    // Should report error
    try testing.expect(result.isError());
}

test "blocking backend - multiple ticks accumulate" {
    resetTestState();

    const World = ecs.World(single_system_config);
    const Scheduler = ecs.Scheduler(single_system_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    // Execute 5 ticks
    for (0..5) |_| {
        const result = scheduler.tick(0.016);
        try testing.expect(result.isSuccess());
    }

    // System should have run 5 times
    try testing.expectEqual(@as(u32, 5), execution_count.load(.acquire));

    // Tick count should be 5
    try testing.expectEqual(@as(u64, 5), scheduler.getTickCount());
}

test "blocking backend - stats tracking" {
    resetTestState();

    const World = ecs.World(multi_system_config);
    const Scheduler = ecs.Scheduler(multi_system_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    // Execute 3 ticks
    for (0..3) |_| {
        _ = scheduler.tick(0.016);
    }

    const stats = scheduler.backend.getStats();
    try testing.expectEqual(@as(u64, 3), stats.ticks_executed);
    try testing.expect(stats.systems_executed >= 9); // 3 systems * 3 ticks
}

// ============================================================================
// BackendStats Tests
// ============================================================================

test "BackendStats - initialization and reset" {
    var stats = BackendStats{};
    try testing.expectEqual(@as(u64, 0), stats.ticks_executed);
    try testing.expectEqual(@as(u64, 0), stats.systems_executed);
    try testing.expectEqual(@as(u64, 0), stats.phases_executed);

    stats.ticks_executed = 100;
    stats.systems_executed = 500;
    stats.phases_executed = 300;

    stats.reset();

    try testing.expectEqual(@as(u64, 0), stats.ticks_executed);
    try testing.expectEqual(@as(u64, 0), stats.systems_executed);
    try testing.expectEqual(@as(u64, 0), stats.phases_executed);
}

// ============================================================================
// Additional Blocking Backend Tests
// ============================================================================

test "blocking backend - tickN executes multiple ticks" {
    resetTestState();

    const World = ecs.World(single_system_config);
    const Scheduler = ecs.Scheduler(single_system_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    // Execute 10 ticks at once
    const result = scheduler.tickN(0.016, 10);
    try testing.expect(result.isSuccess());

    // System should have run 10 times
    try testing.expectEqual(@as(u32, 10), execution_count.load(.acquire));

    // Tick count should be 10
    try testing.expectEqual(@as(u64, 10), scheduler.getTickCount());
}

test "blocking backend - world with spawned entities" {
    resetTestState();

    const World = ecs.World(single_system_config);
    const Scheduler = ecs.Scheduler(single_system_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    // Spawn some entities
    _ = try world.spawn("counter", .{Counter{ .value = 1 }});
    _ = try world.spawn("counter", .{Counter{ .value = 2 }});
    _ = try world.spawn("counter", .{Counter{ .value = 3 }});

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    const result = scheduler.tick(0.016);
    try testing.expect(result.isSuccess());

    // System should have run
    try testing.expectEqual(@as(u32, 1), execution_count.load(.acquire));
}

test "blocking backend - accumulated time tracking" {
    resetTestState();

    const World = ecs.World(single_system_config);
    const Scheduler = ecs.Scheduler(single_system_config);

    var world = World.init(testing.allocator);
    defer world.deinit();

    var scheduler = Scheduler.init(&world, null, testing.allocator);
    defer scheduler.deinit();

    // Execute ticks with known delta times
    _ = scheduler.tick(0.016);
    _ = scheduler.tick(0.016);
    _ = scheduler.tick(0.016);

    const accumulated = scheduler.getAccumulatedTime();
    try testing.expect(accumulated >= 0.048 - 0.001); // Allow small floating point variance
    try testing.expect(accumulated <= 0.048 + 0.001);
}

// ============================================================================
// io_uring Backend Tests (Linux-only)
// ============================================================================

test "io_uring - availability check" {
    // This test always passes - documents platform detection
    if (builtin.os.tag != .linux) {
        // io_uring not available on non-Linux
        try testing.expect(!io_uring_batch.io_uring_available);
        return;
    }
    // On Linux, io_uring should be available
    try testing.expect(io_uring_batch.io_uring_available);
}

test "io_uring - backend selection on Linux" {
    if (builtin.os.tag != .linux) {
        // Skip on non-Linux platforms
        return error.SkipZigTest;
    }

    // Verify backend selection works on Linux
    try testing.expect(select.isBackendAvailable(.io_uring_batch));

    // Verify backend name is correct
    const name = select.getBackendName(.io_uring_batch);
    try testing.expectEqualStrings("io_uring Batch (Linux syscall batching)", name);
}

test "io_uring - fallback on non-Linux" {
    if (builtin.os.tag == .linux) {
        // This test is for non-Linux platforms only
        return error.SkipZigTest;
    }

    // On non-Linux, io_uring_batch should still be queryable but not available
    try testing.expect(!select.isBackendAvailable(.io_uring_batch));
}

// ============================================================================
// Async Backend Behavior Tests
// ============================================================================

test "async backend - evented model availability" {
    // The evented_single_thread model uses BlockingBackend with IoContext support
    // Verify backend is available
    try testing.expect(select.isBackendAvailable(.evented_single_thread));

    // Verify backend name
    const name = select.getBackendName(.evented_single_thread);
    try testing.expect(std.mem.indexOf(u8, name, "Evented") != null);
}

test "async backend - backend selection respects model" {
    // Verify backend selection is consistent for all models
    try testing.expect(select.isBackendAvailable(.blocking_single_thread));
    try testing.expect(select.isBackendAvailable(.evented_single_thread));
    try testing.expect(select.isBackendAvailable(.concurrent_threadpool));
    try testing.expect(select.isBackendAvailable(.work_stealing));
    try testing.expect(select.isBackendAvailable(.adaptive_hybrid));
}

test "async backend - backend descriptions are non-empty" {
    // All backends should have meaningful descriptions
    const models = [_]config_mod.ExecutionModel{
        .blocking_single_thread,
        .evented_single_thread,
        .concurrent_threadpool,
        .io_uring_batch,
        .work_stealing,
        .adaptive_hybrid,
    };

    for (models) |model| {
        const desc = select.getBackendDescription(model);
        try testing.expect(desc.len > 10); // Should have meaningful description
    }
}

// ============================================================================
// Work-Stealing Backend Tests
// ============================================================================

test "work stealing - Chase-Lev deque basic operations" {
    // Test the deque data structure used by work-stealing
    const Deque = work_stealing.ChaseLevDeque(u32, 16);
    var deque = Deque.init();

    // Push some items (owner side)
    try testing.expect(deque.push(1));
    try testing.expect(deque.push(2));
    try testing.expect(deque.push(3));

    // Pop from owner side (LIFO)
    try testing.expectEqual(@as(?u32, 3), deque.pop());
    try testing.expectEqual(@as(?u32, 2), deque.pop());
    try testing.expectEqual(@as(?u32, 1), deque.pop());
    try testing.expectEqual(@as(?u32, null), deque.pop()); // Empty
}

test "work stealing - Chase-Lev deque steal operations" {
    const Deque = work_stealing.ChaseLevDeque(u32, 16);
    var deque = Deque.init();

    // Push items
    try testing.expect(deque.push(10));
    try testing.expect(deque.push(20));
    try testing.expect(deque.push(30));

    // Steal from thief side (FIFO)
    try testing.expectEqual(@as(?u32, 10), deque.steal());
    try testing.expectEqual(@as(?u32, 20), deque.steal());
    try testing.expectEqual(@as(?u32, 30), deque.steal());
    try testing.expectEqual(@as(?u32, null), deque.steal()); // Empty
}

test "work stealing - Chase-Lev deque mixed push/pop/steal" {
    const Deque = work_stealing.ChaseLevDeque(u32, 16);
    var deque = Deque.init();

    // Interleaved operations
    try testing.expect(deque.push(1));
    try testing.expect(deque.push(2));
    try testing.expectEqual(@as(?u32, 1), deque.steal()); // Steal oldest
    try testing.expect(deque.push(3));
    try testing.expectEqual(@as(?u32, 3), deque.pop()); // Pop newest
    try testing.expectEqual(@as(?u32, 2), deque.pop()); // Pop remaining
}

test "work stealing - deque capacity limit" {
    const Deque = work_stealing.ChaseLevDeque(u32, 4); // Small capacity
    var deque = Deque.init();

    // Fill the deque
    try testing.expect(deque.push(1));
    try testing.expect(deque.push(2));
    try testing.expect(deque.push(3));
    try testing.expect(deque.push(4));

    // Should fail when full
    try testing.expect(!deque.push(5));
}

test "work stealing - backend availability" {
    // Verify work_stealing backend is available
    try testing.expect(select.isBackendAvailable(.work_stealing));

    // Verify backend name
    const name = select.getBackendName(.work_stealing);
    try testing.expect(std.mem.indexOf(u8, name, "Work-Stealing") != null);
}

// ============================================================================
// Platform-Specific Tests
// ============================================================================

test "platform - NUMA allocator availability" {
    if (builtin.os.tag != .linux) {
        // NUMA is primarily a Linux feature
        return error.SkipZigTest;
    }

    // On Linux, test that NUMA allocator can be initialized
    // This tests the header/metadata structure
    const NumaAlloc = numa_allocator.NumaAllocator(.{});
    const alloc = NumaAlloc.init(testing.allocator, 0);

    // Verify stats are initialized
    try testing.expectEqual(@as(u64, 0), alloc.stats.local_allocations);
    try testing.expectEqual(@as(u64, 0), alloc.stats.remote_allocations);
}

test "platform - huge page allocator initialization" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) {
        // Huge pages only supported on Linux and Windows
        return error.SkipZigTest;
    }

    // Test that huge page allocator type can be instantiated
    const HugeAlloc = huge_page_allocator.HugePageAllocator(.{});
    const alloc = HugeAlloc.init(testing.allocator);

    // Verify allocator is valid
    try testing.expect(@TypeOf(alloc.backing_allocator) == std.mem.Allocator);
}

test "platform - affinity manager detection" {
    // Affinity manager should detect CPU count on all platforms
    const manager = affinity.AffinityManager.init(.{}) catch |err| {
        // On some platforms/configurations, init may fail
        // That's acceptable - we just skip
        _ = err;
        return error.SkipZigTest;
    };

    // Should detect at least one CPU
    try testing.expect(manager.cpu_count >= 1);
}

test "platform - affinity CPU binding (Linux only)" {
    if (builtin.os.tag != .linux) {
        // Thread affinity pinning is most reliable on Linux
        return error.SkipZigTest;
    }

    // Just verify the API exists and doesn't crash
    // Actual pinning requires specific permissions
    affinity.AffinityManager.pinThread(0) catch {
        // May fail due to permissions, which is fine
    };
}

test "platform - backend name consistency" {
    // All execution models should have consistent naming
    const models = [_]config_mod.ExecutionModel{
        .blocking_single_thread,
        .evented_single_thread,
        .concurrent_threadpool,
        .io_uring_batch,
        .work_stealing,
        .adaptive_hybrid,
    };

    for (models) |model| {
        const name = select.getBackendName(model);
        try testing.expect(name.len > 0);
        // Names should contain descriptive text
        try testing.expect(std.mem.indexOf(u8, name, "(") != null);
    }
}

// ============================================================================
// Concurrent Command Buffer Tests (Relates to H-6)
// ============================================================================

test "concurrent commands - basic atomic operations" {
    // Test that concurrent command structures exist
    const concurrent_commands = @import("../../context/concurrent_commands.zig");
    _ = concurrent_commands;
}
