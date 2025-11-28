# Game Loop Example

A simple 2D game loop demonstrating StaticECS fundamentals.

## Features Demonstrated

- **Components**: Position, Velocity, Health
- **Archetypes**: Player, Static, Projectile entity types
- **Systems**: Movement, physics, render, game state
- **Resources**: GameState for global game data
- **Phases**: Standard phases (update, render, post_update)

## Structure

```
game-loop/
├── README.md    # This file
└── main.zig     # Complete example
```

## Running

From the StaticECS root:

```bash
zig build run-example-game
```

## Code Walkthrough

### 1. Component Definitions

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { current: u32, max: u32 };
```

### 2. World Configuration

```zig
pub const cfg = ecs.WorldConfig{
    .components = .{ .types = &.{ Position, Velocity, Health } },
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
    .resources = .{ .types = &.{GameState} },
    .options = .{ .max_entities = 1000 },
};
```

### 3. System Implementation

Systems receive an opaque pointer that must be cast to the typed context:

```zig
fn gameStateSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const state = ctx.world.resources.get(GameState) orelse return;
    state.frame_count = ctx.tick;
}

fn getContext(ctx_ptr: *anyopaque) *Context {
    return @ptrCast(@alignCast(ctx_ptr));
}
```

> **Note**: The movement, physics, and render systems in this example are stubs.
> A complete game would implement actual game logic in these systems.

### 4. Game Loop

```zig
while (tick < 60) {
    const result = scheduler.tick(1.0 / 60.0);

    switch (result) {
        .success => {},
        .single_error => |err| std.debug.print("Error: {any}\n", .{err}),
        .aggregate_errors => |errs| std.debug.print("Errors: {}\n", .{errs.count}),
    }

    tick += 1;
}
```

### 5. Entity Spawning

```zig
// Spawn player
_ = try world.spawn("player", .{
    Position{ .x = 0, .y = 0 },
    Velocity{ .dx = 0, .dy = 0 },
    Health{ .current = 100, .max = 100 },
});
```

## Key Concepts

| Concept | Example Usage |
|---------|--------------|
| Resources | `ctx.world.resources.get(GameState)` for shared state |
| Phases | `Phase.update.index()` to order system execution |
| Archetypes | Named entity templates with component sets |
| Scheduler | `scheduler.tick(delta)` runs all systems |

## Extending

Ideas for expanding this example:

1. **Movement Logic**: Implement velocity-based position updates
2. **Projectiles**: Add a bullet archetype with collision
3. **Waves**: Increase difficulty over time
4. **Powerups**: Add temporary stat boosts
5. **Particles**: Visual effects with short lifetimes
6. **Save/Load**: Serialize game state