//! Specification types for StaticECS configuration.
//!
//! This module defines specification structures that declare:
//! - Components, archetypes, and systems
//! - Scheduling and tick behavior
//! - Resource types and phases
//! - Global options and limits

const core = @import("core_types.zig");
const definition = @import("definition_types.zig");
const backend = @import("backend_config.zig");

// Re-export for convenience
pub const ExecutionModel = core.ExecutionModel;
pub const TickMode = core.TickMode;
pub const LayoutMode = core.LayoutMode;
pub const CapacityMode = core.CapacityMode;
pub const PhaseDef = core.PhaseDef;
pub const DEFAULT_PHASES = core.DEFAULT_PHASES;
pub const ArchetypeDef = definition.ArchetypeDef;
pub const SystemDef = definition.SystemDef;
pub const BackendConfig = backend.BackendConfig;

// ============================================================================
// Entity and System Specs
// ============================================================================

/// ComponentsSpec declares the universe of component types for a world.
/// Default: Empty - no components defined.
/// Rationale: Users must explicitly declare their component types; there are
/// no "built-in" components to avoid assumptions about domain models.
pub const ComponentsSpec = struct {
    /// List of all component types used by this world.
    types: []const type = &.{},
};

/// ArchetypesSpec defines the fixed set of entity structures.
/// Default: Empty - no archetypes defined.
/// Rationale: Archetypes represent the structural patterns of entities in your
/// domain. Empty default ensures users consciously design their entity layout.
pub const ArchetypesSpec = struct {
    /// List of archetype definitions.
    archetypes: []const ArchetypeDef = &.{},
};

/// SystemsSpec describes all systems for this world.
/// Default: Empty - no systems defined.
/// Rationale: Systems implement game/application logic. Empty default allows
/// testing world infrastructure without logic, or creating data-only worlds.
pub const SystemsSpec = struct {
    /// List of system definitions.
    systems: []const SystemDef = &.{},
};

// ============================================================================
// Schedule and Tick Specs
// ============================================================================

/// ScheduleSpec provides hints/limits to the scheduler.
pub const ScheduleSpec = struct {
    /// Selects the scheduler family and execution semantics.
    /// Default: .blocking_single_thread
    /// Rationale: Single-threaded blocking is the simplest execution model with
    /// deterministic behavior and no concurrency complexity. Safe starting point
    /// for prototyping; switch to concurrent models when profiling shows need.
    execution_model: ExecutionModel = .blocking_single_thread,
    /// Upper bound on concurrent tasks (0 = let scheduler decide).
    /// Default: 0 (auto-detect based on CPU cores and execution model).
    /// Rationale: Auto-detect avoids hardcoding assumptions about deployment
    /// hardware. Most concurrent backends use core count as baseline.
    max_parallel_tasks: u32 = 0,
    /// Backend-specific configuration (optional).
    /// Default: .none - no backend-specific tuning.
    /// Rationale: Sensible defaults for each backend; explicit config only
    /// needed when profiling reveals optimization opportunities.
    backend_config: BackendConfig = .{ .none = {} },
};

/// TickSpec configures frame/tick driving behavior.
pub const TickSpec = struct {
    /// Default: .manual - application controls tick timing.
    /// Rationale: Manual ticking gives full control to the application,
    /// supporting both game loops (fixed timestep) and event-driven servers.
    /// Use .fixed_rate for simulation-style workloads requiring determinism.
    mode: TickMode = .manual,
    /// Fixed frequency when mode is .fixed_rate.
    /// Default: null (must be set when mode is .fixed_rate).
    /// Rationale: Common values: 60hz (games), 20hz (network tick), 1000hz (simulation).
    target_hz: ?u32 = null,
    /// Clamp/skip logic for large frame delays.
    /// Default: null (no clamping - all accumulated time processed).
    /// Rationale: For games, typically set to 100-200ms to prevent spiral-of-death
    /// when system hitches. Null is safe for servers without frame budget concerns.
    max_frame_delay_ns: ?u64 = null,
};

// ============================================================================
// Resource and Phase Specs
// ============================================================================

/// ResourcesSpec declares the global singleton resource types for a world.
/// Default: Empty - no resources defined.
/// Rationale: Resources are application-specific singletons (e.g., Time, Input).
/// Empty default avoids coupling to any particular framework conventions.
pub const ResourcesSpec = struct {
    /// List of all resource types used by this world.
    types: []const type = &.{},
};

/// PhasesSpec configures the execution phases for systems.
/// Tiger Style: Phases are fully configurable.
pub const PhasesSpec = struct {
    /// List of phase definitions in execution order.
    /// Index in array = phase index used in SystemDef.phase.
    /// Default: DEFAULT_PHASES (.pre_update, .update, .post_update).
    /// Rationale: Three-phase model is the minimal useful pattern:
    /// - pre_update: Input handling, physics prep, command processing
    /// - update: Main logic, AI, movement, combat
    /// - post_update: Rendering prep, cleanup, state synchronization
    /// Add more phases (e.g., .fixed_update, .late_update) as needed.
    phases: []const PhaseDef = DEFAULT_PHASES,
};

// ============================================================================
// Global Options
// ============================================================================

/// Options provides miscellaneous global options and invariants.
/// Tiger Style: All bounds are configurable. No hardcoded limits.
pub const Options = struct {
    /// Entity layout mode.
    /// Default: .multi_archetype - supports multiple entity structures.
    /// Rationale: Multi-archetype is the general ECS pattern supporting diverse
    /// entity compositions. Use .single_archetype only for homogeneous data
    /// (e.g., particles) where all entities share identical components.
    layout_mode: LayoutMode = .multi_archetype,

    /// Number of bits for entity index. Generation uses remaining bits (32 - index).
    /// Must be between 8 and 24 (inclusive).
    /// Default: 20 bits (~1M entities, 4096 generations).
    /// Rationale: Balanced trade-off for typical games/simulations:
    /// - 24 bits: ~16M entities, 256 generations (massive open worlds)
    /// - 20 bits: ~1M entities, 4096 generations (most games/servers)
    /// - 16 bits: ~64K entities, 65536 generations (high-turnover scenarios)
    /// Higher generation bits catch stale entity references more reliably.
    entity_index_bits: u5 = 20,

    /// Hard upper bound on entity count.
    /// Must be <= (2^entity_index_bits - 1).
    /// Default: 65536 (64K entities).
    /// Rationale: 64K is sufficient for most real-time applications while keeping
    /// memory footprint reasonable (~4MB for 64-byte entities). This is a
    /// conservative default; large simulations should increase based on profiling.
    /// Memory estimate: max_entities * avg_entity_size = allocation requirement.
    max_entities: u32 = 65536,

    /// Archetype storage capacity mode.
    /// Default: .fixed - pre-allocate based on max_entities.
    /// Rationale: Tiger Style mandates static allocation for predictable memory
    /// and zero runtime allocation failures. Use .dynamic only when entity count
    /// is truly unbounded and you accept allocation failure risks.
    capacity_mode: CapacityMode = .fixed,

    /// Maximum commands per frame (for command buffer sizing).
    /// Default: 1024 commands per frame.
    /// Rationale: Supports typical game frame with ~1000 entity operations
    /// (spawn, despawn, component changes). Increase for batch processing
    /// or procedural generation that creates many entities per frame.
    /// Memory: ~1024 * sizeof(Command) bytes per command buffer.
    max_commands_per_frame: u32 = 1024,

    /// Maximum inline data size for component data in commands (bytes).
    /// Default: 256 bytes.
    /// Rationale: Covers most game components (transforms, stats, states).
    /// Larger components should use pointer-based storage or be split.
    /// Components exceeding this cannot use deferred set_component.
    max_component_data_size: u32 = 256,

    /// Expected entities per archetype (for pre-allocation).
    /// Default: 0 (no pre-allocation, grow on demand).
    /// Rationale: Pre-allocation requires knowing entity distribution upfront.
    /// Set to expected max when archetype counts are predictable for better
    /// cache locality and avoiding reallocation during gameplay.
    expected_entities_per_archetype: u32 = 0,

    /// Maximum phases in a schedule.
    /// Default: 16 phases.
    /// Rationale: Covers complex pipelines (input, physics, AI, render, network).
    /// Most applications need 3-8 phases; 16 provides headroom for future
    /// expansion without code changes.
    max_phases: u8 = 16,

    /// Maximum stages per phase (for schedule building).
    /// Default: 16 stages.
    /// Rationale: Stages represent dependency groups within a phase. 16 allows
    /// complex system graphs with multiple sequential dependency chains.
    /// Increase if automatic scheduling creates deeper dependencies.
    max_stages_per_phase: u16 = 16,

    /// Maximum systems per stage (for schedule building).
    /// Default: 32 systems.
    /// Rationale: Systems in the same stage run in parallel. 32 accommodates
    /// high parallelism in data-parallel workloads (physics, AI, rendering).
    /// Typical applications have 5-15 systems per stage.
    max_systems_per_stage: u16 = 32,

    /// Maximum errors to aggregate per frame (when using aggregate frame policy).
    /// Default: 16 errors.
    /// Rationale: Aggregation prevents error storms from masking root causes.
    /// 16 captures first failures across subsystems for debugging without
    /// unbounded memory growth in pathological cases.
    max_aggregate_errors: u16 = 16,

    /// Controls runtime safety checks.
    /// Default: true - safety checks enabled.
    /// Rationale: Always enable during development; consider disabling in
    /// release builds after extensive testing for ~5-10% performance gain.
    enable_debug_asserts: bool = true,

    /// Optional version lock against the core library.
    /// Default: null - no version checking.
    /// Rationale: Set to specific version when deploying to production to catch
    /// accidental library upgrades that might change behavior.
    core_version: ?struct { major: u32, minor: u32, patch: u32 } = null,
};
