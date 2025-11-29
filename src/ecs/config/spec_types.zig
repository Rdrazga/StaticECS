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

// ============================================================================
// Schedule and Tick Specs
// ============================================================================

/// ScheduleSpec provides hints/limits to the scheduler.
pub const ScheduleSpec = struct {
    /// Selects the scheduler family and execution semantics.
    execution_model: ExecutionModel = .blocking_single_thread,
    /// Upper bound on concurrent tasks (0 = let scheduler decide).
    max_parallel_tasks: u32 = 0,
    /// Backend-specific configuration (optional).
    backend_config: BackendConfig = .{ .none = {} },
};

/// TickSpec configures frame/tick driving behavior.
pub const TickSpec = struct {
    mode: TickMode = .manual,
    /// Fixed frequency when mode is .fixed_rate.
    target_hz: ?u32 = null,
    /// Clamp/skip logic for large frame delays.
    max_frame_delay_ns: ?u64 = null,
};

// ============================================================================
// Resource and Phase Specs
// ============================================================================

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

// ============================================================================
// Global Options
// ============================================================================

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
    /// Archetype storage capacity mode.
    /// Tiger_Style: Default to .fixed for static allocation compliance.
    /// Use .dynamic only when entity count is truly unbounded.
    capacity_mode: CapacityMode = .fixed,
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
