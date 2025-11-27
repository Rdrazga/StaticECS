//! StaticECS Game Loop Example
//!
//! Demonstrates using StaticECS for a simple game:
//! - Entity component management
//! - Multi-phase system execution
//! - Resource-based game state
//!
//! Run with: zig build run-example-game

const std = @import("std");
const ecs = @import("ecs");

const FrameError = ecs.FrameError;
const Phase = ecs.Phase;

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

// ============================================================================
// Resources
// ============================================================================

const GameState = struct {
    running: bool = true,
    frame_count: u64 = 0,
    entity_count: u32 = 0,
};

// ============================================================================
// System Functions (defined BEFORE config)
// ============================================================================

fn movementSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // In a real game: update Position based on Velocity
}

fn physicsSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // In a real game: run collision detection, apply forces
}

fn renderSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // In a real game: render entities
}

fn gameStateSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const state = ctx.world.resources.get(GameState) orelse return;
    state.frame_count = ctx.tick;
}

// ============================================================================
// Configuration (defined AFTER systems)
// ============================================================================

pub const cfg = ecs.WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health },
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
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    _ = world.resources.insert(GameState, .{ .running = true });

    // Spawn player
    _ = try world.spawn("player", .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .dx = 0, .dy = 0 },
        Health{ .current = 100, .max = 100 },
    });

    std.debug.print("StaticECS Game Loop Example\n", .{});
    std.debug.print("============================\n", .{});
    std.debug.print("Running 60 frames at 60 FPS (1 second simulation)\n\n", .{});

    var tick: u64 = 0;
    var scheduler = Scheduler.init(&world, null, allocator);

    while (tick < 60) {
        const result = scheduler.tick(1.0 / 60.0);

        switch (result) {
            .success => {},
            .single_error => |err| std.debug.print("Error: {any}\n", .{err}),
            .aggregate_errors => |errs| std.debug.print("Errors: {}\n", .{errs.count}),
        }

        if (@mod(tick, 20) == 0) {
            if (world.resources.getConst(GameState)) |state| {
                std.debug.print("Frame {}: running={}\n", .{ state.frame_count, state.running });
            }
        }

        tick += 1;
    }

    if (world.resources.getConst(GameState)) |state| {
        std.debug.print("\n=== Game Complete ===\n", .{});
        std.debug.print("Total frames: {}\n", .{state.frame_count});
    }
}
