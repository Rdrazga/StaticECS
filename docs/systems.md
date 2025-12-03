# System Authoring Guide

This guide covers advanced patterns for writing systems in StaticECS.

## System Fundamentals

Systems receive an opaque pointer to the context for compile-time registration flexibility.

### The getContext Helper Pattern

Every system file should define a `getContext` helper function to safely cast the opaque context pointer to the proper type. This pattern is essential for type-safe system authoring:

```zig
const FrameError = ecs.FrameError;
const World = ecs.World(cfg);
const Context = ecs.SystemContext(cfg, World);

/// Helper function to cast opaque pointer to SystemContext.
///
/// This is necessary because systems are registered in the config at comptime,
/// but SystemContext type depends on the config, creating a circular dependency.
/// The opaque pointer breaks this cycle.
///
/// Safety: The scheduler guarantees ctx_ptr points to a valid SystemContext.
fn getContext(ctx_ptr: *anyopaque) *Context {
    return @ptrCast(@alignCast(ctx_ptr));
}
```

With this helper defined, systems become simple:

```zig
fn mySystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    // System logic using ctx.world, ctx.delta_time, etc.
}
```

> **Why opaque pointers?** This pattern enables compile-time system registration without circular type dependencies between the config and system definitions. The `SystemContext` type depends on `WorldConfig`, but we need to reference system functions in `WorldConfig.systems`, creating a cycle that opaque pointers resolve.

Systems receive a `SystemContext` providing access to:
- `ctx.world` - The world instance
- `ctx.delta_time` - Time since last frame (seconds)
- `ctx.tick` - Current frame/tick index
- `ctx.time_ns` - Frame start time (nanoseconds)
- `ctx.commands` - Deferred command buffer
- `ctx.allocator` - User-provided allocator
- `ctx.getResource(T)` / `ctx.getResourceConst(T)` - Resource access
- `ctx.getIo()` - I/O context (if `needs_io: true`)

## System Registration

### Basic Registration

```zig
const Phase = ecs.Phase;

pub const cfg = ecs.WorldConfig{
    .systems = .{
        .systems = &.{
            .{
                .name = "my_system",
                .func = ecs.asSystemFn(mySystem),
                .phase = Phase.update.index(),
            },
        },
    },
    // ...
};
```

### Component Access Declaration

Declare which components your system reads and writes for conflict detection:

```zig
.systems = &.{
    .{
        .name = "movement",
        .func = ecs.asSystemFn(movementSystem),
        .phase = Phase.update.index(),
        .read_components = &.{Velocity},      // Read-only access
        .write_components = &.{Position},     // Read-write access
    },
    .{
        .name = "physics",
        .func = ecs.asSystemFn(physicsSystem),
        .phase = Phase.update.index(),
        .read_components = &.{Mass},
        .write_components = &.{ Position, Velocity },  // Conflicts with movement
    },
},
```

Systems with conflicting component access are placed in separate stages and cannot run concurrently.

---

## Query Patterns

### Basic Query

```zig
fn movementSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{ Position, Velocity },
    });
    
    while (query.next()) |result| {
        const pos = result.get(Position);      // Mutable pointer
        const vel = result.getConst(Velocity); // Const pointer
        
        pos.x += vel.x * @as(f32, @floatCast(ctx.delta_time));
        pos.y += vel.y * @as(f32, @floatCast(ctx.delta_time));
    }
}
```

### Query with Exclusion

Filter out entities with certain components:

```zig
fn processActiveEntities(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{Position},
        .exclude = &.{Disabled},  // Skip entities with Disabled component
    });
    
    while (query.next()) |result| {
        const pos = result.get(Position);
        // Process active entities only
    }
}
```

### Optional Components

Query entities that may or may not have certain components:

```zig
fn renderSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{Position, Sprite},
        .optional = &.{Tint},  // May or may not have Tint
    });
    
    while (query.next()) |result| {
        const pos = result.getConst(Position);
        const sprite = result.getConst(Sprite);
        
        // Check for optional component
        const color = if (result.getOptional(Tint)) |tint|
            tint.value
        else
            0xFFFFFFFF; // Default white
            
        render(pos, sprite, color);
    }
}
```

### Entity Handle Access

Get the entity handle during iteration:

```zig
fn debugSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{Position},
    });
    
    while (query.next()) |result| {
        const entity = result.entity;
        const pos = result.getConst(Position);
        std.debug.print("Entity {}: pos=({}, {})\n", .{
            entity.id.toU32(), pos.x, pos.y
        });
    }
}
```

---

## Deferred Commands

Use the command buffer for operations that would invalidate iterators.

### Despawning Entities

```zig
fn deathSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{Health},
    });
    
    while (query.next()) |result| {
        const health = result.getConst(Health);
        if (health.current <= 0) {
            // Don't despawn directly - would invalidate iterator
            // Queue for later execution
            _ = ctx.commands.despawn(result.entity);
        }
    }
    // Commands execute after system completes
}
```

### Spawning Entities

```zig
fn spawnerSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const spawn_timer = ctx.getResource(SpawnTimer) orelse return;
    
    spawn_timer.elapsed += ctx.delta_time;
    if (spawn_timer.elapsed >= spawn_timer.interval) {
        spawn_timer.elapsed = 0;
        
        // Queue spawn command (archetype index 0)
        _ = ctx.commands.spawnInArchetype(0);
    }
}
```

### Modifying Components

```zig
fn damageSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{ Health, InDamageZone },
    });
    
    while (query.next()) |result| {
        const health = result.getConst(Health);
        
        // Queue deferred component modification
        _ = ctx.commands.setComponent(result.entity, Health, .{
            .current = health.current - 10,
            .max = health.max,
        });
    }
}
```

---

## Resource Access

### Reading Resources

```zig
fn inputSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const input = ctx.getResourceConst(InputState) orelse return;
    
    if (input.jump_pressed) {
        // Handle jump
    }
}
```

### Modifying Resources

```zig
fn scoreSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const score = ctx.getResource(GameScore) orelse return;
    
    var query = ctx.world.query(.{
        .include = &.{Collectible, Collected},
    });
    
    while (query.next()) |result| {
        const collectible = result.getConst(Collectible);
        score.value += collectible.points;
        _ = ctx.commands.despawn(result.entity);
    }
}
```

---

## Phase Organization

### Default Phases

| Index | Name | Typical Use |
|-------|------|-------------|
| 0 | `pre_update` | Input processing, AI decisions |
| 1 | `update` | Core logic, physics, movement |
| 2 | `post_update` | Collision response, cleanup |
| 3 | `render` | Rendering, visual effects |
| 4 | `network` | Network sync, replication |

### Phase Selection Guidelines

**pre_update**: Systems that gather input or make decisions
```zig
.{ .name = "input", .phase = Phase.pre_update.index(), ... },
.{ .name = "ai_decision", .phase = Phase.pre_update.index(), ... },
```

**update**: Core simulation systems
```zig
.{ .name = "movement", .phase = Phase.update.index(), ... },
.{ .name = "physics", .phase = Phase.update.index(), ... },
.{ .name = "combat", .phase = Phase.update.index(), ... },
```

**post_update**: Cleanup and synchronization
```zig
.{ .name = "collision_response", .phase = Phase.post_update.index(), ... },
.{ .name = "death_cleanup", .phase = Phase.post_update.index(), ... },
```

**render**: Visual systems
```zig
.{ .name = "sprite_render", .phase = Phase.render.index(), ... },
.{ .name = "particle_update", .phase = Phase.render.index(), ... },
```

**network**: Network I/O
```zig
.{ .name = "network_send", .phase = Phase.network.index(), ... },
.{ .name = "network_receive", .phase = Phase.network.index(), ... },
```

---

## Error Handling

### Returning Errors

Systems can return errors via the `FrameError!void` return type:

```zig
fn systemThatMayFail(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const resource = ctx.getResource(CriticalResource) orelse
        return error.ResourceNotFound;
    
    // Continue processing...
}
```

### Error Policies

Configure how errors are handled in `WorldConfig.policies`:

```zig
.policies = .{
    .frame = .default,    // Stop on first error
    // or
    .frame = .aggregate,  // Collect all errors and continue
},
```

### Checking Frame Results

```zig
// Create scheduler bound to world
const Scheduler = ecs.Scheduler(cfg);
var scheduler = Scheduler.init(&world, null, allocator);
defer scheduler.deinit();

// Execute frame and handle result
const result = scheduler.tick(delta_time);

switch (result) {
    .success => {},
    .single_error => |err| {
        // First error encountered (default policy)
        handleError(err);
    },
    .aggregate_errors => |errs| {
        // All errors collected (aggregate policy)
        for (errs.getEntries()) |entry| {
            std.debug.print("System {} error: {}\n", .{
                entry.system_index,
                entry.error_value,
            });
        }
    },
}
```

---

## Advanced Patterns

### Singleton Systems

Systems that operate on a single entity:

```zig
fn playerControlSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{ Position, Player },  // Player is marker component
    });
    
    // Expect exactly one player
    if (query.next()) |result| {
        const pos = result.get(Position);
        const input = ctx.getResourceConst(InputState) orelse return;
        
        if (input.move_left) pos.x -= 5;
        if (input.move_right) pos.x += 5;
    }
}
```

### Relationship Systems

Process entities with related entities:

```zig
const Parent = struct { entity: ecs.EntityHandle };
const Child = struct { parent: ecs.EntityHandle };

fn hierarchySystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    // First pass: update parents
    var parent_query = ctx.world.query(.{
        .include = &.{ Position, Parent },
    });
    
    while (parent_query.next()) |result| {
        // Update parent positions...
    }
    
    // Second pass: update children relative to parents
    var child_query = ctx.world.query(.{
        .include = &.{ Position, Child },
    });
    
    while (child_query.next()) |result| {
        const child = result.getConst(Child);
        const child_pos = result.get(Position);
        
        // Get parent position
        if (ctx.world.getComponent(child.parent, Position)) |parent_pos| {
            child_pos.x = parent_pos.x + 10; // Offset
            child_pos.y = parent_pos.y;
        }
    }
}
```

### State Machines

Implement entity state machines with component markers:

```zig
const IdleState = struct {};
const WalkingState = struct { direction: f32 };
const JumpingState = struct { velocity_y: f32 };

fn idleSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    var query = ctx.world.query(.{
        .include = &.{ Position, IdleState },
    });
    
    while (query.next()) |result| {
        const input = ctx.getResourceConst(InputState) orelse continue;
        
        if (input.move_left or input.move_right) {
            // Transition to walking state
            try ctx.world.addComponent(result.entity, WalkingState, .{
                .direction = if (input.move_left) -1.0 else 1.0,
            });
            try ctx.world.removeComponent(result.entity, IdleState);
        }
    }
}
```

### Event Communication

Use event queues for loose coupling between systems:

```zig
const DamageEvent = struct {
    target: ecs.EntityHandle,
    amount: i32,
    source: ?ecs.EntityHandle,
};

// Global event queue (could also be a resource)
var damage_events: ecs.EventQueue(DamageEvent, 256) = undefined;

fn combatSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // Process attack logic, queue damage events
    damage_events.push(.{
        .target = enemy,
        .amount = 25,
        .source = player,
    }) catch {}; // Handle buffer overflow
}

fn damageApplicationSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    // Process damage events
    while (damage_events.pop()) |event| {
        if (ctx.world.getComponent(event.target, Health)) |health| {
            health.current -= event.amount;
        }
    }
}
```

---

## Async I/O Systems

Systems can opt-in to async I/O capabilities when running in evented or concurrent execution models.

### Declaring I/O Need

Mark systems that require I/O context:

```zig
pub const cfg = ecs.WorldConfig{
    .systems = .{
        .systems = &.{
            .{
                .name = "network_handler",
                .func = ecs.asSystemFn(networkHandler),
                .phase = Phase.network.index(),
                .needs_io = true,  // Enable I/O context access
            },
        },
    },
    .schedule = .{
        .execution_model = .evented_single_thread,  // or .concurrent_threadpool
    },
    // ...
};
```

### Checking I/O Availability

Always check before using I/O:

```zig
fn networkHandler(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    
    // Check if I/O context is available
    if (!ctx.hasIo()) {
        // Fallback to synchronous behavior
        return;
    }
    
    const io = ctx.getIo();
    
    // Check specific capabilities
    if (io.hasAsync()) {
        // Can use async operations (evented or concurrent model)
    }
    
    if (io.hasConcurrency()) {
        // Can use true parallel operations (concurrent model only)
    }
}
```

### Async Operation Patterns

```zig
fn serverSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const io = ctx.getIo() orelse return;
    
    // Get raw std.Io for advanced operations
    if (io.getRawIo()) |raw_io| {
        // Use std.Io API directly
        // Note: raw_io is *anyopaque, cast to correct type based on backend
        _ = raw_io;
    }
    
    var query = ctx.world.query(.{
        .include = &.{ Connection, NetworkState },
    });
    
    while (query.next()) |result| {
        const conn = result.get(Connection);
        _ = conn;
        
        // Process connections asynchronously
        // The exact std.Io API depends on platform backend
    }
}
```

### Execution Model Behavior

| Capability | blocking | evented | concurrent |
|------------|----------|---------|------------|
| `hasIo()` | `false` | `true` | `true` |
| `hasAsync()` | `false` | `true` | `true` |
| `hasConcurrency()` | `false` | `false` | `true` |
| I/O operations | N/A | Yields to event loop | True parallel |

### Best Practices

1. **Always check capabilities** - Don't assume I/O is available
2. **Provide synchronous fallbacks** - Systems should work in blocking mode
3. **Declare component access** - Critical for concurrent mode conflict detection
4. **Use command buffer for entity mutations** - Thread-safe across async boundaries

---

## Performance Tips

### Minimize Query Overhead

```zig
// Good: Query once, iterate fully
var query = ctx.world.query(.{ .include = &.{Position} });
while (query.next()) |result| { ... }

// Avoid: Don't create queries in loops
for (entity_list) |entity| {
    var query = ctx.world.query(...);  // Expensive!
}
```

### Batch Operations

```zig
// Good: Batch similar operations
fn cleanupSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    var to_despawn: [64]ecs.EntityHandle = undefined;
    var count: usize = 0;
    
    var query = ctx.world.query(.{ .include = &.{MarkedForDeletion} });
    while (query.next()) |result| {
        if (count < 64) {
            to_despawn[count] = result.entity;
            count += 1;
        }
    }
    
    for (to_despawn[0..count]) |entity| {
        _ = ctx.commands.despawn(entity);
    }
}
```

### Declare Component Access

Always declare read/write components for optimal scheduling:

```zig
// Good: Explicit access declaration
.{
    .name = "movement",
    .read_components = &.{Velocity},
    .write_components = &.{Position},
}

// Allows scheduler to parallelize non-conflicting systems
```

### Use Const Accessors

```zig
// Good: Use getConst for read-only access
const vel = result.getConst(Velocity);

// Avoid: Don't use get() if you don't modify
const vel = result.get(Velocity);  // Implies mutation intent