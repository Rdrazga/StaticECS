//! StaticECS Data Pipeline Example
//!
//! Demonstrates using StaticECS for ETL/data processing:
//! - Records as entities moving through processing stages
//! - Custom phases for pipeline stages
//! - Query iteration with stage-based filtering
//! - Component modification for stage transitions
//! - Resource-based statistics tracking
//!
//! Run with: zig build run-example-pipeline

const std = @import("std");
const ecs = @import("ecs");

const FrameError = ecs.FrameError;
const Query = ecs.query.Query;

// ============================================================================
// Components
// ============================================================================

/// Processing stage for a record
const Stage = enum {
    ingested, // Just received
    validated, // Passed validation
    transformed, // Data transformed
    completed, // Successfully output
    failed, // Processing failed

    fn name(self: Stage) []const u8 {
        return switch (self) {
            .ingested => "ingested",
            .validated => "validated",
            .transformed => "transformed",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

/// Core record component tracking processing state
const Record = struct {
    id: u64,
    stage: Stage = .ingested,
    retry_count: u8 = 0,
};

/// Raw data as initially received
const RawData = struct {
    data_len: usize = 0,
    timestamp_ns: u64 = 0,
    checksum: u32 = 0,
};

/// Parsed and validated data
const ParsedData = struct {
    user_id: u64 = 0,
    value: f64 = 0,
    valid: bool = false,
};

/// Transformed output data
const OutputData = struct {
    normalized_value: f64 = 0,
    category: u8 = 0,
    output_timestamp: u64 = 0,
};

// ============================================================================
// Resources
// ============================================================================

const PipelineStats = struct {
    records_ingested: u64 = 0,
    records_validated: u64 = 0,
    records_transformed: u64 = 0,
    records_completed: u64 = 0,
    records_failed: u64 = 0,
    tick_count: u64 = 0,
    validation_errors: u64 = 0,
};

// ============================================================================
// Query Specifications
// ============================================================================

/// Query for newly ingested records that need validation
const IngestedRecordQuery = Query(.{
    .read = &.{RawData},
    .write = &.{Record},
});

/// Query for validated records needing transformation
const ValidatedRecordQuery = Query(.{
    .read = &.{ Record, RawData, ParsedData },
    .write = &.{},
});

/// Query for records with output data ready to complete
const OutputReadyQuery = Query(.{
    .read = &.{ ParsedData, OutputData },
    .write = &.{Record},
});

/// Query for all records (status check)
const AllRecordsQuery = Query(.{
    .read = &.{Record},
    .optional = &.{ RawData, ParsedData, OutputData },
});

// ============================================================================
// System Functions (defined BEFORE config)
// ============================================================================

/// Ingest system: Creates new records from simulated input.
/// Demonstrates entity spawning and resource updates.
fn ingestSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;

    // Simulate batch ingestion every 3 ticks
    if (@mod(ctx.tick, 3) == 0) {
        const batch_size: usize = 5;
        for (0..batch_size) |i| {
            const record_id = ctx.tick * 10 + i;

            // Simulate varying data quality (some records have bad checksums)
            const checksum: u32 = if (@mod(record_id, 7) == 0)
                0xDEADBEEF // Bad checksum for testing failures
            else
                @truncate(record_id * 31); // Valid checksum

            _ = ctx.world.spawn("record", .{
                Record{ .id = record_id, .stage = .ingested },
                RawData{
                    .data_len = 100 + i * 10,
                    .timestamp_ns = ctx.time_ns,
                    .checksum = checksum,
                },
            }) catch continue;

            stats.records_ingested += 1;
        }
    }
}

/// Validate system: Validates raw records and transitions them to validated stage.
/// Demonstrates query iteration with stage filtering and component modification.
fn validateSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;

    var iter = ctx.world.query(IngestedRecordQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const record = result.getWrite(Record);

        // Only process ingested records
        if (record.stage != .ingested) continue;

        const raw = result.getRead(RawData);

        // Validate checksum (simple validation logic)
        const is_valid = raw.checksum != 0xDEADBEEF and raw.data_len > 0;

        if (is_valid) {
            // Transition to validated stage
            record.stage = .validated;
            stats.records_validated += 1;
        } else {
            // Mark as failed
            record.stage = .failed;
            stats.records_failed += 1;
            stats.validation_errors += 1;
        }
    }
}

/// Transform system: Transforms validated data into output format.
/// Demonstrates stage transitions and data processing.
fn transformSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;

    // Query for records that have been validated
    var iter = ctx.world.query(IngestedRecordQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const record = result.getWrite(Record);

        // Only transform validated records
        if (record.stage != .validated) continue;

        const raw = result.getRead(RawData);

        // Simulate parsing: extract user_id and value from raw data
        // In a real pipeline, these would be stored in ParsedData component
        const parsed_user_id: u64 = (record.id * 17) % 1000;
        const parsed_value: f64 = @as(f64, @floatFromInt(raw.data_len)) / 100.0;

        // Log transformation for demonstration (only for first few records)
        if (stats.records_transformed < 3) {
            std.debug.print("  Transform: record {} -> user_id={} value={d:.2}\n", .{
                record.id,
                parsed_user_id,
                parsed_value,
            });
        }

        record.stage = .transformed;
        stats.records_transformed += 1;
    }
}

/// Output system: Completes processing and outputs records.
/// Demonstrates final stage processing.
fn outputSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;

    var iter = ctx.world.query(IngestedRecordQuery);

    while (iter.next()) |const_result| {
        var result = const_result;
        const record = result.getWrite(Record);

        // Only output transformed records
        if (record.stage != .transformed) continue;

        // Mark as completed
        record.stage = .completed;
        stats.records_completed += 1;
    }
}

/// Cleanup system: Updates stats and reports pipeline health.
/// Demonstrates periodic reporting with resource access.
fn cleanupSystem(ctx_ptr: *anyopaque) FrameError!void {
    const ctx = getContext(ctx_ptr);
    const stats = ctx.world.resources.get(PipelineStats) orelse return;
    stats.tick_count = ctx.tick;

    // Report pipeline status every 10 ticks
    if (@mod(ctx.tick, 10) == 0 and ctx.tick > 0) {
        var stage_counts = [_]u32{ 0, 0, 0, 0, 0 };

        var iter = ctx.world.query(AllRecordsQuery);
        while (iter.next()) |result| {
            const record = result.getRead(Record);
            stage_counts[@intFromEnum(record.stage)] += 1;
        }

        std.debug.print("Tick {}: stages=[ing:{}, val:{}, trans:{}, done:{}, fail:{}]\n", .{
            ctx.tick,
            stage_counts[0], // ingested
            stage_counts[1], // validated
            stage_counts[2], // transformed
            stage_counts[3], // completed
            stage_counts[4], // failed
        });
    }
}

// ============================================================================
// Configuration (defined AFTER systems)
// ============================================================================

pub const cfg = ecs.WorldConfig{
    .components = .{
        .types = &.{ Record, RawData, ParsedData, OutputData },
    },
    .archetypes = .{
        .archetypes = &.{
            // Basic record with raw data
            .{ .name = "record", .components = &.{ Record, RawData } },
            // Record with parsed data (after validation)
            .{ .name = "parsed_record", .components = &.{ Record, RawData, ParsedData } },
            // Record ready for output
            .{ .name = "output_record", .components = &.{ Record, RawData, ParsedData, OutputData } },
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
    std.debug.print("Demonstrating:\n", .{});
    std.debug.print("  - Entity processing through pipeline stages\n", .{});
    std.debug.print("  - Query iteration with stage filtering\n", .{});
    std.debug.print("  - Component-based state transitions\n", .{});
    std.debug.print("  - Custom phases: ingest → validate → transform → output → cleanup\n\n", .{});

    var tick: u64 = 0;
    var scheduler = Scheduler.init(&world, null, allocator);

    // Run pipeline for 30 ticks
    while (tick < 30) {
        const result = scheduler.tick(0.016);

        switch (result) {
            .success => {},
            .single_error => |err| std.debug.print("Pipeline error: {any}\n", .{err}),
            .aggregate_errors => |errs| std.debug.print("Multiple errors: {}\n", .{errs.count}),
        }

        tick += 1;
    }

    // Print final statistics
    if (world.resources.getConst(PipelineStats)) |stats| {
        std.debug.print("\n=== Final Pipeline Stats ===\n", .{});
        std.debug.print("Total ticks: {}\n", .{stats.tick_count});
        std.debug.print("Records ingested: {}\n", .{stats.records_ingested});
        std.debug.print("Records validated: {}\n", .{stats.records_validated});
        std.debug.print("Records transformed: {}\n", .{stats.records_transformed});
        std.debug.print("Records completed: {}\n", .{stats.records_completed});
        std.debug.print("Records failed: {}\n", .{stats.records_failed});
        std.debug.print("Validation errors: {}\n", .{stats.validation_errors});

        // Calculate throughput
        const total_processed = stats.records_completed + stats.records_failed;
        if (stats.tick_count > 0) {
            const throughput = @as(f64, @floatFromInt(total_processed)) / @as(f64, @floatFromInt(stats.tick_count));
            std.debug.print("Average throughput: {d:.2} records/tick\n", .{throughput});
        }
    }

    // Show final record stage distribution
    std.debug.print("\n=== Final Stage Distribution ===\n", .{});
    var stage_counts = [_]u32{ 0, 0, 0, 0, 0 };
    const stage_names = [_][]const u8{ "ingested", "validated", "transformed", "completed", "failed" };

    var final_iter = world.query(AllRecordsQuery);
    while (final_iter.next()) |result| {
        const record = result.getRead(Record);
        stage_counts[@intFromEnum(record.stage)] += 1;
    }

    for (stage_counts, 0..) |count, i| {
        std.debug.print("  {s}: {}\n", .{ stage_names[i], count });
    }
}
