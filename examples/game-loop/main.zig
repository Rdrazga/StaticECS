//! StaticECS Game Loop Example
//!
//! Demonstrates using StaticECS for a simple game:
//! - Entity component management with actual query iteration
//! - Multi-phase system execution
//! - Resource-based game state
//! - Velocity-based movement with delta time
//! - Entity spawning and despawning
//! - **Command buffer usage for deferred entity operations**
//! - **Safe entity despawn during iteration**
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

/// Attack component for entities that can attack
const Attacker = struct {
    cooldown_ticks: u32 = 0,
    attack_interval: u32 = 15, // Attack every 15 ticks
    projectile_speed: f32 = 10.0,
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
    projectiles_fired: u32 = 0,
};

// ============================================================================
// Query Specifications
// ============================================================================

/// Query for entities with Position and Velocity (for movement).
/// Used by movementSystem to update positions based on velocity and delta time.
/// Used by physicsSystem to apply world bounds checking.
/// Reads Velocity (immutable) and writes Position (mutable update).
const MovementQuery = Query(.{
    .read = &.{Velocity},
    .write = &.{Position},
});

/// Query for all entities with positions (for rendering/display).
/// Used by renderSystem to display entity states periodically.
/// Used in main() for final entity state printout.
/// Reads Position and optionally reads Health for display.
const RenderQuery = Query(.{
    .read = &.{Position},
    .optional = &.{Health},
});

/// Query for entities with health to apply health decay.
/// Used by healthDecaySystem to reduce health over time.
/// Reads Position for entity identification, writes Health for decay.
const HealthQuery = Query(.{
    .read = &.{Position},
    .write = &.{Health},
});

/// Query for entities marked for death (despawn candidates).
/// Used by despawnSystem to safely remove entities using command buffer.
const DespawnQuery = Query(.{
    .read = &.{MarkedForDeath},
    .optional = &.{Position},
});

/// Query for entities that can attack (players with Attacker component).
/// Used by attackSystem to spawn projectiles via deferred commands.
const AttackQuery = Query(.{
    .read = &.{Position},
    .write = &.{Attacker},
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

/// Health decay system: Reduces health over time and marks depleted entities for death.
/// Demonstrates write access to components and deferred component addition using commands.
fn healthDecaySystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);

    // Only decay health every 10 frames
    if (@mod(ctx.tick, 10) != 0) return;

    var iter = ctx.world.query(HealthQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const health = result.getWrite(Health);

        // Reduce health by 1 each decay tick (saturating subtract for safety)
        if (health.current > 0) {
            health.current -|= 1;
        }

        // Mark entity for death when health depleted
        // Note: In a real game, we would use commands to add MarkedForDeath component
        // For this example, we log when health reaches zero
        if (health.current == 0) {
            std.log.debug("Entity health depleted - would mark for death", .{});
        }
    }
}

/// Attack system: Spawns projectiles using deferred commands.
/// Demonstrates command buffer usage for safe entity spawning during iteration.
///
/// Why deferred spawn is essential:
/// - Spawning directly during iteration could invalidate iterators
/// - Command buffer collects spawn requests, executes after system completes
/// - This pattern ensures safe concurrent entity manipulation
fn attackSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const state = ctx.world.resources.get(GameState) orelse return;

    var iter = ctx.world.query(AttackQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const pos = result.getRead(Position);
        const attacker = result.getWrite(Attacker);

        // Decrement cooldown
        if (attacker.cooldown_ticks > 0) {
            attacker.cooldown_ticks -= 1;
            continue;
        }

        // Attack is ready - spawn a projectile using deferred command
        // IMPORTANT: Using command buffer ensures the spawn happens AFTER iteration
        // This prevents iterator invalidation that would occur with direct spawns
        //
        // Note: spawnInArchetype queues an entity creation in the target archetype.
        // The entity will be created with default/zero component values.
        // For more complex spawns, use spawnWithData with the archetype's table type.
        const arch_idx = comptime World.archIndex("projectile");
        const success = ctx.commands.spawnInArchetype(arch_idx);

        if (success) {
            attacker.cooldown_ticks = attacker.attack_interval;
            state.projectiles_fired += 1;
            std.log.debug("Queued projectile spawn from ({d:.1}, {d:.1})", .{ pos.x, pos.y });
        }
    }
}

/// Despawn system: Removes entities marked for death using deferred commands.
/// Demonstrates safe entity removal during iteration via command buffer.
///
/// Why deferred despawn is essential:
/// - Despawning directly during iteration invalidates the iterator
/// - Command buffer collects despawn requests to execute after iteration
/// - This pattern is critical for any system that removes entities while iterating
fn despawnSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const state = ctx.world.resources.get(GameState) orelse return;

    var iter = ctx.world.query(DespawnQuery);
    var despawn_count: u32 = 0;

    while (iter.next()) |result| {
        const marked = result.getRead(MarkedForDeath);
        const maybe_pos = result.getOptional(Position);

        // Log the despawn with position if available
        if (maybe_pos) |pos| {
            std.log.info("Despawning entity at ({d:.1}, {d:.1}) reason: {s}", .{
                pos.x,
                pos.y,
                @tagName(marked.reason),
            });
        } else {
            std.log.info("Despawning entity (no position) reason: {s}", .{
                @tagName(marked.reason),
            });
        }

        // Queue deferred despawn - SAFE during iteration
        // The actual despawn happens after the system completes
        // Note: Convert EntityId to EntityHandle for command buffer API
        const handle = ecs.entity.EntityHandle.fromId(result.entity_id);
        _ = ctx.commands.despawn(handle);
        despawn_count += 1;
    }

    // Update statistics
    if (despawn_count > 0) {
        state.entities_despawned += despawn_count;
        std.log.info("Despawned {} entities this frame (total: {})", .{
            despawn_count,
            state.entities_despawned,
        });
    }
}

// ============================================================================
// Configuration (defined AFTER systems)
// ============================================================================

pub const cfg = ecs.WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, MarkedForDeath, Attacker },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "player", .components = &.{ Position, Velocity, Health, Attacker } },
            .{ .name = "static", .components = &.{ Position, Health } },
            .{ .name = "projectile", .components = &.{ Position, Velocity } },
            .{ .name = "dying", .components = &.{ Position, MarkedForDeath } },
        },
    },
    .systems = .{
        .systems = &.{
            // Movement: reads Velocity, writes Position
            // Declaring component access enables scheduler optimization for parallelism
            .{
                .name = "movement",
                .func = ecs.asSystemFn(movementSystem),
                .phase = Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
            },
            // Physics: applies bounds checking, reads Velocity for iteration, writes Position
            .{
                .name = "physics",
                .func = ecs.asSystemFn(physicsSystem),
                .phase = Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
            },
            // Health decay: reduces health over time, reads Position, writes Health
            .{
                .name = "health_decay",
                .func = ecs.asSystemFn(healthDecaySystem),
                .phase = Phase.update.index(),
                .read_components = &.{Position},
                .write_components = &.{Health},
            },
            // Attack: spawns projectiles using command buffer (deferred spawn)
            .{
                .name = "attack",
                .func = ecs.asSystemFn(attackSystem),
                .phase = Phase.update.index(),
                .read_components = &.{Position},
                .write_components = &.{Attacker},
            },
            // Despawn: removes marked entities using command buffer (deferred despawn)
            .{
                .name = "despawn",
                .func = ecs.asSystemFn(despawnSystem),
                .phase = Phase.post_update.index(),
                .read_components = &.{ MarkedForDeath, Position },
            },
            // Render: displays entity state (read-only)
            .{
                .name = "render",
                .func = ecs.asSystemFn(renderSystem),
                .phase = Phase.render.index(),
                .read_components = &.{ Position, Health },
            },
            // Game state: updates global statistics (resource access only)
            .{
                .name = "game_state",
                .func = ecs.asSystemFn(gameStateSystem),
                .phase = Phase.post_update.index(),
            },
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
        Attacker{ .cooldown_ticks = 0, .attack_interval = 15, .projectile_speed = 10.0 },
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
    std.debug.print("  - Resource management\n", .{});
    std.debug.print("  - Command buffer for deferred entity spawning\n", .{});
    std.debug.print("  - Safe entity despawn during iteration\n\n", .{});

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
        std.debug.print("Projectiles fired: {}\n", .{state.projectiles_fired});
        std.debug.print("Entities despawned: {}\n", .{state.entities_despawned});
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
