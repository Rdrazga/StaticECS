//! Schedule Building and Conflict Analysis
//!
//! This module provides compile-time schedule construction including:
//! - Conflict graph analysis between systems
//! - Phase and stage building
//! - System ordering within phases

const std = @import("std");
const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const Phase = config_mod.Phase;
const SystemDef = config_mod.SystemDef;

// ============================================================================
// Conflict Analysis
// ============================================================================

/// Check if two systems have a data conflict (cannot run concurrently).
/// A conflict exists if:
/// - A.write intersects B.write, or
/// - A.write intersects B.read, or
/// - A.read intersects B.write
pub fn systemsConflict(comptime a: SystemDef, comptime b: SystemDef) bool {
    // Check write-write conflicts
    inline for (a.write_components) |aw| {
        inline for (b.write_components) |bw| {
            if (aw == bw) return true;
        }
    }

    // Check write-read conflicts (A writes, B reads)
    inline for (a.write_components) |aw| {
        inline for (b.read_components) |br| {
            if (aw == br) return true;
        }
    }

    // Check read-write conflicts (A reads, B writes)
    inline for (a.read_components) |ar| {
        inline for (b.write_components) |bw| {
            if (ar == bw) return true;
        }
    }

    return false;
}

/// Build a conflict matrix for all systems.
/// Returns a 2D array where conflicts[i][j] is true if systems i and j conflict.
pub fn buildConflictMatrix(comptime systems: []const SystemDef) [systems.len][systems.len]bool {
    var matrix: [systems.len][systems.len]bool = undefined;

    inline for (0..systems.len) |i| {
        inline for (0..systems.len) |j| {
            if (i == j) {
                matrix[i][j] = false; // System doesn't conflict with itself
            } else {
                matrix[i][j] = systemsConflict(systems[i], systems[j]);
            }
        }
    }

    return matrix;
}

// ============================================================================
// Stage Building
// ============================================================================

/// Default maximum systems per stage (used when config not provided).
/// This is overridden by Options.max_systems_per_stage in Schedule().
pub const DEFAULT_MAX_SYSTEMS_PER_STAGE: u16 = 32;

/// Default maximum stages per phase (used when config not provided).
/// This is overridden by Options.max_stages_per_phase in Schedule().
pub const DEFAULT_MAX_STAGES_PER_PHASE: u16 = 16;

/// A stage is a group of systems that can run concurrently (no conflicts).
/// Uses fixed-size arrays sized from config to avoid slice-to-comptime-var issues.
/// Tiger Style: All bounds come from WorldConfig.options.
pub fn StageType(comptime max_systems: u16) type {
    return struct {
        const Self = @This();
        /// Maximum systems this stage can hold.
        pub const max_systems_per_stage = max_systems;

        /// Indices of systems in this stage (fixed-size array).
        system_indices: [max_systems]u16 = .{0} ** max_systems,
        /// Number of valid system indices.
        system_count: u16 = 0,
        /// Phase index this stage belongs to (into WorldConfig.phases).
        phase_index: u8 = 0,
        /// Stage index within the phase.
        stage_index: u16 = 0,

        /// Get the valid system indices as a slice.
        pub fn getSystemIndices(self: *const Self) []const u16 {
            return self.system_indices[0..self.system_count];
        }
    };
}

/// Result of building stages for a phase.
/// Tiger Style: All bounds come from WorldConfig.options.
pub fn PhaseStagesType(comptime max_stages: u16, comptime max_systems: u16) type {
    const StageT = StageType(max_systems);
    return struct {
        const Self = @This();
        /// Maximum stages this phase can hold.
        pub const max_stages_per_phase = max_stages;
        pub const Stage = StageT;

        stages: [max_stages]StageT = .{StageT{}} ** max_stages,
        stage_count: u16 = 0,

        /// Get the valid stages as a slice.
        pub fn getStages(self: *const Self) []const StageT {
            return self.stages[0..self.stage_count];
        }
    };
}

/// @deprecated Use `Schedule(cfg).ConfigStage` for config-aware stage types.
///
/// These legacy type aliases use hardcoded default sizes which may not match
/// your WorldConfig. For new code, access stage types through the Schedule:
///
/// ```zig
/// const Sched = Schedule(cfg);
/// const MyStage = Sched.ConfigStage;           // Config-sized stage type
/// const MyPhaseStages = Sched.ConfigPhaseStages; // Config-sized phase stages
/// ```
///
/// Migration path:
/// - Replace `schedule_build.Stage` with `Schedule(cfg).ConfigStage`
/// - Replace `schedule_build.PhaseStages` with config-aware type from Schedule
///
/// These aliases will be removed in a future version.
pub const Stage = StageType(DEFAULT_MAX_SYSTEMS_PER_STAGE);
/// @deprecated Use `Schedule(cfg).ConfigPhaseStages` instead. See Stage for details.
pub const PhaseStages = PhaseStagesType(DEFAULT_MAX_STAGES_PER_PHASE, DEFAULT_MAX_SYSTEMS_PER_STAGE);

/// Find the earliest stage without conflicts for a system.
/// Uses greedy graph coloring - assigns system to first stage where no conflict exists.
/// Why: Separates stage selection logic for testability and clarity.
/// Tiger Style: Pure helper, no side effects. Returns stage index.
fn findBestStageForSystem(
    comptime sys_idx: u16,
    comptime phase_system_indices: []const u16,
    comptime prior_count: usize,
    comptime stage_assignments: []const u16,
    comptime num_stages: u16,
    comptime conflicts: anytype,
) u16 {
    // Assertion: system index must be within bounds of conflict matrix
    comptime std.debug.assert(sys_idx < conflicts.len);
    // Assertion: prior_count cannot exceed phase_system_indices length
    comptime std.debug.assert(prior_count <= phase_system_indices.len);

    // Search through existing stages plus one potential new stage
    stage_search: for (0..num_stages + 1) |stage| {
        // Check if any previously-assigned system in this stage conflicts
        for (0..prior_count) |prev_pi| {
            const prev_idx = phase_system_indices[prev_pi];
            if (stage_assignments[prev_idx] == stage) {
                if (conflicts[sys_idx][prev_idx]) {
                    continue :stage_search; // Conflict found, try next stage
                }
            }
        }
        return @intCast(stage); // No conflicts in this stage
    }

    // Fallback: create new stage (shouldn't reach here with proper loop bounds)
    return num_stages;
}

/// Build stage structures from assignments array.
/// Why: Separates structure building from assignment logic for clarity.
/// Tiger Style: Pure transformation, predictable output from input.
fn buildStageStructures(
    comptime StageT: type,
    comptime phase_index: u8,
    comptime phase_system_indices: []const u16,
    comptime phase_system_count: u16,
    comptime stage_assignments: []const u16,
    comptime num_stages: u16,
    comptime max_stages: u16,
) [max_stages]StageT {
    // Assertion: num_stages must fit within configured max
    comptime std.debug.assert(num_stages <= max_stages);
    // Assertion: phase_system_count must match indices slice length
    comptime std.debug.assert(phase_system_count == phase_system_indices.len);

    var stages: [max_stages]StageT = .{StageT{}} ** max_stages;

    for (0..num_stages) |stage| {
        stages[stage].phase_index = phase_index;
        stages[stage].stage_index = @intCast(stage);
        stages[stage].system_count = 0;

        // Collect system indices assigned to this stage
        for (0..phase_system_count) |pi| {
            const sys_idx = phase_system_indices[pi];
            if (stage_assignments[sys_idx] == stage) {
                stages[stage].system_indices[stages[stage].system_count] = sys_idx;
                stages[stage].system_count += 1;
            }
        }
    }

    return stages;
}

/// Build stages for a single phase using greedy graph coloring.
/// Systems are assigned to the earliest stage where they have no conflicts.
/// Tiger Style: Uses config-based bounds for stage sizing. Central control.
pub fn buildStagesForPhaseByIndex(
    comptime systems: []const SystemDef,
    comptime phase_index: u8,
    comptime conflicts: [systems.len][systems.len]bool,
    comptime max_stages: u16,
    comptime max_systems: u16,
) PhaseStagesType(max_stages, max_systems) {
    const PhaseStagesT = PhaseStagesType(max_stages, max_systems);
    var result = PhaseStagesT{};

    // Pre-condition: phase_index must be valid (bounded by reasonable value)
    comptime std.debug.assert(phase_index < 255);
    // Pre-condition: systems array must not exceed stage capacity bounds
    comptime std.debug.assert(systems.len <= max_systems * max_stages);

    // Collect systems belonging to this phase
    var phase_system_indices: [systems.len]u16 = undefined;
    var phase_system_count: u16 = 0;

    for (systems, 0..) |sys, i| {
        if (sys.phase == phase_index) {
            phase_system_indices[phase_system_count] = @intCast(i);
            phase_system_count += 1;
        }
    }

    if (phase_system_count == 0) return result; // No systems = empty result

    // Greedy stage assignment: assign each system to earliest non-conflicting stage
    var stage_assignments: [systems.len]u16 = .{0} ** systems.len;
    var num_stages: u16 = 0;

    for (0..phase_system_count) |pi| {
        const sys_idx = phase_system_indices[pi];
        const best = findBestStageForSystem(
            sys_idx,
            phase_system_indices[0..pi],
            pi,
            &stage_assignments,
            num_stages,
            conflicts,
        );
        stage_assignments[sys_idx] = best;
        if (best >= num_stages) num_stages = best + 1;
    }

    // Build stage structures from assignments
    result.stages = buildStageStructures(
        PhaseStagesT.Stage,
        phase_index,
        phase_system_indices[0..phase_system_count],
        phase_system_count,
        &stage_assignments,
        num_stages,
        max_stages,
    );
    result.stage_count = num_stages;

    // Post-condition: if systems exist, we must have at least one stage
    comptime std.debug.assert(phase_system_count == 0 or result.stage_count > 0);

    return result;
}

/// Legacy function for backward compatibility - builds stages using phase enum.
pub fn buildStagesForPhaseWithConfig(
    comptime systems: []const SystemDef,
    comptime phase: Phase,
    comptime conflicts: [systems.len][systems.len]bool,
    comptime max_stages: u16,
    comptime max_systems: u16,
) PhaseStagesType(max_stages, max_systems) {
    return buildStagesForPhaseByIndex(systems, phase.index(), conflicts, max_stages, max_systems);
}

/// Legacy function for backward compatibility with default sizes.
pub fn buildStagesForPhase(
    comptime systems: []const SystemDef,
    comptime phase: Phase,
    comptime conflicts: [systems.len][systems.len]bool,
) PhaseStages {
    return buildStagesForPhaseWithConfig(
        systems,
        phase,
        conflicts,
        DEFAULT_MAX_STAGES_PER_PHASE,
        DEFAULT_MAX_SYSTEMS_PER_STAGE,
    );
}

/// Complete schedule containing all phases and stages.
/// Tiger Style: All bounds come from WorldConfig.options.
/// Phases are now config-driven - WorldConfig.phases defines the phase sequence.
pub fn Schedule(comptime cfg: WorldConfig) type {
    // Get bounds from config
    const max_stages = cfg.options.max_stages_per_phase;
    const max_systems = cfg.options.max_systems_per_stage;
    const PhaseStagesT = PhaseStagesType(max_stages, max_systems);
    const phase_defs = cfg.phases.phases;
    const phase_count = phase_defs.len;

    return struct {
        const Self = @This();

        pub const systems = cfg.systems.systems;
        pub const system_count = systems.len;

        /// Type aliases for config-sized stages.
        pub const ConfigPhaseStages = PhaseStagesT;
        pub const ConfigStage = PhaseStagesT.Stage;

        /// Maximum bounds from config.
        pub const max_stages_per_phase = max_stages;
        pub const max_systems_per_stage = max_systems;

        /// Conflict matrix for all systems.
        pub const conflicts = buildConflictMatrix(systems);

        /// Phase definitions from config.
        /// Tiger Style: Phases are fully configurable.
        pub const phases = phase_defs;

        /// Number of phases in this schedule.
        pub const num_phases = phase_count;

        /// Stages organized by phase index (using config-sized PhaseStages struct).
        pub const stages_by_phase: [phase_count]PhaseStagesT = blk: {
            var result: [phase_count]PhaseStagesT = undefined;
            for (0..phase_count) |i| {
                result[i] = buildStagesForPhaseByIndex(systems, @intCast(i), conflicts, max_stages, max_systems);
            }
            break :blk result;
        };

        /// Total number of stages across all phases.
        pub const total_stages: usize = blk: {
            var count: usize = 0;
            for (stages_by_phase) |phase_stages| {
                count += phase_stages.stage_count;
            }
            break :blk count;
        };

        /// Get stages for a specific phase by index.
        pub fn getStagesForPhaseIndex(phase_index: u8) []const ConfigStage {
            return stages_by_phase[phase_index].getStages();
        }

        /// Get stages for a specific phase (backward compatible with Phase enum).
        pub fn getStagesForPhase(phase: Phase) []const ConfigStage {
            return stages_by_phase[phase.index()].getStages();
        }

        /// Get PhaseStages struct for a specific phase by index.
        pub fn getPhaseStagesByIndex(phase_index: u8) *const ConfigPhaseStages {
            return &stages_by_phase[phase_index];
        }

        /// Get PhaseStages struct for a specific phase (backward compatible).
        pub fn getPhaseStages(phase: Phase) *const ConfigPhaseStages {
            return &stages_by_phase[phase.index()];
        }

        /// Get phase name by index for tracing/debugging.
        pub fn getPhaseName(phase_index: u8) [:0]const u8 {
            return phases[phase_index].name;
        }

        /// Get system definition by index.
        pub fn getSystem(index: u16) SystemDef {
            return systems[index];
        }

        /// Check if two systems conflict.
        pub fn systemsConflictCheck(a: u16, b: u16) bool {
            return conflicts[a][b];
        }

        /// Get total number of systems.
        pub fn systemCount() usize {
            return system_count;
        }
    };
}

// ============================================================================
// System Execution Order
// ============================================================================

/// Flattened execution order for all systems.
pub fn buildExecutionOrder(comptime cfg: WorldConfig) []const u16 {
    const Sched = Schedule(cfg);
    comptime var order: [Sched.system_count]u16 = undefined;
    comptime var idx: usize = 0;

    // Iterate by phase index, not PhaseDef structs
    // Use getStagesForPhaseIndex which takes u8 index
    inline for (0..Sched.num_phases) |phase_idx| {
        const phase_stages = Sched.getStagesForPhaseIndex(@intCast(phase_idx));
        inline for (phase_stages) |stage| {
            // Use getSystemIndices() to get only valid indices
            const valid_indices = stage.getSystemIndices();
            inline for (valid_indices) |sys_idx| {
                order[idx] = sys_idx;
                idx += 1;
            }
        }
    }

    return order[0..idx];
}

// ============================================================================
// Tests
// ============================================================================

test "systemsConflict" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    const sys1 = SystemDef{
        .name = "sys1",
        .func = undefined,
        .write_components = &.{A},
        .read_components = &.{},
    };

    const sys2 = SystemDef{
        .name = "sys2",
        .func = undefined,
        .write_components = &.{A},
        .read_components = &.{},
    };

    const sys3 = SystemDef{
        .name = "sys3",
        .func = undefined,
        .write_components = &.{B},
        .read_components = &.{A},
    };

    const sys4 = SystemDef{
        .name = "sys4",
        .func = undefined,
        .write_components = &.{C},
        .read_components = &.{},
    };

    // Write-write conflict
    try std.testing.expect(systemsConflict(sys1, sys2));

    // Write-read conflict
    try std.testing.expect(systemsConflict(sys1, sys3));
    try std.testing.expect(systemsConflict(sys3, sys1));

    // No conflict
    try std.testing.expect(!systemsConflict(sys1, sys4));
    try std.testing.expect(!systemsConflict(sys3, sys4));
}

test "buildConflictMatrix" {
    const A = struct {};
    const B = struct {};

    const systems = [_]SystemDef{
        .{ .name = "s1", .func = undefined, .write_components = &.{A} },
        .{ .name = "s2", .func = undefined, .write_components = &.{B} },
        .{ .name = "s3", .func = undefined, .read_components = &.{A} },
    };

    const matrix = buildConflictMatrix(&systems);

    // s1 writes A, conflicts with s3 (reads A)
    try std.testing.expect(matrix[0][2]);
    try std.testing.expect(matrix[2][0]);

    // s1 and s2 don't conflict (different components)
    try std.testing.expect(!matrix[0][1]);

    // No self-conflicts
    try std.testing.expect(!matrix[0][0]);
    try std.testing.expect(!matrix[1][1]);
}

// Test config struct for Schedule type generation (module level for comptime evaluation)
const ScheduleTestConfig = struct {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    fn dummySystem(_: *anyopaque) void {}

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        } },
        .systems = .{
            .systems = &.{
                .{
                    .name = "physics",
                    .func = config_mod.asSystemFn(dummySystem),
                    .phase = 1, // update phase index
                    .write_components = &.{Position},
                    .read_components = &.{Velocity},
                },
                .{
                    .name = "render",
                    .func = config_mod.asSystemFn(dummySystem),
                    .phase = 3, // render phase index
                    .read_components = &.{Position},
                },
            },
        },
        .options = .{ .max_entities = 100 },
    };
};

test "Schedule type generation" {
    const Sched = Schedule(ScheduleTestConfig.cfg);

    try std.testing.expectEqual(@as(usize, 2), Sched.system_count);
    // Systems DO have a data conflict (physics writes Position, render reads Position)
    // They're in different phases so won't run in parallel, but the conflict matrix
    // correctly identifies the potential conflict if they did run simultaneously
    try std.testing.expect(Sched.conflicts[0][1]); // Conflict exists (write/read on Position)
}
