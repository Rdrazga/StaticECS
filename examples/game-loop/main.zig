//! StaticECS Game Loop Example
//!
//! Demonstrates using StaticECS for a simple game:
//! - Entity component management with actual query iteration
//! - Multi-phase system execution
//! - Resource-based game state
//! - Velocity-based movement with delta time
//! - Entity spawning and despawning
//!
//! Run with: zig build run-example-game

const std = @import("std");
const ecs = @import("ecs");

const FrameError = ecs.FrameError;
const Phase = ecs.Phase;
const Query = ecs.query.Query;

// ============================================================================
// Components
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

/// Marker component for entities that should be despawned
const MarkedForDeath = struct {
    reason: enum { out_of_bounds, health_depleted, lifetime_expired },
};

// ============================================================================
// Resources
// ============================================================================

const GameState = struct {
    running: bool = true,
    frame_count: u64 = 0,
    entity_count: u32 = 0,
    entities_spawned: u32 = 0,
    entities_despawned: u32 = 0,
};

// ============================================================================
// Query Specifications
// ============================================================================

/// Query for entities with Position and Velocity (for movement)
const MovementQuery = Query(.{
    .read = &.{Velocity},
    .write = &.{Position},
});

/// Query for all entities with positions (for rendering/display)
const RenderQuery = Query(.{
    .read = &.{Position},
    .optional = &.{Health},
});

/// Query for entities with health to check for death
const HealthQuery = Query(.{
    .read = &.{Position},
    .write = &.{Health},
});

// ============================================================================
// System Functions (defined BEFORE config)
// ============================================================================

/// Movement system: Updates position based on velocity and delta time.
/// Demonstrates actual query iteration and component modification.
fn movementSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const dt: f32 = @floatCast(ctx.delta_time);

    // Query all entities with Position and Velocity
    var iter = ctx.world.query(MovementQuery);

    while (iter.next()) |const_result| {
        // Need mutable to call getWrite
        var result = const_result;

        // Read velocity (immutable access)
        const vel = result.getRead(Velocity);

        // Get mutable position pointer and update it
        const pos = result.getWrite(Position);
        pos.x += vel.dx * dt;
        pos.y += vel.dy * dt;
    }
}

/// Physics system: Applies bounds checking and "physics" like gravity.
/// Demonstrates conditional component access and modification.
fn physicsSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const bounds_min: f32 = -100.0;
    const bounds_max: f32 = 100.0;

    // Apply bounds checking to all entities with velocity
    var iter = ctx.world.query(MovementQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const pos = result.getWrite(Position);

        // Apply simple world bounds (wrap around)
        if (pos.x < bounds_min) pos.x = bounds_max;
        if (pos.x > bounds_max) pos.x = bounds_min;
        if (pos.y < bounds_min) pos.y = bounds_max;
        if (pos.y > bounds_max) pos.y = bounds_min;
    }
}

/// Render system: "Renders" entities by printing their state periodically.
/// Demonstrates read-only queries and optional components.
fn renderSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);

    // Only render every 20 frames to reduce output
    if (@mod(ctx.tick, 20) != 0) return;

    std.debug.print("\n--- Frame {} Render ---\n", .{ctx.tick});

    var entity_num: u32 = 0;
    var iter = ctx.world.query(RenderQuery);

    while (iter.next()) |result| {
        const pos = result.getRead(Position);
        const maybe_health = result.getOptional(Health);

        if (maybe_health) |health| {
            std.debug.print("  Entity {}: pos=({d:.1}, {d:.1}) health={}/{}\n", .{
                entity_num,
                pos.x,
                pos.y,
                health.current,
                health.max,
            });
        } else {
            std.debug.print("  Entity {}: pos=({d:.1}, {d:.1}) [no health]\n", .{
                entity_num,
                pos.x,
                pos.y,
            });
        }
        entity_num += 1;
    }
}

/// Game state system: Updates global game state and statistics.
/// Demonstrates resource access and modification.
fn gameStateSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const state = ctx.world.resources.get(GameState) orelse return;

    state.frame_count = ctx.tick;
    state.entity_count = ctx.world.entityCount();
}

/// Health decay system: Reduces health over time (simulating damage).
/// Demonstrates write access to components.
fn healthDecaySystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);

    // Only decay health every 10 frames
    if (@mod(ctx.tick, 10) != 0) return;

    var iter = ctx.world.query(HealthQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const health = result.getWrite(Health);

        // Reduce health by 1 each decay tick
        if (health.current > 0) {
            health.current -= 1;
        }
    }
}

// ============================================================================
// Configuration (defined AFTER systems)
// ============================================================================

pub const cfg = ecs.WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, MarkedForDeath },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "player", .components = &.{ Position, Velocity, Health } },
            .{ .name = "static", .components = &.{ Position, Health } },
            .{ .name = "projectile", .components = &.{ Position, Velocity } },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "movement", .func = ecs.asSystemFn(movementSystem), .phase = Phase.update.index() },
            .{ .name = "physics", .func = ecs.asSystemFn(physicsSystem), .phase = Phase.update.index() },
            .{ .name = "health_decay", .func = ecs.asSystemFn(healthDecaySystem), .phase = Phase.update.index() },
            .{ .name = "render", .func = ecs.asSystemFn(renderSystem), .phase = Phase.render.index() },
            .{ .name = "game_state", .func = ecs.asSystemFn(gameStateSystem), .phase = Phase.post_update.index() },
        },
    },
    .resources = .{
        .types = &.{GameState},
    },
    .options = .{
        .max_entities = 1000,
        .max_commands_per_frame = 128,
    },
};

// Types and helpers (after config)
const World = ecs.World(cfg);
const Scheduler = ecs.Scheduler(cfg);
const Context = ecs.SystemContext(cfg, World);

fn getContext(ctx_ptr: *anyopaque) *Context {
    return @ptrCast(@alignCast(ctx_ptr));
}

// ============================================================================
// Entity Spawning Helpers
// ============================================================================

/// Spawn a player entity with initial position and velocity
fn spawnPlayer(world: *World, x: f32, y: f32, vx: f32, vy: f32) !void {
    _ = try world.spawn("player", .{
        Position{ .x = x, .y = y },
        Velocity{ .dx = vx, .dy = vy },
        Health{ .current = 100, .max = 100 },
    });
}

/// Spawn a projectile with position and velocity
fn spawnProjectile(world: *World, x: f32, y: f32, vx: f32, vy: f32) !void {
    _ = try world.spawn("projectile", .{
        Position{ .x = x, .y = y },
        Velocity{ .dx = vx, .dy = vy },
    });
}

/// Spawn a static obstacle
fn spawnObstacle(world: *World, x: f32, y: f32, health: u32) !void {
    _ = try world.spawn("static", .{
        Position{ .x = x, .y = y },
        Health{ .current = health, .max = health },
    });
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    // Initialize resources
    _ = world.resources.insert(GameState, .{ .running = true });

    std.debug.print("StaticECS Game Loop Example\n", .{});
    std.debug.print("============================\n", .{});
    std.debug.print("Demonstrating:\n", .{});
    std.debug.print("  - Query iteration with component access\n", .{});
    std.debug.print("  - Velocity-based movement with delta time\n", .{});
    std.debug.print("  - Health decay system\n", .{});
    std.debug.print("  - Resource management\n\n", .{});

    // Spawn initial entities
    std.debug.print("Spawning initial entities...\n", .{});

    // Spawn player at origin, moving diagonally
    try spawnPlayer(&world, 0, 0, 5.0, 3.0);
    std.debug.print("  Spawned player at (0, 0) with velocity (5, 3)\n", .{});

    // Spawn some projectiles
    try spawnProjectile(&world, 10, 10, -2.0, 1.0);
    try spawnProjectile(&world, -20, 5, 4.0, -1.0);
    std.debug.print("  Spawned 2 projectiles\n", .{});

    // Spawn some obstacles
    try spawnObstacle(&world, 50, 0, 50);
    try spawnObstacle(&world, -30, 20, 30);
    std.debug.print("  Spawned 2 obstacles\n", .{});

    if (world.resources.getConst(GameState)) |state| {
        std.debug.print("\nInitial entity count: {}\n", .{world.entityCount()});
        _ = state;
    }

    std.debug.print("\nRunning 60 frames at 60 FPS (1 second simulation)...\n", .{});

    var tick: u64 = 0;
    var scheduler = Scheduler.init(&world, null, allocator);

    // Run game loop
    while (tick < 60) {
        const dt = 1.0 / 60.0; // 60 FPS
        const result = scheduler.tick(dt);

        switch (result) {
            .success => {},
            .single_error => |err| std.debug.print("System error: {any}\n", .{err}),
            .aggregate_errors => |errs| std.debug.print("Multiple errors: {} occurred\n", .{errs.count}),
        }

        tick += 1;
    }

    // Print final state
    if (world.resources.getConst(GameState)) |state| {
        std.debug.print("\n=== Game Complete ===\n", .{});
        std.debug.print("Total frames: {}\n", .{state.frame_count});
        std.debug.print("Final entity count: {}\n", .{state.entity_count});
    }

    // Print final entity positions
    std.debug.print("\n=== Final Entity States ===\n", .{});
    var final_iter = world.query(RenderQuery);
    var idx: u32 = 0;
    while (final_iter.next()) |result| {
        const pos = result.getRead(Position);
        const maybe_health = result.getOptional(Health);

        if (maybe_health) |health| {
            std.debug.print("Entity {}: final_pos=({d:.1}, {d:.1}) health={}/{}\n", .{
                idx,
                pos.x,
                pos.y,
                health.current,
                health.max,
            });
        } else {
            std.debug.print("Entity {}: final_pos=({d:.1}, {d:.1})\n", .{
                idx,
                pos.x,
                pos.y,
            });
        }
        idx += 1;
    }
}
