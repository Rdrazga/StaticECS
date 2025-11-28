# HTTP Server Example

Demonstrates using StaticECS for server-side applications with connection management.

## Features Demonstrated

- **Connection Entities**: Each connection is an entity with state
- **Request/Response Components**: HTTP data attached to connection entities
- **State Machine Pattern**: Connection state transitions via component values
- **Resources**: Server configuration and statistics
- **Custom Phases**: accept → read → process → write → cleanup
- **I/O Context**: Demonstrates async I/O capability check

## Structure

```
http-server/
├── README.md    # This file
└── main.zig     # Complete example (simulated networking)
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        HTTP Server ECS                          │
├─────────────────────────────────────────────────────────────────┤
│ Resources:                                                       │
│   ServerStats  - requests, active connections, tick count        │
├─────────────────────────────────────────────────────────────────┤
│ Connection Entity:                                               │
│   ├── Connection (fd, state, timestamp)                         │
│   ├── Request (method_len, path_len, content_length)            │
│   └── Response (status_code, content_length, sent flags)        │
├─────────────────────────────────────────────────────────────────┤
│ Systems (per frame):                                             │
│   1. accept   - Spawn new connection entities                   │
│   2. read     - Parse incoming HTTP (stub)                      │
│   3. process  - Route and generate response (stub)              │
│   4. write    - Write response back                             │
│   5. cleanup  - Update stats                                    │
└─────────────────────────────────────────────────────────────────┘
```

## Connection State Machine

```
    new → reading → processing → writing → closed → [despawn]
                ↑                              ↑
                └─── timeout ──────────────────┘
```

## Running

From the StaticECS root:

```bash
zig build run-example-server
```

## Key Concepts

### Connections as Entities

Each network connection becomes an ECS entity:

```zig
// In acceptSystem - simulate accepting connections every 5 ticks
if (@mod(ctx.tick, 5) == 0) {
    const stats = ctx.world.resources.get(ServerStats) orelse return;
    _ = ctx.world.spawn("connection", .{
        Connection{ .fd = @intCast(ctx.tick), .state = .reading, .timestamp_ns = ctx.time_ns },
    }) catch {};
    stats.connections_active += 1;
}
```

### Centralized Statistics

Resources track server-wide metrics:

```zig
const ServerStats = struct {
    connections_active: u32 = 0,
    requests_total: u64 = 0,
    tick_count: u64 = 0,
};

fn writeSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(ServerStats) orelse return;
    // Simulate completing requests
    if (stats.connections_active > 0) {
        stats.requests_total += 1;
        stats.connections_active -|= 1;
    }
}
```

### I/O Context Capability

Systems can check for async I/O support:

```zig
fn acceptSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);

    // Check for async I/O support
    if (ctx.hasIo()) {
        _ = ctx.hasAsync();
    }
    // ...
}
```

### Execution Model

The example uses blocking single-thread mode:

```zig
.schedule = .{
    .execution_model = .blocking_single_thread, // Would use .evented_single_thread when std.Io is ready
},
```

> **Note**: The read, process, and cleanup systems in this example are stubs.
> A real server would implement full HTTP parsing and response generation.

### System Context Helper

Systems receive an opaque pointer that must be cast to the typed context:

```zig
const Context = ecs.SystemContext(cfg, World);

fn getContext(ctx_ptr: *anyopaque) *Context {
    return @ptrCast(@alignCast(ctx_ptr));
}
```

## Extending

Ideas for building a real server:

1. **Real Sockets**: Replace simulated I/O with `std.net`
2. **HTTP Parsing**: Use or build HTTP/1.1 parser
3. **Async I/O**: Use `evented_single_thread` execution model when available
4. **Keep-Alive**: Reset connection state instead of closing
5. **Middleware**: Add logging, auth as system phases
6. **Rate Limiting**: Track requests per client in component
7. **WebSocket**: Add upgrade handling and frame components

## Comparison with Traditional Servers

| Aspect | Traditional | ECS-Based |
|--------|-------------|-----------|
| Connection state | Object/closure | Component data |
| Request handling | Callback chain | System pipeline |
| Global state | Shared mutable | Resources (explicit) |
| Timeout handling | Timer callbacks | Per-frame system check |
| Memory | Per-connection alloc | Fixed archetype pools |
| Debugging | Stack traces | Entity inspection |