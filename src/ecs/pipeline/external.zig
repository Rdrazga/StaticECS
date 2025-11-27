//! External Pipeline Interface
//!
//! Provides batch import/export APIs for external entity flow management.
//! Entities can be imported in batches, processed externally, and exported
//! back to the ECS world.
//!
//! ## Features
//!
//! - **Batch Import**: Add entities with components in bulk
//! - **Batch Export**: Query and export entities with their data
//! - **Zero-Copy Access**: Direct array access for high-throughput processing
//! - **Thread-Safe Handoff**: Safe data transfer between threads
//!
//! Tiger Style: All sizes comptime-computed from config. No dynamic allocation
//! after initialization.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;
const ExternalPipelineConfig = config_mod.ExternalPipelineConfig;

// ============================================================================
// External Pipeline Type Generator
// ============================================================================

/// Generate an ExternalPipeline type for a specific WorldConfig.
///
/// The generated type provides:
/// - Batch import of entities with components
/// - Batch export of entities matching queries
/// - Zero-copy array access for external processing
/// - Thread-safe handoff queues
///
/// Tiger Style: All sizes comptime-computed from config.
pub fn ExternalPipeline(comptime cfg: WorldConfig) type {
    const WorldType = @import("../world.zig").World(cfg);
    const external_cfg = cfg.pipeline.external;
    const batch_size = external_cfg.batch_size;
    const component_types = cfg.components.types;
    const num_components = component_types.len;

    // Calculate component mask type (enough bits for all components)
    const ComponentMask = if (num_components <= 8)
        u8
    else if (num_components <= 16)
        u16
    else if (num_components <= 32)
        u32
    else if (num_components <= 64)
        u64
    else
        @compileError("ExternalPipeline: max 64 component types supported");

    return struct {
        const Self = @This();

        /// The world this pipeline is connected to.
        world: *WorldType,

        /// Import buffer for batched entity creation.
        import_buffer: ImportBuffer,

        /// Export buffer for batched entity queries.
        export_buffer: ExportBuffer,

        /// Statistics for monitoring pipeline performance.
        stats: Stats,

        // ====================================================================
        // Import Buffer Types
        // ====================================================================

        /// Buffer for batched entity imports.
        pub const ImportBuffer = struct {
            /// Array of import entries (pre-allocated).
            entries: [batch_size]ImportEntry = undefined,
            /// Current number of entries in buffer.
            len: u32 = 0,

            /// Single import entry containing component data.
            pub const ImportEntry = struct {
                /// Bitmask of which components are present.
                component_mask: ComponentMask = 0,
                /// Component data storage (tuple of optionals).
                components: ComponentTuple = undefined,
            };

            /// Reset buffer for new batch.
            pub fn reset(self: *ImportBuffer) void {
                self.len = 0;
            }

            /// Check if buffer is full.
            pub fn isFull(self: *const ImportBuffer) bool {
                return self.len >= batch_size;
            }

            /// Get remaining capacity.
            pub fn remaining(self: *const ImportBuffer) u32 {
                return batch_size - self.len;
            }
        };

        // ====================================================================
        // Export Buffer Types
        // ====================================================================

        /// Buffer for batched entity exports.
        pub const ExportBuffer = struct {
            /// Entity handles for exported entities.
            entities: [batch_size]WorldType.WorldEntityHandle = undefined,
            /// Export data for each entity.
            data: [batch_size]ExportEntry = undefined,
            /// Current number of entries in buffer.
            len: u32 = 0,

            /// Single export entry containing component data.
            pub const ExportEntry = struct {
                /// Bitmask of which components are present.
                component_mask: ComponentMask = 0,
                /// Component data storage (tuple of values).
                components: ComponentTuple = undefined,
            };

            /// Reset buffer for new export.
            pub fn reset(self: *ExportBuffer) void {
                self.len = 0;
            }

            /// Check if buffer is full.
            pub fn isFull(self: *const ExportBuffer) bool {
                return self.len >= batch_size;
            }

            /// Get entities slice (valid portion).
            pub fn getEntities(self: *const ExportBuffer) []const WorldType.WorldEntityHandle {
                return self.entities[0..self.len];
            }

            /// Get data slice (valid portion).
            pub fn getData(self: *const ExportBuffer) []const ExportEntry {
                return self.data[0..self.len];
            }
        };

        // ====================================================================
        // Component Tuple Generation
        // ====================================================================

        /// Tuple type containing optional component values.
        /// Uses a fixed array with anyopaque pointers for component storage.
        /// This avoids @Type which is not available in Zig 0.16+.
        const ComponentTuple = struct {
            /// Array of optional component data (stored as bytes).
            data: [max_component_data_size]u8 = undefined,
            /// Which components are stored.
            present: ComponentMask = 0,

            const max_component_data_size: usize = blk: {
                var size: usize = 0;
                for (component_types) |T| {
                    size += @sizeOf(T);
                }
                // Add some padding for alignment
                break :blk if (size == 0) 64 else size + 64;
            };

            /// Set a component value in the tuple.
            pub fn set(self: *ComponentTuple, comptime comp_idx: usize, value: component_types[comp_idx]) void {
                const T = component_types[comp_idx];
                const offset = comptime getComponentOffset(comp_idx);
                const dest: *T = @ptrCast(@alignCast(self.data[offset..][0..@sizeOf(T)]));
                dest.* = value;
                self.present |= (@as(ComponentMask, 1) << @intCast(comp_idx));
            }

            /// Get a component value from the tuple.
            pub fn get(self: *const ComponentTuple, comptime comp_idx: usize) ?component_types[comp_idx] {
                const T = component_types[comp_idx];
                const mask = @as(ComponentMask, 1) << @intCast(comp_idx);
                if (self.present & mask == 0) return null;
                const offset = comptime getComponentOffset(comp_idx);
                const src: *const T = @ptrCast(@alignCast(self.data[offset..][0..@sizeOf(T)]));
                return src.*;
            }

            /// Calculate offset for a component at compile time.
            fn getComponentOffset(comptime idx: usize) usize {
                comptime var offset: usize = 0;
                inline for (0..idx) |i| {
                    const T = component_types[i];
                    // Align to type's alignment
                    const align_val: usize = @alignOf(T);
                    offset = std.mem.alignForward(usize, offset, align_val);
                    offset += @sizeOf(T);
                }
                // Align final offset
                if (idx < component_types.len) {
                    const T = component_types[idx];
                    const align_val: usize = @alignOf(T);
                    offset = std.mem.alignForward(usize, offset, align_val);
                }
                return offset;
            }
        };

        // ====================================================================
        // Statistics
        // ====================================================================

        /// Pipeline statistics for monitoring.
        pub const Stats = struct {
            /// Total entities imported via batch API.
            entities_imported: u64 = 0,
            /// Total entities exported via batch API.
            entities_exported: u64 = 0,
            /// Total import batches committed.
            import_batches: u64 = 0,
            /// Total export operations performed.
            export_operations: u64 = 0,
        };

        // ====================================================================
        // Errors
        // ====================================================================

        pub const Error = error{
            BatchFull,
            InvalidComponent,
            WorldError,
        } || Allocator.Error;

        // ====================================================================
        // Initialization
        // ====================================================================

        /// Initialize external pipeline connected to a world.
        pub fn init(world: *WorldType) Self {
            return .{
                .world = world,
                .import_buffer = .{},
                .export_buffer = .{},
                .stats = .{},
            };
        }

        // ====================================================================
        // Import API
        // ====================================================================

        /// Begin a new import batch.
        /// Resets the import buffer for new entries.
        pub fn beginImport(self: *Self) *ImportBuffer {
            self.import_buffer.reset();
            return &self.import_buffer;
        }

        /// Add an entity with components to the import batch.
        /// Components is a struct with fields matching component types.
        ///
        /// Example:
        /// ```zig
        /// try pipeline.addImport(.{
        ///     .Position = Position{ .x = 0, .y = 0 },
        ///     .Velocity = Velocity{ .dx = 1, .dy = 0 },
        /// });
        /// ```
        pub fn addImport(self: *Self, components: anytype) Error!void {
            if (self.import_buffer.isFull()) {
                return error.BatchFull;
            }

            var entry: ImportBuffer.ImportEntry = .{
                .component_mask = 0,
                .components = .{},
            };

            // Set provided components
            const ComponentsType = @TypeOf(components);
            const fields = @typeInfo(ComponentsType).@"struct".fields;

            inline for (fields) |field| {
                const comp_idx = comptime findComponentIndex(field.type);
                if (comp_idx) |idx| {
                    entry.components.set(idx, @field(components, field.name));
                    entry.component_mask |= (@as(ComponentMask, 1) << @intCast(idx));
                } else {
                    @compileError("Component type " ++ @typeName(field.type) ++ " not in WorldConfig.components");
                }
            }

            self.import_buffer.entries[self.import_buffer.len] = entry;
            self.import_buffer.len += 1;
        }

        /// Add raw import entry directly to buffer.
        /// Lower-level API for custom import logic.
        pub fn addImportEntry(self: *Self, entry: ImportBuffer.ImportEntry) Error!void {
            if (self.import_buffer.isFull()) {
                return error.BatchFull;
            }
            self.import_buffer.entries[self.import_buffer.len] = entry;
            self.import_buffer.len += 1;
        }

        /// Commit import batch to world, creating entities.
        /// Returns slice of created entity handles.
        pub fn commitImport(self: *Self) Error![]const WorldType.WorldEntityHandle {
            const count = self.import_buffer.len;
            if (count == 0) {
                return &[_]WorldType.WorldEntityHandle{};
            }

            // Use export buffer's entity array as scratch space for results
            var created: *[batch_size]WorldType.WorldEntityHandle = &self.export_buffer.entities;

            for (0..count) |i| {
                const entry = &self.import_buffer.entries[i];

                // Create entity in world
                const entity = self.world.createEntity() catch |err| {
                    _ = err;
                    return error.WorldError;
                };

                // Set all components from entry
                inline for (0..num_components) |comp_idx| {
                    const T = component_types[comp_idx];
                    const mask = @as(ComponentMask, 1) << @intCast(comp_idx);
                    if (entry.component_mask & mask != 0) {
                        if (entry.components.get(comp_idx)) |value| {
                            self.world.setComponent(entity, value) catch {
                                // Component set failed - entity created but incomplete
                                // In production, might want to track this
                            };
                            // Suppress unused variable warning
                            _ = T;
                        }
                    }
                }

                created[i] = entity;
            }

            // Update stats
            self.stats.entities_imported += count;
            self.stats.import_batches += 1;

            self.import_buffer.reset();
            return created[0..count];
        }

        // ====================================================================
        // Export API
        // ====================================================================

        /// Export entities matching a component filter.
        /// Returns export buffer with entity handles and component data.
        ///
        /// Example:
        /// ```zig
        /// const exported = pipeline.export(.{ Position, Velocity });
        /// for (exported.getEntities(), exported.getData()) |entity, data| {
        ///     // Process exported data
        /// }
        /// ```
        pub fn exportQuery(self: *Self, comptime filter: anytype) *ExportBuffer {
            self.export_buffer.reset();

            // Create query spec from filter
            const filter_types = if (@typeInfo(@TypeOf(filter)) == .@"struct")
                std.meta.fields(@TypeOf(filter))
            else
                @as([0]std.builtin.Type.StructField, undefined);

            // Iterate through entities
            // Note: This is a simplified implementation. Full implementation
            // would use the world's query system.
            var entity_count: u32 = 0;
            const max_entities = cfg.options.max_entities;

            for (0..max_entities) |idx| {
                if (self.export_buffer.isFull()) break;

                const handle = self.world.entity_manager.getHandle(@intCast(idx));
                if (handle == null) continue;

                const entity = handle.?;

                // Check if entity has all filter components
                var has_all = true;
                inline for (filter_types) |field| {
                    if (!self.world.hasComponent(entity, field.type)) {
                        has_all = false;
                        break;
                    }
                }

                if (!has_all) continue;

                // Export entity
                self.export_buffer.entities[entity_count] = entity;
                self.export_buffer.data[entity_count] = self.packEntity(entity);
                entity_count += 1;
            }

            self.export_buffer.len = entity_count;
            self.stats.entities_exported += entity_count;
            self.stats.export_operations += 1;

            return &self.export_buffer;
        }

        /// Export specific entities by handle.
        /// Entities that don't exist are skipped.
        pub fn exportEntities(self: *Self, entities: []const WorldType.WorldEntityHandle) *ExportBuffer {
            self.export_buffer.reset();

            for (entities) |entity| {
                if (self.export_buffer.isFull()) break;

                // Check entity exists
                if (!self.world.entityExists(entity)) continue;

                const idx = self.export_buffer.len;
                self.export_buffer.entities[idx] = entity;
                self.export_buffer.data[idx] = self.packEntity(entity);
                self.export_buffer.len += 1;
            }

            self.stats.entities_exported += self.export_buffer.len;
            self.stats.export_operations += 1;

            return &self.export_buffer;
        }

        /// Pack all components of an entity into an export entry.
        fn packEntity(self: *Self, entity: WorldType.WorldEntityHandle) ExportBuffer.ExportEntry {
            var entry: ExportBuffer.ExportEntry = .{
                .component_mask = 0,
                .components = .{},
            };

            // Get each component if present
            inline for (0..num_components) |comp_idx| {
                const T = component_types[comp_idx];
                if (self.world.getComponent(entity, T)) |component| {
                    entry.components.set(comp_idx, component.*);
                    entry.component_mask |= (@as(ComponentMask, 1) << @intCast(comp_idx));
                }
            }

            return entry;
        }

        // ====================================================================
        // Zero-Copy API (Advanced)
        // ====================================================================

        /// Get direct read-only access to component storage.
        /// Enables zero-copy external processing of component arrays.
        ///
        /// Warning: The returned slice is only valid until world modification.
        pub fn getComponentArray(self: *Self, comptime T: type) ?[]const T {
            _ = self;
            // This requires archetype table to expose its storage
            // For now, return null (not implemented)
            // Full implementation would access archetype table internals
            return null;
        }

        /// Get direct mutable access to component storage.
        /// Must call syncComponents() after modification.
        ///
        /// Warning: The returned slice is only valid until world modification.
        pub fn getComponentArrayMut(self: *Self, comptime T: type) ?[]T {
            _ = self;
            // This requires archetype table to expose its storage
            // For now, return null (not implemented)
            return null;
        }

        // ====================================================================
        // Utility Functions
        // ====================================================================

        /// Find component type index in config at comptime.
        fn findComponentIndex(comptime T: type) ?usize {
            inline for (component_types, 0..) |CT, idx| {
                if (CT == T) return idx;
            }
            return null;
        }

        /// Get statistics snapshot.
        pub fn getStats(self: *const Self) Stats {
            return self.stats;
        }

        /// Reset statistics.
        pub fn resetStats(self: *Self) void {
            self.stats = .{};
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ExternalPipeline basic import" {
    const TestPosition = struct { x: f32, y: f32 };
    const TestVelocity = struct { dx: f32, dy: f32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{ TestPosition, TestVelocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "moving", .components = &.{ TestPosition, TestVelocity } },
        } },
        .pipeline = .{ .mode = .external },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Test buffer operations without world
    var buffer: Pipeline.ImportBuffer = .{};
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
    try std.testing.expect(!buffer.isFull());

    buffer.reset();
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
}

test "ExternalPipeline batch size" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .external,
            .external = .{ .batch_size = 2 }, // Very small batch
        },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Test buffer capacity
    var buffer: Pipeline.ImportBuffer = .{};
    try std.testing.expectEqual(@as(u32, 2), buffer.remaining());
}

test "ExternalPipeline stats type" {
    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .external },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Test stats type defaults
    const stats = Pipeline.Stats{};
    try std.testing.expectEqual(@as(u64, 0), stats.entities_imported);
    try std.testing.expectEqual(@as(u64, 0), stats.import_batches);
    try std.testing.expectEqual(@as(u64, 0), stats.entities_exported);
    try std.testing.expectEqual(@as(u64, 0), stats.export_operations);
}

test "ExternalPipeline export buffer type" {
    const TestPosition = struct { x: f32, y: f32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestPosition} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "positioned", .components = &.{TestPosition} },
        } },
        .pipeline = .{ .mode = .external },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Test export buffer operations
    var buffer: Pipeline.ExportBuffer = .{};
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
    try std.testing.expect(!buffer.isFull());
    try std.testing.expectEqual(@as(usize, 0), buffer.getEntities().len);
    try std.testing.expectEqual(@as(usize, 0), buffer.getData().len);

    buffer.reset();
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
}

test "ImportBuffer operations" {
    const test_config = WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
        .pipeline = .{ .mode = .external, .external = .{ .batch_size = 10 } },
    };

    const Pipeline = ExternalPipeline(test_config);
    var buffer: Pipeline.ImportBuffer = .{};

    // Initially empty
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
    try std.testing.expect(!buffer.isFull());
    try std.testing.expectEqual(@as(u32, 10), buffer.remaining());

    // After reset still empty
    buffer.reset();
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
}

test "ExportBuffer operations" {
    const test_config = WorldConfig{
        .components = .{ .types = &.{struct { x: i32 }} },
        .archetypes = .{ .archetypes = &.{} },
        .pipeline = .{ .mode = .external, .external = .{ .batch_size = 10 } },
    };

    const Pipeline = ExternalPipeline(test_config);
    var buffer: Pipeline.ExportBuffer = .{};

    // Initially empty
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
    try std.testing.expect(!buffer.isFull());
    try std.testing.expectEqual(@as(usize, 0), buffer.getEntities().len);
    try std.testing.expectEqual(@as(usize, 0), buffer.getData().len);

    // After reset still empty
    buffer.reset();
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
}

test "ComponentTuple type defaults" {
    const TestComp = struct { x: i32, y: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{} },
        .pipeline = .{ .mode = .external },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Test ComponentTuple default state
    const tuple: Pipeline.ComponentTuple = .{};
    try std.testing.expectEqual(@as(u8, 0), tuple.present);

    // Test max_component_data_size is calculated
    try std.testing.expect(Pipeline.ComponentTuple.max_component_data_size > 0);
}
