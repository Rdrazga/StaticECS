//! Multi-world coordination configuration types for StaticECS (Phase 5).
//!
//! This module defines configurations for coordinating multiple worlds
//! in a pipeline architecture:
//! - World roles (accept, I/O, compute, etc.)
//! - Transfer queues for entity passing
//! - Routing rules for entity direction

// ============================================================================
// World Role
// ============================================================================

/// Role of a world in a multi-world setup.
/// Determines default component types, scheduling hints, and optimizations.
/// Tiger Style: Each role can have different optimization profiles.
pub const WorldRole = enum {
    /// Default standalone world (current behavior, no coordination).
    /// Suitable for simple applications that don't need multi-world pipelines.
    standalone,

    /// Accept world: handles connection acceptance.
    /// Optimized for: low latency, high connection rate, minimal component set.
    /// Typically runs on a dedicated thread polling for new connections.
    accept,

    /// I/O world: handles read/write operations.
    /// Optimized for: syscall batching, buffer management, io_uring usage.
    /// Best paired with io_uring_batch execution model on Linux.
    io,

    /// Compute world: handles CPU-bound processing.
    /// Optimized for: cache efficiency, parallelism, work-stealing.
    /// Best paired with work_stealing or concurrent_threadpool execution model.
    compute,

    /// Custom role for user-defined pipelines.
    /// No built-in optimizations; user controls all behavior.
    custom,
};

// ============================================================================
// Transfer Queue Configuration
// ============================================================================

/// Configuration for transfer queues between worlds.
/// Tiger Style: All bounds configurable, power-of-two for efficient modulo.
pub const TransferQueueConfig = struct {
    /// Queue capacity (bounded). Must be power of 2 for lock-free efficiency.
    /// Default 4096 allows high throughput while limiting memory usage.
    capacity: u32 = 4096,

    /// Batch size for bulk transfers. Larger batches reduce overhead.
    /// Default 64 balances latency vs throughput.
    batch_size: u32 = 64,

    /// Enable single-producer-single-consumer optimization.
    /// Use when only one world produces and one consumes (most pipeline patterns).
    /// Enables more efficient lock-free algorithm with relaxed ordering.
    spsc: bool = false,
};

// ============================================================================
// Routing Configuration
// ============================================================================

/// Component-based routing rule for entity transfers.
/// Routes entities to specific target worlds based on component presence.
pub const ComponentRoute = struct {
    /// Name of the component type to match (for comptime lookup).
    component_name: []const u8,
    /// Target world ID for entities with this component.
    target_world: u8,
};

/// Configuration for entity routing between worlds.
/// Determines how entities are directed after processing.
pub const RoutingConfig = struct {
    /// Default target world for completed entities (null = no auto-routing).
    /// Entities without explicit routing markers go to this world.
    default_target: ?u8 = null,

    /// Component-based routing rules (evaluated at comptime).
    /// Higher indices take precedence when multiple routes match.
    component_routes: []const ComponentRoute = &.{},
};

// ============================================================================
// Combined World Coordination Configuration
// ============================================================================

/// Configuration for world coordination in multi-world pipelines.
/// When role is .standalone, coordination features are compiled out.
/// Tiger Style: Zero overhead when not using multi-world features.
pub const WorldCoordinationConfig = struct {
    /// Role of this world in the pipeline.
    role: WorldRole = .standalone,

    /// Unique world ID (unique within a WorldCoordinator).
    /// Used as index into transfer queue arrays.
    /// Must be < world count in coordinator.
    world_id: u8 = 0,

    /// Transfer queue configuration for incoming/outgoing entities.
    transfer_queue: TransferQueueConfig = .{},

    /// Entity routing configuration for outgoing transfers.
    routing: RoutingConfig = .{},
};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "WorldRole enum values" {
    // Verify all world roles are defined
    try std.testing.expectEqual(WorldRole.standalone, WorldRole.standalone);
    try std.testing.expectEqual(WorldRole.accept, WorldRole.accept);
    try std.testing.expectEqual(WorldRole.io, WorldRole.io);
    try std.testing.expectEqual(WorldRole.compute, WorldRole.compute);
    try std.testing.expectEqual(WorldRole.custom, WorldRole.custom);

    // Verify roles are distinct
    try std.testing.expect(WorldRole.standalone != WorldRole.accept);
    try std.testing.expect(WorldRole.io != WorldRole.compute);
}

test "TransferQueueConfig defaults" {
    // Verify default transfer queue configuration
    const cfg = TransferQueueConfig{};

    // Default capacity should be power of 2
    try std.testing.expectEqual(@as(u32, 4096), cfg.capacity);

    // Verify batch size is reasonable
    try std.testing.expectEqual(@as(u32, 64), cfg.batch_size);
    try std.testing.expect(cfg.batch_size < cfg.capacity);

    // SPSC should be disabled by default (more flexible)
    try std.testing.expect(!cfg.spsc);
}

test "TransferQueueConfig custom values" {
    // Test custom configuration
    const cfg = TransferQueueConfig{
        .capacity = 8192,
        .batch_size = 128,
        .spsc = true,
    };

    try std.testing.expectEqual(@as(u32, 8192), cfg.capacity);
    try std.testing.expectEqual(@as(u32, 128), cfg.batch_size);
    try std.testing.expect(cfg.spsc);
}

test "RoutingConfig defaults" {
    // Verify default routing configuration
    const cfg = RoutingConfig{};

    // No default target by default (no auto-routing)
    try std.testing.expectEqual(@as(?u8, null), cfg.default_target);

    // Empty component routes
    try std.testing.expectEqual(@as(usize, 0), cfg.component_routes.len);
}

test "RoutingConfig with default target" {
    // Test routing with default target
    const cfg = RoutingConfig{
        .default_target = 2, // Route to world 2 by default
    };

    try std.testing.expectEqual(@as(?u8, 2), cfg.default_target);
}

test "RoutingConfig component-based routing" {
    // Test component-based routing rules
    const cfg = RoutingConfig{
        .default_target = 0,
        .component_routes = &[_]ComponentRoute{
            .{ .component_name = "NetworkComponent", .target_world = 1 },
            .{ .component_name = "ComputeComponent", .target_world = 2 },
            .{ .component_name = "StorageComponent", .target_world = 3 },
        },
    };

    try std.testing.expectEqual(@as(usize, 3), cfg.component_routes.len);
    try std.testing.expectEqualStrings("NetworkComponent", cfg.component_routes[0].component_name);
    try std.testing.expectEqual(@as(u8, 1), cfg.component_routes[0].target_world);
    try std.testing.expectEqualStrings("ComputeComponent", cfg.component_routes[1].component_name);
    try std.testing.expectEqual(@as(u8, 2), cfg.component_routes[1].target_world);
}

test "WorldCoordinationConfig defaults" {
    // Verify default coordination configuration
    const cfg = WorldCoordinationConfig{};

    // Default role is standalone
    try std.testing.expectEqual(WorldRole.standalone, cfg.role);

    // Default world ID is 0
    try std.testing.expectEqual(@as(u8, 0), cfg.world_id);

    // Verify nested defaults
    try std.testing.expectEqual(@as(u32, 4096), cfg.transfer_queue.capacity);
    try std.testing.expectEqual(@as(?u8, null), cfg.routing.default_target);
}

test "WorldCoordinationConfig accept world" {
    // Test accept world configuration
    const cfg = WorldCoordinationConfig{
        .role = .accept,
        .world_id = 0,
        .transfer_queue = .{
            .capacity = 8192, // Higher capacity for accept world
            .batch_size = 32, // Smaller batches for lower latency
            .spsc = true, // SPSC for accept -> IO handoff
        },
        .routing = .{
            .default_target = 1, // Route to IO world
        },
    };

    try std.testing.expectEqual(WorldRole.accept, cfg.role);
    try std.testing.expectEqual(@as(u8, 0), cfg.world_id);
    try std.testing.expectEqual(@as(u32, 8192), cfg.transfer_queue.capacity);
    try std.testing.expect(cfg.transfer_queue.spsc);
    try std.testing.expectEqual(@as(?u8, 1), cfg.routing.default_target);
}

test "WorldCoordinationConfig IO world" {
    // Test IO world configuration
    const cfg = WorldCoordinationConfig{
        .role = .io,
        .world_id = 1,
        .transfer_queue = .{
            .batch_size = 128, // Larger batches for I/O efficiency
        },
        .routing = .{
            .default_target = 2, // Route to compute world
        },
    };

    try std.testing.expectEqual(WorldRole.io, cfg.role);
    try std.testing.expectEqual(@as(u8, 1), cfg.world_id);
    try std.testing.expectEqual(@as(u32, 128), cfg.transfer_queue.batch_size);
}

test "WorldCoordinationConfig compute world" {
    // Test compute world configuration
    const cfg = WorldCoordinationConfig{
        .role = .compute,
        .world_id = 2,
        .routing = .{
            .component_routes = &[_]ComponentRoute{
                // Route based on component type
                .{ .component_name = "Response", .target_world = 1 },
            },
        },
    };

    try std.testing.expectEqual(WorldRole.compute, cfg.role);
    try std.testing.expectEqual(@as(u8, 2), cfg.world_id);
    try std.testing.expectEqual(@as(usize, 1), cfg.routing.component_routes.len);
}

test "ComponentRoute struct" {
    // Test individual component route
    const route = ComponentRoute{
        .component_name = "MyComponent",
        .target_world = 5,
    };

    try std.testing.expectEqualStrings("MyComponent", route.component_name);
    try std.testing.expectEqual(@as(u8, 5), route.target_world);
}
