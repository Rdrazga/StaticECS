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

// Direct imports from within the ecs module (avoids circular dependency with ecs.zig)
const config = @import("config.zig");
const WorldConfig = config.WorldConfig;
const world_mod = @import("world.zig");
const entity = @import("world/entity.zig");

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

const BenchWorld = world_mod.World(BenchConfig);

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
    var handles: [1000]entity.EntityHandle = undefined;

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
    var handles: [1000]entity.EntityHandle = undefined;

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
    var handles: [100]entity.EntityHandle = undefined;
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
    var handles: [100]entity.EntityHandle = undefined;
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
    var handles: [100]entity.EntityHandle = undefined;
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
    var handles: [100]entity.EntityHandle = undefined;
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
    var handles: [500]entity.EntityHandle = undefined;

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

// ============================================================================
// Executable Entry Point (for `zig build benchmark`)
// ============================================================================

/// Main entry point for benchmark executable.
/// This allows benchmarks to run in ReleaseFast mode via `zig build benchmark`.
pub fn main() !void {
    const print = std.debug.print;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("\n", .{});
    print("╔══════════════════════════════════════════════════════════════════╗\n", .{});
    print("║               StaticECS Benchmark Suite                          ║\n", .{});
    print("║               Running in ReleaseFast mode                        ║\n", .{});
    print("╚══════════════════════════════════════════════════════════════════╝\n", .{});
    print("\n", .{});

    // Run all benchmarks and collect results
    var results: [7]BenchResult = undefined;
    var result_count: usize = 0;

    // Benchmark: Entity spawn throughput
    {
        var world = BenchWorld.init(allocator);
        defer world.deinit();

        const iterations: u64 = 10000;
        var handles: [10000]entity.EntityHandle = undefined;

        const start = time.Instant.now() catch unreachable;
        for (0..iterations) |i| {
            handles[i] = world.spawn("static", .{Position{}}) catch break;
        }
        const end = time.Instant.now() catch unreachable;
        const elapsed = end.since(start);

        results[result_count] = .{
            .name = "entity_spawn",
            .iterations = iterations,
            .total_ns = elapsed,
            .min_ns = elapsed / iterations,
            .max_ns = elapsed / iterations,
        };
        result_count += 1;

        // Cleanup for despawn benchmark
        const despawn_start = time.Instant.now() catch unreachable;
        for (0..iterations) |i| {
            world.despawn(handles[i]) catch break;
        }
        const despawn_end = time.Instant.now() catch unreachable;
        const despawn_elapsed = despawn_end.since(despawn_start);

        results[result_count] = .{
            .name = "entity_despawn",
            .iterations = iterations,
            .total_ns = despawn_elapsed,
            .min_ns = despawn_elapsed / iterations,
            .max_ns = despawn_elapsed / iterations,
        };
        result_count += 1;
    }

    // Benchmark: Component access
    {
        var world = BenchWorld.init(allocator);
        defer world.deinit();

        var handles: [100]entity.EntityHandle = undefined;
        for (0..100) |i| {
            handles[i] = world.spawn("moving", .{
                Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
                Velocity{ .dx = 1, .dy = 0, .dz = 0 },
            }) catch break;
        }

        const iterations: u64 = 100000;
        var sum: f32 = 0;

        const start = time.Instant.now() catch unreachable;
        for (0..iterations) |i| {
            const handle = handles[i % 100];
            if (world.getComponent(handle, Position)) |pos| {
                sum += pos.x;
            }
        }
        const end = time.Instant.now() catch unreachable;
        std.mem.doNotOptimizeAway(sum);

        results[result_count] = .{
            .name = "component_access",
            .iterations = iterations,
            .total_ns = end.since(start),
            .min_ns = end.since(start) / iterations,
            .max_ns = end.since(start) / iterations,
        };
        result_count += 1;
    }

    // Benchmark: Component mutation
    {
        var world = BenchWorld.init(allocator);
        defer world.deinit();

        var handles: [100]entity.EntityHandle = undefined;
        for (0..100) |i| {
            handles[i] = world.spawn("moving", .{
                Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
                Velocity{ .dx = 1, .dy = 0, .dz = 0 },
            }) catch break;
        }

        const iterations: u64 = 100000;

        const start = time.Instant.now() catch unreachable;
        for (0..iterations) |i| {
            const handle = handles[i % 100];
            _ = world.setComponent(handle, Position, Position{ .x = @floatFromInt(i), .y = 0, .z = 0 });
        }
        const end = time.Instant.now() catch unreachable;

        results[result_count] = .{
            .name = "component_mutation",
            .iterations = iterations,
            .total_ns = end.since(start),
            .min_ns = end.since(start) / iterations,
            .max_ns = end.since(start) / iterations,
        };
        result_count += 1;
    }

    // Benchmark: hasComponent check
    {
        var world = BenchWorld.init(allocator);
        defer world.deinit();

        var handles: [100]entity.EntityHandle = undefined;
        for (0..100) |i| {
            handles[i] = world.spawn("moving", .{
                Position{ .x = @floatFromInt(i), .y = 0, .z = 0 },
                Velocity{ .dx = 1, .dy = 0, .dz = 0 },
            }) catch break;
        }

        const iterations: u64 = 100000;
        var has_count: u64 = 0;

        const start = time.Instant.now() catch unreachable;
        for (0..iterations) |i| {
            const handle = handles[i % 100];
            if (world.hasComponent(handle, Position)) {
                has_count += 1;
            }
        }
        const end = time.Instant.now() catch unreachable;
        std.mem.doNotOptimizeAway(has_count);

        results[result_count] = .{
            .name = "hasComponent_check",
            .iterations = iterations,
            .total_ns = end.since(start),
            .min_ns = end.since(start) / iterations,
            .max_ns = end.since(start) / iterations,
        };
        result_count += 1;
    }

    // Benchmark: isAlive check
    {
        var world = BenchWorld.init(allocator);
        defer world.deinit();

        var handles: [100]entity.EntityHandle = undefined;
        for (0..100) |i| {
            handles[i] = world.spawn("static", .{Position{}}) catch break;
        }

        const iterations: u64 = 100000;
        var alive_count: u64 = 0;

        const start = time.Instant.now() catch unreachable;
        for (0..iterations) |i| {
            const handle = handles[i % 100];
            if (world.isAlive(handle)) {
                alive_count += 1;
            }
        }
        const end = time.Instant.now() catch unreachable;
        std.mem.doNotOptimizeAway(alive_count);

        results[result_count] = .{
            .name = "isAlive_check",
            .iterations = iterations,
            .total_ns = end.since(start),
            .min_ns = end.since(start) / iterations,
            .max_ns = end.since(start) / iterations,
        };
        result_count += 1;
    }

    // Benchmark: Full entity with large component
    {
        var world = BenchWorld.init(allocator);
        defer world.deinit();

        const iterations: u64 = 5000;
        var handles: [5000]entity.EntityHandle = undefined;

        const start = time.Instant.now() catch unreachable;
        for (0..iterations) |i| {
            handles[i] = world.spawn("full", .{
                Position{},
                Velocity{},
                Health{},
                Transform{},
            }) catch break;
        }
        const end = time.Instant.now() catch unreachable;

        results[result_count] = .{
            .name = "full_entity_spawn",
            .iterations = iterations,
            .total_ns = end.since(start),
            .min_ns = end.since(start) / iterations,
            .max_ns = end.since(start) / iterations,
        };
        result_count += 1;
    }

    // Print results
    print("┌────────────────────────┬───────────────┬───────────────┬───────────────┐\n", .{});
    print("│ Benchmark              │ Iterations    │ ns/op         │ ops/sec       │\n", .{});
    print("├────────────────────────┼───────────────┼───────────────┼───────────────┤\n", .{});

    for (results[0..result_count]) |result| {
        print("│ {s:<22} │ {d:>13} │ {d:>13} │ {d:>13} │\n", .{
            result.name,
            result.iterations,
            result.avgNs(),
            result.opsPerSec(),
        });
    }

    print("└────────────────────────┴───────────────┴───────────────┴───────────────┘\n", .{});
    print("\n", .{});
}
