//! StaticECS HTTP Server Example
//!
//! Demonstrates using StaticECS for an HTTP server:
//! - Connections as entities
//! - Async I/O via IoContext
//! - Custom phases for request processing
//!
//! Run with: zig build run-example-server

const std = @import("std");
const ecs = @import("ecs");

const FrameError = ecs.FrameError;

// ============================================================================
// Components
// ============================================================================

const ConnectionState = enum { accepting, reading, processing, writing, closed };

const Connection = struct {
    fd: i32 = -1,
    state: ConnectionState = .accepting,
    timestamp_ns: u64 = 0,
};

const Request = struct {
    method_len: u8 = 0,
    path_len: u8 = 0,
    content_length: u32 = 0,
    keep_alive: bool = false,
};

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
    requests_total: u64 = 0,
    tick_count: u64 = 0,
};

// ============================================================================
// System Functions (defined BEFORE config)
// ============================================================================

fn acceptSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);

    // Check for async I/O support
    if (ctx.hasIo()) {
        // Server demonstrates async capability
        _ = ctx.hasAsync();
    }

    // Simulate accepting connections every 5 ticks
    if (@mod(ctx.tick, 5) == 0) {
        const stats = ctx.world.resources.get(ServerStats) orelse return;
        _ = ctx.world.spawn("connection", .{
            Connection{ .fd = @intCast(ctx.tick), .state = .reading, .timestamp_ns = ctx.time_ns },
        }) catch {};
        stats.connections_active += 1;
    }
}

fn readSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // In a real server: read request data with async I/O
}

fn processSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // In a real server: process request, generate response
}

fn writeSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(ServerStats) orelse return;
    // Simulate completing requests
    if (stats.connections_active > 0) {
        stats.requests_total += 1;
        stats.connections_active -|= 1;
    }
}

fn cleanupSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(ServerStats) orelse return;
    stats.tick_count = ctx.tick;
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
            .{ .name = "connection", .components = &.{Connection} },
            .{ .name = "active_request", .components = &.{ Connection, Request } },
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
        .types = &.{ServerStats},
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

    _ = world.resources.insert(ServerStats, .{});

    std.debug.print("StaticECS HTTP Server Example\n", .{});
    std.debug.print("==============================\n", .{});
    std.debug.print("Custom phases: accept → read → process → write → cleanup\n\n", .{});

    var tick: u64 = 0;
    var scheduler = Scheduler.init(&world, null, allocator);

    while (tick < 50) {
        const result = scheduler.tick(0.016);

        switch (result) {
            .success => {},
            .single_error => |err| std.debug.print("Error: {any}\n", .{err}),
            .aggregate_errors => |errs| std.debug.print("Errors: {}\n", .{errs.count}),
        }

        if (@mod(tick, 10) == 0) {
            if (world.resources.getConst(ServerStats)) |stats| {
                std.debug.print("Tick {}: {} requests, {} active connections\n", .{
                    stats.tick_count,
                    stats.requests_total,
                    stats.connections_active,
                });
            }
        }

        tick += 1;
    }

    if (world.resources.getConst(ServerStats)) |stats| {
        std.debug.print("\n=== Final Stats ===\n", .{});
        std.debug.print("Total requests: {}\n", .{stats.requests_total});
        std.debug.print("Active connections: {}\n", .{stats.connections_active});
    }
}
