//! StaticECS - A comptime-driven Entity Component System
//!
//! This module provides the public API for StaticECS. All structural aspects
//! of a world (components, archetypes, systems, scheduling hints, tick behavior)
//! are defined at compile time from a single `WorldConfig` value.
//!
//! ## Quick Start
//! ```zig
//! const ecs = @import("static-ecs");
//!
//! // Define components
//! const Position = struct { x: f32, y: f32, z: f32 };
//! const Velocity = struct { dx: f32, dy: f32, dz: f32 };
//!
//! // Create world configuration
//! const config = ecs.WorldConfig{
//!     .components = .{ .types = &.{ Position, Velocity } },
//!     .archetypes = .{ .archetypes = &.{
//!         .{ .name = "moving", .components = &.{ Position, Velocity } },
//!     }},
//!     .systems = .{ .systems = &.{} },
//!     .options = .{ .max_entities = 10000 },
//! };
//!
//! // Generate world type
//! const MyWorld = ecs.World(config);
//! ```

const std = @import("std");

// Core modules
pub const config = @import("ecs/config.zig");
pub const version = @import("ecs/version.zig");

// World modules
pub const world_mod = @import("ecs/world.zig");
pub const entity = @import("ecs/world/entity.zig");
pub const query = @import("ecs/world/query.zig");
pub const archetype_table = @import("ecs/world/archetype_table.zig");

// Scheduler modules
pub const scheduler = @import("ecs/scheduler.zig");

// Error handling
pub const errors = @import("ecs/error/error_types.zig");

// Tracing
pub const tracing = @import("ecs/trace/tracing.zig");

// System context and command buffer
pub const system_context = @import("ecs/system_context.zig");

// Event queue for inter-system communication
pub const event_queue = @import("ecs/event_queue.zig");

// I/O backend for async operations
pub const io_backend = @import("ecs/io/io_backend.zig");

// Multi-world coordination
pub const coordination = struct {
    pub const lock_free_queue = @import("ecs/coordination/lock_free_queue.zig");
    pub const transfer = @import("ecs/coordination/transfer.zig");
    pub const coordinator = @import("ecs/coordination/coordinator.zig");
};

// Pipeline configuration (Phase 6)
pub const pipeline = struct {
    pub const external = @import("ecs/pipeline/external.zig");
    pub const hybrid = @import("ecs/pipeline/hybrid.zig");
    pub const orchestrator = @import("ecs/pipeline/orchestrator.zig");
    pub const executors = @import("ecs/pipeline/executors.zig");
};

// Scalability infrastructure (Phase 7)
pub const scalability = struct {
    pub const numa_allocator = @import("ecs/scalability/numa_allocator.zig");
    pub const huge_page_allocator = @import("ecs/scalability/huge_page_allocator.zig");
    pub const affinity = @import("ecs/scalability/affinity.zig");
    pub const cluster = @import("ecs/scalability/cluster.zig");
};

// Re-export core types for convenience
pub const WorldConfig = config.WorldConfig;
pub const ComponentsSpec = config.ComponentsSpec;
pub const ArchetypesSpec = config.ArchetypesSpec;
pub const SystemsSpec = config.SystemsSpec;
pub const ResourcesSpec = config.ResourcesSpec;
pub const ScheduleSpec = config.ScheduleSpec;
pub const TickSpec = config.TickSpec;
pub const Options = config.Options;
pub const RuntimePolicy = config.RuntimePolicy;
pub const TracingSpec = config.TracingSpec;
pub const PhasesSpec = config.PhasesSpec;
pub const PhaseDef = config.PhaseDef;
pub const DEFAULT_PHASES = config.DEFAULT_PHASES;

// Re-export enums
pub const Phase = config.Phase;
pub const AsynchronyKind = config.AsynchronyKind;
pub const ParallelismMode = config.ParallelismMode;
pub const ExecutionModel = config.ExecutionModel;
pub const TickMode = config.TickMode;
pub const LayoutMode = config.LayoutMode;
pub const TraceLevel = tracing.TraceLevel;

// Re-export backend configuration types (Phase 4)
pub const BackendConfig = config.BackendConfig;
pub const IoUringBatchConfig = config.IoUringBatchConfig;
pub const WorkStealingConfig = config.WorkStealingConfig;
pub const AdaptiveConfig = config.AdaptiveConfig;

// Re-export entity types
pub const EntityId = entity.EntityId;
pub const EntityHandle = entity.EntityHandle;

// Re-export validation functions
pub const validateWorldConfig = config.validateWorldConfig;
pub const validateSchedulerConfig = config.validateSchedulerConfig;

// Re-export system function helper
pub const asSystemFn = config.asSystemFn;

// Re-export SystemDef for configuration
pub const SystemDef = config.SystemDef;

// Re-export version
pub const ECS_VERSION = version.ECS_VERSION;

// Re-export system context types
pub const SystemContext = system_context.SystemContext;
pub const CommandBuffer = system_context.CommandBuffer;
pub const CommandBufferType = system_context.CommandBufferType;
pub const ConcurrentCommandBuffers = system_context.ConcurrentCommandBuffers;
pub const ConcurrentCommandBuffersFromConfig = system_context.ConcurrentCommandBuffersFromConfig;
pub const Command = system_context.Command;
pub const Resources = system_context.Resources;

// Re-export error types
pub const FrameError = errors.FrameError;

// Re-export event queue type
pub const EventQueue = event_queue.EventQueue;
pub const EventQueueError = event_queue.EventQueueError;

// Re-export I/O backend types
pub const IoBackend = io_backend.IoBackend;
pub const IoBackendError = io_backend.IoBackendError;
pub const BackendOptions = io_backend.BackendOptions;

// Re-export IoContext from system_context
pub const IoContext = system_context.IoContext;

// Re-export coordination types (Phase 5)
pub const WorldRole = config.WorldRole;
pub const WorldCoordinationConfig = config.WorldCoordinationConfig;
pub const TransferQueueConfig = config.TransferQueueConfig;
pub const RoutingConfig = config.RoutingConfig;
pub const ComponentRoute = config.ComponentRoute;

// Re-export lock-free queue types
pub const LockFreeQueue = coordination.lock_free_queue.LockFreeQueue;
pub const SPSCQueue = coordination.lock_free_queue.SPSCQueue;

// Re-export transfer types
pub const TransferMarker = coordination.transfer.TransferMarker;
pub const TransferFlags = coordination.transfer.TransferFlags;
pub const EntityTransfer = coordination.transfer.EntityTransfer;
pub const TransferQueue = coordination.transfer.TransferQueue;
pub const SPSCTransferQueue = coordination.transfer.SPSCTransferQueue;

// Re-export coordinator types
pub const WorldCoordinator = coordination.coordinator.WorldCoordinator;
pub const CoordinatorStats = coordination.coordinator.CoordinatorStats;
pub const createPipelineConfigs = coordination.coordinator.createPipelineConfigs;

// Re-export pipeline types (Phase 6)
pub const PipelineMode = config.PipelineMode;
pub const PipelineConfig = config.PipelineConfig;
pub const ExternalPipelineConfig = config.ExternalPipelineConfig;
pub const HybridPipelineConfig = config.HybridPipelineConfig;
pub const DefaultFastPathPredicate = config.DefaultFastPathPredicate;

// Re-export pipeline interfaces
pub const ExternalPipeline = pipeline.external.ExternalPipeline;
pub const HybridPipeline = pipeline.hybrid.HybridPipeline;
pub const PipelineOrchestrator = pipeline.orchestrator.PipelineOrchestrator;
pub const PipelineStats = pipeline.orchestrator.PipelineStats;

// Re-export executor types
pub const ExecutorType = pipeline.executors.ExecutorType;
pub const ExecutorStatus = pipeline.executors.ExecutorStatus;
pub const GpuComputeConfig = pipeline.executors.GpuComputeConfig;
pub const GpuComputeExecutor = pipeline.executors.GpuComputeExecutor;
pub const SimdWorkerConfig = pipeline.executors.SimdWorkerConfig;
pub const SimdWorkerPool = pipeline.executors.SimdWorkerPool;
pub const ExternalThreadPoolConfig = pipeline.executors.ExternalThreadPoolConfig;
pub const ExternalThreadPool = pipeline.executors.ExternalThreadPool;

// Re-export scalability config types (Phase 7)
pub const ScalabilityConfig = config.ScalabilityConfig;
pub const NumaConfig = config.NumaConfig;
pub const HugePageConfig = config.HugePageConfig;
pub const AffinityConfig = config.AffinityConfig;
pub const ClusterConfig = config.ClusterConfig;

// Re-export scalability module types
pub const NumaAllocator = scalability.numa_allocator.NumaAllocator;
pub const detectNumaNodes = scalability.numa_allocator.detectNumaNodes;
pub const getCurrentNumaNode = scalability.numa_allocator.getCurrentNumaNode;
pub const isNumaAvailable = scalability.numa_allocator.isNumaAvailable;

pub const HugePageAllocator = scalability.huge_page_allocator.HugePageAllocator;
pub const areHugePagesAvailable = scalability.huge_page_allocator.areHugePagesAvailable;
pub const getMinimumHugePageSize = scalability.huge_page_allocator.getMinimumHugePageSize;

pub const AffinityManager = scalability.affinity.AffinityManager;
pub const getCurrentCpu = scalability.affinity.getCurrentCpu;
pub const isThreadPinned = scalability.affinity.isThreadPinned;

pub const EntityOwnership = scalability.cluster.EntityOwnership;
pub const ClusterCoordinator = scalability.cluster.ClusterCoordinator;
pub const ClusterState = scalability.cluster.ClusterState;
pub const ClusterStats = scalability.cluster.ClusterStats;
pub const PeerState = scalability.cluster.PeerState;
pub const SharedStateBackend = scalability.cluster.SharedStateBackend;
pub const InMemoryBackend = scalability.cluster.InMemoryBackend;

/// Generate a concrete World type from a compile-time WorldConfig.
///
/// The returned type provides:
/// - Entity creation/deletion with generation-checked handles
/// - Storage for all configured archetypes
/// - A minimal structured query API driven by compile-time QuerySpec
///
/// Example:
/// ```zig
/// const MyWorld = ecs.World(config);
/// var world = try MyWorld.init(allocator);
/// defer world.deinit();
/// ```
pub fn World(comptime cfg: WorldConfig) type {
    return world_mod.World(cfg);
}

/// Generate a concrete Scheduler type from a compile-time WorldConfig.
///
/// The returned type provides:
/// - Phase/stage-based system execution
/// - Conflict analysis and safe concurrency
/// - run_frame and run_fixed_loop APIs
///
/// Example:
/// ```zig
/// const MyScheduler = ecs.Scheduler(config);
/// var sched = try MyScheduler.init(&world);
/// defer sched.deinit();
/// try sched.runFrame(dt);
/// ```
pub fn Scheduler(comptime cfg: WorldConfig) type {
    return scheduler.Scheduler(cfg);
}

/// WorldConfigView provides a stable, read-only view over a WorldConfig.
/// Use this instead of accessing raw config for better API stability.
pub const WorldConfigView = config.WorldConfigView;

// Integration tests
const integration_test = @import("ecs/integration_test.zig");

// Fuzz tests
const fuzz_test = @import("ecs/fuzz_test.zig");

// Benchmarks
const benchmark = @import("ecs/benchmark.zig");

// Configuration validation tests
const config_validation_test = @import("ecs/config_validation_test.zig");

// Tests
test {
    // Import all test modules
    _ = config;
    _ = version;
    _ = world_mod;
    _ = entity;
    _ = query;
    _ = archetype_table;
    _ = scheduler;
    _ = errors;
    _ = tracing;
    _ = system_context;
    _ = event_queue;
    _ = io_backend;
    _ = coordination.lock_free_queue;
    _ = coordination.transfer;
    _ = coordination.coordinator;
    _ = pipeline.external;
    _ = pipeline.hybrid;
    _ = pipeline.orchestrator;
    _ = pipeline.executors;
    _ = scalability.numa_allocator;
    _ = scalability.huge_page_allocator;
    _ = scalability.affinity;
    _ = scalability.cluster;
    _ = integration_test;
    _ = fuzz_test;
    _ = benchmark;
    _ = config_validation_test;
}
