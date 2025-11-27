# Game Loop Example

A simple 2D game loop demonstrating StaticECS fundamentals.

## Features Demonstrated

- **Components**: Position, Velocity, Health, Bounds, marker components
- **Archetypes**: Player, Enemy, Collectible entity types
- **Systems**: Input, movement, collision, spawning, lifetime, death
- **Resources**: GameState, InputState, SpawnTimer
- **Phases**: pre_update (input), update (logic), post_update (collision)
- **Command Buffer**: Deferred entity despawning

## Structure

```
game-loop/
├── README.md    # This file
└── main.zig     # Complete example
```

## Running

From the StaticECS root:

```bash
zig build
zig run examples/game-loop/main.zig
```

Or add to your build.zig:

```zig
const example = b.addExecutable(.{
    .name = "game-example",
    .root_source_file = b.path("examples/game-loop/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

## Code Walkthrough

### 1. Component Definitions

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { current: i32, max: i32 };
const Player = struct {};  // Marker component
```

### 2. World Configuration

```zig
pub const cfg = ecs.WorldConfig{
    .components = .{ .types = &.{ Position, Velocity, ... } },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "player", .components = &.{ Position, Velocity, Player, Health } },
            .{ .name = "enemy", .components = &.{ Position, Velocity, Enemy, Lifetime } },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "movement", .func = ecs.asSystemFn(movementSystem), ... },
        },
    },
    .options = .{ .max_entities = 1000 },
};
```

### 3. System Implementation

```zig
fn movementSystem(ctx: *ecs.SystemContext(cfg, World)) !void {
    var query = ctx.world.query(.{
        .include = &.{ Position, Velocity },
    });
    
    while (query.next()) |result| {
        const pos = result.get(Position);
        const vel = result.getConst(Velocity);
        pos.x += vel.x * @floatCast(ctx.delta_time);
        pos.y += vel.y * @floatCast(ctx.delta_time);
    }
}
```

### 4. Game Loop

```zig
while (!game_over) {
    const delta = calculateDeltaTime();
    _ = Scheduler.executeFrame(&world, delta, tick, null, allocator);
    tick += 1;
    std.time.sleep(16_666_666); // ~60 FPS
}
```

## Key Concepts

| Concept | Example Usage |
|---------|--------------|
| Marker Components | `Player{}`, `Enemy{}` - No data, just tags |
| Lifetime System | Entities auto-despawn after duration |
| Collision | Simple AABB overlap detection |
| Resource Access | `ctx.getResource(GameState)` |
| Deferred Commands | `ctx.commands.despawn(entity)` |

## Extending

Ideas for expanding this example:

1. **Projectiles**: Add a bullet archetype with collision
2. **Waves**: Increase difficulty over time
3. **Powerups**: Add temporary stat boosts
4. **Particles**: Visual effects with short lifetimes
5. **Save/Load**: Serialize game state