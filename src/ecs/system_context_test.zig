//! Unit tests for SystemContext.
//!
//! Tests verify SystemContext lifecycle, data access patterns,
//! command buffering, resource access, and I/O capabilities.
//!
//! Tiger Style: Exhaustive assertions, test both positive and negative cases.

const std = @import("std");
const testing = std.testing;

const ecs = @import("../ecs.zig");
const WorldConfig = ecs.WorldConfig;
const EntityHandle = ecs.EntityHandle;

const system_context_mod = @import("system_context.zig");
const SystemContext = system_context_mod.SystemContext;
const Resources = system_context_mod.Resources;
const CommandBufferType = system_context_mod.CommandBufferType;
const IoContext = system_context_mod.IoContext;

const query_mod = @import("world/query.zig");

// ============================================================================
// Test Components
// ============================================================================

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    dx: f32,
    dy: f32,
};

const Health = struct {
    current: u32,
    max: u32,
};

const Tag = struct {};

// ============================================================================
// Test Resources
// ============================================================================

const GameState = struct {
    level: u32,
    score: u64,
    paused: bool,
};

const PlayerStats = struct {
    kills: u32,
    deaths: u32,
};

// ============================================================================
// Test Configuration
// ============================================================================

const test_config = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Tag },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
            .{ .name = "static", .components = &.{Position} },
            .{ .name = "living", .components = &.{ Position, Health } },
            .{ .name = "empty", .components = &.{Tag} },
        },
    },
    .resources = .{
        .types = &.{ GameState, PlayerStats },
    },
    .options = .{
        .max_entities = 100,
        .max_commands_per_frame = 50,
        .max_component_data_size = 64,
    },
};

const TestWorld = ecs.World(test_config);
const TestContext = SystemContext(test_config, TestWorld);
const TestResources = Resources(test_config.resources.types);
const TestCmdBuf = TestContext.CmdBuf;

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a test context with default values for testing.
fn createTestContext(world: *TestWorld, resources: *TestResources, commands: *TestCmdBuf) TestContext {
    return TestContext.init(
        world,
        resources,
        0.016, // 60fps delta
        0, // tick 0
        0, // time_ns 0
        commands,
        testing.allocator,
    );
}

// ============================================================================
// Lifecycle Tests
// ============================================================================

test "SystemContext - creation and initialization" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();

    const ctx = createTestContext(&world, &resources, &commands);

    // Verify all fields are properly initialized
    try testing.expect(ctx.world == &world);
    try testing.expect(ctx.resources == &resources);
    try testing.expect(ctx.commands == &commands);
    try testing.expectEqual(@as(f64, 0.016), ctx.delta_time);
    try testing.expectEqual(@as(u64, 0), ctx.tick);
    try testing.expectEqual(@as(u64, 0), ctx.time_ns);
    try testing.expect(ctx.io == null);
}

test "SystemContext - init with different frame info values" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();

    const delta_time: f64 = 0.033; // 30fps
    const tick: u64 = 42;
    const time_ns: u64 = 1_000_000_000; // 1 second

    const ctx = TestContext.init(
        &world,
        &resources,
        delta_time,
        tick,
        time_ns,
        &commands,
        testing.allocator,
    );

    try testing.expectEqual(delta_time, ctx.delta_time);
    try testing.expectEqual(tick, ctx.tick);
    try testing.expectEqual(time_ns, ctx.time_ns);
}

test "SystemContext - initWithIo creates context with I/O" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var io_context = IoContext.blocking();

    const ctx = TestContext.initWithIo(
        &world,
        &resources,
        0.016,
        0,
        0,
        &commands,
        testing.allocator,
        &io_context,
    );

    try testing.expect(ctx.io != null);
    try testing.expect(ctx.io == &io_context);
}

test "SystemContext - configuration limits exposed correctly" {
    // Verify config-based limits are accessible
    try testing.expectEqual(@as(usize, 50), TestContext.max_commands_per_frame);
    try testing.expectEqual(@as(u32, 64), TestContext.max_component_data_size);
}

// ============================================================================
// World Access Tests
// ============================================================================

test "SystemContext - spawn entities through context" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    // Spawn entity with Position and Velocity
    const handle = try ctx.spawn("moving", .{
        Position{ .x = 10.0, .y = 20.0 },
        Velocity{ .dx = 1.0, .dy = 2.0 },
    });

    try testing.expect(ctx.isAlive(handle));
    try testing.expectEqual(@as(u32, 1), ctx.entityCount());
}

test "SystemContext - despawn entities through context" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    const handle = try ctx.spawn("static", .{Position{ .x = 0, .y = 0 }});
    try testing.expect(ctx.isAlive(handle));

    try ctx.despawn(handle);
    try testing.expect(!ctx.isAlive(handle));
    try testing.expectEqual(@as(u32, 0), ctx.entityCount());
}

test "SystemContext - getComponent returns correct data" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    const handle = try ctx.spawn("moving", .{
        Position{ .x = 5.5, .y = 10.5 },
        Velocity{ .dx = -1.0, .dy = 3.0 },
    });

    const pos = ctx.getComponent(handle, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(f32, 5.5), pos.?.x);
    try testing.expectEqual(@as(f32, 10.5), pos.?.y);

    const vel = ctx.getComponent(handle, Velocity);
    try testing.expect(vel != null);
    try testing.expectEqual(@as(f32, -1.0), vel.?.dx);
    try testing.expectEqual(@as(f32, 3.0), vel.?.dy);
}

test "SystemContext - getComponent returns null for missing component" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    // Entity in "static" archetype has only Position, not Velocity
    const handle = try ctx.spawn("static", .{Position{ .x = 0, .y = 0 }});

    const vel = ctx.getComponent(handle, Velocity);
    try testing.expect(vel == null);
}

test "SystemContext - getComponentMut allows modification" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    const handle = try ctx.spawn("moving", .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .dx = 0, .dy = 0 },
    });

    // Modify position through mutable pointer
    const pos = ctx.getComponentMut(handle, Position);
    try testing.expect(pos != null);
    pos.?.x = 100.0;
    pos.?.y = 200.0;

    // Verify modification persisted
    const pos_after = ctx.getComponent(handle, Position);
    try testing.expectEqual(@as(f32, 100.0), pos_after.?.x);
    try testing.expectEqual(@as(f32, 200.0), pos_after.?.y);
}

test "SystemContext - setComponent updates component value" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    const handle = try ctx.spawn("living", .{
        Position{ .x = 0, .y = 0 },
        Health{ .current = 100, .max = 100 },
    });

    // Update health via setComponent
    const success = ctx.setComponent(handle, Health, Health{ .current = 50, .max = 100 });
    try testing.expect(success);

    const health = ctx.getComponent(handle, Health);
    try testing.expectEqual(@as(u32, 50), health.?.current);
    try testing.expectEqual(@as(u32, 100), health.?.max);
}

test "SystemContext - hasComponent checks correctly" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    // "moving" has Position and Velocity
    const handle = try ctx.spawn("moving", .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .dx = 0, .dy = 0 },
    });

    try testing.expect(ctx.hasComponent(handle, Position));
    try testing.expect(ctx.hasComponent(handle, Velocity));
    try testing.expect(!ctx.hasComponent(handle, Health));
}

// ============================================================================
// Query Access Tests
// ============================================================================

test "SystemContext - query entities" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    // Spawn multiple entities
    _ = try ctx.spawn("moving", .{
        Position{ .x = 1.0, .y = 1.0 },
        Velocity{ .dx = 0.1, .dy = 0.1 },
    });
    _ = try ctx.spawn("moving", .{
        Position{ .x = 2.0, .y = 2.0 },
        Velocity{ .dx = 0.2, .dy = 0.2 },
    });
    _ = try ctx.spawn("static", .{Position{ .x = 3.0, .y = 3.0 }});

    // Query for entities with Position and Velocity (only "moving" archetype)
    const QuerySpec = query_mod.QuerySpec(&.{}, &.{ Position, Velocity }, &.{}, &.{});
    var query_iter = ctx.query(QuerySpec);

    var count: u32 = 0;
    while (query_iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(u32, 2), count);
}

// ============================================================================
// Command Buffer Tests
// ============================================================================

test "SystemContext - despawnDeferred queues command" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    const handle = try ctx.spawn("static", .{Position{ .x = 0, .y = 0 }});

    // Queue deferred despawn
    try testing.expect(ctx.despawnDeferred(handle));

    // Entity should still be alive (command not executed yet)
    try testing.expect(ctx.isAlive(handle));

    // Verify command was queued
    const cmds = commands.getCommands();
    try testing.expectEqual(@as(usize, 1), cmds.len);
}

test "SystemContext - spawnDeferred queues command" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    // Queue deferred spawn in archetype 0 ("moving")
    try testing.expect(ctx.spawnDeferred(0));
    try testing.expect(ctx.spawnDeferred(1));

    // Verify commands were queued
    const cmds = commands.getCommands();
    try testing.expectEqual(@as(usize, 2), cmds.len);
}

test "SystemContext - setComponentDeferred queues command" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    const handle = try ctx.spawn("living", .{
        Position{ .x = 0, .y = 0 },
        Health{ .current = 100, .max = 100 },
    });

    // Queue deferred component set
    try testing.expect(ctx.setComponentDeferred(handle, Health, Health{ .current = 75, .max = 100 }));

    // Original value should be unchanged (command not executed yet)
    const health = ctx.getComponent(handle, Health);
    try testing.expectEqual(@as(u32, 100), health.?.current);

    // Verify command was queued
    const cmds = commands.getCommands();
    try testing.expectEqual(@as(usize, 1), cmds.len);
}

test "SystemContext - customCommand queues command" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    try testing.expect(ctx.customCommand(42, null));
    try testing.expect(ctx.customCommand(99, null));

    const cmds = commands.getCommands();
    try testing.expectEqual(@as(usize, 2), cmds.len);
}

test "SystemContext - isCommandBufferFull detects full buffer" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    try testing.expect(!ctx.isCommandBufferFull());

    // Fill buffer to capacity (50 commands)
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const result = ctx.customCommand(@intCast(i), null);
        if (i < 50) {
            try testing.expect(result);
        }
    }

    try testing.expect(ctx.isCommandBufferFull());

    // Additional command should fail
    try testing.expect(!ctx.customCommand(999, null));
}

test "SystemContext - command buffer overflow handling" {
    // Standalone command buffer test - doesn't need world

    // Use a very small buffer for overflow testing
    const SmallCmdBuf = CommandBufferType(3, 64);
    var small_buf = SmallCmdBuf.init();

    // Fill the buffer
    try testing.expect(small_buf.custom(1, null));
    try testing.expect(small_buf.custom(2, null));
    try testing.expect(small_buf.custom(3, null));
    try testing.expect(small_buf.isFull());

    // Overflow attempts should return false
    try testing.expect(!small_buf.custom(4, null));
    try testing.expect(!small_buf.custom(5, null));

    // Buffer should still have exactly 3 commands
    try testing.expectEqual(@as(usize, 3), small_buf.getCommands().len);
}

// ============================================================================
// Resource Access Tests
// ============================================================================

test "SystemContext - getResource returns null for uninitialized" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    // No resources initialized yet
    try testing.expect(ctx.getResource(GameState) == null);
    try testing.expect(ctx.getResource(PlayerStats) == null);
}

test "SystemContext - insertResource and getResource" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    // Insert game state
    ctx.insertResource(GameState, GameState{
        .level = 1,
        .score = 0,
        .paused = false,
    });

    // Retrieve and verify
    const state = ctx.getResource(GameState);
    try testing.expect(state != null);
    try testing.expectEqual(@as(u32, 1), state.?.level);
    try testing.expectEqual(@as(u64, 0), state.?.score);
    try testing.expect(!state.?.paused);
}

test "SystemContext - getResourceConst for read-only access" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();

    // Insert resource before creating context
    _ = resources.insert(PlayerStats, PlayerStats{ .kills = 10, .deaths = 2 });

    const ctx = createTestContext(&world, &resources, &commands);

    // Get const pointer
    const stats = ctx.getResourceConst(PlayerStats);
    try testing.expect(stats != null);
    try testing.expectEqual(@as(u32, 10), stats.?.kills);
    try testing.expectEqual(@as(u32, 2), stats.?.deaths);
}

test "SystemContext - hasResource checks correctly" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    try testing.expect(!ctx.hasResource(GameState));
    try testing.expect(!ctx.hasResource(PlayerStats));

    ctx.insertResource(GameState, GameState{ .level = 1, .score = 0, .paused = false });

    try testing.expect(ctx.hasResource(GameState));
    try testing.expect(!ctx.hasResource(PlayerStats));
}

test "SystemContext - modify resource through pointer" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    ctx.insertResource(GameState, GameState{ .level = 1, .score = 0, .paused = false });

    // Modify through mutable pointer
    const state = ctx.getResource(GameState).?;
    state.level = 5;
    state.score = 1000;
    state.paused = true;

    // Verify changes persisted
    const state_after = ctx.getResourceConst(GameState).?;
    try testing.expectEqual(@as(u32, 5), state_after.level);
    try testing.expectEqual(@as(u64, 1000), state_after.score);
    try testing.expect(state_after.paused);
}

// ============================================================================
// I/O Context Tests
// ============================================================================

test "SystemContext - getIo returns null when not initialized" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    try testing.expect(ctx.getIo() == null);
}

test "SystemContext - hasIo returns false when not initialized" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    const ctx = createTestContext(&world, &resources, &commands);

    try testing.expect(!ctx.hasIo());
}

test "SystemContext - getIo returns context when initialized" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var io_context = IoContext.blocking();

    var ctx = TestContext.initWithIo(
        &world,
        &resources,
        0.016,
        0,
        0,
        &commands,
        testing.allocator,
        &io_context,
    );

    const io = ctx.getIo();
    try testing.expect(io != null);
    try testing.expect(io == &io_context);
}

test "SystemContext - hasIo returns true when initialized" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var io_context = IoContext.blocking();

    const ctx = TestContext.initWithIo(
        &world,
        &resources,
        0.016,
        0,
        0,
        &commands,
        testing.allocator,
        &io_context,
    );

    try testing.expect(ctx.hasIo());
}

test "SystemContext - hasAsync returns false for blocking backend" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var io_context = IoContext.blocking();

    const ctx = TestContext.initWithIo(
        &world,
        &resources,
        0.016,
        0,
        0,
        &commands,
        testing.allocator,
        &io_context,
    );

    try testing.expect(!ctx.hasAsync());
}

test "SystemContext - hasConcurrency returns false for blocking backend" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var io_context = IoContext.blocking();

    const ctx = TestContext.initWithIo(
        &world,
        &resources,
        0.016,
        0,
        0,
        &commands,
        testing.allocator,
        &io_context,
    );

    try testing.expect(!ctx.hasConcurrency());
}

test "SystemContext - hasAsync/Concurrency returns false without I/O" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    const ctx = createTestContext(&world, &resources, &commands);

    try testing.expect(!ctx.hasAsync());
    try testing.expect(!ctx.hasConcurrency());
}

// ============================================================================
// Delta Time / Frame Info Tests
// ============================================================================

test "SystemContext - delta_time access" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();

    // Test various delta time values
    const deltas = [_]f64{ 0.016, 0.033, 0.001, 1.0, 0.0 };

    for (deltas) |delta| {
        const ctx = TestContext.init(
            &world,
            &resources,
            delta,
            0,
            0,
            &commands,
            testing.allocator,
        );
        try testing.expectEqual(delta, ctx.delta_time);
    }
}

test "SystemContext - tick counter access" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();

    // Test various tick values
    const ticks = [_]u64{ 0, 1, 100, 1000, std.math.maxInt(u64) };

    for (ticks) |tick| {
        const ctx = TestContext.init(
            &world,
            &resources,
            0.016,
            tick,
            0,
            &commands,
            testing.allocator,
        );
        try testing.expectEqual(tick, ctx.tick);
    }
}

test "SystemContext - time_ns access" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();

    // Test various time values (in nanoseconds)
    const times = [_]u64{
        0,
        1_000_000, // 1ms
        1_000_000_000, // 1s
        60_000_000_000, // 1min
    };

    for (times) |time| {
        const ctx = TestContext.init(
            &world,
            &resources,
            0.016,
            0,
            time,
            &commands,
            testing.allocator,
        );
        try testing.expectEqual(time, ctx.time_ns);
    }
}

test "SystemContext - allocator access" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    const ctx = createTestContext(&world, &resources, &commands);

    // Verify allocator is accessible and functional
    const mem = try ctx.allocator.alloc(u8, 100);
    defer ctx.allocator.free(mem);

    try testing.expectEqual(@as(usize, 100), mem.len);
}

// ============================================================================
// Combined Workflow Tests
// ============================================================================

test "SystemContext - typical system workflow" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var resources = TestResources.init();
    var commands = TestCmdBuf.init();
    var ctx = createTestContext(&world, &resources, &commands);

    // Initialize resources
    ctx.insertResource(GameState, GameState{ .level = 1, .score = 0, .paused = false });

    // Spawn some entities
    const entity1 = try ctx.spawn("moving", .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .dx = 1, .dy = 0 },
    });
    const entity2 = try ctx.spawn("living", .{
        Position{ .x = 10, .y = 10 },
        Health{ .current = 100, .max = 100 },
    });

    // Read and modify components
    const pos = ctx.getComponentMut(entity1, Position).?;
    const delta_f32: f32 = @floatCast(ctx.delta_time);
    pos.x += delta_f32 * ctx.getComponent(entity1, Velocity).?.dx;

    // Update resource
    const state = ctx.getResource(GameState).?;
    state.score += 10;

    // Queue deferred operations
    _ = ctx.setComponentDeferred(entity2, Health, Health{ .current = 90, .max = 100 });

    // Verify state
    try testing.expect(ctx.isAlive(entity1));
    try testing.expect(ctx.isAlive(entity2));
    try testing.expectEqual(@as(u64, 10), ctx.getResourceConst(GameState).?.score);
    try testing.expectEqual(@as(usize, 1), commands.getCommands().len);
}
