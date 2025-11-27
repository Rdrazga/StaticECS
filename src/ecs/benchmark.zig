//! Benchmark Suite for StaticECS
//!
//! This module provides performance benchmarks for core ECS operations.
//! Run with: zig build bench
//!
//! Benchmarks measure:
//! - Entity spawn/despawn throughput
//! - Component access latency
//! - Query iteration speed
//! - System execution overhead

const std = @import("std");
const time = std.time;
const testing = std.testing;

const ecs = @import("../ecs.zig");
const WorldConfig = ecs.WorldConfig;

// ============================================================================
// Benchmark Components
// ============================================================================

const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

const Velocity = struct {
    dx: f32 = 0,
    dy: f32 = 0,
    dz: f32 = 0,
};

const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
};

const Transform = struct {
    matrix: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },
};

// ============================================================================
// Benchmark Configuration
// ============================================================================

const BenchConfig = WorldConfig{
    .components = .{
        .types = &.{ Position, Velocity, Health, Transform },
    },
    .archetypes = .{
        .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
            .{ .name = "moving", .components = &.{ Position, Velocity } },
            .{ .name = "living", .components = &.{ Position, Health } },
            .{ .name = "full", .components = &.{ Position, Velocity, Health, Transform } },
        },
    },
    .options = .{
        .max_entities = 65536,
        .enable_debug_asserts = false, // Disable for accurate benchmarks
    },
};

const BenchWorld = ecs.World(BenchConfig);

// ============================================================================
// Timing Utilities
// ============================================================================

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,

    fn avgNs(self: BenchResult) u64 {
        return self.total_ns / self.iterations;
    }

    fn opsPerSec(self: BenchResult) u64 {
        if (self.avgNs() == 0) return 0;
        return @divFloor(1_000_000_000, self.avgNs());
    }

    fn format(self: BenchResult, writer: anytype) !void {
        try writer.print("{s}: {d} ops, {d} ns/op avg, {d} ops/sec\n", .{
            self.name,
            self.iterations,
            self.avgNs(),
            self.opsPerSec(),
        });
    }
};

fn benchmark(comptime name: []const u8, iterations: u64, func: anytype) BenchResult {
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..iterations) |_| {
        const start = time.Instant.now() catch {
            // Platform doesn't support high-resolution timing
            return .{ .name = name, .iterations = 0, .total_ns = 0, .min_ns = 0, .max_ns = 0 };
        };
        func();
        const end = time.Instant.now() catch {
            return .{ .name = name, .iterations = 0, .total_ns = 0, .min_ns = 0, .max_ns = 0 };
        };

        const elapsed = end.since(start);
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

// ============================================================================
// Benchmark Tests (run as part of test suite for verification)
// ============================================================================

test "bench: entity spawn throughput" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    const iterations: u64 = 1000;
    var handles: [1000]ecs.entity.EntityHandle = undefined;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        handles[i] = try world.spawn("static", .{Position{}});
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_spawn = elapsed / iterations;

    // Cleanup
    for (handles[0..iterations]) |h| {
        try world.despawn(h);
    }

    // Verify reasonable performance (should be < 10us per spawn)
    try testing.expect(ns_per_spawn < 10_000);
}

test "bench: entity despawn throughput" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    const iterations: u64 = 1000;
    var handles: [1000]ecs.entity.EntityHandle = undefined;

    // Spawn first
    for (0..iterations) |i| {
        handles[i] = try world.spawn("static", .{Position{}});
    }

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        try world.despawn(handles[i]);
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_despawn = elapsed / iterations;

    // Verify reasonable performance (should be < 10us per despawn)
    try testing.expect(ns_per_despawn < 10_000);
}

test "bench: component access" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    var handles: [100]ecs.entity.EntityHandle = undefined;
    for (0..100) |i| {
        handles[i] = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        });
    }

    const iterations: u64 = 10000;
    var sum: f32 = 0;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        const handle = handles[i % 100];
        if (world.getComponent(handle, Position)) |pos| {
            sum += pos.x;
        }
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_access = elapsed / iterations;

    // Prevent optimization of sum
    try testing.expect(sum > 0);

    // Verify reasonable performance (should be < 1us per access)
    try testing.expect(ns_per_access < 1_000);
}

test "bench: component mutation" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    var handles: [100]ecs.entity.EntityHandle = undefined;
    for (0..100) |i| {
        handles[i] = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        });
    }

    const iterations: u64 = 10000;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        const handle = handles[i % 100];
        _ = world.setComponent(handle, Position, Position{ .x = @floatFromInt(i), .y = 0, .z = 0 });
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_mutation = elapsed / iterations;

    // Verify reasonable performance (should be < 1us per mutation)
    try testing.expect(ns_per_mutation < 1_000);
}

test "bench: hasComponent check" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    var handles: [100]ecs.entity.EntityHandle = undefined;
    for (0..100) |i| {
        handles[i] = try world.spawn("moving", .{
            Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
            Velocity{ .dx = 1, .dy = 0, .dz = 0 },
        });
    }

    const iterations: u64 = 10000;
    var has_count: u64 = 0;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        const handle = handles[i % 100];
        if (world.hasComponent(handle, Position)) {
            has_count += 1;
        }
        if (world.hasComponent(handle, Velocity)) {
            has_count += 1;
        }
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_check = elapsed / (iterations * 2);

    // Should have found all
    try testing.expectEqual(@as(u64, iterations * 2), has_count);

    // Verify reasonable performance (should be < 500ns per check)
    try testing.expect(ns_per_check < 500);
}

test "bench: isAlive check" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    // Spawn entities
    var handles: [100]ecs.entity.EntityHandle = undefined;
    for (0..100) |i| {
        handles[i] = try world.spawn("static", .{Position{}});
    }

    const iterations: u64 = 10000;
    var alive_count: u64 = 0;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        const handle = handles[i % 100];
        if (world.isAlive(handle)) {
            alive_count += 1;
        }
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_check = elapsed / iterations;

    // Should all be alive
    try testing.expectEqual(@as(u64, iterations), alive_count);

    // Verify reasonable performance (should be < 200ns per check)
    try testing.expect(ns_per_check < 200);
}

test "bench: full entity with large component" {
    var world = BenchWorld.init(testing.allocator);
    defer world.deinit();

    const iterations: u64 = 500;
    var handles: [500]ecs.entity.EntityHandle = undefined;

    const start = try time.Instant.now();

    for (0..iterations) |i| {
        handles[i] = try world.spawn("full", .{
            Position{},
            Velocity{},
            Health{},
            Transform{}, // 64 bytes
        });
    }

    const end = try time.Instant.now();
    const elapsed = end.since(start);
    const ns_per_spawn = elapsed / iterations;

    // Cleanup
    for (handles[0..iterations]) |h| {
        try world.despawn(h);
    }

    // Large component spawn should still be < 50us
    try testing.expect(ns_per_spawn < 50_000);
}

// ============================================================================
// Summary Report (can be run standalone)
// ============================================================================

test "bench: print summary" {
    // This test just verifies the benchmark infrastructure works
    // In a real benchmark run, you'd call printSummary() from main()
    const result = BenchResult{
        .name = "test",
        .iterations = 100,
        .total_ns = 10000,
        .min_ns = 50,
        .max_ns = 200,
    };

    try testing.expectEqual(@as(u64, 100), result.avgNs());
    try testing.expectEqual(@as(u64, 10_000_000), result.opsPerSec());
}
