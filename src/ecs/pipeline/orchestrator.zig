//! Pipeline Orchestrator
//!
//! Provides a unified interface across all pipeline modes (internal, external,
//! hybrid). The orchestrator abstracts mode differences and provides a consistent
//! API for submitting work, ticking, and gathering statistics.
//!
//! ## Features
//!
//! - **Unified API**: Same interface regardless of pipeline mode
//! - **Mode-Specific Optimization**: Each mode runs its optimal path
//! - **Statistics Aggregation**: Combined stats across all modes
//! - **Comptime Mode Selection**: Zero overhead for unused modes
//!
//! Tiger Style: Mode selection is comptime, unused code paths are eliminated.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const PipelineMode = config_mod.PipelineMode;

const external = @import("external.zig");
const hybrid = @import("hybrid.zig");

// ============================================================================
// Pipeline Orchestrator Type Generator
// ============================================================================

/// Generate a PipelineOrchestrator type for a specific WorldConfig.
///
/// The generated type provides:
/// - Unified submit/tick interface
/// - Mode-specific optimizations
/// - Aggregated statistics
///
/// Tiger Style: All unused mode code is compiled out.
pub fn PipelineOrchestrator(comptime cfg: WorldConfig) type {
    const WorldType = @import("../world.zig").World(cfg);
    const mode = cfg.pipeline.mode;

    // Only include types for enabled modes
    const ExternalPipelineType = if (mode == .external)
        external.ExternalPipeline(cfg)
    else
        void;

    const HybridPipelineType = if (mode == .hybrid)
        hybrid.HybridPipeline(cfg)
    else
        void;

    return struct {
        const Self = @This();

        /// The world this orchestrator manages.
        world: *WorldType,

        /// Mode-specific state (only relevant fields are active).
        external_pipeline: if (mode == .external) ExternalPipelineType else void,
        hybrid_pipeline: if (mode == .hybrid) HybridPipelineType else void,

        /// Aggregated statistics.
        stats: AggregatedStats,

        /// Last tick result for getter-based access.
        /// Tiger Style: Always available - never null after first tick.
        last_tick_result: TickResult,

        // ====================================================================
        // Statistics
        // ====================================================================

        /// Aggregated pipeline statistics.
        pub const AggregatedStats = struct {
            /// Current pipeline mode.
            mode: PipelineMode = mode,
            /// Total entities submitted.
            entities_submitted: u64 = 0,
            /// Total ticks executed.
            ticks_executed: u64 = 0,

            // Mode-specific stats
            /// External mode: imported entities.
            external_imported: u64 = 0,
            /// External mode: exported entities.
            external_exported: u64 = 0,
            /// Hybrid mode: fast-path hits.
            hybrid_fast_path_hits: u64 = 0,
            /// Hybrid mode: fast-path misses.
            hybrid_fast_path_misses: u64 = 0,
        };

        /// Result of a single tick operation.
        /// Aggregates commit results and processing statistics.
        ///
        /// Tiger Style: No silent error swallowing - all failures are visible.
        pub const TickResult = struct {
            /// Whether the tick completed without catching errors.
            success: bool = true,

            // External mode results (from CommitResult)
            /// Number of entities successfully created (external mode).
            entities_created: u32 = 0,
            /// Number of entity spawn failures (external mode).
            spawn_failures: u32 = 0,
            /// Number of component set failures causing rollback (external mode).
            component_failures: u32 = 0,

            // Hybrid mode results
            /// Number of fast-path items processed this tick (hybrid mode).
            fast_path_processed: u32 = 0,

            /// Returns true if all operations succeeded with no failures.
            pub fn isComplete(self: TickResult) bool {
                return self.success and self.spawn_failures == 0 and self.component_failures == 0;
            }

            /// Returns total failure count across all operations.
            pub fn totalFailures(self: TickResult) u32 {
                return self.spawn_failures + self.component_failures;
            }
        };

        // ====================================================================
        // Errors
        // ====================================================================

        pub const Error = error{
            SubmitFailed,
            TickFailed,
            InvalidMode,
        } || Allocator.Error;

        // ====================================================================
        // Initialization
        // ====================================================================

        /// Initialize pipeline orchestrator for a world.
        pub fn init(world: *WorldType) Self {
            return .{
                .world = world,
                .external_pipeline = if (mode == .external)
                    ExternalPipelineType.init(world)
                else {},
                .hybrid_pipeline = if (mode == .hybrid)
                    HybridPipelineType.init(world)
                else {},
                .stats = .{},
                .last_tick_result = .{},
            };
        }

        // ====================================================================
        // Unified Submit API
        // ====================================================================

        /// Submit data for processing.
        /// Behavior depends on pipeline mode:
        /// - internal: Creates entity directly in world
        /// - external: Adds to import batch
        /// - hybrid: Routes via predicate (fast-path or ECS)
        pub fn submit(self: *Self, comptime T: type, data: T) Error!void {
            self.stats.entities_submitted += 1;

            switch (mode) {
                .internal => {
                    // Create entity directly
                    const entity = self.world.createEntity() catch return error.SubmitFailed;
                    self.world.setComponent(entity, data) catch return error.SubmitFailed;
                },
                .external => {
                    // Add to import batch
                    // Note: This requires T to be a struct with component fields
                    self.external_pipeline.addImport(data) catch return error.SubmitFailed;
                },
                .hybrid => {
                    // Route via hybrid pipeline
                    // Note: This uses a default callback for processing
                    const input = dataToInput(data);
                    self.hybrid_pipeline.process(input, defaultCallback) catch return error.SubmitFailed;
                },
            }
        }

        /// Submit multiple items in a batch.
        /// More efficient for external mode.
        pub fn submitBatch(self: *Self, comptime T: type, items: []const T) Error!void {
            for (items) |item| {
                try self.submit(T, item);
            }
        }

        // ====================================================================
        // Unified Tick API
        // ====================================================================

        /// Execute one tick of the pipeline.
        /// Behavior depends on pipeline mode:
        /// - internal: Just updates stats (ECS scheduler handles execution)
        /// - external: Commits import batch, captures all CommitResult data
        /// - hybrid: Processes fast-path queue, captures processed count
        ///
        /// Returns TickResult with all success/failure information.
        /// Tiger Style: No silent error swallowing - failures always visible.
        pub fn tick(self: *Self) Error!TickResult {
            self.stats.ticks_executed += 1;

            var result: TickResult = .{};

            switch (mode) {
                .internal => {
                    // Internal mode: ECS scheduler handles everything
                    // Nothing special to do here - result stays at defaults
                },
                .external => {
                    // External mode: Commit pending imports
                    // Tiger Style: commitImport cannot error (uses fail-fast internally)
                    const commit_result = self.external_pipeline.commitImport();

                    // Capture ALL CommitResult data - no silent loss
                    result.entities_created = commit_result.entities_created;
                    result.spawn_failures = commit_result.spawn_failures;
                    result.component_failures = commit_result.component_failures;
                    result.success = commit_result.isComplete();

                    // Update aggregated stats
                    self.stats.external_imported += commit_result.entities_created;

                    // Update external stats
                    const ext_stats = self.external_pipeline.getStats();
                    self.stats.external_exported = ext_stats.entities_exported;
                },
                .hybrid => {
                    // Hybrid mode: Process fast-path queue
                    // Capture processed count - no silent discard
                    const processed = self.hybrid_pipeline.tickFastPath();
                    result.fast_path_processed = processed;

                    // Update hybrid stats
                    const hyb_stats = self.hybrid_pipeline.getStats();
                    self.stats.hybrid_fast_path_hits = hyb_stats.fast_path_hits;
                    self.stats.hybrid_fast_path_misses = hyb_stats.fast_path_misses;
                },
            }

            // Store for getter-based access
            self.last_tick_result = result;

            return result;
        }

        /// Execute one tick with delta time for ECS system execution.
        ///
        /// ## API Design Note
        ///
        /// The `delta_time` parameter is accepted for API consistency with game loops
        /// and external schedulers that provide time deltas. Currently, the pipeline
        /// orchestrator delegates to mode-specific tick() which handles its own timing.
        ///
        /// **When delta_time becomes used:**
        /// - Scheduler integration will forward delta_time to FrameExecutor
        /// - Systems can access it via SystemContext.delta_time
        /// - Time-scaled updates (physics, animations) will use this value
        ///
        /// **Current behavior:** Parameter is validated but not forwarded until
        /// scheduler integration is complete. Use tick() for equivalent behavior.
        ///
        /// Returns TickResult from the underlying tick operation.
        pub fn tickWithDelta(self: *Self, delta_time: f64) Error!TickResult {
            // Tiger Style: Validate inputs - this also serves as documentation that
            // delta_time is intentionally accepted but not yet forwarded.
            // The assertion prevents invalid inputs and silences the "unused parameter" warning.
            std.debug.assert(!std.math.isNan(delta_time) and delta_time >= 0.0);

            // First handle mode-specific pre-tick
            const result = try self.tick();

            // TODO(scheduler-integration): Forward delta_time to FrameExecutor when
            // scheduler integration is implemented. This parameter exists for API
            // compatibility with game loops that provide frame timing.
            // See: scheduler_runtime.zig executeFrame() for delta_time usage pattern.

            return result;
        }

        // ====================================================================
        // Mode-Specific Access
        // ====================================================================

        /// Get external pipeline interface (only available in external mode).
        pub fn getExternalPipeline(self: *Self) if (mode == .external) *ExternalPipelineType else @TypeOf(null) {
            if (mode == .external) {
                return &self.external_pipeline;
            } else {
                return null;
            }
        }

        /// Get hybrid pipeline interface (only available in hybrid mode).
        pub fn getHybridPipeline(self: *Self) if (mode == .hybrid) *HybridPipelineType else @TypeOf(null) {
            if (mode == .hybrid) {
                return &self.hybrid_pipeline;
            } else {
                return null;
            }
        }

        // ====================================================================
        // Statistics
        // ====================================================================

        /// Get aggregated statistics.
        pub fn getStats(self: *const Self) AggregatedStats {
            return self.stats;
        }

        /// Get the result from the last tick operation.
        /// Useful for callers who don't capture the tick() return value.
        ///
        /// Tiger Style: Always available after first tick.
        pub fn getLastTickResult(self: *const Self) TickResult {
            return self.last_tick_result;
        }

        /// Reset all statistics.
        pub fn resetStats(self: *Self) void {
            self.stats = .{};

            switch (mode) {
                .internal => {},
                .external => self.external_pipeline.resetStats(),
                .hybrid => self.hybrid_pipeline.resetStats(),
            }
        }

        /// Get current pipeline mode.
        pub fn getMode(self: *const Self) PipelineMode {
            _ = self;
            return mode;
        }

        // ====================================================================
        // Utility Functions
        // ====================================================================

        /// Convert data to hybrid input format.
        fn dataToInput(data: anytype) HybridPipelineType.InputData {
            if (mode != .hybrid) {
                unreachable;
            }

            // Serialize data to input buffer
            var input: HybridPipelineType.InputData = .{};
            const bytes = std.mem.asBytes(&data);
            const copy_len = @min(bytes.len, input.data.len);
            @memcpy(input.data[0..copy_len], bytes[0..copy_len]);
            input.len = @intCast(copy_len);
            return input;
        }

        /// Default callback for hybrid mode processing.
        fn defaultCallback(input: *HybridPipelineType.InputData, output: *HybridPipelineType.OutputData) void {
            // Default implementation just copies input to output
            const copy_len = @min(input.len, @as(u32, @intCast(output.data.len)));
            @memcpy(output.data[0..copy_len], input.data[0..copy_len]);
            output.len = copy_len;
            output.status = 0;
        }
    };
}

// ============================================================================
// Pipeline Statistics
// ============================================================================

/// Statistics structure returned by orchestrator.
pub const PipelineStats = struct {
    mode: PipelineMode,
    entities_submitted: u64,
    ticks_executed: u64,
    external_imported: u64,
    external_exported: u64,
    hybrid_fast_path_hits: u64,
    hybrid_fast_path_misses: u64,
};

// ============================================================================
// Tests
// ============================================================================

test "PipelineOrchestrator internal mode stats" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .internal },
    };

    const Orchestrator = PipelineOrchestrator(test_config);

    // Test stats type
    const stats = Orchestrator.AggregatedStats{};
    try std.testing.expectEqual(PipelineMode.internal, stats.mode);
    try std.testing.expectEqual(@as(u64, 0), stats.entities_submitted);
    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
}

test "PipelineOrchestrator external mode type" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .external },
    };

    const Orchestrator = PipelineOrchestrator(test_config);

    // Verify mode in stats type
    const stats = Orchestrator.AggregatedStats{};
    try std.testing.expectEqual(PipelineMode.external, stats.mode);
}

test "PipelineOrchestrator hybrid mode type" {
    const AlwaysFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return true;
        }
    };

    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = AlwaysFastPath,
            },
        },
    };

    const Orchestrator = PipelineOrchestrator(test_config);

    // Verify mode in stats type
    const stats = Orchestrator.AggregatedStats{};
    try std.testing.expectEqual(PipelineMode.hybrid, stats.mode);
}

test "PipelineOrchestrator stats structure" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .internal },
    };

    const Orchestrator = PipelineOrchestrator(test_config);

    // Verify stats fields exist and have correct defaults
    var stats = Orchestrator.AggregatedStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.entities_submitted);
    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
    try std.testing.expectEqual(@as(u64, 0), stats.external_imported);
    try std.testing.expectEqual(@as(u64, 0), stats.external_exported);
    try std.testing.expectEqual(@as(u64, 0), stats.hybrid_fast_path_hits);
    try std.testing.expectEqual(@as(u64, 0), stats.hybrid_fast_path_misses);

    // Modify stats to ensure they're mutable
    stats.entities_submitted = 100;
    stats.ticks_executed = 50;
    try std.testing.expectEqual(@as(u64, 100), stats.entities_submitted);
    try std.testing.expectEqual(@as(u64, 50), stats.ticks_executed);
}

test "AggregatedStats defaults" {
    const Orchestrator = PipelineOrchestrator(WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
    });

    const stats = Orchestrator.AggregatedStats{};
    try std.testing.expectEqual(PipelineMode.internal, stats.mode);
    try std.testing.expectEqual(@as(u64, 0), stats.entities_submitted);
    try std.testing.expectEqual(@as(u64, 0), stats.ticks_executed);
    try std.testing.expectEqual(@as(u64, 0), stats.external_imported);
    try std.testing.expectEqual(@as(u64, 0), stats.hybrid_fast_path_hits);
}

test "TickResult defaults and helpers" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .internal },
    };

    const Orchestrator = PipelineOrchestrator(test_config);

    // Test default TickResult is successful and complete
    const result = Orchestrator.TickResult{};
    try std.testing.expect(result.success);
    try std.testing.expect(result.isComplete());
    try std.testing.expectEqual(@as(u32, 0), result.totalFailures());
    try std.testing.expectEqual(@as(u32, 0), result.entities_created);
    try std.testing.expectEqual(@as(u32, 0), result.spawn_failures);
    try std.testing.expectEqual(@as(u32, 0), result.component_failures);
    try std.testing.expectEqual(@as(u32, 0), result.fast_path_processed);
}

test "TickResult failure tracking" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .external },
    };

    const Orchestrator = PipelineOrchestrator(test_config);

    // Test TickResult with failures reports correctly
    var result = Orchestrator.TickResult{
        .success = true,
        .entities_created = 10,
        .spawn_failures = 2,
        .component_failures = 1,
    };

    // Should not be complete due to failures
    try std.testing.expect(!result.isComplete());
    try std.testing.expectEqual(@as(u32, 3), result.totalFailures());

    // Even with success=true, isComplete checks for zero failures
    try std.testing.expect(result.success);
    try std.testing.expect(!result.isComplete());

    // Reset to zero failures - now should be complete
    result.spawn_failures = 0;
    result.component_failures = 0;
    try std.testing.expect(result.isComplete());
    try std.testing.expectEqual(@as(u32, 0), result.totalFailures());
}

test "TickResult with success=false" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .internal },
    };

    const Orchestrator = PipelineOrchestrator(test_config);

    // Test that success=false alone makes isComplete return false
    const result = Orchestrator.TickResult{
        .success = false,
        .spawn_failures = 0,
        .component_failures = 0,
    };

    try std.testing.expect(!result.success);
    try std.testing.expect(!result.isComplete());
    try std.testing.expectEqual(@as(u32, 0), result.totalFailures());
}

test "getLastTickResult available after init" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .internal },
    };

    const WorldType = @import("../world.zig").World(test_config);
    const Orchestrator = PipelineOrchestrator(test_config);

    // Create a world to initialize orchestrator
    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var orchestrator = Orchestrator.init(&world);

    // getLastTickResult should be available immediately with defaults
    const last_result = orchestrator.getLastTickResult();
    try std.testing.expect(last_result.success);
    try std.testing.expect(last_result.isComplete());
}
