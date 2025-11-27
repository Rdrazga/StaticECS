//! StaticECS Configuration Types
//!
//! This module defines the central `WorldConfig` type and all its sub-structs.
//! WorldConfig is the single source of truth for a world's architecture,
//! describing components, archetypes, systems, scheduling, tick behavior,
//! and runtime policies.

const std = @import("std");
const meta = std.meta;

// ============================================================================
// Core Enums
// ============================================================================

/// Phase definition for custom phase sequences.
/// Tiger Style: Phases are configurable - define your own execution bands.
pub const PhaseDef = struct {
    /// Phase name (for tracing and debugging).
    name: [:0]const u8,
    /// Execution order (lower = earlier). Used for sorting when specified.
    order: u8 = 0,
};

/// Default phases matching traditional game loop patterns.
/// Users can override with custom phases via WorldConfig.phases.
pub const DEFAULT_PHASES: []const PhaseDef = &.{
    .{ .name = "pre_update", .order = 0 },
    .{ .name = "update", .order = 1 },
    .{ .name = "post_update", .order = 2 },
    .{ .name = "render", .order = 3 },
    .{ .name = "network", .order = 4 },
};

/// Default phase enum for backward compatibility.
/// Maps to indices in DEFAULT_PHASES.
/// Use Phase.index() to get the u8 index for SystemDef.phase.
pub const Phase = enum(u8) {
    pre_update = 0,
    update = 1,
    post_update = 2,
    render = 3,
    network = 4,

    /// Returns the phase index for use with SystemDef.phase.
    pub fn index(self: Phase) u8 {
        return @intFromEnum(self);
    }

    /// Returns the numeric ordering value for this phase (alias for index).
    pub fn order(self: Phase) u8 {
        return @intFromEnum(self);
    }
};

/// AsynchronyKind describes how a system relates to async I/O.
pub const AsynchronyKind = enum {
    /// No asynchrony; the scheduler calls the system synchronously.
    none,
    /// The scheduler may launch the system via async Io primitives.
    /// Correctness must not depend on concurrent progress.
    may_async,
};

/// ParallelismMode describes intra-system parallelization strategy.
pub const ParallelismMode = enum {
    /// A single task handles the entire system.
    none,
    /// The entity set is partitioned into chunks processed by multiple tasks.
    by_entity,
    /// One task per matching archetype/component set.
    by_set,
    /// Reserved for higher-level orchestration across multiple worlds.
    by_world,
};

/// ExecutionModel selects the scheduler family and runtime semantics.
pub const ExecutionModel = enum {
    /// Single-threaded, blocking scheduler.
    blocking_single_thread,
    /// Single-threaded, evented Io with task switching.
    evented_single_thread,
    /// Multi-threaded scheduler backed by a thread pool.
    concurrent_threadpool,
    /// io_uring-based syscall batching (Linux only).
    /// Batches I/O operations per phase for reduced syscall overhead.
    io_uring_batch,
    /// Work-stealing scheduler with per-core queues.
    /// Optimal for CPU-bound parallel workloads.
    work_stealing,
    /// Adaptive hybrid that switches backends based on runtime metrics.
    /// Combines benefits of batching and parallelism dynamically.
    adaptive_hybrid,
};

/// TickMode configures how frames/ticks are driven.
pub const TickMode = enum {
    /// Manual ticking via explicit run_frame calls.
    manual,
    /// Fixed-rate ticking at a configured frequency.
    fixed_rate,
};

/// LayoutMode controls entity representation and storage layout.
pub const LayoutMode = enum {
    /// Multiple archetypes with full archetype transition support.
    multi_archetype,
    /// Single archetype with more compact entity representation.
    single_archetype,
};

// ============================================================================
// Runtime Policy Types
// ============================================================================

/// InvariantPolicy governs how StaticECS reacts to internal invariant violations.
pub const InvariantPolicy = enum {
    /// Immediate fail-fast with contextual diagnostics.
    default,
    /// Minimal diagnostics before abort.
    fail_fast_minimal,
};

/// InitPolicy governs how initialization/Io-capability errors are surfaced.
pub const InitPolicy = enum {
    /// Fail initialization without panicking, return error describing first failure.
    default,
    /// Aggregate and report multiple capability issues before failing.
    aggregate_and_fail,
};

/// FramePolicy governs how per-frame system execution errors are handled.
pub const FramePolicy = enum {
    /// First error wins: stop executing, return error without panicking.
    default,
    /// Run all systems, collect all errors, return aggregate report.
    aggregate,
};

/// RuntimePolicy groups all runtime error-handling policies.
/// Embedded in WorldConfig as the `policies` field.
pub const RuntimePolicy = struct {
    invariants: InvariantPolicy = .default,
    init: InitPolicy = .default,
    frame: FramePolicy = .default,
};

// ============================================================================
// Tracing Types
// ============================================================================

/// TraceLevel controls how much tracing data is emitted.
/// Uses u8 backing type for compatibility with tracing module.
pub const TraceLevel = enum(u8) {
    /// No tracing; all emission sites compile to no-ops.
    off = 0,
    /// Only error-related events are emitted.
    errors = 1,
    /// System start/end events plus errors.
    systems = 2,
    /// Verbose: all supported event types.
    verbose = 3,
};

/// TraceSink is an opaque pointer to a user-provided trace consumer.
/// The actual structure is defined in trace/tracing.zig.
pub const TraceSink = *const anyopaque;

/// TracingSpec configures tracing behavior for a world.
pub const TracingSpec = struct {
    level: TraceLevel = .off,
    sink: ?TraceSink = null,
};

// ============================================================================
// Archetype Definition
// ============================================================================

/// ArchetypeDef defines a single archetype's structure.
pub const ArchetypeDef = struct {
    /// Symbolic identifier for diagnostics and APIs (sentinel-terminated for struct field names).
    name: [:0]const u8,
    /// Subset of ComponentsSpec.types stored in this archetype.
    components: []const type,
};

// ============================================================================
// System Definition
// ============================================================================

/// SystemDef defines a single system's metadata.
pub const SystemDef = struct {
    name: []const u8,
    /// Pointer to the system function.
    /// Use `asSystemFn` to safely convert a typed function to this field.
    func: *const anyopaque,
    /// Phase index (0-based, into WorldConfig.phases).
    /// Default is 1 which maps to "update" in DEFAULT_PHASES.
    /// Use Phase enum for convenience: `.phase = Phase.update.index()`
    phase: u8 = 1,
    asynchrony: AsynchronyKind = .none,
    parallelism: ParallelismMode = .none,
    read_components: []const type = &.{},
    write_components: []const type = &.{},
    /// Whether this system requires I/O context for async operations.
    /// When true, the system can access IoContext via ctx.getIo().
    /// Requires ExecutionModel other than blocking_single_thread.
    needs_io: bool = false,
};

/// Compile-time helper to validate and convert a system function to the opaque pointer.
/// This provides type-safety at the configuration site.
///
/// The function must have one of these signatures:
/// - `fn(*anyopaque) FrameError!void` (legacy, no compile-time type checking)
/// - `fn(*SystemContext) FrameError!void` (preferred, where SystemContext is any type)
///
/// Usage in WorldConfig:
/// ```zig
/// .func = asSystemFn(mySystem),
/// ```
pub fn asSystemFn(comptime func: anytype) *const anyopaque {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn);

    if (fn_info != .@"fn" and fn_info != .pointer) {
        @compileError("asSystemFn: expected a function, got " ++ @typeName(Fn));
    }

    // For function pointers, get the underlying function type
    const actual_fn_info = if (fn_info == .pointer)
        @typeInfo(fn_info.pointer.child)
    else
        fn_info;

    if (actual_fn_info != .@"fn") {
        @compileError("asSystemFn: expected a function type");
    }

    const params = actual_fn_info.@"fn".params;

    // Validate: must have exactly 1 parameter (the context)
    if (params.len != 1) {
        @compileError("asSystemFn: system function must have exactly 1 parameter (context pointer)");
    }

    // Validate: parameter must be a pointer
    const param_type = params[0].type orelse
        @compileError("asSystemFn: parameter type must be known at compile time");

    const param_info = @typeInfo(param_type);
    if (param_info != .pointer) {
        @compileError("asSystemFn: first parameter must be a pointer type");
    }

    // Validate: return type must be FrameError!void or just void
    // (We allow void for systems that never fail)
    const return_type = actual_fn_info.@"fn".return_type orelse
        @compileError("asSystemFn: return type must be known at compile time");

    const return_info = @typeInfo(return_type);
    switch (return_info) {
        .void => {}, // OK: system never fails
        .error_union => {
            // OK: system may fail - payload should be void
            if (return_info.error_union.payload != void) {
                @compileError("asSystemFn: system must return FrameError!void or void, not " ++ @typeName(return_type));
            }
        },
        else => {
            @compileError("asSystemFn: system must return FrameError!void or void, not " ++ @typeName(return_type));
        },
    }

    return @ptrCast(&func);
}

// ============================================================================
// Configuration Sub-Specs
// ============================================================================

/// ComponentsSpec declares the universe of component types for a world.
pub const ComponentsSpec = struct {
    /// List of all component types used by this world.
    types: []const type = &.{},
};

/// ArchetypesSpec defines the fixed set of entity structures.
pub const ArchetypesSpec = struct {
    /// List of archetype definitions.
    archetypes: []const ArchetypeDef = &.{},
};

/// SystemsSpec describes all systems for this world.
pub const SystemsSpec = struct {
    /// List of system definitions.
    systems: []const SystemDef = &.{},
};

/// ScheduleSpec provides hints/limits to the scheduler.
pub const ScheduleSpec = struct {
    /// Selects the scheduler family and execution semantics.
    execution_model: ExecutionModel = .blocking_single_thread,
    /// Upper bound on concurrent tasks (0 = let scheduler decide).
    max_parallel_tasks: u32 = 0,
    /// Backend-specific configuration (optional).
    backend_config: BackendConfig = .{ .none = {} },
};

// ============================================================================
// Backend Configuration Types (Phase 4)
// ============================================================================

/// Backend-specific configuration for scheduler execution models.
/// Each variant contains settings relevant to that particular backend.
/// Tiger Style: All bounds configurable via these settings.
pub const BackendConfig = union(enum) {
    /// No backend-specific config (for simple models).
    none: void,
    /// io_uring batch backend configuration.
    io_uring_batch: IoUringBatchConfig,
    /// Work-stealing backend configuration.
    work_stealing: WorkStealingConfig,
    /// Adaptive hybrid backend configuration.
    adaptive: AdaptiveConfig,
};

/// Configuration for io_uring batch backend (Linux only).
/// Controls submission/completion queue sizes and batching behavior.
/// Tiger Style: Fixed bounds, power-of-two sizes for efficiency.
pub const IoUringBatchConfig = struct {
    /// Submission queue depth. Must be power of 2.
    /// Default 256 balances memory usage with batching efficiency.
    sq_entries: u16 = 256,
    /// Completion queue depth. Usually 2x sq_entries.
    /// Default 512 prevents completion queue overflow.
    cq_entries: u16 = 512,
    /// Maximum operations to batch per phase.
    /// Default 64 balances syscall reduction with latency.
    batch_size: u16 = 64,
    /// Enable kernel-side polling (IORING_SETUP_SQPOLL).
    /// Reduces syscalls but uses CPU. Best for high-throughput servers.
    kernel_poll: bool = false,
    /// CPU affinity for submission thread (when kernel_poll enabled).
    /// null = no affinity (OS decides).
    sq_thread_cpu: ?u8 = null,
    /// Idle timeout in milliseconds before sq thread goes to sleep.
    /// Only relevant when kernel_poll is true.
    sq_thread_idle_ms: u32 = 1000,
};

/// Configuration for work-stealing backend.
/// Controls worker threads, queue sizes, and stealing behavior.
/// Tiger Style: Per-core optimization, bounded queues.
pub const WorkStealingConfig = struct {
    /// Worker thread count. 0 = auto-detect CPU count.
    worker_count: u16 = 0,
    /// Local queue capacity per worker. Must be power of 2.
    /// Default 256 balances memory per-worker with queue depth.
    local_queue_size: u16 = 256,
    /// Number of tasks to steal in one operation.
    /// Default 32 balances fairness with stealing overhead.
    steal_batch: u8 = 32,
    /// Enable LIFO slot for producer cache locality.
    /// Improves cache performance for producer-heavy workloads.
    lifo_slot: bool = true,
    /// Spin iterations before parking a worker thread.
    /// Higher = lower latency, more CPU usage when idle.
    spin_count: u16 = 100,
};

/// Configuration for adaptive hybrid backend.
/// Controls thresholds for switching between underlying backends.
/// Tiger Style: Metric-driven, configurable windows.
pub const AdaptiveConfig = struct {
    /// Switch to batch mode when pending I/O operations exceed this.
    /// Default 64 triggers batching under moderate I/O load.
    batch_threshold: u32 = 64,
    /// Switch to work-stealing when CPU load imbalance exceeds this ratio.
    /// 0.3 = switch when slowest worker is 30% behind fastest.
    imbalance_threshold: f32 = 0.3,
    /// Metrics measurement window size (in ticks).
    /// Default 100 provides stable measurements without too much lag.
    window_size: u32 = 100,
    /// Minimum ticks between backend switches (cooldown period).
    /// Default 10 prevents oscillation between backends.
    switch_cooldown: u32 = 10,
    /// Which backend to start with. If null, auto-detect based on platform.
    initial_backend: ?ExecutionModel = null,
};

// ============================================================================
// Pipeline Configuration Types (Phase 6)
// ============================================================================

/// Pipeline entity flow mode.
/// Determines how entities flow through processing stages.
/// Tiger Style: Mode selection at comptime enables zero-cost abstractions.
pub const PipelineMode = enum {
    /// ECS manages entity lifecycle internally.
    /// Entities flow through phases automatically.
    /// Best for: complex state machines, game-like processing.
    internal,

    /// User code manages entity flow externally.
    /// ECS provides batch import/export APIs.
    /// Best for: high-throughput pipelines, event streams.
    external,

    /// Hybrid mode with fast-path bypass.
    /// Simple entities bypass ECS, complex use full pipeline.
    /// Best for: HTTP servers, mixed workloads.
    hybrid,
};

/// External pipeline configuration.
/// Controls batch sizes and buffer capacities for external mode.
/// Tiger Style: All bounds configurable.
pub const ExternalPipelineConfig = struct {
    /// Maximum batch size for import/export operations.
    /// Default 256 balances memory usage with batching efficiency.
    batch_size: u32 = 256,

    /// Enable zero-copy imports when possible.
    /// When true, avoids copying component data during import.
    zero_copy: bool = true,

    /// Export buffer capacity (max entities buffered for export).
    /// Default 4096 allows high throughput.
    export_buffer_size: u32 = 4096,

    /// Import buffer capacity (max entities buffered for import).
    /// Default 4096 allows high throughput.
    import_buffer_size: u32 = 4096,
};

/// Default fast-path predicate that rejects all entities.
/// Users should provide their own predicate for actual fast-path logic.
pub const DefaultFastPathPredicate = struct {
    /// Returns true if entity data can use fast-path processing.
    /// Default implementation returns false (no fast-path).
    pub fn canFastPath(entity_data: anytype) bool {
        _ = entity_data;
        return false;
    }
};

/// Hybrid pipeline configuration.
/// Controls fast-path behavior and fallback settings.
/// Tiger Style: Predicate type is comptime for zero overhead when not matching.
pub const HybridPipelineConfig = struct {
    /// Fast-path predicate function type.
    /// Must have `fn canFastPath(data: anytype) bool` method.
    /// Default rejects all entities (no fast-path).
    fast_path_predicate_type: type = DefaultFastPathPredicate,

    /// Maximum entities in fast-path queue per tick.
    /// Default 1024 balances throughput with memory.
    fast_path_capacity: u32 = 1024,

    /// Fallback to ECS when fast-path queue is full.
    /// When false, returns error.FastPathFull instead.
    fallback_on_full: bool = true,
};

/// Pipeline configuration options.
/// Added to WorldConfig as the `pipeline` field.
/// Tiger Style: Zero overhead when using internal mode (default).
pub const PipelineConfig = struct {
    /// Pipeline mode selection.
    mode: PipelineMode = .internal,

    /// External mode settings (only used when mode == .external).
    external: ExternalPipelineConfig = .{},

    /// Hybrid mode settings (only used when mode == .hybrid).
    hybrid: HybridPipelineConfig = .{},
};

// ============================================================================
// Scalability Configuration Types (Phase 7)
// ============================================================================

/// NUMA memory allocation configuration.
/// Enables NUMA-aware memory allocation for optimal memory bandwidth.
/// Tiger Style: All bounds configurable, graceful fallback on unsupported platforms.
pub const NumaConfig = struct {
    /// Enable NUMA-aware allocation.
    enabled: bool = false,

    /// Memory allocation strategy.
    strategy: Strategy = .local_preferred,

    /// Specific node bindings (or null for auto).
    /// Maps worker IDs to NUMA nodes for explicit control.
    node_bindings: ?[]const NodeBinding = null,

    /// Interleave settings (for .interleave strategy).
    interleave: InterleaveConfig = .{},

    pub const Strategy = enum {
        /// Allocate from local node, fall back to any.
        local_preferred,
        /// Strict local allocation (fail if unavailable).
        local_strict,
        /// Interleave across all nodes for distributed access.
        interleave,
        /// Bind to specific nodes via node_bindings.
        explicit,
    };

    pub const NodeBinding = struct {
        /// Worker or thread identifier.
        worker_id: u16,
        /// NUMA node to bind allocations to.
        node_id: u8,
    };

    pub const InterleaveConfig = struct {
        /// Page size for interleaving (default: 4KB).
        page_size: usize = 4096,
        /// Nodes to interleave across (null = all available).
        nodes: ?[]const u8 = null,
    };
};

/// Huge page allocation configuration.
/// Enables huge pages to reduce TLB misses for large allocations.
/// Tiger Style: Configurable thresholds, automatic fallback.
pub const HugePageConfig = struct {
    /// Enable huge pages for large allocations.
    enabled: bool = false,

    /// Page size to request.
    size: PageSize = .@"2MB",

    /// Fallback to regular pages if huge pages unavailable.
    fallback: bool = true,

    /// Minimum allocation size to use huge pages (bytes).
    /// Allocations below this threshold use regular pages.
    threshold: usize = 2 * 1024 * 1024, // 2MB

    pub const PageSize = enum(usize) {
        @"2MB" = 2 * 1024 * 1024,
        @"1GB" = 1024 * 1024 * 1024,
    };
};

/// Thread CPU affinity configuration.
/// Controls thread-to-CPU pinning for cache locality and predictable latency.
/// Tiger Style: Strategy-based configuration with explicit overrides.
pub const AffinityConfig = struct {
    /// Enable thread-to-CPU pinning.
    enabled: bool = false,

    /// Affinity strategy for automatic assignment.
    strategy: Strategy = .sequential,

    /// Explicit CPU assignments (for .explicit strategy).
    cpu_bindings: ?[]const CpuBinding = null,

    /// Prefer physical cores over hyperthreads.
    prefer_physical: bool = true,

    pub const Strategy = enum {
        /// Pin threads to sequential CPUs (0, 1, 2, ...).
        sequential,
        /// Pin threads to physical cores only (skip hyperthreads).
        physical_only,
        /// Spread across NUMA nodes evenly.
        numa_spread,
        /// Use explicit CPU assignments from cpu_bindings.
        explicit,
    };

    pub const CpuBinding = struct {
        /// Thread identifier (worker index).
        thread_id: u16,
        /// CPU to pin to.
        cpu_id: u16,
    };
};

/// Cluster coordination configuration.
/// Enables horizontal scaling across multiple instances.
/// Tiger Style: Optional feature, compiles to nothing when disabled.
pub const ClusterConfig = struct {
    /// Enable cluster mode.
    enabled: bool = false,

    /// This instance's node ID (unique within cluster).
    node_id: u16 = 0,

    /// Total instance count in cluster (for static partitioning).
    total_instances: u16 = 1,

    /// Discovery mechanism for finding peers.
    discovery: Discovery = .static,

    /// Communication transport.
    transport: Transport = .tcp,

    /// Cluster topology.
    topology: Topology = .mesh,

    /// Peer addresses (for static discovery).
    peers: []const PeerAddress = &.{},

    /// Entity ownership strategy.
    ownership: OwnershipStrategy = .hash_based,

    /// Heartbeat interval in milliseconds.
    heartbeat_interval_ms: u32 = 1000,

    /// Peer timeout in milliseconds (consider dead after this).
    peer_timeout_ms: u32 = 5000,

    pub const Discovery = enum {
        /// Static peer list from configuration.
        static,
        /// DNS-based discovery (SRV records).
        dns,
        /// Multicast discovery on local network.
        multicast,
        /// Kubernetes service discovery.
        kubernetes,
    };

    pub const Transport = enum {
        /// TCP connections.
        tcp,
        /// UDP datagrams (for low-latency).
        udp,
        /// RDMA for high-performance clusters.
        rdma,
    };

    pub const Topology = enum {
        /// Full mesh - all nodes connected to all.
        mesh,
        /// Star - all nodes connect to leader.
        star,
        /// Ring - each node has two neighbors.
        ring,
    };

    pub const PeerAddress = struct {
        /// Host address (IP or hostname).
        host: []const u8,
        /// Port number.
        port: u16,
        /// Node ID of this peer.
        node_id: u16,
    };

    pub const OwnershipStrategy = enum {
        /// Hash-based entity distribution.
        hash_based,
        /// Range-based partitioning.
        range_based,
        /// Consistent hashing for dynamic scaling.
        consistent_hash,
    };
};

/// Combined scalability configuration.
/// Groups all vertical and horizontal scaling options.
/// Tiger Style: Zero overhead when all features disabled.
pub const ScalabilityConfig = struct {
    /// NUMA-aware memory allocation.
    numa: NumaConfig = .{},

    /// Huge page allocation.
    huge_pages: HugePageConfig = .{},

    /// Thread CPU affinity.
    affinity: AffinityConfig = .{},

    /// Cluster coordination.
    cluster: ClusterConfig = .{},

    /// Returns true if any scalability feature is enabled.
    pub fn anyEnabled(self: ScalabilityConfig) bool {
        return self.numa.enabled or
            self.huge_pages.enabled or
            self.affinity.enabled or
            self.cluster.enabled;
    }

    /// Returns true if NUMA features are requested.
    pub fn wantsNuma(self: ScalabilityConfig) bool {
        return self.numa.enabled;
    }

    /// Returns true if huge pages are requested.
    pub fn wantsHugePages(self: ScalabilityConfig) bool {
        return self.huge_pages.enabled;
    }

    /// Returns true if thread affinity is requested.
    pub fn wantsAffinity(self: ScalabilityConfig) bool {
        return self.affinity.enabled;
    }

    /// Returns true if cluster mode is requested.
    pub fn wantsCluster(self: ScalabilityConfig) bool {
        return self.cluster.enabled;
    }
};

// ============================================================================
// Multi-World Coordination Types (Phase 5)
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

/// TickSpec configures frame/tick driving behavior.
pub const TickSpec = struct {
    mode: TickMode = .manual,
    /// Fixed frequency when mode is .fixed_rate.
    target_hz: ?u32 = null,
    /// Clamp/skip logic for large frame delays.
    max_frame_delay_ns: ?u64 = null,
};

/// ResourcesSpec declares the global singleton resource types for a world.
pub const ResourcesSpec = struct {
    /// List of all resource types used by this world.
    types: []const type = &.{},
};

/// PhasesSpec configures the execution phases for systems.
/// Tiger Style: Phases are fully configurable.
pub const PhasesSpec = struct {
    /// List of phase definitions in execution order.
    /// Index in array = phase index used in SystemDef.phase.
    phases: []const PhaseDef = DEFAULT_PHASES,
};

/// Options provides miscellaneous global options and invariants.
/// Tiger Style: All bounds are configurable. No hardcoded limits.
pub const Options = struct {
    /// Entity layout mode.
    layout_mode: LayoutMode = .multi_archetype,
    /// Number of bits for entity index. Generation uses remaining bits (32 - index).
    /// Must be between 8 and 24 (inclusive).
    /// Default 20 allows ~1M entities with 4096 generations.
    /// Tiger Style: Configure based on your max entity count vs generation cycle needs.
    /// - 24 bits: ~16M entities, 256 generations (high entity count)
    /// - 20 bits: ~1M entities, 4096 generations (default, balanced)
    /// - 16 bits: ~64K entities, 65536 generations (high turnover)
    entity_index_bits: u5 = 20,
    /// Hard upper bound on entity count.
    /// Must be <= (2^entity_index_bits - 1).
    /// Default with 20-bit index: max 1,048,575 entities.
    max_entities: u32 = 65536,
    /// Maximum commands per frame (for command buffer sizing).
    max_commands_per_frame: u32 = 1024,
    /// Maximum inline data size for component data in commands (bytes).
    /// Components larger than this cannot be used with deferred set_component.
    /// Tiger Style: Configure based on your largest component type.
    max_component_data_size: u32 = 256,
    /// Expected entities per archetype (for pre-allocation).
    /// Set to 0 to disable pre-allocation (use dynamic growth).
    /// Tiger Style: Set this to your expected max for fixed allocation.
    expected_entities_per_archetype: u32 = 0,
    /// Maximum phases in a schedule.
    /// Tiger Style: Configure based on your phase definitions.
    /// Default of 16 covers most use cases with custom phases.
    max_phases: u8 = 16,
    /// Maximum stages per phase (for schedule building).
    /// Tiger Style: Configure based on expected system graph complexity.
    max_stages_per_phase: u16 = 16,
    /// Maximum systems per stage (for schedule building).
    /// Tiger Style: Configure based on expected parallelism.
    max_systems_per_stage: u16 = 32,
    /// Maximum errors to aggregate per frame (when using aggregate frame policy).
    /// Tiger Style: Configure based on expected error frequency.
    max_aggregate_errors: u16 = 16,
    /// Controls runtime safety checks.
    enable_debug_asserts: bool = true,
    /// Optional version lock against the core library.
    core_version: ?struct { major: u32, minor: u32, patch: u32 } = null,
};

// ============================================================================
// WorldConfig - The Central Configuration Type
// ============================================================================

/// WorldConfig is the central compile-time description of a world.
/// It aggregates all configuration segments into a single structure.
pub const WorldConfig = struct {
    components: ComponentsSpec = .{},
    archetypes: ArchetypesSpec = .{},
    systems: SystemsSpec = .{},
    resources: ResourcesSpec = .{},
    phases: PhasesSpec = .{},
    schedule: ScheduleSpec = .{},
    tick: TickSpec = .{},
    options: Options = .{},
    policies: RuntimePolicy = .{},
    tracing: TracingSpec = .{},
    /// Multi-world coordination settings.
    /// Only used when role != .standalone.
    coordination: WorldCoordinationConfig = .{},
    /// Pipeline configuration for entity flow control.
    /// Controls internal/external/hybrid processing modes.
    pipeline: PipelineConfig = .{},
    /// Scalability settings for vertical and horizontal scaling.
    /// Controls NUMA, huge pages, affinity, and clustering.
    scalability: ScalabilityConfig = .{},

    /// Returns the number of component types in this config.
    pub fn componentCount(self: WorldConfig) usize {
        return self.components.types.len;
    }

    /// Returns the number of archetypes in this config.
    pub fn archetypeCount(self: WorldConfig) usize {
        return self.archetypes.archetypes.len;
    }

    /// Returns the number of systems in this config.
    pub fn systemCount(self: WorldConfig) usize {
        return self.systems.systems.len;
    }

    /// Returns the number of resource types in this config.
    pub fn resourceCount(self: WorldConfig) usize {
        return self.resources.types.len;
    }

    /// Returns the number of phases in this config.
    pub fn phaseCount(self: WorldConfig) usize {
        return self.phases.phases.len;
    }

    /// Returns whether this world participates in multi-world coordination.
    pub fn isCoordinated(self: WorldConfig) bool {
        return self.coordination.role != .standalone;
    }

    /// Returns the world's role in multi-world coordination.
    pub fn worldRole(self: WorldConfig) WorldRole {
        return self.coordination.role;
    }

    /// Returns the pipeline mode for this world.
    pub fn pipelineMode(self: WorldConfig) PipelineMode {
        return self.pipeline.mode;
    }

    /// Returns whether this world uses external pipeline mode.
    pub fn isExternalPipeline(self: WorldConfig) bool {
        return self.pipeline.mode == .external;
    }

    /// Returns whether this world uses hybrid pipeline mode.
    pub fn isHybridPipeline(self: WorldConfig) bool {
        return self.pipeline.mode == .hybrid;
    }

    /// Returns whether any scalability features are enabled.
    pub fn hasScalabilityFeatures(self: WorldConfig) bool {
        return self.scalability.anyEnabled();
    }

    /// Returns whether NUMA allocation is enabled.
    pub fn wantsNuma(self: WorldConfig) bool {
        return self.scalability.wantsNuma();
    }

    /// Returns whether huge pages are enabled.
    pub fn wantsHugePages(self: WorldConfig) bool {
        return self.scalability.wantsHugePages();
    }

    /// Returns whether thread affinity is enabled.
    pub fn wantsAffinity(self: WorldConfig) bool {
        return self.scalability.wantsAffinity();
    }

    /// Returns whether cluster mode is enabled.
    pub fn wantsCluster(self: WorldConfig) bool {
        return self.scalability.wantsCluster();
    }

    /// Returns the cluster node ID (0 if not in cluster mode).
    pub fn clusterNodeId(self: WorldConfig) u16 {
        return self.scalability.cluster.node_id;
    }
};

// ============================================================================
// WorldConfigView - Stable Read-Only View
// ============================================================================

/// WorldConfigView provides a stable, read-only view over a WorldConfig.
/// Prefer using this over direct config access for better API stability.
pub const WorldConfigView = struct {
    config: WorldConfig,

    pub fn init(cfg: WorldConfig) WorldConfigView {
        return .{ .config = cfg };
    }

    /// Returns the layout mode from Options.
    pub fn layoutMode(self: WorldConfigView) LayoutMode {
        return self.config.options.layout_mode;
    }

    /// Returns the max entity count from Options.
    pub fn maxEntities(self: WorldConfigView) u32 {
        return self.config.options.max_entities;
    }

    /// Returns the tick mode from TickSpec.
    pub fn tickMode(self: WorldConfigView) TickMode {
        return self.config.tick.mode;
    }

    /// Returns the target tick frequency (if in fixed_rate mode).
    pub fn tickTargetHz(self: WorldConfigView) ?u32 {
        return self.config.tick.target_hz;
    }

    /// Returns the core version pin from Options.
    pub fn coreVersionPin(self: WorldConfigView) ?struct { major: u32, minor: u32, patch: u32 } {
        return self.config.options.core_version;
    }

    /// Returns the execution model from ScheduleSpec.
    pub fn executionModel(self: WorldConfigView) ExecutionModel {
        return self.config.schedule.execution_model;
    }

    /// Returns the trace level from TracingSpec.
    pub fn traceLevel(self: WorldConfigView) TraceLevel {
        return self.config.tracing.level;
    }

    /// Returns whether this world participates in multi-world coordination.
    pub fn isCoordinated(self: WorldConfigView) bool {
        return self.config.isCoordinated();
    }

    /// Returns the world's role in multi-world coordination.
    pub fn worldRole(self: WorldConfigView) WorldRole {
        return self.config.worldRole();
    }

    /// Returns the world's ID in a coordinator.
    pub fn worldId(self: WorldConfigView) u8 {
        return self.config.coordination.world_id;
    }

    /// Returns the pipeline mode for this world.
    pub fn pipelineMode(self: WorldConfigView) PipelineMode {
        return self.config.pipelineMode();
    }

    /// Returns whether this world uses external pipeline mode.
    pub fn isExternalPipeline(self: WorldConfigView) bool {
        return self.config.isExternalPipeline();
    }

    /// Returns whether this world uses hybrid pipeline mode.
    pub fn isHybridPipeline(self: WorldConfigView) bool {
        return self.config.isHybridPipeline();
    }

    /// Returns whether any scalability features are enabled.
    pub fn hasScalabilityFeatures(self: WorldConfigView) bool {
        return self.config.hasScalabilityFeatures();
    }

    /// Returns whether NUMA allocation is enabled.
    pub fn wantsNuma(self: WorldConfigView) bool {
        return self.config.wantsNuma();
    }

    /// Returns whether huge pages are enabled.
    pub fn wantsHugePages(self: WorldConfigView) bool {
        return self.config.wantsHugePages();
    }

    /// Returns whether thread affinity is enabled.
    pub fn wantsAffinity(self: WorldConfigView) bool {
        return self.config.wantsAffinity();
    }

    /// Returns whether cluster mode is enabled.
    pub fn wantsCluster(self: WorldConfigView) bool {
        return self.config.wantsCluster();
    }

    /// Returns the cluster node ID (0 if not in cluster mode).
    pub fn clusterNodeId(self: WorldConfigView) u16 {
        return self.config.clusterNodeId();
    }
};

// ============================================================================
// Configuration Validation
// ============================================================================

/// Validation error types for compile-time config checking.
pub const ConfigValidationError = error{
    /// Component referenced in archetype not found in ComponentsSpec.
    ComponentNotInSpec,
    /// Duplicate archetype definition (same component set).
    DuplicateArchetype,
    /// System references component not in ComponentsSpec.
    SystemComponentNotInSpec,
    /// Single archetype mode requires exactly one archetype.
    SingleArchetypeModeViolation,
    /// Invalid execution model for given asynchrony/parallelism combination.
    InvalidExecutionModelCombination,
    /// Fixed-rate tick mode requires target_hz to be set.
    FixedRateMissingHz,
    /// max_entities must be greater than zero.
    ZeroMaxEntities,
    /// Transfer queue capacity must be power of 2.
    TransferQueueCapacityNotPowerOfTwo,
    /// Transfer batch size exceeds queue capacity.
    TransferBatchSizeExceedsCapacity,
    /// Component route references invalid target world.
    InvalidRouteTarget,
};

/// Validates a WorldConfig at compile time.
/// Emits @compileError on invalid configurations.
pub fn validateWorldConfig(comptime cfg: WorldConfig) void {
    // Validate entity_index_bits range [8, 24]
    if (cfg.options.entity_index_bits < 8 or cfg.options.entity_index_bits > 24) {
        @compileError("WorldConfig: entity_index_bits must be between 8 and 24 (inclusive)");
    }

    // Compute max possible index from bit width
    const max_index: u32 = (@as(u32, 1) << cfg.options.entity_index_bits) - 1;

    // Validate max_entities > 0
    if (cfg.options.max_entities == 0) {
        @compileError("WorldConfig: max_entities must be greater than zero");
    }

    // Validate max_entities fits in entity_index_bits
    if (cfg.options.max_entities > max_index) {
        @compileError("WorldConfig: max_entities exceeds capacity of entity_index_bits");
    }

    // Validate phases
    if (cfg.phases.phases.len == 0) {
        @compileError("WorldConfig: at least one phase must be defined");
    }
    if (cfg.phases.phases.len > cfg.options.max_phases) {
        @compileError("WorldConfig: phase count exceeds max_phases option");
    }

    // Validate single archetype mode
    if (cfg.options.layout_mode == .single_archetype) {
        if (cfg.archetypes.archetypes.len != 1) {
            @compileError("WorldConfig: single_archetype layout_mode requires exactly one archetype definition");
        }
    }

    // Validate fixed-rate tick mode
    if (cfg.tick.mode == .fixed_rate) {
        if (cfg.tick.target_hz == null) {
            @compileError("WorldConfig: fixed_rate tick mode requires target_hz to be set");
        }
    }

    // Validate archetype component references
    for (cfg.archetypes.archetypes) |arch| {
        for (arch.components) |comp| {
            if (!componentInSpec(cfg.components, comp)) {
                @compileError("WorldConfig: archetype '" ++ arch.name ++ "' references component not in ComponentsSpec");
            }
        }
    }

    // Validate system component references and phase indices
    const phase_count = cfg.phases.phases.len;
    for (cfg.systems.systems) |sys| {
        // Validate phase index
        if (sys.phase >= phase_count) {
            @compileError("WorldConfig: system '" ++ sys.name ++ "' references invalid phase index");
        }
        for (sys.read_components) |comp| {
            if (!componentInSpec(cfg.components, comp)) {
                @compileError("WorldConfig: system '" ++ sys.name ++ "' read_components references component not in ComponentsSpec");
            }
        }
        for (sys.write_components) |comp| {
            if (!componentInSpec(cfg.components, comp)) {
                @compileError("WorldConfig: system '" ++ sys.name ++ "' write_components references component not in ComponentsSpec");
            }
        }
    }

    // Validate no duplicate archetypes (same component sets)
    const archs = cfg.archetypes.archetypes;
    for (archs, 0..) |arch_a, i| {
        for (archs[i + 1 ..]) |arch_b| {
            if (componentSetsEqual(arch_a.components, arch_b.components)) {
                @compileError("WorldConfig: duplicate archetype definitions with same component set: '" ++ arch_a.name ++ "' and '" ++ arch_b.name ++ "'");
            }
        }
    }

    // Validate coordination config (only for coordinated worlds)
    if (cfg.coordination.role != .standalone) {
        validateCoordinationConfig(cfg.coordination);
    }

    // Validate pipeline config
    validatePipelineConfig(cfg.pipeline);

    // Validate scalability config (only when features are enabled)
    if (cfg.scalability.anyEnabled()) {
        validateScalabilityConfig(cfg.scalability);
    }
}

/// Validates pipeline-specific configuration at compile time.
pub fn validatePipelineConfig(comptime pipeline: PipelineConfig) void {
    // Validate external mode settings
    if (pipeline.mode == .external or pipeline.mode == .hybrid) {
        // Batch size must be positive
        if (pipeline.external.batch_size == 0) {
            @compileError("WorldConfig: pipeline.external.batch_size must be at least 1");
        }

        // Buffer sizes must be positive
        if (pipeline.external.export_buffer_size == 0) {
            @compileError("WorldConfig: pipeline.external.export_buffer_size must be at least 1");
        }
        if (pipeline.external.import_buffer_size == 0) {
            @compileError("WorldConfig: pipeline.external.import_buffer_size must be at least 1");
        }
    }

    // Validate hybrid mode settings
    if (pipeline.mode == .hybrid) {
        // Fast-path capacity must be positive
        if (pipeline.hybrid.fast_path_capacity == 0) {
            @compileError("WorldConfig: pipeline.hybrid.fast_path_capacity must be at least 1");
        }

        // Verify predicate type has canFastPath method
        const PredicateType = pipeline.hybrid.fast_path_predicate_type;
        if (!@hasDecl(PredicateType, "canFastPath")) {
            @compileError("WorldConfig: pipeline.hybrid.fast_path_predicate_type must have canFastPath method");
        }
    }
}

/// Validates coordination-specific configuration at compile time.
pub fn validateCoordinationConfig(comptime coord: WorldCoordinationConfig) void {
    // Validate transfer queue capacity is power of 2
    if (!std.math.isPowerOfTwo(coord.transfer_queue.capacity)) {
        @compileError("WorldConfig: transfer_queue.capacity must be power of 2 for lock-free efficiency");
    }

    // Validate batch size doesn't exceed capacity
    if (coord.transfer_queue.batch_size > coord.transfer_queue.capacity) {
        @compileError("WorldConfig: transfer_queue.batch_size exceeds queue capacity");
    }

    // Validate batch size is reasonable (at least 1)
    if (coord.transfer_queue.batch_size == 0) {
        @compileError("WorldConfig: transfer_queue.batch_size must be at least 1");
    }
}

/// Validates scalability-specific configuration at compile time.
pub fn validateScalabilityConfig(comptime scale: ScalabilityConfig) void {
    // Validate cluster config
    if (scale.cluster.enabled) {
        // Node ID must be less than total instances
        if (scale.cluster.node_id >= scale.cluster.total_instances) {
            @compileError("WorldConfig: scalability.cluster.node_id must be less than total_instances");
        }

        // Total instances must be at least 1
        if (scale.cluster.total_instances == 0) {
            @compileError("WorldConfig: scalability.cluster.total_instances must be at least 1");
        }

        // Heartbeat interval must be positive
        if (scale.cluster.heartbeat_interval_ms == 0) {
            @compileError("WorldConfig: scalability.cluster.heartbeat_interval_ms must be at least 1");
        }

        // Peer timeout must be greater than heartbeat interval
        if (scale.cluster.peer_timeout_ms <= scale.cluster.heartbeat_interval_ms) {
            @compileError("WorldConfig: scalability.cluster.peer_timeout_ms must be greater than heartbeat_interval_ms");
        }
    }

    // Validate huge pages threshold is at least page size
    if (scale.huge_pages.enabled) {
        const page_size = @intFromEnum(scale.huge_pages.size);
        if (scale.huge_pages.threshold > 0 and scale.huge_pages.threshold < page_size) {
            @compileError("WorldConfig: scalability.huge_pages.threshold should be at least the page size");
        }
    }

    // Validate NUMA interleave config
    if (scale.numa.enabled and scale.numa.strategy == .interleave) {
        if (scale.numa.interleave.page_size == 0) {
            @compileError("WorldConfig: scalability.numa.interleave.page_size must be at least 1");
        }
    }
}

/// Validates scheduler-specific configuration at compile time.
pub fn validateSchedulerConfig(comptime cfg: WorldConfig) void {
    // First validate world config
    validateWorldConfig(cfg);

    // Validate execution model compatibility with system modes
    for (cfg.systems.systems) |sys| {
        // blocking_single_thread ignores parallelism hints, no validation needed
        // evented_single_thread: parallelism creates logical tasks but no true parallelism
        // concurrent_threadpool: full parallelism support

        // For blocking_single_thread, warn if parallelism is specified but won't be used
        // (This is informational, not an error - the config is still valid)

        // Validate that may_async is only used with compatible execution models
        if (sys.asynchrony == .may_async) {
            if (cfg.schedule.execution_model == .blocking_single_thread) {
                // This is valid but the async hint is ignored - no error
            }
        }
    }
}

/// Helper: check if a component type exists in ComponentsSpec.
fn componentInSpec(comptime spec: ComponentsSpec, comptime T: type) bool {
    inline for (spec.types) |comp| {
        if (comp == T) return true;
    }
    return false;
}

/// Helper: check if two component sets are equal (same types, order-independent).
fn componentSetsEqual(comptime a: []const type, comptime b: []const type) bool {
    if (a.len != b.len) return false;
    inline for (a) |ta| {
        var found = false;
        inline for (b) |tb| {
            if (ta == tb) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "WorldConfig defaults" {
    const cfg = WorldConfig{};
    try std.testing.expectEqual(@as(usize, 0), cfg.componentCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.archetypeCount());
    try std.testing.expectEqual(@as(usize, 0), cfg.systemCount());
    try std.testing.expectEqual(LayoutMode.multi_archetype, cfg.options.layout_mode);
    try std.testing.expectEqual(@as(u32, 65536), cfg.options.max_entities);
}

test "WorldConfigView" {
    const cfg = WorldConfig{
        .options = .{ .max_entities = 1000, .layout_mode = .single_archetype },
        .tick = .{ .mode = .fixed_rate, .target_hz = 60 },
        .archetypes = .{ .archetypes = &.{.{ .name = "test", .components = &.{} }} },
    };

    const view = WorldConfigView.init(cfg);
    try std.testing.expectEqual(LayoutMode.single_archetype, view.layoutMode());
    try std.testing.expectEqual(@as(u32, 1000), view.maxEntities());
    try std.testing.expectEqual(TickMode.fixed_rate, view.tickMode());
    try std.testing.expectEqual(@as(?u32, 60), view.tickTargetHz());
}

test "componentInSpec" {
    const TestComp = struct { x: i32 };
    const OtherComp = struct { y: f32 };

    const spec = ComponentsSpec{ .types = &.{TestComp} };
    try std.testing.expect(componentInSpec(spec, TestComp));
    try std.testing.expect(!componentInSpec(spec, OtherComp));
}

test "componentSetsEqual" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    try std.testing.expect(componentSetsEqual(&.{ A, B }, &.{ B, A }));
    try std.testing.expect(componentSetsEqual(&.{A}, &.{A}));
    try std.testing.expect(componentSetsEqual(&.{}, &.{}));
    try std.testing.expect(!componentSetsEqual(&.{ A, B }, &.{ A, C }));
    try std.testing.expect(!componentSetsEqual(&.{A}, &.{ A, B }));
}

test "WorldRole enum" {
    // Test WorldRole values exist and are distinct
    try std.testing.expect(@intFromEnum(WorldRole.standalone) != @intFromEnum(WorldRole.accept));
    try std.testing.expect(@intFromEnum(WorldRole.io) != @intFromEnum(WorldRole.compute));
    try std.testing.expect(@intFromEnum(WorldRole.custom) != @intFromEnum(WorldRole.standalone));
}

test "WorldCoordinationConfig defaults" {
    const coord = WorldCoordinationConfig{};
    try std.testing.expectEqual(WorldRole.standalone, coord.role);
    try std.testing.expectEqual(@as(u8, 0), coord.world_id);
    try std.testing.expectEqual(@as(u32, 4096), coord.transfer_queue.capacity);
    try std.testing.expectEqual(@as(u32, 64), coord.transfer_queue.batch_size);
    try std.testing.expectEqual(false, coord.transfer_queue.spsc);
    try std.testing.expectEqual(@as(?u8, null), coord.routing.default_target);
}

test "WorldConfig isCoordinated" {
    // Standalone world (default)
    const standalone_cfg = WorldConfig{};
    try std.testing.expect(!standalone_cfg.isCoordinated());

    // Coordinated world
    const coord_cfg = WorldConfig{
        .coordination = .{
            .role = .io,
            .world_id = 1,
        },
    };
    try std.testing.expect(coord_cfg.isCoordinated());
    try std.testing.expectEqual(WorldRole.io, coord_cfg.worldRole());
}

test "WorldConfigView coordination accessors" {
    const cfg = WorldConfig{
        .coordination = .{
            .role = .compute,
            .world_id = 2,
            .routing = .{ .default_target = 1 },
        },
    };
    const view = WorldConfigView.init(cfg);

    try std.testing.expect(view.isCoordinated());
    try std.testing.expectEqual(WorldRole.compute, view.worldRole());
    try std.testing.expectEqual(@as(u8, 2), view.worldId());
}

test "TransferQueueConfig validation - power of 2" {
    // Valid power of 2 capacities should not compile error
    const valid_configs = [_]u32{ 64, 128, 256, 512, 1024, 2048, 4096 };
    inline for (valid_configs) |cap| {
        try std.testing.expect(std.math.isPowerOfTwo(cap));
    }
}

// ============================================================================
// Pipeline Configuration Tests (Phase 6)
// ============================================================================

test "PipelineMode enum" {
    // Test PipelineMode values exist and are distinct
    try std.testing.expect(@intFromEnum(PipelineMode.internal) != @intFromEnum(PipelineMode.external));
    try std.testing.expect(@intFromEnum(PipelineMode.external) != @intFromEnum(PipelineMode.hybrid));
    try std.testing.expect(@intFromEnum(PipelineMode.hybrid) != @intFromEnum(PipelineMode.internal));
}

test "PipelineConfig defaults" {
    const pipeline = PipelineConfig{};
    try std.testing.expectEqual(PipelineMode.internal, pipeline.mode);
    try std.testing.expectEqual(@as(u32, 256), pipeline.external.batch_size);
    try std.testing.expectEqual(true, pipeline.external.zero_copy);
    try std.testing.expectEqual(@as(u32, 4096), pipeline.external.export_buffer_size);
    try std.testing.expectEqual(@as(u32, 4096), pipeline.external.import_buffer_size);
    try std.testing.expectEqual(@as(u32, 1024), pipeline.hybrid.fast_path_capacity);
    try std.testing.expectEqual(true, pipeline.hybrid.fallback_on_full);
}

test "DefaultFastPathPredicate always returns false" {
    const TestData = struct { value: i32 };
    const result = DefaultFastPathPredicate.canFastPath(TestData{ .value = 42 });
    try std.testing.expect(!result);
}

test "WorldConfig pipelineMode" {
    // Default internal mode
    const internal_cfg = WorldConfig{};
    try std.testing.expectEqual(PipelineMode.internal, internal_cfg.pipelineMode());
    try std.testing.expect(!internal_cfg.isExternalPipeline());
    try std.testing.expect(!internal_cfg.isHybridPipeline());

    // External mode
    const external_cfg = WorldConfig{
        .pipeline = .{ .mode = .external },
    };
    try std.testing.expectEqual(PipelineMode.external, external_cfg.pipelineMode());
    try std.testing.expect(external_cfg.isExternalPipeline());
    try std.testing.expect(!external_cfg.isHybridPipeline());

    // Hybrid mode
    const hybrid_cfg = WorldConfig{
        .pipeline = .{ .mode = .hybrid },
    };
    try std.testing.expectEqual(PipelineMode.hybrid, hybrid_cfg.pipelineMode());
    try std.testing.expect(!hybrid_cfg.isExternalPipeline());
    try std.testing.expect(hybrid_cfg.isHybridPipeline());
}

test "WorldConfigView pipeline accessors" {
    const cfg = WorldConfig{
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{ .fast_path_capacity = 2048 },
        },
    };
    const view = WorldConfigView.init(cfg);

    try std.testing.expectEqual(PipelineMode.hybrid, view.pipelineMode());
    try std.testing.expect(!view.isExternalPipeline());
    try std.testing.expect(view.isHybridPipeline());
}

test "ExternalPipelineConfig custom values" {
    const external = ExternalPipelineConfig{
        .batch_size = 512,
        .zero_copy = false,
        .export_buffer_size = 8192,
        .import_buffer_size = 8192,
    };
    try std.testing.expectEqual(@as(u32, 512), external.batch_size);
    try std.testing.expectEqual(false, external.zero_copy);
    try std.testing.expectEqual(@as(u32, 8192), external.export_buffer_size);
    try std.testing.expectEqual(@as(u32, 8192), external.import_buffer_size);
}

test "HybridPipelineConfig custom predicate" {
    const CustomPredicate = struct {
        pub fn canFastPath(data: anytype) bool {
            _ = data;
            return true; // Always fast-path
        }
    };

    const hybrid = HybridPipelineConfig{
        .fast_path_predicate_type = CustomPredicate,
        .fast_path_capacity = 4096,
        .fallback_on_full = false,
    };

    try std.testing.expectEqual(@as(u32, 4096), hybrid.fast_path_capacity);
    try std.testing.expectEqual(false, hybrid.fallback_on_full);

    // Verify custom predicate works
    const TestData = struct { x: i32 };
    const result = CustomPredicate.canFastPath(TestData{ .x = 1 });
    try std.testing.expect(result);
}

// ============================================================================
// Scalability Configuration Tests (Phase 7)
// ============================================================================

test "NumaConfig defaults" {
    const numa = NumaConfig{};
    try std.testing.expectEqual(false, numa.enabled);
    try std.testing.expectEqual(NumaConfig.Strategy.local_preferred, numa.strategy);
    try std.testing.expectEqual(@as(?[]const NumaConfig.NodeBinding, null), numa.node_bindings);
    try std.testing.expectEqual(@as(usize, 4096), numa.interleave.page_size);
}

test "NumaConfig custom values" {
    const numa = NumaConfig{
        .enabled = true,
        .strategy = .interleave,
        .interleave = .{
            .page_size = 2 * 1024 * 1024, // 2MB
        },
    };
    try std.testing.expectEqual(true, numa.enabled);
    try std.testing.expectEqual(NumaConfig.Strategy.interleave, numa.strategy);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), numa.interleave.page_size);
}

test "HugePageConfig defaults" {
    const huge = HugePageConfig{};
    try std.testing.expectEqual(false, huge.enabled);
    try std.testing.expectEqual(HugePageConfig.PageSize.@"2MB", huge.size);
    try std.testing.expectEqual(true, huge.fallback);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), huge.threshold);
}

test "HugePageConfig custom values" {
    const huge = HugePageConfig{
        .enabled = true,
        .size = .@"1GB",
        .fallback = false,
        .threshold = 512 * 1024 * 1024, // 512MB
    };
    try std.testing.expectEqual(true, huge.enabled);
    try std.testing.expectEqual(HugePageConfig.PageSize.@"1GB", huge.size);
    try std.testing.expectEqual(false, huge.fallback);
    try std.testing.expectEqual(@as(usize, 512 * 1024 * 1024), huge.threshold);
}

test "HugePageConfig page size values" {
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), @intFromEnum(HugePageConfig.PageSize.@"2MB"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), @intFromEnum(HugePageConfig.PageSize.@"1GB"));
}

test "AffinityConfig defaults" {
    const aff = AffinityConfig{};
    try std.testing.expectEqual(false, aff.enabled);
    try std.testing.expectEqual(AffinityConfig.Strategy.sequential, aff.strategy);
    try std.testing.expectEqual(@as(?[]const AffinityConfig.CpuBinding, null), aff.cpu_bindings);
    try std.testing.expectEqual(true, aff.prefer_physical);
}

test "AffinityConfig custom values" {
    const aff = AffinityConfig{
        .enabled = true,
        .strategy = .numa_spread,
        .prefer_physical = false,
    };
    try std.testing.expectEqual(true, aff.enabled);
    try std.testing.expectEqual(AffinityConfig.Strategy.numa_spread, aff.strategy);
    try std.testing.expectEqual(false, aff.prefer_physical);
}

test "ClusterConfig defaults" {
    const cluster = ClusterConfig{};
    try std.testing.expectEqual(false, cluster.enabled);
    try std.testing.expectEqual(@as(u16, 0), cluster.node_id);
    try std.testing.expectEqual(@as(u16, 1), cluster.total_instances);
    try std.testing.expectEqual(ClusterConfig.Discovery.static, cluster.discovery);
    try std.testing.expectEqual(ClusterConfig.Transport.tcp, cluster.transport);
    try std.testing.expectEqual(ClusterConfig.Topology.mesh, cluster.topology);
    try std.testing.expectEqual(ClusterConfig.OwnershipStrategy.hash_based, cluster.ownership);
    try std.testing.expectEqual(@as(u32, 1000), cluster.heartbeat_interval_ms);
    try std.testing.expectEqual(@as(u32, 5000), cluster.peer_timeout_ms);
}

test "ClusterConfig custom values" {
    const cluster = ClusterConfig{
        .enabled = true,
        .node_id = 2,
        .total_instances = 5,
        .discovery = .dns,
        .transport = .udp,
        .topology = .ring,
        .ownership = .consistent_hash,
        .heartbeat_interval_ms = 500,
        .peer_timeout_ms = 3000,
    };
    try std.testing.expectEqual(true, cluster.enabled);
    try std.testing.expectEqual(@as(u16, 2), cluster.node_id);
    try std.testing.expectEqual(@as(u16, 5), cluster.total_instances);
    try std.testing.expectEqual(ClusterConfig.Discovery.dns, cluster.discovery);
    try std.testing.expectEqual(ClusterConfig.Transport.udp, cluster.transport);
    try std.testing.expectEqual(ClusterConfig.Topology.ring, cluster.topology);
    try std.testing.expectEqual(ClusterConfig.OwnershipStrategy.consistent_hash, cluster.ownership);
    try std.testing.expectEqual(@as(u32, 500), cluster.heartbeat_interval_ms);
    try std.testing.expectEqual(@as(u32, 3000), cluster.peer_timeout_ms);
}

test "ScalabilityConfig defaults" {
    const scale = ScalabilityConfig{};
    try std.testing.expect(!scale.anyEnabled());
    try std.testing.expect(!scale.wantsNuma());
    try std.testing.expect(!scale.wantsHugePages());
    try std.testing.expect(!scale.wantsAffinity());
    try std.testing.expect(!scale.wantsCluster());
}

test "ScalabilityConfig anyEnabled" {
    // Test each feature individually
    var scale = ScalabilityConfig{};

    scale.numa.enabled = true;
    try std.testing.expect(scale.anyEnabled());
    try std.testing.expect(scale.wantsNuma());
    scale.numa.enabled = false;

    scale.huge_pages.enabled = true;
    try std.testing.expect(scale.anyEnabled());
    try std.testing.expect(scale.wantsHugePages());
    scale.huge_pages.enabled = false;

    scale.affinity.enabled = true;
    try std.testing.expect(scale.anyEnabled());
    try std.testing.expect(scale.wantsAffinity());
    scale.affinity.enabled = false;

    scale.cluster.enabled = true;
    try std.testing.expect(scale.anyEnabled());
    try std.testing.expect(scale.wantsCluster());
}

test "WorldConfig default scalability" {
    const cfg = WorldConfig{};
    try std.testing.expect(!cfg.hasScalabilityFeatures());
    try std.testing.expect(!cfg.wantsNuma());
    try std.testing.expect(!cfg.wantsHugePages());
    try std.testing.expect(!cfg.wantsAffinity());
    try std.testing.expect(!cfg.wantsCluster());
    try std.testing.expectEqual(@as(u16, 0), cfg.clusterNodeId());
}

test "WorldConfig with scalability" {
    const cfg = WorldConfig{
        .scalability = .{
            .numa = .{ .enabled = true, .strategy = .local_strict },
            .huge_pages = .{ .enabled = true, .size = .@"2MB" },
            .affinity = .{ .enabled = true, .strategy = .physical_only },
            .cluster = .{ .enabled = true, .node_id = 3, .total_instances = 8 },
        },
    };
    try std.testing.expect(cfg.hasScalabilityFeatures());
    try std.testing.expect(cfg.wantsNuma());
    try std.testing.expect(cfg.wantsHugePages());
    try std.testing.expect(cfg.wantsAffinity());
    try std.testing.expect(cfg.wantsCluster());
    try std.testing.expectEqual(@as(u16, 3), cfg.clusterNodeId());
}

test "WorldConfigView scalability accessors" {
    const cfg = WorldConfig{
        .scalability = .{
            .numa = .{ .enabled = true },
            .cluster = .{ .enabled = true, .node_id = 5, .total_instances = 10 },
        },
    };
    const view = WorldConfigView.init(cfg);

    try std.testing.expect(view.hasScalabilityFeatures());
    try std.testing.expect(view.wantsNuma());
    try std.testing.expect(!view.wantsHugePages());
    try std.testing.expect(!view.wantsAffinity());
    try std.testing.expect(view.wantsCluster());
    try std.testing.expectEqual(@as(u16, 5), view.clusterNodeId());
}
