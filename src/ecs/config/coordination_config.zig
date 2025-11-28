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
