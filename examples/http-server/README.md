# HTTP Server Example

Demonstrates using StaticECS for server-side applications with connection management.

## Features Demonstrated

- **Connection Entities**: Each connection is an entity with state
- **Request/Response Components**: HTTP data attached to connection entities
- **State Machine Pattern**: Connection state transitions via component values
- **Resources**: Server configuration and statistics
- **Event Queues**: Logging request completions
- **Timeout Handling**: Automatic cleanup of stale connections

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
│   ServerConfig - host, port, max_connections, timeout           │
│   ServerStats  - requests, bytes, active connections            │
├─────────────────────────────────────────────────────────────────┤
│ Connection Entity:                                               │
│   ├── Connection (client_id, state, bytes_sent/received)        │
│   ├── Request (method, path, headers)                           │
│   ├── Response (status, body, headers)                          │
│   └── Timing (created_at, last_activity, timeout)               │
├─────────────────────────────────────────────────────────────────┤
│ Systems (per frame):                                             │
│   1. accept_connections  - Spawn new connection entities        │
│   2. read_requests       - Parse incoming HTTP                  │
│   3. process_requests    - Route and generate response          │
│   4. send_responses      - Write response back                  │
│   5. timeout_check       - Mark stale connections               │
│   6. cleanup             - Despawn closed connections           │
└─────────────────────────────────────────────────────────────────┘
```

## Connection State Machine

```
    new → reading_request → processing → writing_response → closing → [despawn]
                    ↑                                           ↑
                    └─── timeout ───────────────────────────────┘
```

## Running

From the StaticECS root:

```bash
zig build
zig run examples/http-server/main.zig
```

## Key Concepts

### Connections as Entities

Each network connection becomes an ECS entity:

```zig
_ = world.spawn("connection", .{
    Connection{ .client_id = socket_fd, .state = .new },
    Request{},   // Populated by read system
    Response{},  // Populated by router
    Timing{ .created_at_ns = now },
});
```

### State-Based Processing

Systems filter by connection state:

```zig
fn readRequestsSystem(ctx: *Context) !void {
    var query = ctx.world.query(.{ .include = &.{Connection, Request} });
    while (query.next()) |result| {
        const conn = result.get(Connection);
        if (conn.state != .new and conn.state != .reading_request) continue;
        // Read from socket...
        conn.state = .processing;
    }
}
```

### Centralized Statistics

Resources track server-wide metrics:

```zig
const ServerStats = struct {
    requests_total: u64 = 0,
    requests_success: u64 = 0,
    connections_active: u32 = 0,
    bytes_sent: u64 = 0,
};

fn processRequestsSystem(ctx: *Context) !void {
    const stats = ctx.getResource(ServerStats) orelse return;
    stats.requests_total += 1;
    // ...
}
```

### Graceful Cleanup

Command buffer handles entity removal after iteration:

```zig
fn cleanupSystem(ctx: *Context) !void {
    var query = ctx.world.query(.{ .include = &.{Connection} });
    while (query.next()) |result| {
        if (result.getConst(Connection).state == .closing) {
            ctx.commands.despawn(result.entity);
        }
    }
}
```

## Extending

Ideas for building a real server:

1. **Real Sockets**: Replace simulated I/O with `std.net`
2. **HTTP Parsing**: Use or build HTTP/1.1 parser
3. **Async I/O**: Use `evented_single_thread` execution model
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