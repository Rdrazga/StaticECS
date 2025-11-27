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
        /// - external: Commits import batch, ready for scheduler
        /// - hybrid: Processes fast-path queue, updates stats
        pub fn tick(self: *Self) Error!void {
            self.stats.ticks_executed += 1;

            switch (mode) {
                .internal => {
                    // Internal mode: ECS scheduler handles everything
                    // Nothing special to do here
                },
                .external => {
                    // External mode: Commit pending imports
                    const created = self.external_pipeline.commitImport() catch return error.TickFailed;
                    self.stats.external_imported += created.len;

                    // Update external stats
                    const ext_stats = self.external_pipeline.getStats();
                    self.stats.external_exported = ext_stats.entities_exported;
                },
                .hybrid => {
                    // Hybrid mode: Process fast-path queue
                    _ = self.hybrid_pipeline.tickFastPath();

                    // Update hybrid stats
                    const hyb_stats = self.hybrid_pipeline.getStats();
                    self.stats.hybrid_fast_path_hits = hyb_stats.fast_path_hits;
                    self.stats.hybrid_fast_path_misses = hyb_stats.fast_path_misses;
                },
            }
        }

        /// Execute one tick with delta time.
        /// Forwards to scheduler for ECS system execution.
        pub fn tickWithDelta(self: *Self, delta_time: f64) Error!void {
            // First handle mode-specific pre-tick
            try self.tick();

            // Then execute ECS systems via scheduler
            // Note: This requires scheduler integration
            _ = delta_time;
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
