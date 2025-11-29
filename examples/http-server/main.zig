//! StaticECS HTTP Server Example
//!
//! Demonstrates using StaticECS for an HTTP server:
//! - Connections as entities progressing through states
//! - Request/response processing via components
//! - State machine transitions using component updates
//! - Custom phases for HTTP request pipeline
//! - Resource-based server statistics
//!
//! Run with: zig build run-example-server

const std = @import("std");
const ecs = @import("ecs");

const FrameError = ecs.FrameError;
const Query = ecs.query.Query;

// ============================================================================
// Components
// ============================================================================

/// Connection lifecycle states
const ConnectionState = enum {
    accepting, // Waiting for connection
    reading, // Reading request data
    processing, // Processing request
    writing, // Writing response
    closed, // Connection closed

    fn name(self: ConnectionState) []const u8 {
        return switch (self) {
            .accepting => "accepting",
            .reading => "reading",
            .processing => "processing",
            .writing => "writing",
            .closed => "closed",
        };
    }
};

/// Core connection component
const Connection = struct {
    fd: i32 = -1,
    state: ConnectionState = .accepting,
    timestamp_ns: u64 = 0,
    bytes_read: u32 = 0,
    bytes_written: u32 = 0,
};

/// HTTP request data
const Request = struct {
    method: enum { GET, POST, PUT, DELETE, UNKNOWN } = .UNKNOWN,
    path_hash: u32 = 0, // Hash of path for routing
    content_length: u32 = 0,
    keep_alive: bool = false,
    parse_error: bool = false,
};

/// HTTP response data
const Response = struct {
    status_code: u16 = 200,
    content_length: u32 = 0,
    headers_sent: bool = false,
    body_sent: bool = false,
};

// ============================================================================
// Resources
// ============================================================================

const ServerStats = struct {
    connections_active: u32 = 0,
    connections_total: u64 = 0,
    requests_total: u64 = 0,
    requests_success: u64 = 0,
    requests_error: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    tick_count: u64 = 0,
};

const ServerConfig = struct {
    max_connections: u32 = 100,
    read_timeout_ms: u32 = 5000,
    keep_alive_timeout_ms: u32 = 30000,
};

// ============================================================================
// Query Specifications
// ============================================================================

/// Query for new connections waiting for request data
const ReadingConnectionsQuery = Query(.{
    .write = &.{Connection},
});

/// Query for connections with parsed requests needing processing
const ProcessingQuery = Query(.{
    .read = &.{Request},
    .write = &.{ Connection, Response },
});

/// Query for connections ready to send response
const WritingQuery = Query(.{
    .read = &.{Response},
    .write = &.{Connection},
});

/// Query for all connections (status check)
const AllConnectionsQuery = Query(.{
    .read = &.{Connection},
    .optional = &.{ Request, Response },
});

// ============================================================================
// System Functions (defined BEFORE config)
// ============================================================================

/// Accept system: Simulates accepting new connections.
/// Demonstrates entity spawning based on external events.
fn acceptSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(ServerStats) orelse return;

    // Check for async I/O support (demonstrates capability checking)
    if (ctx.hasIo()) {
        // In a real server, we would use io_uring/epoll here
        _ = ctx.hasAsync();
    }

    // Simulate accepting new connections every 5 ticks
    if (@mod(ctx.tick, 5) == 0) {
        const new_connections: usize = if (@mod(ctx.tick, 15) == 0) 3 else 1;

        for (0..new_connections) |i| {
            // Simulate a new file descriptor
            const fake_fd: i32 = @intCast((ctx.tick * 10 + i) % 10000);

            _ = ctx.world.spawn("connection", .{
                Connection{
                    .fd = fake_fd,
                    .state = .reading,
                    .timestamp_ns = ctx.time_ns,
                },
            }) catch continue;

            stats.connections_active += 1;
            stats.connections_total += 1;
        }
    }
}

/// Read system: Simulates reading request data from connections.
/// Demonstrates state transitions and data parsing simulation.
fn readSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(ServerStats) orelse return;

    var iter = ctx.world.query(ReadingConnectionsQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const conn = result.getWrite(Connection);

        // Only process connections in reading state
        if (conn.state != .reading) continue;

        // Simulate reading data (in real server, this would be actual I/O)
        const fd_as_u64: u64 = @bitCast(@as(i64, conn.fd));
        const simulated_bytes: u32 = 256 + @as(u32, @truncate(fd_as_u64 % 512));
        conn.bytes_read += simulated_bytes;
        stats.bytes_received += simulated_bytes;

        // Transition to processing after "reading" is complete
        conn.state = .processing;
    }
}

/// Process system: Parse requests and generate responses.
/// Demonstrates request routing and response building.
fn processSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(ServerStats) orelse return;

    // We need to iterate connections in processing state
    var iter = ctx.world.query(ReadingConnectionsQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const conn = result.getWrite(Connection);

        // Only process connections in processing state
        if (conn.state != .processing) continue;

        // Simulate request parsing and routing
        // In a real server, we'd parse HTTP headers here
        const path_type = @mod(conn.fd, 4);

        // Simulate different response types based on "path"
        const status_code: u16 = switch (path_type) {
            0 => 200, // OK
            1 => 201, // Created
            2 => 404, // Not Found
            else => 500, // Internal Server Error
        };

        // Track stats based on response status
        if (status_code < 400) {
            stats.requests_success += 1;
        } else {
            stats.requests_error += 1;
        }
        stats.requests_total += 1;

        // Transition to writing state
        conn.state = .writing;
    }
}

/// Write system: Simulates sending response data.
/// Demonstrates response completion and connection cleanup.
fn writeSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(ServerStats) orelse return;

    var iter = ctx.world.query(ReadingConnectionsQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const conn = result.getWrite(Connection);

        // Only process connections in writing state
        if (conn.state != .writing) continue;

        // Simulate writing response (in real server, this would be actual I/O)
        const fd_as_u64: u64 = @bitCast(@as(i64, conn.fd));
        const simulated_write: u32 = 512 + @as(u32, @truncate(fd_as_u64 % 256));
        conn.bytes_written += simulated_write;
        stats.bytes_sent += simulated_write;

        // Mark connection as closed after writing
        conn.state = .closed;
    }
}

/// Cleanup system: Remove closed connections and update stats.
/// Demonstrates entity lifecycle management.
fn cleanupSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(ServerStats) orelse return;
    stats.tick_count = ctx.tick;

    // Count closed connections (would despawn in a real implementation)
    var closed_count: u32 = 0;
    var iter = ctx.world.query(AllConnectionsQuery);

    while (iter.next()) |result| {
        const conn = result.getRead(Connection);
        if (conn.state == .closed) {
            closed_count += 1;
        }
    }

    // Update active connection count
    if (stats.connections_active >= closed_count) {
        stats.connections_active -= closed_count;
    }

    // Report server status every 10 ticks
    if (@mod(ctx.tick, 10) == 0 and ctx.tick > 0) {
        var state_counts = [_]u32{ 0, 0, 0, 0, 0 };

        var status_iter = ctx.world.query(AllConnectionsQuery);
        while (status_iter.next()) |result| {
            const conn = result.getRead(Connection);
            state_counts[@intFromEnum(conn.state)] += 1;
        }

        std.debug.print("Tick {}: reqs={} active={} [acc:{} read:{} proc:{} write:{} closed:{}]\n", .{
            ctx.tick,
            stats.requests_total,
            stats.connections_active,
            state_counts[0],
            state_counts[1],
            state_counts[2],
            state_counts[3],
            state_counts[4],
        });
    }
}

// ============================================================================
// Configuration (defined AFTER systems)
// ============================================================================

pub const cfg = ecs.WorldConfig{
    .components = .{
        .types = &.{ Connection, Request, Response },
    },
    .archetypes = .{
        .archetypes = &.{
            // Basic connection (accepting/reading)
            .{ .name = "connection", .components = &.{Connection} },
            // Connection with parsed request
            .{ .name = "active_request", .components = &.{ Connection, Request } },
            // Connection with request and response
            .{ .name = "full_request", .components = &.{ Connection, Request, Response } },
        },
    },
    // Custom phases for HTTP processing pipeline
    .phases = .{
        .phases = &.{
            .{ .name = "accept", .order = 0 },
            .{ .name = "read", .order = 1 },
            .{ .name = "process", .order = 2 },
            .{ .name = "write", .order = 3 },
            .{ .name = "cleanup", .order = 4 },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "accept", .func = ecs.asSystemFn(acceptSystem), .phase = 0, .needs_io = true },
            .{ .name = "read", .func = ecs.asSystemFn(readSystem), .phase = 1, .needs_io = true },
            .{ .name = "process", .func = ecs.asSystemFn(processSystem), .phase = 2 },
            .{ .name = "write", .func = ecs.asSystemFn(writeSystem), .phase = 3, .needs_io = true },
            .{ .name = "cleanup", .func = ecs.asSystemFn(cleanupSystem), .phase = 4 },
        },
    },
    .resources = .{
        .types = &.{ ServerStats, ServerConfig },
    },
    .schedule = .{
        .execution_model = .blocking_single_thread, // Would use .evented_single_thread when std.Io is ready
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

    // Initialize resources
    _ = world.resources.insert(ServerStats, .{});
    _ = world.resources.insert(ServerConfig, .{
        .max_connections = 100,
        .read_timeout_ms = 5000,
        .keep_alive_timeout_ms = 30000,
    });

    std.debug.print("StaticECS HTTP Server Example\n", .{});
    std.debug.print("==============================\n", .{});
    std.debug.print("Demonstrating:\n", .{});
    std.debug.print("  - Connection entities with state machine\n", .{});
    std.debug.print("  - Request/response processing pipeline\n", .{});
    std.debug.print("  - Query iteration for connection management\n", .{});
    std.debug.print("  - Custom phases: accept → read → process → write → cleanup\n\n", .{});
    std.debug.print("Simulating 50 server ticks...\n\n", .{});

    var tick: u64 = 0;
    var scheduler = Scheduler.init(&world, null, allocator);

    // Run server simulation
    while (tick < 50) {
        const result = scheduler.tick(0.016); // ~60 Hz tick rate

        switch (result) {
            .success => {},
            .single_error => |err| std.debug.print("Server error: {any}\n", .{err}),
            .aggregate_errors => |errs| std.debug.print("Multiple errors: {}\n", .{errs.count}),
        }

        tick += 1;
    }

    // Print final statistics
    if (world.resources.getConst(ServerStats)) |stats| {
        std.debug.print("\n=== Final Server Stats ===\n", .{});
        std.debug.print("Total ticks: {}\n", .{stats.tick_count});
        std.debug.print("Connections total: {}\n", .{stats.connections_total});
        std.debug.print("Connections active: {}\n", .{stats.connections_active});
        std.debug.print("Requests total: {}\n", .{stats.requests_total});
        std.debug.print("Requests success: {}\n", .{stats.requests_success});
        std.debug.print("Requests error: {}\n", .{stats.requests_error});
        std.debug.print("Bytes received: {}\n", .{stats.bytes_received});
        std.debug.print("Bytes sent: {}\n", .{stats.bytes_sent});

        // Calculate throughput
        if (stats.tick_count > 0) {
            const rps = @as(f64, @floatFromInt(stats.requests_total)) / @as(f64, @floatFromInt(stats.tick_count));
            std.debug.print("Average requests/tick: {d:.2}\n", .{rps});
        }

        // Calculate success rate
        if (stats.requests_total > 0) {
            const success_rate = @as(f64, @floatFromInt(stats.requests_success)) / @as(f64, @floatFromInt(stats.requests_total)) * 100.0;
            std.debug.print("Success rate: {d:.1}%\n", .{success_rate});
        }
    }

    // Show final connection state distribution
    std.debug.print("\n=== Final Connection States ===\n", .{});
    var state_counts = [_]u32{ 0, 0, 0, 0, 0 };
    const state_names = [_][]const u8{ "accepting", "reading", "processing", "writing", "closed" };

    var final_iter = world.query(AllConnectionsQuery);
    while (final_iter.next()) |result| {
        const conn = result.getRead(Connection);
        state_counts[@intFromEnum(conn.state)] += 1;
    }

    for (state_counts, 0..) |count, i| {
        if (count > 0) {
            std.debug.print("  {s}: {}\n", .{ state_names[i], count });
        }
    }

    std.debug.print("\nNote: In production, use .evented_single_thread with io_uring/epoll\n", .{});
}
