//! Hybrid Pipeline with Fast-Path Bypass
//!
//! Provides a hybrid processing model where simple entities can bypass
//! the full ECS pipeline for lower latency, while complex entities use
//! the standard ECS processing.
//!
//! ## Features
//!
//! - **Fast-Path Queue**: Direct processing for eligible entities
//! - **Predicate-Based Routing**: Comptime predicate determines eligibility
//! - **Automatic Fallback**: Falls back to ECS when fast-path is full
//! - **Statistics Tracking**: Monitor fast-path hit/miss rates
//!
//! Tiger Style: Predicate type is comptime for zero overhead when not matching.
//! Queue sizes are configurable via HybridPipelineConfig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const HybridPipelineConfig = config_mod.HybridPipelineConfig;

// ============================================================================
// Hybrid Pipeline Type Generator
// ============================================================================

/// Generate a HybridPipeline type for a specific WorldConfig.
///
/// The generated type provides:
/// - Fast-path queue for eligible entities
/// - Automatic routing based on predicate
/// - Fallback to ECS for complex entities
/// - Statistics tracking
///
/// Tiger Style: All sizes comptime-computed from config.
pub fn HybridPipeline(comptime cfg: WorldConfig) type {
    const WorldType = @import("../world.zig").World(cfg);
    const hybrid_cfg = cfg.pipeline.hybrid;
    const fast_path_capacity = hybrid_cfg.fast_path_capacity;
    const FastPathPredicate = hybrid_cfg.fast_path_predicate_type;

    return struct {
        const Self = @This();

        /// The world this pipeline is connected to.
        world: *WorldType,

        /// Fast-path queue for eligible entities.
        fast_path_queue: FastPathQueue,

        /// Statistics for monitoring.
        stats: Stats,

        // ====================================================================
        // Fast-Path Queue
        // ====================================================================

        /// Ring buffer queue for fast-path entities.
        pub const FastPathQueue = struct {
            /// Storage for fast-path items.
            items: [fast_path_capacity]FastPathItem = undefined,
            /// Head index (read position).
            head: u32 = 0,
            /// Tail index (write position).
            tail: u32 = 0,
            /// Number of items in queue.
            count: u32 = 0,

            /// Single fast-path item containing input and callback.
            pub const FastPathItem = struct {
                /// Input data for processing.
                input: InputData,
                /// Callback to invoke for processing.
                callback: *const fn (*InputData, *OutputData) void,
                /// Output data (filled by callback).
                output: OutputData,
                /// User context pointer (optional).
                user_ctx: ?*anyopaque = null,
            };

            /// Initialize empty queue.
            pub fn init() FastPathQueue {
                return .{};
            }

            /// Push item to queue.
            /// Returns false if queue is full.
            pub fn push(self: *FastPathQueue, item: FastPathItem) bool {
                if (self.count >= fast_path_capacity) {
                    return false; // Queue full
                }

                self.items[self.tail] = item;
                self.tail = (self.tail + 1) % fast_path_capacity;
                self.count += 1;
                return true;
            }

            /// Pop item from queue.
            /// Returns null if queue is empty.
            pub fn pop(self: *FastPathQueue) ?*FastPathItem {
                if (self.count == 0) {
                    return null; // Queue empty
                }

                const item = &self.items[self.head];
                self.head = (self.head + 1) % fast_path_capacity;
                self.count -= 1;
                return item;
            }

            /// Check if queue is empty.
            pub fn isEmpty(self: *const FastPathQueue) bool {
                return self.count == 0;
            }

            /// Check if queue is full.
            pub fn isFull(self: *const FastPathQueue) bool {
                return self.count >= fast_path_capacity;
            }

            /// Get current queue size.
            pub fn len(self: *const FastPathQueue) u32 {
                return self.count;
            }

            /// Get remaining capacity.
            pub fn remaining(self: *const FastPathQueue) u32 {
                return fast_path_capacity - self.count;
            }

            /// Clear all items from queue.
            pub fn clear(self: *FastPathQueue) void {
                self.head = 0;
                self.tail = 0;
                self.count = 0;
            }
        };

        // ====================================================================
        // Data Types
        // ====================================================================

        /// Input data type (can be customized via config).
        /// Default is a generic byte buffer.
        pub const InputData = struct {
            /// Raw data buffer.
            data: [256]u8 = undefined,
            /// Length of valid data.
            len: u32 = 0,
            /// User-defined flags.
            flags: u32 = 0,

            /// Initialize from slice.
            pub fn fromSlice(slice: []const u8) InputData {
                var input: InputData = .{};
                const copy_len = @min(slice.len, input.data.len);
                @memcpy(input.data[0..copy_len], slice[0..copy_len]);
                input.len = @intCast(copy_len);
                return input;
            }

            /// Get data as slice.
            pub fn asSlice(self: *const InputData) []const u8 {
                return self.data[0..self.len];
            }
        };

        /// Output data type (can be customized via config).
        pub const OutputData = struct {
            /// Raw data buffer.
            data: [256]u8 = undefined,
            /// Length of valid data.
            len: u32 = 0,
            /// Status code.
            status: i32 = 0,

            /// Initialize from slice.
            pub fn fromSlice(slice: []const u8) OutputData {
                var output: OutputData = .{};
                const copy_len = @min(slice.len, output.data.len);
                @memcpy(output.data[0..copy_len], slice[0..copy_len]);
                output.len = @intCast(copy_len);
                return output;
            }

            /// Get data as slice.
            pub fn asSlice(self: *const OutputData) []const u8 {
                return self.data[0..self.len];
            }
        };

        // ====================================================================
        // Statistics
        // ====================================================================

        /// Pipeline statistics for monitoring.
        pub const Stats = struct {
            /// Entities that used fast-path.
            fast_path_hits: u64 = 0,
            /// Entities that couldn't use fast-path (predicate returned false).
            fast_path_misses: u64 = 0,
            /// Entities that fell back to ECS due to full queue.
            fallback_count: u64 = 0,
            /// Total entities processed via ECS.
            ecs_processed: u64 = 0,
            /// Fast-path items processed.
            fast_path_processed: u64 = 0,
            /// ECS processing errors (spawn failures, etc.).
            ecs_errors: u64 = 0,
        };

        // ====================================================================
        // Errors
        // ====================================================================

        pub const Error = error{
            FastPathFull,
            EcsProcessingFailed,
            NoArchetypeConfigured,
        };

        // ====================================================================
        // Initialization
        // ====================================================================

        /// Initialize hybrid pipeline connected to a world.
        pub fn init(world: *WorldType) Self {
            return .{
                .world = world,
                .fast_path_queue = FastPathQueue.init(),
                .stats = .{},
            };
        }

        // ====================================================================
        // Processing API
        // ====================================================================

        /// Process input with automatic routing.
        /// Fast-path for eligible inputs, ECS for complex ones.
        ///
        /// Returns error.FastPathFull if fast-path queue is full and
        /// fallback_on_full is false.
        pub fn process(
            self: *Self,
            input: InputData,
            callback: *const fn (*InputData, *OutputData) void,
        ) Error!void {
            return self.processWithContext(input, callback, null);
        }

        /// Process input with user context pointer.
        pub fn processWithContext(
            self: *Self,
            input: InputData,
            callback: *const fn (*InputData, *OutputData) void,
            user_ctx: ?*anyopaque,
        ) Error!void {
            // Check if fast-path eligible
            if (FastPathPredicate.canFastPath(input)) {
                // Try fast-path
                const item: FastPathQueue.FastPathItem = .{
                    .input = input,
                    .callback = callback,
                    .output = .{},
                    .user_ctx = user_ctx,
                };

                if (self.fast_path_queue.push(item)) {
                    self.stats.fast_path_hits += 1;
                    return;
                }

                // Fast-path full, check fallback setting
                if (hybrid_cfg.fallback_on_full) {
                    self.stats.fallback_count += 1;
                    try self.processViaEcs(input);
                    return;
                }

                return error.FastPathFull;
            }

            // Not eligible, use ECS
            self.stats.fast_path_misses += 1;
            try self.processViaEcs(input);
        }

        /// Run fast-path processing.
        /// Call this each tick to process queued fast-path items.
        /// Returns number of items processed.
        pub fn tickFastPath(self: *Self) u32 {
            var processed: u32 = 0;

            while (self.fast_path_queue.pop()) |item| {
                // Direct execution, bypass ECS
                item.callback(&item.input, &item.output);
                processed += 1;
            }

            self.stats.fast_path_processed += processed;
            return processed;
        }

        /// Run fast-path processing with limit.
        /// Processes up to max_items from the queue.
        pub fn tickFastPathLimited(self: *Self, max_items: u32) u32 {
            var processed: u32 = 0;

            while (processed < max_items) {
                if (self.fast_path_queue.pop()) |item| {
                    item.callback(&item.input, &item.output);
                    processed += 1;
                } else {
                    break;
                }
            }

            self.stats.fast_path_processed += processed;
            return processed;
        }

        /// Process input via ECS pipeline.
        /// Creates an entity in the first configured archetype with default-initialized
        /// components. The input data is acknowledged but semantic mapping to specific
        /// component fields requires user-provided converters (future enhancement).
        ///
        /// Tiger Style: Fail-fast on errors, explicit bounds checking.
        fn processViaEcs(self: *Self, input: InputData) Error!void {
            // Tiger Style: Assert input invariants
            std.debug.assert(input.len <= input.data.len);

            // Compile-time check: require at least one archetype for fallback
            const archetype_count = cfg.archetypes.archetypes.len;
            if (archetype_count == 0) {
                // No archetypes configured - cannot create entities
                self.stats.ecs_errors += 1;
                return error.NoArchetypeConfigured;
            }

            // Use first archetype as fallback destination
            // Future: Make fallback archetype configurable via HybridPipelineConfig
            const fallback_arch = cfg.archetypes.archetypes[0];
            const FallbackComponents = @Tuple(fallback_arch.components);

            // Create default-initialized component values
            // Note: Components are zero-initialized; input bytes are acknowledged
            // but not copied to components (would require type-specific mapping)
            var components: FallbackComponents = undefined;
            inline for (0..fallback_arch.components.len) |i| {
                components[i] = std.mem.zeroes(fallback_arch.components[i]);
            }

            // Spawn entity with fallback archetype
            _ = self.world.spawn(fallback_arch.name, components) catch |err| {
                // Track failed spawn attempts
                self.stats.ecs_errors += 1;
                // Log error type for debugging
                if (cfg.options.enable_debug_asserts) {
                    std.debug.print("processViaEcs spawn failed: {}\n", .{err});
                }
                return error.EcsProcessingFailed;
            };

            // Input data acknowledged - entity created as proxy
            // The input.data bytes could be stored if we had a RawData component,
            // but that would require adding it to the archetype configuration
            // Input is used in assert above, no need for explicit discard
            self.stats.ecs_processed += 1;
        }

        // ====================================================================
        // Queue Management
        // ====================================================================

        /// Get current fast-path queue size.
        pub fn getQueueSize(self: *const Self) u32 {
            return self.fast_path_queue.len();
        }

        /// Get fast-path queue capacity.
        pub fn getQueueCapacity(self: *const Self) u32 {
            _ = self;
            return fast_path_capacity;
        }

        /// Check if fast-path queue is empty.
        pub fn isQueueEmpty(self: *const Self) bool {
            return self.fast_path_queue.isEmpty();
        }

        /// Check if fast-path queue is full.
        pub fn isQueueFull(self: *const Self) bool {
            return self.fast_path_queue.isFull();
        }

        /// Clear fast-path queue (drops pending items).
        pub fn clearQueue(self: *Self) void {
            self.fast_path_queue.clear();
        }

        // ====================================================================
        // Statistics
        // ====================================================================

        /// Get statistics snapshot.
        pub fn getStats(self: *const Self) Stats {
            return self.stats;
        }

        /// Reset statistics.
        pub fn resetStats(self: *Self) void {
            self.stats = .{};
        }

        /// Calculate fast-path hit rate (0.0 to 1.0).
        pub fn getHitRate(self: *const Self) f64 {
            const total = self.stats.fast_path_hits + self.stats.fast_path_misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.stats.fast_path_hits)) /
                @as(f64, @floatFromInt(total));
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "HybridPipeline stats type" {
    // Define a predicate that always allows fast-path
    const AlwaysFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return true;
        }
    };

    const TestComp = struct { x: i32 };
    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = AlwaysFastPath,
                .fast_path_capacity = 100,
            },
        },
    };

    const Pipeline = HybridPipeline(test_config);

    // Test stats defaults
    const stats = Pipeline.Stats{};
    try std.testing.expectEqual(@as(u64, 0), stats.fast_path_hits);
    try std.testing.expectEqual(@as(u64, 0), stats.fast_path_misses);
    try std.testing.expectEqual(@as(u64, 0), stats.fallback_count);
    try std.testing.expectEqual(@as(u64, 0), stats.ecs_processed);
    try std.testing.expectEqual(@as(u64, 0), stats.fast_path_processed);
}

test "HybridPipeline queue operations" {
    // Define a predicate that never allows fast-path
    const NeverFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return false;
        }
    };

    const TestComp = struct { x: i32 };
    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = NeverFastPath,
                .fast_path_capacity = 10,
            },
        },
    };

    const Pipeline = HybridPipeline(test_config);

    // Test queue type operations
    var queue = Pipeline.FastPathQueue.init();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(!queue.isFull());
    try std.testing.expectEqual(@as(u32, 0), queue.len());
    try std.testing.expectEqual(@as(u32, 10), queue.remaining());

    // Pop from empty returns null
    try std.testing.expect(queue.pop() == null);
}

test "HybridPipeline queue capacity" {
    const AlwaysFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return true;
        }
    };

    const TestComp = struct { x: i32 };
    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = AlwaysFastPath,
                .fast_path_capacity = 4, // Very small
                .fallback_on_full = false,
            },
        },
    };

    const Pipeline = HybridPipeline(test_config);

    // Test queue capacity
    var queue = Pipeline.FastPathQueue.init();
    try std.testing.expectEqual(@as(u32, 4), queue.remaining());
    try std.testing.expect(!queue.isFull());
}

test "HybridPipeline fallback config" {
    const AlwaysFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return true;
        }
    };

    const TestComp = struct { x: i32 };
    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = AlwaysFastPath,
                .fast_path_capacity = 2, // Very small
                .fallback_on_full = true, // Enable fallback
            },
        },
    };

    const Pipeline = HybridPipeline(test_config);

    // Test queue type
    var queue = Pipeline.FastPathQueue.init();
    try std.testing.expectEqual(@as(u32, 2), queue.remaining());
}

test "HybridPipeline hit rate calculation" {
    const AlwaysFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return true;
        }
    };

    const TestComp = struct { x: i32 };
    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{ .fast_path_predicate_type = AlwaysFastPath },
        },
    };

    const Pipeline = HybridPipeline(test_config);

    // Test hit rate calculation with manual stats
    var stats = Pipeline.Stats{};
    stats.fast_path_hits = 80;
    stats.fast_path_misses = 20;

    const total = stats.fast_path_hits + stats.fast_path_misses;
    const hit_rate = @as(f64, @floatFromInt(stats.fast_path_hits)) /
        @as(f64, @floatFromInt(total));
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), hit_rate, 0.001);
}

test "FastPathQueue operations" {
    const test_config = WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{ .fast_path_capacity = 4 },
        },
    };

    const Pipeline = HybridPipeline(test_config);
    var queue = Pipeline.FastPathQueue.init();

    // Initially empty
    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(!queue.isFull());
    try std.testing.expectEqual(@as(u32, 0), queue.len());
    try std.testing.expectEqual(@as(u32, 4), queue.remaining());

    // Pop from empty returns null
    try std.testing.expect(queue.pop() == null);

    // Push items
    const callback = struct {
        fn cb(input: *Pipeline.InputData, output: *Pipeline.OutputData) void {
            _ = input;
            output.status = 200;
        }
    }.cb;

    const item: Pipeline.FastPathQueue.FastPathItem = .{
        .input = .{},
        .callback = callback,
        .output = .{},
    };

    try std.testing.expect(queue.push(item));
    try std.testing.expect(!queue.isEmpty());
    try std.testing.expectEqual(@as(u32, 1), queue.len());

    // Fill queue
    try std.testing.expect(queue.push(item));
    try std.testing.expect(queue.push(item));
    try std.testing.expect(queue.push(item));
    try std.testing.expect(queue.isFull());
    try std.testing.expectEqual(@as(u32, 0), queue.remaining());

    // Push to full fails
    try std.testing.expect(!queue.push(item));

    // Pop all items
    try std.testing.expect(queue.pop() != null);
    try std.testing.expect(queue.pop() != null);
    try std.testing.expect(queue.pop() != null);
    try std.testing.expect(queue.pop() != null);
    try std.testing.expect(queue.isEmpty());

    // Clear
    _ = queue.push(item);
    queue.clear();
    try std.testing.expect(queue.isEmpty());
}

test "InputData and OutputData" {
    const Pipeline = HybridPipeline(WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
        .pipeline = .{ .mode = .hybrid },
    });

    // Test InputData
    const input = Pipeline.InputData.fromSlice("hello world");
    try std.testing.expectEqual(@as(u32, 11), input.len);
    try std.testing.expectEqualStrings("hello world", input.asSlice());

    // Test OutputData
    const output = Pipeline.OutputData.fromSlice("response");
    try std.testing.expectEqual(@as(u32, 8), output.len);
    try std.testing.expectEqualStrings("response", output.asSlice());
}

// ============================================================================
// Phase 2 Bug Fix Regression Test
// ============================================================================

test "HybridPipeline processViaEcs creates entity in world" {
    // Test that processViaEcs actually creates an entity when called.
    //
    // Verifies fix for P1-HYBRID where ECS fallback was non-functional.
    // Previously processViaEcs was just a stub that only counted entities
    // without actually creating them. Now it spawns real entities.

    // Define a predicate that never allows fast-path, forcing ECS fallback
    const NeverFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return false; // Force all processing through ECS
        }
    };

    const TestPosition = struct { x: f32, y: f32 };
    const TestVelocity = struct { dx: f32, dy: f32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{ TestPosition, TestVelocity } },
        .archetypes = .{
            .archetypes = &.{
                // First archetype is used as fallback destination
                .{ .name = "movable", .components = &.{ TestPosition, TestVelocity } },
            },
        },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = NeverFastPath,
                .fast_path_capacity = 10,
                .fallback_on_full = true,
            },
        },
        .options = .{
            .max_entities = 100,
            .enable_debug_asserts = false, // Disable debug prints in test
        },
    };

    const WorldType = @import("../world.zig").World(test_config);
    const Pipeline = HybridPipeline(test_config);

    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var pipeline = Pipeline.init(&world);

    // 1. Save initial entity count (should be 0)
    const initial_count = world.entityCount();
    try std.testing.expectEqual(@as(u32, 0), initial_count);

    // 2. Create InputData with some test bytes
    const input = Pipeline.InputData.fromSlice("test input data");

    // 3. Define a callback (won't be used since fast-path is disabled)
    const dummy_callback = struct {
        fn cb(in: *Pipeline.InputData, out: *Pipeline.OutputData) void {
            _ = in;
            out.status = 200;
        }
    }.cb;

    // 4. Process via the pipeline - should go to ECS since predicate returns false
    try pipeline.process(input, dummy_callback);

    // 5. Verify world entity count increased by 1
    try std.testing.expectEqual(@as(u32, 1), world.entityCount());

    // 6. Verify stats.ecs_processed incremented
    try std.testing.expectEqual(@as(u64, 1), pipeline.stats.ecs_processed);

    // 7. Verify fast_path_misses was also recorded (predicate returned false)
    try std.testing.expectEqual(@as(u64, 1), pipeline.stats.fast_path_misses);

    // 8. Verify no errors occurred
    try std.testing.expectEqual(@as(u64, 0), pipeline.stats.ecs_errors);

    // 9. Process another input - entity count should increase again
    try pipeline.process(input, dummy_callback);
    try std.testing.expectEqual(@as(u32, 2), world.entityCount());
    try std.testing.expectEqual(@as(u64, 2), pipeline.stats.ecs_processed);
}

test "HybridPipeline processViaEcs fallback when queue full" {
    // Test that when fast-path queue is full, entities fall back to ECS.
    //
    // This verifies the fix handles the fallback path correctly.

    // Define a predicate that always allows fast-path
    const AlwaysFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return true; // Allow fast-path
        }
    };

    const TestComp = struct { x: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = AlwaysFastPath,
                .fast_path_capacity = 2, // Very small capacity
                .fallback_on_full = true, // Enable fallback
            },
        },
        .options = .{
            .max_entities = 100,
            .enable_debug_asserts = false,
        },
    };

    const WorldType = @import("../world.zig").World(test_config);
    const Pipeline = HybridPipeline(test_config);

    var world = WorldType.init(std.testing.allocator);
    defer world.deinit();

    var pipeline = Pipeline.init(&world);

    const input = Pipeline.InputData.fromSlice("test");
    const dummy_callback = struct {
        fn cb(in: *Pipeline.InputData, out: *Pipeline.OutputData) void {
            _ = in;
            out.status = 200;
        }
    }.cb;

    // Fill fast-path queue (capacity = 2)
    try pipeline.process(input, dummy_callback);
    try pipeline.process(input, dummy_callback);

    // Queue should now be full
    try std.testing.expect(pipeline.isQueueFull());
    try std.testing.expectEqual(@as(u64, 2), pipeline.stats.fast_path_hits);
    try std.testing.expectEqual(@as(u32, 0), world.entityCount()); // No ECS entities yet

    // Next process should fall back to ECS
    try pipeline.process(input, dummy_callback);

    // Verify fallback occurred
    try std.testing.expectEqual(@as(u64, 1), pipeline.stats.fallback_count);
    try std.testing.expectEqual(@as(u64, 1), pipeline.stats.ecs_processed);
    try std.testing.expectEqual(@as(u32, 1), world.entityCount()); // One ECS entity created
}
