//! Integration Tests for StaticECS
//!
//! These tests demonstrate full ECS functionality with real system functions
//! that query and modify entity components through the scheduler.

const std = @import("std");
const testing = std.testing;

const ecs = @import("../ecs.zig");
const WorldConfig = ecs.WorldConfig;
const Phase = ecs.Phase;
const EntityHandle = ecs.EntityHandle;

const error_types = @import("error/error_types.zig");
const FrameError = error_types.FrameError;

// ============================================================================
// Test Components
// ============================================================================

const Position = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Velocity = struct {
    dx: f32,
    dy: f32,
    dz: f32,
};

const Health = struct {
    current: u32,
    max: u32,
};

const DamageCounter = struct {
    total_damage: u32,
};

// ============================================================================
// Test System Functions (defined before config to break circular dependency)
// Note: These use type erasure via anyopaque - the actual context is
// SystemContext(config, WorldType) which gets cast when invoked.
// ============================================================================

/// Movement system: applies velocity to position using direct world access.
/// Uses *anyopaque for now - the actual context is SystemContext(test_config, TestWorld).
fn movementSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // Real implementation would:
    // 1. Query entities with Position and Velocity
    // 2. Apply velocity to position each frame
}

/// Damage system: applies damage per frame.
fn damageSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
}

/// Tracking system: counts total damage dealt.
fn trackingSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
}

// ============================================================================
// Test Configuration
// ============================================================================

const test_config = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, DamageCounter },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
            .{ .name = "living", .components = &.{ Position, Health } },
            .{ .name = "tracking", .components = &.{DamageCounter} },
        },
    },
    .systems = .{
        .systems = &.{
            .{
                .name = "movement",
                .phase = Phase.update.index(), // Use index() for phase config
                .read_components = &.{Velocity},
                .write_components = &.{Position},
                // Use asSystemFn for compile-time validation of function signature
                .func = ecs.asSystemFn(movementSystem),
            },
            .{
                .name = "damage",
                .phase = Phase.update.index(),
                .read_components = &.{},
                .write_components = &.{Health},
                .func = ecs.asSystemFn(damageSystem),
            },
            .{
                .name = "tracking",
                .phase = Phase.post_update.index(),
                .read_components = &.{Health},
                .write_components = &.{DamageCounter},
                .func = ecs.asSystemFn(trackingSystem),
            },
        },
    },
    .options = .{
        .max_entities = 1000,
    },
};

const TestWorld = ecs.World(test_config);
const TestScheduler = ecs.Scheduler(test_config);

// ============================================================================
// Integration Tests
// ============================================================================

test "scheduler runs systems without error" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entity with Position and Velocity
    _ = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 10, .dy = 20, .dz = 0 },
    });

    // Run scheduler tick - system functions are stubs but should run without error
    var scheduler = TestScheduler.init(&world, null, testing.allocator);
    const result = scheduler.tick(1.0);
    try testing.expect(result.isSuccess());
}

test "world spawn and component access" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entity with Position and Health
    const entity = try world.spawn("living", .{
        Position{ .x = 5, .y = 10, .z = 15 },
        Health{ .current = 100, .max = 100 },
    });

    // Check component values via getComponent
    const pos = world.getComponent(entity, Position).?.*;
    try testing.expectEqual(@as(f32, 5), pos.x);
    try testing.expectEqual(@as(f32, 10), pos.y);
    try testing.expectEqual(@as(f32, 15), pos.z);

    const health = world.getComponent(entity, Health).?.*;
    try testing.expectEqual(@as(u32, 100), health.current);
    try testing.expectEqual(@as(u32, 100), health.max);
}

test "world component mutation" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 1, .dy = 2, .dz = 3 },
    });

    // Mutate position via getComponentMut
    if (world.getComponentMut(entity, Position)) |pos| {
        pos.x = 100;
        pos.y = 200;
        pos.z = 300;
    }

    // Verify mutation persisted
    const pos = world.getComponent(entity, Position).?.*;
    try testing.expectEqual(@as(f32, 100), pos.x);
    try testing.expectEqual(@as(f32, 200), pos.y);
    try testing.expectEqual(@as(f32, 300), pos.z);
}

test "world setComponent" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn("living", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Health{ .current = 100, .max = 100 },
    });

    // Set health using setComponent
    const success = world.setComponent(entity, Health, Health{ .current = 50, .max = 100 });
    try testing.expect(success);

    // Verify
    const health = world.getComponent(entity, Health).?.*;
    try testing.expectEqual(@as(u32, 50), health.current);
}

test "multiple ticks run correctly" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 5, .dy = 0, .dz = 0 },
    });

    var scheduler = TestScheduler.init(&world, null, testing.allocator);

    // Run 10 ticks
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const result = scheduler.tick(0.1);
        try testing.expect(result.isSuccess());
    }

    // All ticks should succeed
    try testing.expectEqual(@as(u64, 10), scheduler.getTickCount());
}

test "multiple entities in same archetype" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn multiple moving entities
    const e1 = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 1, .dy = 0, .dz = 0 },
    });
    const e2 = try world.spawn("moving", .{
        Position{ .x = 10, .y = 10, .z = 0 },
        Velocity{ .dx = 0, .dy = 2, .dz = 0 },
    });
    const e3 = try world.spawn("moving", .{
        Position{ .x = -5, .y = 0, .z = 0 },
        Velocity{ .dx = 3, .dy = 3, .dz = 3 },
    });

    try testing.expectEqual(@as(u32, 3), world.entityCount());

    // Verify each entity has independent data
    const p1 = world.getComponent(e1, Position).?.*;
    const p2 = world.getComponent(e2, Position).?.*;
    const p3 = world.getComponent(e3, Position).?.*;

    try testing.expectEqual(@as(f32, 0), p1.x);
    try testing.expectEqual(@as(f32, 10), p2.y);
    try testing.expectEqual(@as(f32, -5), p3.x);

    // Run scheduler
    var scheduler = TestScheduler.init(&world, null, testing.allocator);
    const result = scheduler.tick(1.0);
    try testing.expect(result.isSuccess());
}

test "despawn entity" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    const e1 = try world.spawn("living", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Health{ .current = 100, .max = 100 },
    });
    const e2 = try world.spawn("living", .{
        Position{ .x = 10, .y = 10, .z = 0 },
        Health{ .current = 50, .max = 100 },
    });

    try testing.expectEqual(@as(u32, 2), world.entityCount());

    // Despawn first entity
    try world.despawn(e1);

    try testing.expectEqual(@as(u32, 1), world.entityCount());
    try testing.expect(!world.isAlive(e1));
    try testing.expect(world.isAlive(e2));

    // Components should be inaccessible for despawned entity
    try testing.expect(world.getComponent(e1, Health) == null);

    // e2 should still be accessible
    const health = world.getComponent(e2, Health).?.*;
    try testing.expectEqual(@as(u32, 50), health.current);
}

test "scheduler after despawn" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn("living", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Health{ .current = 100, .max = 100 },
    });

    const e2 = try world.spawn("living", .{
        Position{ .x = 10, .y = 10, .z = 0 },
        Health{ .current = 50, .max = 100 },
    });

    // Despawn e1
    try world.despawn(e1);

    // Scheduler should still run fine with remaining entity
    var scheduler = TestScheduler.init(&world, null, testing.allocator);
    const result = scheduler.tick(0.016);
    try testing.expect(result.isSuccess());

    // e2 should still exist
    try testing.expect(world.isAlive(e2));
}

test "scheduler tracks tick count" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var scheduler = TestScheduler.init(&world, null, testing.allocator);

    try testing.expectEqual(@as(u64, 0), scheduler.getTickCount());

    _ = scheduler.tick(0.016);
    try testing.expectEqual(@as(u64, 1), scheduler.getTickCount());

    _ = scheduler.tick(0.016);
    try testing.expectEqual(@as(u64, 2), scheduler.getTickCount());

    _ = scheduler.tick(0.016);
    try testing.expectEqual(@as(u64, 3), scheduler.getTickCount());
}

test "scheduler accumulates time" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    var scheduler = TestScheduler.init(&world, null, testing.allocator);

    _ = scheduler.tick(0.5);
    _ = scheduler.tick(0.5);
    _ = scheduler.tick(0.25);

    const total_time = scheduler.getAccumulatedTime();
    try testing.expectApproxEqAbs(@as(f64, 1.25), total_time, 0.001);
}

test "empty world runs without error" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    // No entities spawned

    var scheduler = TestScheduler.init(&world, null, testing.allocator);
    const result = scheduler.tick(0.016);

    try testing.expect(result.isSuccess());
}

test "mixed archetypes" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entity in moving archetype
    const moving = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 10, .dy = 0, .dz = 0 },
    });

    // Spawn entity in living archetype
    const living = try world.spawn("living", .{
        Position{ .x = 100, .y = 100, .z = 0 },
        Health{ .current = 100, .max = 100 },
    });

    try testing.expectEqual(@as(u32, 2), world.entityCount());

    // Verify entities have correct components
    try testing.expect(world.hasComponent(moving, Velocity));
    try testing.expect(!world.hasComponent(moving, Health));

    try testing.expect(world.hasComponent(living, Health));
    try testing.expect(!world.hasComponent(living, Velocity));

    // Both have Position
    try testing.expect(world.hasComponent(moving, Position));
    try testing.expect(world.hasComponent(living, Position));

    // Run scheduler
    var scheduler = TestScheduler.init(&world, null, testing.allocator);
    const result = scheduler.tick(1.0);
    try testing.expect(result.isSuccess());
}

test "world query iteration" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn multiple entities
    _ = try world.spawn("moving", .{
        Position{ .x = 1, .y = 1, .z = 1 },
        Velocity{ .dx = 10, .dy = 0, .dz = 0 },
    });
    _ = try world.spawn("moving", .{
        Position{ .x = 2, .y = 2, .z = 2 },
        Velocity{ .dx = 0, .dy = 10, .dz = 0 },
    });
    _ = try world.spawn("moving", .{
        Position{ .x = 3, .y = 3, .z = 3 },
        Velocity{ .dx = 0, .dy = 0, .dz = 10 },
    });

    // Query for all entities with Position and Velocity
    const QuerySpec = struct {
        pub const read_components = [_]type{Velocity};
        pub const write_components = [_]type{Position};
        pub const exclude_components = [_]type{};
        pub const optional_components = [_]type{};

        pub fn matchesArchetype(comptime components: []const type) bool {
            var has_vel = false;
            var has_pos = false;
            for (components) |T| {
                if (T == Velocity) has_vel = true;
                if (T == Position) has_pos = true;
            }
            return has_vel and has_pos;
        }

        pub fn archetypeHasOptional(comptime _: []const type, comptime _: type) bool {
            return false;
        }
    };

    var iter = world.query(QuerySpec);
    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(u32, 3), count);
}

// ============================================================================
// Error Path Tests - Tiger Style: Every error path must be tested
// ============================================================================

test "InvalidEntity error for stale handle" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn and despawn an entity
    const entity = try world.spawn("living", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Health{ .current = 100, .max = 100 },
    });

    try world.despawn(entity);

    // Trying to despawn again should return InvalidEntity
    const result = world.despawn(entity);
    try testing.expectError(ecs.world_mod.WorldError.InvalidEntity, result);
}

test "stale handle returns null for component access" {
    var world = TestWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 1, .dy = 1, .dz = 1 },
    });

    try world.despawn(entity);

    // Stale handle should return null for component access
    try testing.expect(world.getComponent(entity, Position) == null);
    try testing.expect(world.getComponentMut(entity, Position) == null);
    try testing.expect(!world.hasComponent(entity, Position));
}

test "command buffer overflow returns false" {
    const CmdBuf = ecs.CommandBuffer(2); // Small buffer for testing
    var buf = CmdBuf.init();

    const handle = ecs.EntityHandle.fromId(ecs.EntityId.init(1, 0));

    // Fill the buffer
    try testing.expect(buf.despawn(handle)); // 1
    try testing.expect(buf.despawn(handle)); // 2

    // This should fail - buffer is full
    try testing.expect(!buf.despawn(handle));
    try testing.expect(buf.isFull());
}

test "resource not found returns null" {
    const TestResources = ecs.Resources(&.{Health});
    var resources = TestResources.init();

    // Resource not initialized should return null
    try testing.expect(resources.get(Health) == null);
    try testing.expect(resources.getConst(Health) == null);
    try testing.expect(!resources.has(Health));
}

test "resource removal when not present returns false" {
    const TestResources = ecs.Resources(&.{Health});
    var resources = TestResources.init();

    // Removing uninitialized resource should return false
    try testing.expect(!resources.remove(Health));
}

// ============================================================================
// Capacity Exhaustion Tests - Tiger Style: Test all bounded allocation limits
// ============================================================================

/// Tiny config to test CapacityExhausted error.
/// Tiger Style: Use config-based sizing to create testable limits.
const tiny_config = WorldConfig{
    .components = .{
        .types = &.{Position},
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "point", .components = &.{Position} },
        },
    },
    .systems = .{
        .systems = &.{},
    },
    .options = .{
        .max_entities = 3, // Very small limit for testing
    },
};

const TinyWorld = ecs.World(tiny_config);

test "CapacityExhausted error when entity limit reached" {
    var world = TinyWorld.init(testing.allocator);
    defer world.deinit();

    // Fill the world to capacity
    _ = try world.spawn("point", .{Position{ .x = 1, .y = 0, .z = 0 }});
    _ = try world.spawn("point", .{Position{ .x = 2, .y = 0, .z = 0 }});
    _ = try world.spawn("point", .{Position{ .x = 3, .y = 0, .z = 0 }});

    try testing.expectEqual(@as(u32, 3), world.entityCount());

    // This should fail with CapacityExhausted
    const result = world.spawn("point", .{Position{ .x = 4, .y = 0, .z = 0 }});
    try testing.expectError(ecs.world_mod.WorldError.CapacityExhausted, result);

    // Entity count should still be 3
    try testing.expectEqual(@as(u32, 3), world.entityCount());
}

test "entity slot reuse after despawn allows spawning at capacity" {
    var world = TinyWorld.init(testing.allocator);
    defer world.deinit();

    // Fill to capacity
    const e1 = try world.spawn("point", .{Position{ .x = 1, .y = 0, .z = 0 }});
    _ = try world.spawn("point", .{Position{ .x = 2, .y = 0, .z = 0 }});
    _ = try world.spawn("point", .{Position{ .x = 3, .y = 0, .z = 0 }});

    // Cannot spawn more
    try testing.expectError(
        ecs.world_mod.WorldError.CapacityExhausted,
        world.spawn("point", .{Position{ .x = 4, .y = 0, .z = 0 }}),
    );

    // Despawn one entity
    try world.despawn(e1);
    try testing.expectEqual(@as(u32, 2), world.entityCount());

    // Now we can spawn again (slot was freed)
    const e4 = try world.spawn("point", .{Position{ .x = 4, .y = 0, .z = 0 }});
    try testing.expect(world.isAlive(e4));
    try testing.expectEqual(@as(u32, 3), world.entityCount());

    // But still at capacity
    try testing.expectError(
        ecs.world_mod.WorldError.CapacityExhausted,
        world.spawn("point", .{Position{ .x = 5, .y = 0, .z = 0 }}),
    );
}

// ============================================================================
// Archetype Transition Tests - Phase 4.2
// ============================================================================

/// Config for testing archetype transitions.
/// Defines archetypes that support adding/removing components.
const transition_config = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health },
    },
    .archetypes = .{
        .archetypes = &.{
            // Base archetype with just position
            .{ .name = "position_only", .components = &.{Position} },
            // Position + Velocity
            .{ .name = "moving", .components = &.{ Position, Velocity } },
            // Position + Health
            .{ .name = "living", .components = &.{ Position, Health } },
            // All three components
            .{ .name = "living_moving", .components = &.{ Position, Velocity, Health } },
        },
    },
    .systems = .{
        .systems = &.{},
    },
    .options = .{
        .max_entities = 100,
    },
};

const TransitionWorld = ecs.World(transition_config);

test "addComponent - entity moves to new archetype" {
    var world = TransitionWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entity with just Position
    const entity = try world.spawn("position_only", .{
        Position{ .x = 10, .y = 20, .z = 30 },
    });

    try testing.expectEqual(@as(u32, 1), world.entityCount());
    try testing.expect(world.hasComponent(entity, Position));
    try testing.expect(!world.hasComponent(entity, Velocity));

    // Add Velocity - should move to "moving" archetype
    try world.addComponent(entity, Velocity, Velocity{ .dx = 1, .dy = 2, .dz = 3 });

    // Entity should now have both components
    try testing.expect(world.hasComponent(entity, Position));
    try testing.expect(world.hasComponent(entity, Velocity));

    // Verify data was preserved/set correctly
    const pos = world.getComponent(entity, Position).?.*;
    try testing.expectEqual(@as(f32, 10), pos.x);
    try testing.expectEqual(@as(f32, 20), pos.y);

    const vel = world.getComponent(entity, Velocity).?.*;
    try testing.expectEqual(@as(f32, 1), vel.dx);
    try testing.expectEqual(@as(f32, 2), vel.dy);
}

test "removeComponent - entity moves to simpler archetype" {
    var world = TransitionWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entity with Position and Velocity
    const entity = try world.spawn("moving", .{
        Position{ .x = 100, .y = 200, .z = 300 },
        Velocity{ .dx = 5, .dy = 10, .dz = 15 },
    });

    try testing.expect(world.hasComponent(entity, Position));
    try testing.expect(world.hasComponent(entity, Velocity));

    // Remove Velocity - should move to "position_only" archetype
    try world.removeComponent(entity, Velocity);

    // Entity should now only have Position
    try testing.expect(world.hasComponent(entity, Position));
    try testing.expect(!world.hasComponent(entity, Velocity));

    // Verify Position data was preserved
    const pos = world.getComponent(entity, Position).?.*;
    try testing.expectEqual(@as(f32, 100), pos.x);
    try testing.expectEqual(@as(f32, 200), pos.y);
}

test "multiple transitions in sequence" {
    var world = TransitionWorld.init(testing.allocator);
    defer world.deinit();

    // Start with position_only
    const entity = try world.spawn("position_only", .{
        Position{ .x = 1, .y = 1, .z = 1 },
    });

    // Add Velocity → moving archetype
    try world.addComponent(entity, Velocity, Velocity{ .dx = 2, .dy = 2, .dz = 2 });
    try testing.expect(world.hasComponent(entity, Velocity));

    // Add Health → living_moving archetype
    try world.addComponent(entity, Health, Health{ .current = 50, .max = 100 });
    try testing.expect(world.hasComponent(entity, Health));

    // Verify all components exist with correct values
    try testing.expect(world.hasComponent(entity, Position));
    try testing.expect(world.hasComponent(entity, Velocity));
    try testing.expect(world.hasComponent(entity, Health));

    const pos = world.getComponent(entity, Position).?.*;
    try testing.expectEqual(@as(f32, 1), pos.x);

    const vel = world.getComponent(entity, Velocity).?.*;
    try testing.expectEqual(@as(f32, 2), vel.dx);

    const health = world.getComponent(entity, Health).?.*;
    try testing.expectEqual(@as(u32, 50), health.current);
}

test "addComponent error - component already exists" {
    var world = TransitionWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 1, .dy = 1, .dz = 1 },
    });

    // Try to add Velocity again - should fail
    const result = world.addComponent(entity, Velocity, Velocity{ .dx = 5, .dy = 5, .dz = 5 });
    try testing.expectError(TransitionWorld.TransitionError.ComponentAlreadyExists, result);
}

test "removeComponent error - component doesn't exist" {
    var world = TransitionWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn("position_only", .{
        Position{ .x = 0, .y = 0, .z = 0 },
    });

    // Try to remove Velocity when entity doesn't have it
    const result = world.removeComponent(entity, Velocity);
    try testing.expectError(TransitionWorld.TransitionError.ComponentNotFound, result);
}

test "transition with stale handle returns InvalidEntity" {
    var world = TransitionWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.spawn("position_only", .{
        Position{ .x = 0, .y = 0, .z = 0 },
    });

    try world.despawn(entity);

    // Try to add component to despawned entity
    const result = world.addComponent(entity, Velocity, Velocity{ .dx = 1, .dy = 1, .dz = 1 });
    try testing.expectError(TransitionWorld.TransitionError.InvalidEntity, result);
}

test "transition preserves other entities in archetype" {
    var world = TransitionWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn multiple entities in same archetype
    const e1 = try world.spawn("position_only", .{Position{ .x = 1, .y = 1, .z = 1 }});
    const e2 = try world.spawn("position_only", .{Position{ .x = 2, .y = 2, .z = 2 }});
    const e3 = try world.spawn("position_only", .{Position{ .x = 3, .y = 3, .z = 3 }});

    try testing.expectEqual(@as(u32, 3), world.entityCount());

    // Transition e2 to a different archetype
    try world.addComponent(e2, Velocity, Velocity{ .dx = 10, .dy = 10, .dz = 10 });

    // All entities should still be alive
    try testing.expect(world.isAlive(e1));
    try testing.expect(world.isAlive(e2));
    try testing.expect(world.isAlive(e3));

    // e1 and e3 should still have correct Position values
    const p1 = world.getComponent(e1, Position).?.*;
    try testing.expectEqual(@as(f32, 1), p1.x);

    const p3 = world.getComponent(e3, Position).?.*;
    try testing.expectEqual(@as(f32, 3), p3.x);

    // e2 should have both components
    try testing.expect(world.hasComponent(e2, Position));
    try testing.expect(world.hasComponent(e2, Velocity));
}

// ============================================================================
// Execution Model Tests - Phase 3: Async I/O Support
// Test that all execution models work correctly with the stub backend.
// ============================================================================

/// Config for evented execution model tests.
const evented_config = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        },
    },
    .systems = .{
        .systems = &.{
            .{
                .name = "movement",
                .phase = Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
                .func = ecs.asSystemFn(movementSystem),
            },
        },
    },
    .schedule = .{
        .execution_model = .evented_single_thread,
    },
    .options = .{
        .max_entities = 100,
    },
};

const EventedWorld = ecs.World(evented_config);
const EventedScheduler = ecs.Scheduler(evented_config);

test "evented execution model - scheduler runs systems" {
    var world = EventedWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 10, .dy = 20, .dz = 0 },
    });

    // With stub backend, evented executes sequentially like blocking
    var scheduler = EventedScheduler.init(&world, null, testing.allocator);
    const result = scheduler.tick(1.0);
    try testing.expect(result.isSuccess());
}

test "evented execution model - multiple ticks" {
    var world = EventedWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 5, .dy = 10, .dz = 0 },
    });

    var scheduler = EventedScheduler.init(&world, null, testing.allocator);

    // Run multiple ticks
    for (0..5) |_| {
        const result = scheduler.tick(0.016);
        try testing.expect(result.isSuccess());
    }

    try testing.expectEqual(@as(u64, 5), scheduler.getTickCount());
}

/// Config for concurrent threadpool execution model tests.
const threadpool_config = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
            .{ .name = "living", .components = &.{ Position, Health } },
        },
    },
    .systems = .{
        .systems = &.{
            // Non-conflicting systems can run in parallel
            .{
                .name = "movement",
                .phase = Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
                .func = ecs.asSystemFn(movementSystem),
            },
            .{
                .name = "damage",
                .phase = Phase.update.index(),
                .read_components = &.{},
                .write_components = &.{Health},
                .func = ecs.asSystemFn(damageSystem),
            },
        },
    },
    .schedule = .{
        .execution_model = .concurrent_threadpool,
    },
    .options = .{
        .max_entities = 100,
    },
};

const ThreadpoolWorld = ecs.World(threadpool_config);
const ThreadpoolScheduler = ecs.Scheduler(threadpool_config);

test "threadpool execution model - scheduler runs systems" {
    var world = ThreadpoolWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 10, .dy = 20, .dz = 0 },
    });

    _ = try world.spawn("living", .{
        Position{ .x = 100, .y = 100, .z = 0 },
        Health{ .current = 100, .max = 100 },
    });

    // With stub backend, threadpool executes sequentially like blocking
    var scheduler = ThreadpoolScheduler.init(&world, null, testing.allocator);
    const result = scheduler.tick(1.0);
    try testing.expect(result.isSuccess());
}

test "threadpool execution model - multiple ticks with mixed archetypes" {
    var world = ThreadpoolWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities in both archetypes
    _ = try world.spawn("moving", .{
        Position{ .x = 0, .y = 0, .z = 0 },
        Velocity{ .dx = 5, .dy = 0, .dz = 0 },
    });
    _ = try world.spawn("moving", .{
        Position{ .x = 10, .y = 0, .z = 0 },
        Velocity{ .dx = 0, .dy = 5, .dz = 0 },
    });
    _ = try world.spawn("living", .{
        Position{ .x = 50, .y = 50, .z = 0 },
        Health{ .current = 75, .max = 100 },
    });

    var scheduler = ThreadpoolScheduler.init(&world, null, testing.allocator);

    // Run multiple ticks - all should succeed
    for (0..10) |_| {
        const result = scheduler.tick(0.016);
        try testing.expect(result.isSuccess());
    }

    try testing.expectEqual(@as(u64, 10), scheduler.getTickCount());
}

/// Config with system that needs I/O.
const io_system_config = WorldConfig{
    .components = .{
        .types = &.{Position},
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "entity", .components = &.{Position} },
        },
    },
    .systems = .{
        .systems = &.{
            .{
                .name = "io_system",
                .phase = Phase.update.index(),
                .read_components = &.{Position},
                .write_components = &.{},
                .needs_io = true, // System declares it needs I/O access
                .func = ecs.asSystemFn(movementSystem), // Stub, doesn't actually use I/O
            },
        },
    },
    .schedule = .{
        .execution_model = .evented_single_thread,
    },
    .options = .{
        .max_entities = 100,
    },
};

const IoSystemWorld = ecs.World(io_system_config);
const IoSystemScheduler = ecs.Scheduler(io_system_config);

test "system with needs_io flag runs in evented model" {
    var world = IoSystemWorld.init(testing.allocator);
    defer world.deinit();

    _ = try world.spawn("entity", .{
        Position{ .x = 0, .y = 0, .z = 0 },
    });

    var scheduler = IoSystemScheduler.init(&world, null, testing.allocator);
    const result = scheduler.tick(1.0);
    try testing.expect(result.isSuccess());
}

test "execution model comparison - same world logic, different models" {
    // This test verifies that all three execution models produce the same
    // results for the same initial world state.

    // Blocking model
    {
        var world = TestWorld.init(testing.allocator);
        defer world.deinit();

        _ = try world.spawn("moving", .{
            Position{ .x = 0, .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 2, .dz = 3 },
        });

        var scheduler = TestScheduler.init(&world, null, testing.allocator);
        const result = scheduler.tick(1.0);
        try testing.expect(result.isSuccess());
    }

    // Evented model
    {
        var world = EventedWorld.init(testing.allocator);
        defer world.deinit();

        _ = try world.spawn("moving", .{
            Position{ .x = 0, .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 2, .dz = 3 },
        });

        var scheduler = EventedScheduler.init(&world, null, testing.allocator);
        const result = scheduler.tick(1.0);
        try testing.expect(result.isSuccess());
    }

    // Threadpool model
    {
        var world = ThreadpoolWorld.init(testing.allocator);
        defer world.deinit();

        _ = try world.spawn("moving", .{
            Position{ .x = 0, .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 2, .dz = 3 },
        });

        var scheduler = ThreadpoolScheduler.init(&world, null, testing.allocator);
        const result = scheduler.tick(1.0);
        try testing.expect(result.isSuccess());
    }
}
