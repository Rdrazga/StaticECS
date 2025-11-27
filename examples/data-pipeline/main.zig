//! StaticECS Data Pipeline Example
//!
//! Demonstrates using StaticECS for ETL/data processing:
//! - Records as entities moving through processing stages
//! - Custom phases for pipeline stages
//! - Resource-based statistics
//!
//! Run with: zig build run-example-pipeline

const std = @import("std");
const ecs = @import("ecs");

const FrameError = ecs.FrameError;

// ============================================================================
// Components
// ============================================================================

const Stage = enum { ingested, validated, transformed, completed, failed };

const Record = struct {
    id: u64,
    stage: Stage = .ingested,
};

const RawData = struct {
    data_len: usize = 0,
    timestamp_ns: u64 = 0,
};

const ParsedData = struct {
    user_id: u64 = 0,
    value: f64 = 0,
    valid: bool = false,
};

// ============================================================================
// Resources
// ============================================================================

const PipelineStats = struct {
    records_ingested: u64 = 0,
    records_completed: u64 = 0,
    records_failed: u64 = 0,
    tick_count: u64 = 0,
};

// ============================================================================
// System Functions (defined BEFORE config)
// ============================================================================

fn ingestSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;

    // Simulate batch ingestion every 3 ticks
    if (@mod(ctx.tick, 3) == 0) {
        for (0..5) |i| {
            _ = ctx.world.spawn("record", .{
                Record{ .id = ctx.tick * 10 + i, .stage = .ingested },
                RawData{ .data_len = 100, .timestamp_ns = ctx.time_ns },
            }) catch {};
            stats.records_ingested += 1;
        }
    }
}

fn validateSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // In a real pipeline: validate and parse records
}

fn transformSystem(ctx_ptr: *anyopaque) FrameError!void {
    _ = ctx_ptr;
    // In a real pipeline: transform and normalize data
}

fn outputSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;
    // In a real pipeline: write to output destination
    stats.records_completed += stats.records_ingested / 2;
}

fn cleanupSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;
    stats.tick_count = ctx.tick;
}

// ============================================================================
// Configuration (defined AFTER systems)
// ============================================================================

pub const cfg = ecs.WorldConfig{
    .components = .{
        .types = &.{ Record, RawData, ParsedData },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "record", .components = &.{ Record, RawData } },
            .{ .name = "parsed_record", .components = &.{ Record, RawData, ParsedData } },
        },
    },
    // Custom phases for pipeline stages
    .phases = .{
        .phases = &.{
            .{ .name = "ingest", .order = 0 },
            .{ .name = "validate", .order = 1 },
            .{ .name = "transform", .order = 2 },
            .{ .name = "output", .order = 3 },
            .{ .name = "cleanup", .order = 4 },
        },
    },
    .systems = .{
        .systems = &.{
            .{ .name = "ingest", .func = ecs.asSystemFn(ingestSystem), .phase = 0 },
            .{ .name = "validate", .func = ecs.asSystemFn(validateSystem), .phase = 1 },
            .{ .name = "transform", .func = ecs.asSystemFn(transformSystem), .phase = 2 },
            .{ .name = "output", .func = ecs.asSystemFn(outputSystem), .phase = 3 },
            .{ .name = "cleanup", .func = ecs.asSystemFn(cleanupSystem), .phase = 4 },
        },
    },
    .resources = .{
        .types = &.{PipelineStats},
    },
    .options = .{
        .max_entities = 10000,
        .max_commands_per_frame = 256,
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

    _ = world.resources.insert(PipelineStats, .{});

    std.debug.print("StaticECS Data Pipeline Example\n", .{});
    std.debug.print("================================\n", .{});
    std.debug.print("Custom phases: ingest → validate → transform → output → cleanup\n\n", .{});

    var tick: u64 = 0;
    var scheduler = Scheduler.init(&world, null, allocator);

    while (tick < 30) {
        const result = scheduler.tick(0.016);

        switch (result) {
            .success => {},
            .single_error => |err| std.debug.print("Error: {any}\n", .{err}),
            .aggregate_errors => |errs| std.debug.print("Errors: {}\n", .{errs.count}),
        }

        if (@mod(tick, 10) == 0) {
            if (world.resources.getConst(PipelineStats)) |stats| {
                std.debug.print("Tick {}: ingested={} completed={}\n", .{
                    stats.tick_count,
                    stats.records_ingested,
                    stats.records_completed,
                });
            }
        }

        tick += 1;
    }

    if (world.resources.getConst(PipelineStats)) |stats| {
        std.debug.print("\n=== Final Pipeline Stats ===\n", .{});
        std.debug.print("Ingested: {}\n", .{stats.records_ingested});
        std.debug.print("Completed: {}\n", .{stats.records_completed});
    }
}
