//! Fuzz Testing for StaticECS
//!
//! This module provides deterministic fuzz-style tests for the ECS core operations.
//! These tests exercise random-like sequences of operations to find edge cases.
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

const ecs = @import("../ecs.zig");
const WorldConfig = ecs.WorldConfig;

// ============================================================================
// Test Components
// ============================================================================

const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

const Velocity = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    dz: f32 = 0,
};

const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
};

// ============================================================================
// Fuzz Test Configuration
// ============================================================================

const FuzzConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
            .{ .name = "moving", .components = &.{ Position, Velocity } },
            .{ .name = "living", .components = &.{ Position, Health } },
            .{ .name = "full", .components = &.{ Position, Velocity, Health } },
        },
    },
    .options = .{
        .max_entities = 128, // Small for faster fuzzing
        .enable_debug_asserts = true,
    },
};

const FuzzWorld = ecs.World(FuzzConfig);

// ============================================================================
// Deterministic Fuzz Tests
// ============================================================================

test "fuzz: spawn until capacity then despawn all" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    var handles: [128]ecs.entity.EntityHandle = undefined;
    var count: usize = 0;

    // Spawn until capacity - use "static" archetype only
    while (count < 128) {
        if (world.spawn("static", .{Position{ .x = @floatFromInt(count), .y = 0, .z = 0 }})) |handle| {
            handles[count] = handle;
            count += 1;
        } else |_| {
            break;
        }
    }

    // Should have spawned many entities
    try testing.expect(count > 100);

    // Despawn in reverse order
    while (count > 0) {
        count -= 1;
        try world.despawn(handles[count]);
    }

    // World should be empty
    try testing.expectEqual(@as(u32, 0), world.entityCount());
}

test "fuzz: interleaved spawn and despawn" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    var prng = std.Random.DefaultPrng.init(12345);
    var handles: [64]ecs.entity.EntityHandle = undefined;
    var active_count: usize = 0;

    // Perform 200 operations
    for (0..200) |i| {
        const rand_val = prng.random().uintLessThan(u8, 100);

        if (rand_val < 70 and active_count < 64) {
            // 70% chance to spawn (if space available)
            if (world.spawn("static", .{Position{ .x = @floatFromInt(i), .y = 0, .z = 0 }})) |handle| {
                handles[active_count] = handle;
                active_count += 1;
            } else |_| {}
        } else if (active_count > 0) {
            // 30% chance to despawn (if entities exist)
            active_count -= 1;
            world.despawn(handles[active_count]) catch {};
        }
    }

    // Verify remaining entities are alive
    for (0..active_count) |i| {
        try testing.expect(world.isAlive(handles[i]));
    }
}

test "fuzz: spawn different archetypes" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    var handles: [80]ecs.entity.EntityHandle = undefined;
    var count: usize = 0;

    // Spawn 20 of each archetype
    for (0..20) |i| {
        const x: f32 = @floatFromInt(i);
        handles[count] = try world.spawn("static", .{Position{ .x = x, .y = 0, .z = 0 }});
        count += 1;
    }

    for (0..20) |i| {
        const x: f32 = @floatFromInt(i + 20);
        handles[count] = try world.spawn("moving", .{ Position{ .x = x, .y = 0, .z = 0 }, Velocity{ .dx = 1, .dy = 0, .dz = 0 } });
        count += 1;
    }

    for (0..20) |i| {
        const x: f32 = @floatFromInt(i + 40);
        handles[count] = try world.spawn("living", .{ Position{ .x = x, .y = 0, .z = 0 }, Health{ .current = 100, .max = 100 } });
        count += 1;
    }

    for (0..20) |i| {
        const x: f32 = @floatFromInt(i + 60);
        handles[count] = try world.spawn("full", .{ Position{ .x = x, .y = 0, .z = 0 }, Velocity{}, Health{} });
        count += 1;
    }

    try testing.expectEqual(@as(usize, 80), count);
    try testing.expectEqual(@as(u32, 80), world.entityCount());

    // All entities should be alive
    for (handles[0..count]) |handle| {
        try testing.expect(world.isAlive(handle));
    }
}

test "fuzz: component mutations" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities with all components
    var handles: [30]ecs.entity.EntityHandle = undefined;
    for (0..30) |i| {
        handles[i] = try world.spawn("full", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
            Health{ .current = 100, .max = 100 },
        });
    }

    var prng = std.Random.DefaultPrng.init(99999);

    // Perform many random mutations
    for (0..500) |_| {
        const idx = prng.random().uintLessThan(usize, 30);
        const handle = handles[idx];

        // Mutate Position
        const new_x = @as(f32, @floatFromInt(prng.random().int(i16)));
        _ = world.setComponent(handle, Position, Position{ .x = new_x, .y = 0, .z = 0 });
    }

    // Verify all entities still valid and have correct components
    for (handles) |handle| {
        try testing.expect(world.isAlive(handle));
        try testing.expect(world.hasComponent(handle, Position));
        try testing.expect(world.hasComponent(handle, Velocity));
        try testing.expect(world.hasComponent(handle, Health));
    }
}

test "fuzz: entity slot reuse" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    // Repeat spawn-despawn cycle to exercise slot reuse
    for (0..5) |_| {
        var handles: [20]ecs.entity.EntityHandle = undefined;

        // Spawn batch
        for (0..20) |i| {
            handles[i] = try world.spawn("static", .{Position{}});
        }

        try testing.expectEqual(@as(u32, 20), world.entityCount());

        // Despawn all
        for (handles) |h| {
            try world.despawn(h);
        }

        try testing.expectEqual(@as(u32, 0), world.entityCount());

        // Old handles should be invalid (generation changed)
        for (handles) |h| {
            try testing.expect(!world.isAlive(h));
        }
    }
}

test "fuzz: rapid spawn-despawn same slot" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    // Rapidly spawn and despawn single entities
    for (0..100) |i| {
        const handle = try world.spawn("static", .{Position{ .x = @floatFromInt(i), .y = 0, .z = 0 }});
        try testing.expect(world.isAlive(handle));
        try world.despawn(handle);
        try testing.expect(!world.isAlive(handle));
    }
}

// ============================================================================
// Property-Based Tests
// ============================================================================

test "property: spawn always increases count" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    for (0..50) |_| {
        const before = world.entityCount();
        _ = try world.spawn("static", .{Position{}});
        const after = world.entityCount();
        try testing.expectEqual(before + 1, after);
    }
}

test "property: despawn always decreases count" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    // First spawn some entities
    var handles: [50]ecs.entity.EntityHandle = undefined;
    for (0..50) |i| {
        handles[i] = try world.spawn("static", .{Position{}});
    }

    // Then despawn them and verify count decreases
    for (handles) |handle| {
        const before = world.entityCount();
        try world.despawn(handle);
        const after = world.entityCount();
        try testing.expectEqual(before - 1, after);
    }
}

test "property: getComponent returns set value" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    const handle = try world.spawn("static", .{Position{ .x = 1.0, .y = 2.0, .z = 3.0 }});

    const pos = world.getComponent(handle, Position).?;
    try testing.expectEqual(@as(f32, 1.0), pos.x);
    try testing.expectEqual(@as(f32, 2.0), pos.y);
    try testing.expectEqual(@as(f32, 3.0), pos.z);

    // Set and verify new value
    _ = world.setComponent(handle, Position, Position{ .x = 10.0, .y = 20.0, .z = 30.0 });

    const pos2 = world.getComponent(handle, Position).?;
    try testing.expectEqual(@as(f32, 10.0), pos2.x);
    try testing.expectEqual(@as(f32, 20.0), pos2.y);
    try testing.expectEqual(@as(f32, 30.0), pos2.z);
}

test "property: hasComponent reflects actual state" {
    var world = FuzzWorld.init(testing.allocator);
    defer world.deinit();

    const handle = try world.spawn("static", .{Position{}});

    // Has Position, doesn't have Velocity or Health
    try testing.expect(world.hasComponent(handle, Position));
    try testing.expect(!world.hasComponent(handle, Velocity));
    try testing.expect(!world.hasComponent(handle, Health));
}
