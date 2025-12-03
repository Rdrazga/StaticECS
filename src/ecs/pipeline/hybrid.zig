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

        /// Thread-safe ring buffer queue for fast-path entities.
        ///
        /// ## Why Hybrid-Only (Architecture Decision)
        ///
        /// This SPSC queue is intentionally scoped to the hybrid pipeline and is NOT
        /// exposed as a general-purpose data structure. Reasons:
        ///
        /// 1. **Tight Coupling**: The queue's semantics (FastPathItem, InputData, OutputData)
        ///    are specifically designed for the hybrid pipeline's fast-path bypass pattern.
        ///
        /// 2. **Existing Alternatives**: For general SPSC/MPSC needs:
        ///    - `coordination/lock_free_queue.zig` - MPSC lock-free queue for multi-world
        ///    - `std.fifo` - Standard library bounded FIFO
        ///
        /// 3. **Simplicity**: Hybrid-specific allows optimizations (e.g., fixed item types)
        ///    that wouldn't apply to a generic queue.
        ///
        /// If you need a general-purpose SPSC queue, consider using `std.fifo` or
        /// implementing one in a shared `utils/` module with generic types.
        ///
        /// ## Thread Safety Model: SPSC (Single-Producer Single-Consumer)
        ///
        /// This queue is designed for scenarios where exactly ONE thread
        /// produces (calls `push`) and exactly ONE thread consumes (calls `pop`).
        /// This is the common pattern for fast-path processing where:
        /// - Main/request thread pushes items to the queue
        /// - Worker/processing thread pops and processes items
        ///
        /// ### Atomic Operations:
        /// - `head`: Modified only by consumer via `pop()`, read by producer
        /// - `tail`: Modified only by producer via `push()`, read by consumer
        /// - `count`: Derived atomically from head and tail positions
        ///
        /// ### Memory Ordering:
        /// - Release semantics on writes ensure data visibility before index update
        /// - Acquire semantics on reads ensure seeing the latest data after index read
        ///
        /// ### NOT Safe For:
        /// - Multiple producers (MPSC) - use lock-free queue from coordination module
        /// - Multiple consumers (SPMC/MPMC) - requires additional synchronization
        ///
        /// Tiger Style: Fixed capacity, no dynamic allocation, bounded queue.
        pub const FastPathQueue = struct {
            /// Storage for fast-path items.
            items: [fast_path_capacity]FastPathItem = undefined,
            /// Head index (read position) - modified only by consumer.
            head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
            /// Tail index (write position) - modified only by producer.
            tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

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

            /// Push item to queue (producer-side operation).
            ///
            /// Thread Safety: Only ONE thread should call push() concurrently.
            /// Uses acquire-release ordering to ensure item data is visible
            /// to consumer after tail update.
            ///
            /// Returns false if queue is full.
            pub fn push(self: *FastPathQueue, item: FastPathItem) bool {
                const current_tail = self.tail.load(.acquire);
                const current_head = self.head.load(.acquire);

                // Calculate count from head/tail positions (handles wrap-around)
                const count = current_tail -% current_head;
                if (count >= fast_path_capacity) {
                    return false; // Queue full
                }

                // Write item at current tail position
                self.items[current_tail % fast_path_capacity] = item;

                // Release store ensures item write is visible before tail update
                self.tail.store(current_tail +% 1, .release);
                return true;
            }

            /// Pop item from queue (consumer-side operation).
            ///
            /// Thread Safety: Only ONE thread should call pop() concurrently.
            /// Uses acquire-release ordering to ensure item data is read
            /// before head update signals availability for reuse.
            ///
            /// Returns null if queue is empty.
            pub fn pop(self: *FastPathQueue) ?*FastPathItem {
                const current_head = self.head.load(.acquire);
                const current_tail = self.tail.load(.acquire);

                // Calculate count from head/tail positions (handles wrap-around)
                const count = current_tail -% current_head;
                if (count == 0) {
                    return null; // Queue empty
                }

                // Get item pointer at current head position
                const item = &self.items[current_head % fast_path_capacity];

                // Release store ensures item read completes before head update
                self.head.store(current_head +% 1, .release);
                return item;
            }

            /// Check if queue is empty.
            /// Thread-safe read using atomic loads.
            pub fn isEmpty(self: *const FastPathQueue) bool {
                const current_tail = self.tail.load(.acquire);
                const current_head = self.head.load(.acquire);
                return current_tail == current_head;
            }

            /// Check if queue is full.
            /// Thread-safe read using atomic loads.
            pub fn isFull(self: *const FastPathQueue) bool {
                const current_tail = self.tail.load(.acquire);
                const current_head = self.head.load(.acquire);
                const count = current_tail -% current_head;
                return count >= fast_path_capacity;
            }

            /// Get current queue size.
            /// Thread-safe read using atomic loads.
            pub fn len(self: *const FastPathQueue) u32 {
                const current_tail = self.tail.load(.acquire);
                const current_head = self.head.load(.acquire);
                return current_tail -% current_head;
            }

            /// Get remaining capacity.
            /// Thread-safe read using atomic loads.
            pub fn remaining(self: *const FastPathQueue) u32 {
                return fast_path_capacity - self.len();
            }

            /// Clear all items from queue.
            ///
            /// WARNING: NOT thread-safe! Only call when no other threads
            /// are accessing the queue (e.g., during initialization or shutdown).
            pub fn clear(self: *FastPathQueue) void {
                self.head.store(0, .release);
                self.tail.store(0, .release);
            }
        };

        // ====================================================================
        // Data Types
        // ====================================================================

        /// Configurable buffer sizes from HybridPipelineConfig.
        /// Tiger Style: Comptime-computed sizes for zero runtime overhead.
        const input_buffer_size = hybrid_cfg.input_buffer_size;
        const output_buffer_size = hybrid_cfg.output_buffer_size;

        /// Input data type (can be customized via config).
        /// Buffer size is configurable via HybridPipelineConfig.input_buffer_size.
        /// Default 256 bytes maintains backward compatibility.
        pub const InputData = struct {
            /// Raw data buffer (size configurable via config).
            data: [input_buffer_size]u8 = undefined,
            /// Length of valid data.
            len: u32 = 0,
            /// User-defined flags.
            flags: u32 = 0,

            /// Get the configured buffer capacity.
            pub fn capacity() u32 {
                return input_buffer_size;
            }

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
        /// Buffer size is configurable via HybridPipelineConfig.output_buffer_size.
        /// Default 256 bytes maintains backward compatibility.
        pub const OutputData = struct {
            /// Raw data buffer (size configurable via config).
            data: [output_buffer_size]u8 = undefined,
            /// Length of valid data.
            len: u32 = 0,
            /// Status code.
            status: i32 = 0,

            /// Get the configured buffer capacity.
            pub fn capacity() u32 {
                return output_buffer_size;
            }

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
        /// Creates an entity in the first configured archetype with components
        /// initialized via the configured InputDataMapper.
        ///
        /// The mapper determines how input data maps to component values:
        /// - DefaultInputDataMapper: Zero-initializes all components (backward compatible)
        /// - RawInputDataMapper: Stores input bytes in RawInputData component if present
        /// - Custom mappers: User-defined mapping logic
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

            // Use configured mapper to convert input data to components
            // This fixes P-M3: Input data now mapped to components instead of zero-initialization
            const InputMapper = hybrid_cfg.input_data_mapper_type;
            const components = InputMapper.mapInputToComponents(fallback_arch.components, input);

            // Spawn entity with mapped component values
            _ = self.world.spawn(fallback_arch.name, components) catch |err| {
                // Track failed spawn attempts
                self.stats.ecs_errors += 1;
                // Log error type for debugging
                if (cfg.options.enable_debug_asserts) {
                    std.debug.print("processViaEcs spawn failed: {}\n", .{err});
                }
                return error.EcsProcessingFailed;
            };

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

test "InputData configurable buffer size" {
    // Test P-M4: InputData buffer size is configurable via config.
    // Verifies that different buffer sizes work correctly.

    // Test 1: Small buffer (64 bytes)
    {
        const SmallPipeline = HybridPipeline(WorldConfig{
            .components = .{ .types = &.{struct { x: i32 }} },
            .archetypes = .{ .archetypes = &.{} },
            .pipeline = .{
                .mode = .hybrid,
                .hybrid = .{
                    .input_buffer_size = 64,
                    .output_buffer_size = 64,
                },
            },
        });

        // Verify capacity reports configured size
        try std.testing.expectEqual(@as(u32, 64), SmallPipeline.InputData.capacity());
        try std.testing.expectEqual(@as(u32, 64), SmallPipeline.OutputData.capacity());

        // Test data fits within small buffer
        const input = SmallPipeline.InputData.fromSlice("short data");
        try std.testing.expectEqual(@as(u32, 10), input.len);
        try std.testing.expectEqualStrings("short data", input.asSlice());
    }

    // Test 2: Large buffer (1024 bytes)
    {
        const LargePipeline = HybridPipeline(WorldConfig{
            .components = .{ .types = &.{struct { x: i32 }} },
            .archetypes = .{ .archetypes = &.{} },
            .pipeline = .{
                .mode = .hybrid,
                .hybrid = .{
                    .input_buffer_size = 1024,
                    .output_buffer_size = 512,
                },
            },
        });

        // Verify capacity reports configured size
        try std.testing.expectEqual(@as(u32, 1024), LargePipeline.InputData.capacity());
        try std.testing.expectEqual(@as(u32, 512), LargePipeline.OutputData.capacity());

        // Test large data fits in large buffer
        var large_data: [500]u8 = undefined;
        @memset(&large_data, 'X');
        const input = LargePipeline.InputData.fromSlice(&large_data);
        try std.testing.expectEqual(@as(u32, 500), input.len);
    }

    // Test 3: Default buffer (256 bytes - backward compatible)
    {
        const DefaultPipeline = HybridPipeline(WorldConfig{
            .components = .{ .types = &.{struct { x: i32 }} },
            .archetypes = .{ .archetypes = &.{} },
            .pipeline = .{ .mode = .hybrid },
        });

        // Verify default maintains backward compatibility
        try std.testing.expectEqual(@as(u32, 256), DefaultPipeline.InputData.capacity());
        try std.testing.expectEqual(@as(u32, 256), DefaultPipeline.OutputData.capacity());
    }

    // Test 4: Truncation with small buffer
    {
        const TinyPipeline = HybridPipeline(WorldConfig{
            .components = .{ .types = &.{struct { x: i32 }} },
            .archetypes = .{ .archetypes = &.{} },
            .pipeline = .{
                .mode = .hybrid,
                .hybrid = .{
                    .input_buffer_size = 8,
                    .output_buffer_size = 8,
                },
            },
        });

        // Data exceeding buffer should be truncated
        const input = TinyPipeline.InputData.fromSlice("this is way too long for the buffer");
        try std.testing.expectEqual(@as(u32, 8), input.len);
        try std.testing.expectEqualStrings("this is ", input.asSlice());
    }
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

// ============================================================================
// P-M3 Fix Tests: Input Data Mapping in ECS Fallback
// ============================================================================

const query_mod = @import("../world/query.zig");
const QuerySpec = query_mod.QuerySpec;

test "HybridPipeline RawInputDataMapper preserves input data" {
    // Test P-M3 fix: Input data is properly mapped to components during ECS fallback.
    //
    // Previously, processViaEcs zero-initialized all components, losing input data.
    // Now, with RawInputDataMapper, input bytes are preserved in RawInputData component.

    const RawInputData = config_mod.RawInputData;
    const RawInputDataMapper = config_mod.RawInputDataMapper;

    // Predicate that forces ECS fallback for all inputs
    const NeverFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return false;
        }
    };

    const test_config = WorldConfig{
        .components = .{ .types = &.{RawInputData} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "raw_entity", .components = &.{RawInputData} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = NeverFastPath,
                .fast_path_capacity = 10,
                .fallback_on_full = true,
                .input_data_mapper_type = RawInputDataMapper, // Use mapper that preserves input
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

    // Create input with known data
    var input = Pipeline.InputData.fromSlice("Hello, ECS Fallback!");
    input.flags = 42;

    const dummy_callback = struct {
        fn cb(in: *Pipeline.InputData, out: *Pipeline.OutputData) void {
            _ = in;
            out.status = 200;
        }
    }.cb;

    // Process - should go through ECS fallback with data mapping
    try pipeline.process(input, dummy_callback);

    // Verify entity was created
    try std.testing.expectEqual(@as(u32, 1), world.entityCount());
    try std.testing.expectEqual(@as(u64, 1), pipeline.stats.ecs_processed);

    // Query to verify the RawInputData component has the correct data
    const RawQuery = QuerySpec(&.{RawInputData}, &.{}, &.{}, &.{});
    var query = world.query(RawQuery);

    var found = false;
    while (query.next()) |result| {
        found = true;
        const raw = result.getRead(RawInputData);
        // Verify data was preserved
        try std.testing.expectEqual(@as(u32, 20), raw.len); // "Hello, ECS Fallback!".len == 20
        try std.testing.expectEqual(@as(u32, 42), raw.flags);
        try std.testing.expectEqualStrings("Hello, ECS Fallback!", raw.data[0..raw.len]);
    }

    try std.testing.expect(found);
}

test "HybridPipeline DefaultInputDataMapper zero-initializes (backward compatible)" {
    // Test that DefaultInputDataMapper maintains backward compatibility by zero-initializing.
    //
    // This ensures existing code that doesn't configure a mapper continues to work.

    const NeverFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return false;
        }
    };

    const TestPosition = struct { x: f32 = 999.0, y: f32 = 999.0 }; // Non-zero defaults

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestPosition} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "positioned", .components = &.{TestPosition} },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = NeverFastPath,
                // No input_data_mapper_type specified - uses default
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

    const input = Pipeline.InputData.fromSlice("some data");
    const dummy_callback = struct {
        fn cb(in: *Pipeline.InputData, out: *Pipeline.OutputData) void {
            _ = in;
            out.status = 200;
        }
    }.cb;

    try pipeline.process(input, dummy_callback);

    // Verify entity created
    try std.testing.expectEqual(@as(u32, 1), world.entityCount());

    // Query to verify TestPosition was zero-initialized (not using struct defaults)
    const PosQuery = QuerySpec(&.{TestPosition}, &.{}, &.{}, &.{});
    var query = world.query(PosQuery);

    var found = false;
    while (query.next()) |result| {
        found = true;
        const pos = result.getRead(TestPosition);
        // Default mapper zero-initializes, so x and y should be 0, not 999
        try std.testing.expectEqual(@as(f32, 0.0), pos.x);
        try std.testing.expectEqual(@as(f32, 0.0), pos.y);
    }

    try std.testing.expect(found);
}

test "HybridPipeline custom InputDataMapper maps input fields" {
    // Test that users can provide custom mappers to map input data to specific components.
    //
    // This demonstrates the P-M3 fix extensibility: users define how input maps to components.

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    // Custom mapper that extracts position from input flags
    const CustomPositionMapper = struct {
        pub fn mapInputToComponents(comptime ComponentTypes: []const type, input: anytype) Tuple(ComponentTypes) {
            var result: Tuple(ComponentTypes) = undefined;
            inline for (0..ComponentTypes.len) |i| {
                const CompType = ComponentTypes[i];
                if (CompType == Position) {
                    // Extract x,y from input flags (high/low bytes for demo)
                    const flags = input.flags;
                    result[i] = Position{
                        .x = @floatFromInt((flags >> 16) & 0xFFFF),
                        .y = @floatFromInt(flags & 0xFFFF),
                    };
                } else {
                    result[i] = std.mem.zeroes(CompType);
                }
            }
            return result;
        }

        fn Tuple(comptime types: []const type) type {
            return std.meta.Tuple(types);
        }
    };

    const NeverFastPath = struct {
        pub fn canFastPath(input: anytype) bool {
            _ = input;
            return false;
        }
    };

    const test_config = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "movable", .components = &.{ Position, Velocity } },
        } },
        .pipeline = .{
            .mode = .hybrid,
            .hybrid = .{
                .fast_path_predicate_type = NeverFastPath,
                .input_data_mapper_type = CustomPositionMapper,
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

    // Create input with encoded position in flags: x=100, y=200
    var input = Pipeline.InputData{};
    input.flags = (100 << 16) | 200;

    const dummy_callback = struct {
        fn cb(in: *Pipeline.InputData, out: *Pipeline.OutputData) void {
            _ = in;
            out.status = 200;
        }
    }.cb;

    try pipeline.process(input, dummy_callback);

    // Verify entity created with mapped position
    try std.testing.expectEqual(@as(u32, 1), world.entityCount());

    const MoveQuery = QuerySpec(&.{ Position, Velocity }, &.{}, &.{}, &.{});
    var query = world.query(MoveQuery);

    var found = false;
    while (query.next()) |result| {
        found = true;
        const pos = result.getRead(Position);
        const vel = result.getRead(Velocity);
        // Custom mapper extracted position from flags
        try std.testing.expectEqual(@as(f32, 100.0), pos.x);
        try std.testing.expectEqual(@as(f32, 200.0), pos.y);
        // Velocity was zero-initialized
        try std.testing.expectEqual(@as(f32, 0.0), vel.dx);
        try std.testing.expectEqual(@as(f32, 0.0), vel.dy);
    }

    try std.testing.expect(found);
}
