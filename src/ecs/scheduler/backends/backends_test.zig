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

const ecs = @import("../../../ecs.zig");
const WorldConfig = ecs.WorldConfig;
const Phase = ecs.Phase;

const error_types = @import("../../error/error_types.zig");
const FrameError = error_types.FrameError;

const interface = @import("interface.zig");
const BackendStats = interface.BackendStats;

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
