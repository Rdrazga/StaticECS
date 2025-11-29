# StaticECS Quick Start Guide

Get up and running with StaticECS in 5 minutes.

## Installation

Add StaticECS to your `build.zig.zon`:

```zig
.dependencies = .{
    .static_ecs = .{
        .path = "path/to/StaticECS",
    },
},
```

In your `build.zig`:

```zig
const static_ecs = b.dependency("static_ecs", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ecs", static_ecs.module("ecs"));
```

## Your First World

### Step 1: Define Components

Components are plain Zig structs:

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Name = struct { value: [32]u8 };
```

### Step 2: Create the Configuration

```zig
const ecs = @import("ecs");

pub const cfg = ecs.WorldConfig{
    // All component types used in this world
    .components = .{
        .types = &.{ Position, Velocity, Name },
    },
    
    // Entity structures (combinations of components)
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "static_object", .components = &.{ Position, Name } },
            .{ .name = "moving_object", .components = &.{ Position, Velocity, Name } },
        },
    },
    
    // Configure limits (Tiger Style: all bounds explicit)
    .options = .{
        .max_entities = 1000,
    },
};

const World = ecs.World(cfg);
```

### Step 3: Create and Use the World

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize world (does not return error)
    var world = World.init(allocator);
    defer world.deinit();

    // Spawn an entity
    const entity = try world.spawn("moving_object", .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .x = 1, .y = 0.5 },
        Name{ .value = "Player".* ++ [_]u8{0} ** 26 },
    });

    // Access components
    if (world.getComponent(entity, Position)) |pos| {
        std.debug.print("Position: ({}, {})\n", .{ pos.x, pos.y });
    }

    // Modify components
    if (world.getComponent(entity, Velocity)) |vel| {
        vel.x *= 2;
    }

    // Despawn
    try world.despawn(entity);
}
```

## Adding Systems

Systems process entities each frame.

### Step 1: Define Types and Helpers

```zig
const World = ecs.World(cfg);
const FrameError = ecs.FrameError;
const Context = ecs.SystemContext(cfg, World);

// Helper to cast opaque pointer to typed context
fn getContext(ctx_ptr: *anyopaque) *Context {
    return @ptrCast(@alignCast(ctx_ptr));
}
```

### Step 2: Write the System Function

Systems receive an opaque pointer for compatibility with the scheduler. Cast it using the helper:

```zig
fn movementSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    // Query all entities with Position and Velocity
    var query = ctx.world.query(.{
        .include = &.{ Position, Velocity },
    });
    
    while (query.next()) |result| {
        const pos = result.get(Position);           // Mutable
        const vel = result.getConst(Velocity);      // Read-only
        
        // Apply velocity
        pos.x += vel.x * @as(f32, @floatCast(ctx.delta_time));
        pos.y += vel.y * @as(f32, @floatCast(ctx.delta_time));
    }
}
```

> **Note**: The opaque pointer pattern enables compile-time system registration without type dependencies between the config and system definitions.

### Step 3: Register in Config

```zig
const Phase = ecs.Phase;

pub const cfg = ecs.WorldConfig{
    .components = .{ .types = &.{ Position, Velocity, Name } },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "moving_object", .components = &.{ Position, Velocity, Name } },
        },
    },
    .systems = .{
        .systems = &.{
            .{
                .name = "movement",
                .func = ecs.asSystemFn(movementSystem),
                .phase = Phase.update.index(),
                .read_components = &.{Velocity},
                .write_components = &.{Position},
            },
        },
    },
    .options = .{ .max_entities = 1000 },
};
```

### Step 4: Run the Frame

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // World.init does not return an error
    var world = World.init(allocator);
    defer world.deinit();

    // Spawn some entities
    _ = try world.spawn("moving_object", .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .x = 10, .y = 5 },
        Name{ .value = "Ball".* ++ [_]u8{0} ** 28 },
    });

    // Game loop using Scheduler
    const Scheduler = ecs.Scheduler(cfg);
    var tick: u64 = 0;
    var scheduler = Scheduler.init(&world, null, allocator);

    while (tick < 1000) {
        // Execute frame - runs all systems in phase order
        const result = scheduler.tick(1.0 / 60.0);  // ~60 FPS delta
        
        switch (result) {
            .success => {},
            .single_error => |err| {
                std.debug.print("Frame error: {any}\n", .{err});
            },
            .aggregate_errors => |errs| {
                std.debug.print("Multiple errors: {}\n", .{errs.count});
            },
        }

        tick += 1;
        std.time.sleep(16_666_666); // ~60 FPS
    }
}
```

## Deferred Commands

Use the command buffer during system execution to avoid iterator invalidation:

```zig
fn spawnerSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    // Deferred spawn - executed after system completes
    _ = ctx.commands.spawnInArchetype(0); // Archetype index 0
    
    // Deferred despawn
    // _ = ctx.commands.despawn(some_entity);
    
    // Deferred component set
    // _ = ctx.commands.setComponent(entity, Position, .{ .x = 0, .y = 0 });
}
```

## Global Resources

Share data across systems without entity attachment:

```zig
const GameTime = struct {
    total: f64,
    frame: u64,
};

pub const cfg = ecs.WorldConfig{
    // ... components, archetypes, systems ...
    .resources = .{
        .types = &.{GameTime},
    },
};

fn timeSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    if (ctx.getResource(GameTime)) |time| {
        time.total += ctx.delta_time;
        time.frame = ctx.tick;
    }
}

pub fn main() !void {
    // World.init does not return an error
    var world = World.init(allocator);
    defer world.deinit();
    
    // Initialize resource
    _ = world.resources.insert(GameTime, .{ .total = 0, .frame = 0 });
    
    // ... run frames ...
}
```

## Optional Query Components

Query entities that may or may not have certain components:

```zig
fn renderSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{Position},
        .optional = &.{Velocity},  // Might not be present
    });
    
    while (query.next()) |result| {
        const pos = result.getConst(Position);
        
        // Check if optional component exists
        if (result.getOptional(Velocity)) |vel| {
            // Has velocity - moving object
            renderMoving(pos, vel);
        } else {
            // No velocity - static object
            renderStatic(pos);
        }
    }
}
```

## Event Queues

Communicate between systems without tight coupling:

```zig
const CollisionEvent = struct {
    entity_a: ecs.EntityHandle,
    entity_b: ecs.EntityHandle,
    normal: [3]f32,
};

// Create a ring buffer for events (max 64 events)
var collision_events = ecs.EventQueue(CollisionEvent, 64).init();

// In physics system: push events
collision_events.push(.{
    .entity_a = entity1,
    .entity_b = entity2,
    .normal = .{ 0, 1, 0 },
}) catch {}; // Handle full buffer

// In response system: consume events
while (collision_events.pop()) |event| {
    // Handle collision
    _ = event;
}
```

## Next Steps

- **[Configuration Reference](CONFIGURATION.md)** - All configuration options
- **[System Authoring Guide](systems.md)** - Advanced system patterns
- **[Execution Models](execution-models.md)** - Async and threading options
- **[Multi-World Coordination](multi-world.md)** - Running multiple worlds with entity transfers

## Key Concepts

| Concept | Description |
|---------|-------------|
| **Component** | Plain data struct attached to entities |
| **Archetype** | Named collection of components defining entity structure |
| **Entity** | Instance of an archetype |
| **System** | Function that processes entities each frame |
| **Phase** | Execution stage (pre_update, update, post_update, etc.) |
| **Resource** | Global singleton data shared across systems |
| **Query** | Pattern for finding entities with specific components |
| **Command Buffer** | Deferred entity operations to avoid iterator invalidation |

## Tiger Style Principles

StaticECS follows Tiger Style which means:

1. **All bounds are configurable** - No surprise limits
2. **No dynamic allocation after init** - Predictable memory usage
3. **Compile-time validation** - Errors caught before runtime
4. **Explicit over implicit** - Configuration declares intent
5. **Fail-fast** - Errors surface immediately, not silently ignored