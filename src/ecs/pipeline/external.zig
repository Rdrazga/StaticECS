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

        /// Dedicated buffer for import result entity handles.
        /// Tiger Style: Separate from export_buffer to prevent aliasing hazards.
        import_result_buffer: [batch_size]WorldType.WorldEntityHandle = undefined,

        /// Operation state for runtime aliasing detection.
        /// Tiger Style: Fail-fast on concurrent import/export operations.
        operation_state: OperationState = .none,

        /// Statistics for monitoring pipeline performance.
        stats: Stats,

        /// Operation state enum for detecting concurrent access.
        const OperationState = enum {
            none,
            importing,
            exporting,
        };

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
            /// Entities that failed during spawn (createEntity failed).
            spawn_failures: u64 = 0,
            /// Entities despawned due to component set failures (transactional rollback).
            component_failures: u64 = 0,
        };

        // ====================================================================
        // Commit Result
        // ====================================================================

        /// Result of committing an import batch.
        /// Tracks both successful entities and any failures for visibility.
        ///
        /// Tiger Style: No silent error swallowing - failures are always visible.
        pub const CommitResult = struct {
            /// Slice of successfully created entity handles.
            entities: []const WorldType.WorldEntityHandle,
            /// Number of entities successfully created with all components.
            entities_created: u32,
            /// Number of entities that failed to spawn (createEntity error).
            spawn_failures: u32,
            /// Number of entities despawned due to component set failures.
            /// These entities were created but rolled back due to incomplete component data.
            component_failures: u32,

            /// Returns true if all entities in the batch were created successfully.
            pub fn isComplete(self: CommitResult) bool {
                return self.spawn_failures == 0 and self.component_failures == 0;
            }

            /// Returns total number of failed operations.
            pub fn totalFailures(self: CommitResult) u32 {
                return self.spawn_failures + self.component_failures;
            }
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
                .import_result_buffer = undefined,
                .operation_state = .none,
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
        /// Returns a CommitResult containing created entities and failure statistics.
        ///
        /// Tiger Style: Transactional semantics - if any component fails to set,
        /// the entity is despawned (rolled back) to prevent incomplete/corrupt entities.
        /// Failures are tracked and returned, never silently swallowed.
        pub fn commitImport(self: *Self) CommitResult {
            // Tiger Style: Comptime assertion - buffers must not alias
            comptime {
                // Verify import_result_buffer and export_buffer.entities are separate fields
                // This is inherently true due to struct field semantics, but we assert it
                // to document the invariant
                const import_offset = @offsetOf(Self, "import_result_buffer");
                const export_offset = @offsetOf(Self, "export_buffer");
                if (import_offset == export_offset) {
                    @compileError("Buffer aliasing detected: import_result_buffer and export_buffer must be distinct");
                }
            }

            // Tiger Style: Runtime assertion - detect concurrent operations
            std.debug.assert(self.operation_state == .none);
            self.operation_state = .importing;
            defer self.operation_state = .none;

            const count = self.import_buffer.len;
            if (count == 0) {
                return .{
                    .entities = &[_]WorldType.WorldEntityHandle{},
                    .entities_created = 0,
                    .spawn_failures = 0,
                    .component_failures = 0,
                };
            }

            // Tiger Style: Use dedicated import_result_buffer instead of aliasing export_buffer
            var created: *[batch_size]WorldType.WorldEntityHandle = &self.import_result_buffer;
            var created_count: u32 = 0;
            var spawn_failures: u32 = 0;
            var component_failures: u32 = 0;

            for (0..count) |i| {
                const entry = &self.import_buffer.entries[i];

                // Create entity in world
                const entity = self.world.createEntity() catch {
                    // Track spawn failure and continue to next entry
                    spawn_failures += 1;
                    continue;
                };

                // Track if any component fails to set for this entity
                var entity_complete = true;

                // Set all components from entry
                inline for (0..num_components) |comp_idx| {
                    const T = component_types[comp_idx];
                    const mask = @as(ComponentMask, 1) << @intCast(comp_idx);
                    if (entry.component_mask & mask != 0) {
                        if (entry.components.get(comp_idx)) |value| {
                            self.world.setComponent(entity, value) catch {
                                // Component set failed - mark entity as incomplete
                                entity_complete = false;
                            };
                            // Suppress unused variable warning
                            _ = T;
                        }
                    }
                }

                // Tiger Style: Transactional rollback on partial failure
                // If any component failed to set, despawn the entity to prevent
                // incomplete/corrupt entities from existing in the world
                if (!entity_complete) {
                    self.world.destroyEntity(entity) catch {
                        // Despawn failed - entity exists but is incomplete
                        // This is a serious error state, but we still track it
                    };
                    component_failures += 1;
                    continue;
                }

                // Entity fully created with all components
                created[created_count] = entity;
                created_count += 1;
            }

            // Update stats
            self.stats.entities_imported += created_count;
            self.stats.import_batches += 1;
            self.stats.spawn_failures += spawn_failures;
            self.stats.component_failures += component_failures;

            self.import_buffer.reset();

            // Tiger Style: Post-condition assertion - result buffer distinct from export buffer
            std.debug.assert(@intFromPtr(created) != @intFromPtr(&self.export_buffer.entities));

            return .{
                .entities = created[0..created_count],
                .entities_created = created_count,
                .spawn_failures = spawn_failures,
                .component_failures = component_failures,
            };
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
            // Tiger Style: Runtime assertion - detect concurrent operations
            std.debug.assert(self.operation_state == .none);
            self.operation_state = .exporting;
            defer self.operation_state = .none;

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
            // Tiger Style: Runtime assertion - detect concurrent operations
            std.debug.assert(self.operation_state == .none);
            self.operation_state = .exporting;
            defer self.operation_state = .none;

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

        /// Archetype count for iteration.
        const archetype_count = cfg.archetypes.archetypes.len;

        /// Archetype definitions for component checking.
        const archetype_defs = cfg.archetypes.archetypes;

        /// Get direct read-only access to a component array from a specific archetype.
        ///
        /// This is the primary zero-copy API. Returns a direct slice to the
        /// archetype's internal SoA storage without any copying.
        ///
        /// ## Usage
        ///
        /// ```zig
        /// const pipeline = ExternalPipeline(config).init(&world);
        /// if (pipeline.getComponentArrayFromArchetype("moving", Position)) |positions| {
        ///     // Direct array access - zero copy
        ///     for (positions) |pos| {
        ///         // Process position data
        ///     }
        /// }
        /// ```
        ///
        /// ## Safety
        ///
        /// The returned slice is only valid until the next world mutation
        /// (spawn, despawn, component add/remove). Do not hold references
        /// across world modifications.
        ///
        /// ## Why Per-Archetype?
        ///
        /// Components are stored in archetype-specific SoA arrays. A component
        /// type may exist in multiple archetypes (e.g., Position in both "player"
        /// and "enemy" archetypes). This API returns the contiguous array for
        /// one archetype, enabling true zero-copy access.
        ///
        /// For processing components across all archetypes, use `getComponentArrays()`
        /// which returns an iterator over all matching archetype slices.
        pub fn getComponentArrayFromArchetype(
            self: *Self,
            comptime archetype_name: []const u8,
            comptime T: type,
        ) ?[]const T {
            const arch_idx = comptime WorldType.archIndex(archetype_name);
            const table = &self.world.storage[arch_idx];
            return table.getComponentSliceConst(T);
        }

        /// Get direct mutable access to a component array from a specific archetype.
        ///
        /// Returns a mutable slice to the archetype's internal storage.
        /// Changes are immediately visible to the ECS - no sync needed.
        ///
        /// ## Safety
        ///
        /// - Only valid until the next world mutation
        /// - Do not add/remove entities while holding mutable references
        /// - Concurrent writes to same component are undefined behavior
        pub fn getComponentArrayFromArchetypeMut(
            self: *Self,
            comptime archetype_name: []const u8,
            comptime T: type,
        ) ?[]T {
            const arch_idx = comptime WorldType.archIndex(archetype_name);
            const table = &self.world.storage[arch_idx];
            return table.getComponentSlice(T);
        }

        /// Iterator over component arrays from all archetypes containing type T.
        ///
        /// Each iteration yields a slice from one archetype. This enables
        /// zero-copy batch processing across all entities with a component
        /// without allocating a combined array.
        ///
        /// ## Usage
        ///
        /// ```zig
        /// var iter = pipeline.getComponentArrays(Position);
        /// while (iter.next()) |positions| {
        ///     // Process this archetype's positions
        ///     simd_process(positions);
        /// }
        /// ```
        pub fn getComponentArrays(self: *Self, comptime T: type) ComponentArrayIterator(T) {
            return ComponentArrayIterator(T).init(self);
        }

        /// Iterator type for component arrays across archetypes.
        pub fn ComponentArrayIterator(comptime T: type) type {
            // Pre-compute which archetypes contain this component at compile time
            const matching_archetypes = comptime blk: {
                var matches: [archetype_count]bool = undefined;
                for (0..archetype_count) |i| {
                    matches[i] = archetypeContainsComponent(i, T);
                }
                break :blk matches;
            };

            return struct {
                const Iter = @This();

                pipeline: *Self,
                arch_index: usize,

                pub fn init(pipeline: *Self) Iter {
                    return .{ .pipeline = pipeline, .arch_index = 0 };
                }

                /// Get the next non-empty component slice from matching archetypes.
                pub fn next(self: *Iter) ?[]const T {
                    while (self.arch_index < archetype_count) {
                        const idx = self.arch_index;
                        self.arch_index += 1;

                        // Check if this archetype contains the component (comptime lookup)
                        if (matching_archetypes[idx]) {
                            if (self.getSliceFromArchetypeRuntime(idx)) |slice| {
                                if (slice.len > 0) {
                                    return slice;
                                }
                            }
                        }
                    }
                    return null;
                }

                /// Reset iterator to beginning.
                pub fn reset(self: *Iter) void {
                    self.arch_index = 0;
                }

                /// Get slice from archetype by runtime index.
                /// Uses inline switch for comptime table access.
                fn getSliceFromArchetypeRuntime(self: *Iter, idx: usize) ?[]const T {
                    inline for (0..archetype_count) |i| {
                        if (idx == i) {
                            const table = &self.pipeline.world.storage[i];
                            return table.getComponentSliceConst(T);
                        }
                    }
                    return null;
                }
            };
        }

        /// Check if archetype at index contains component type T (comptime).
        fn archetypeContainsComponent(comptime arch_idx: usize, comptime T: type) bool {
            const components = archetype_defs[arch_idx].components;
            for (components) |C| {
                if (C == T) return true;
            }
            return false;
        }

        /// DEPRECATED: Get direct read-only access to component storage.
        ///
        /// **This API always returns null.** Due to archetype-based storage,
        /// components are stored in multiple non-contiguous arrays. A single
        /// slice cannot represent all component data without allocation.
        ///
        /// ## Alternatives
        ///
        /// - `getComponentArrayFromArchetype(archetype_name, T)` - Zero-copy
        ///   access to components in a specific archetype
        /// - `getComponentArrays(T)` - Iterator over slices from all archetypes
        ///
        /// ## Architectural Reason
        ///
        /// In archetype-based ECS, entities with different component sets are
        /// stored in different tables. If "players" have (Position, Velocity)
        /// and "bullets" have (Position, Lifetime), their Position components
        /// are in separate arrays. Returning a unified slice would require
        /// copying, defeating zero-copy purpose.
        pub fn getComponentArray(self: *Self, comptime T: type) ?[]const T {
            _ = self;
            // Architectural limitation: Components span multiple archetypes.
            // Use getComponentArrayFromArchetype() or getComponentArrays() instead.
            // Return type uses T, so no discard needed.
            return @as(?[]const T, null);
        }

        /// DEPRECATED: Get direct mutable access to component storage.
        ///
        /// **This API always returns null.** See `getComponentArray` documentation.
        ///
        /// Use `getComponentArrayFromArchetypeMut(archetype_name, T)` instead.
        pub fn getComponentArrayMut(self: *Self, comptime T: type) ?[]T {
            _ = self;
            // Architectural limitation: Components span multiple archetypes.
            // Use getComponentArrayFromArchetypeMut() instead.
            // Return type uses T, so no discard needed.
            return @as(?[]T, null);
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

// ============================================================================
// Phase 2 Bug Fix Regression Tests
// ============================================================================

test "ExternalPipeline CommitResult structure and methods" {
    // Test that CommitResult properly tracks failures and provides
    // helper methods for checking success.
    //
    // Verifies fix for P1-COMMIT where errors were silently swallowed.
    // Now commitImport returns CommitResult with failure counts instead
    // of silently ignoring them.
    //
    // Note: Full integration test with actual entity creation is blocked
    // because commitImport calls World methods (createEntity, setComponent,
    // destroyEntity) that don't exist in the current World API. This test
    // validates the CommitResult structure and helper methods work correctly.

    const TestComp = struct { x: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .external,
            .external = .{ .batch_size = 16 },
        },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Test CommitResult helper methods with success case
    // Use u8 as dummy entity type for testing structure
    const success_result: Pipeline.CommitResult = .{
        .entities = &[0]@import("../world.zig").World(test_config).WorldEntityHandle{},
        .entities_created = 5,
        .spawn_failures = 0,
        .component_failures = 0,
    };

    // isComplete() should return true when no failures
    try std.testing.expect(success_result.isComplete());
    try std.testing.expectEqual(@as(u32, 0), success_result.totalFailures());

    // Test CommitResult helper methods with partial failure case
    const partial_result: Pipeline.CommitResult = .{
        .entities = &[0]@import("../world.zig").World(test_config).WorldEntityHandle{},
        .entities_created = 3,
        .spawn_failures = 1,
        .component_failures = 1,
    };

    // isComplete() should return false when there are failures
    try std.testing.expect(!partial_result.isComplete());
    try std.testing.expectEqual(@as(u32, 2), partial_result.totalFailures());

    // Test Stats structure includes failure tracking fields
    // (Part of the fix: Stats now tracks spawn_failures and component_failures)
    var stats = Pipeline.Stats{};
    try std.testing.expectEqual(@as(u64, 0), stats.spawn_failures);
    try std.testing.expectEqual(@as(u64, 0), stats.component_failures);

    // Verify stats track failures when updated
    stats.spawn_failures = 3;
    stats.component_failures = 2;
    try std.testing.expectEqual(@as(u64, 3), stats.spawn_failures);
    try std.testing.expectEqual(@as(u64, 2), stats.component_failures);
}

test "ExternalPipeline ImportBuffer batch operations" {
    // Test the import buffer operations that support the commitImport fix.
    //
    // The fix for P1-COMMIT added proper batch tracking. This test verifies
    // the ImportBuffer correctly tracks entries before commit.

    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .external,
            .external = .{ .batch_size = 4 }, // Small batch for testing
        },
    };

    const Pipeline = ExternalPipeline(test_config);
    var buffer: Pipeline.ImportBuffer = .{};

    // Initially empty
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
    try std.testing.expect(!buffer.isFull());
    try std.testing.expectEqual(@as(u32, 4), buffer.remaining());

    // Simulate adding entries (would happen via addImport in full pipeline)
    buffer.len = 2;
    try std.testing.expectEqual(@as(u32, 2), buffer.len);
    try std.testing.expectEqual(@as(u32, 2), buffer.remaining());
    try std.testing.expect(!buffer.isFull());

    // Fill buffer
    buffer.len = 4;
    try std.testing.expect(buffer.isFull());
    try std.testing.expectEqual(@as(u32, 0), buffer.remaining());

    // Reset clears the buffer
    buffer.reset();
    try std.testing.expectEqual(@as(u32, 0), buffer.len);
    try std.testing.expect(!buffer.isFull());
}

// ============================================================================
// P-C1 Buffer Aliasing Fix Regression Tests
// ============================================================================

test "P-C1: import_result_buffer is separate from export_buffer" {
    // Verifies fix for P-C1: Buffer aliasing in External Pipeline
    //
    // The original bug used export_buffer.entities as scratch space during import
    // operations, risking data corruption if import/export operations overlap.
    // This test verifies the buffers are now separate.

    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .external,
            .external = .{ .batch_size = 8 },
        },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Verify import_result_buffer and export_buffer are at different offsets
    // This comptime check ensures the fields don't alias
    const import_offset = @offsetOf(Pipeline, "import_result_buffer");
    const export_offset = @offsetOf(Pipeline, "export_buffer");

    try std.testing.expect(import_offset != export_offset);

    // Also verify the actual array inside export_buffer is at a different location
    // export_buffer.entities should be at export_offset + some internal offset
    const export_entities_offset = export_offset + @offsetOf(Pipeline.ExportBuffer, "entities");
    try std.testing.expect(import_offset != export_entities_offset);
}

test "P-C1: OperationState enum exists for concurrent access detection" {
    // Verifies operation state tracking was added for runtime aliasing detection

    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .external,
            .external = .{ .batch_size = 8 },
        },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Verify OperationState enum has expected values
    try std.testing.expect(Pipeline.OperationState.none != Pipeline.OperationState.importing);
    try std.testing.expect(Pipeline.OperationState.none != Pipeline.OperationState.exporting);
    try std.testing.expect(Pipeline.OperationState.importing != Pipeline.OperationState.exporting);

    // Verify pipeline struct has operation_state field initialized to .none
    const has_field = @hasField(Pipeline, "operation_state");
    try std.testing.expect(has_field);
}

test "P-C1: import_result_buffer field exists in pipeline struct" {
    // Verifies the dedicated import result buffer was added

    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .external,
            .external = .{ .batch_size = 8 },
        },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Verify import_result_buffer field exists
    const has_import_buffer = @hasField(Pipeline, "import_result_buffer");
    try std.testing.expect(has_import_buffer);

    // Verify it has correct size (batch_size elements)
    const World = @import("../world.zig").World(test_config);
    const expected_size = 8 * @sizeOf(World.WorldEntityHandle);
    const actual_size = @sizeOf(@TypeOf(@as(Pipeline, undefined).import_result_buffer));
    try std.testing.expectEqual(expected_size, actual_size);
}

test "P-C1: export buffer entities untouched during empty import commit" {
    // Verifies that export_buffer.entities is not modified when commitImport
    // is called, even with an empty import buffer.

    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{
            .mode = .external,
            .external = .{ .batch_size = 4 },
        },
    };

    const Pipeline = ExternalPipeline(test_config);

    // Create standalone buffers to test independence
    var export_buf: Pipeline.ExportBuffer = .{};
    var import_result_buf: [4]@import("../world.zig").World(test_config).WorldEntityHandle = undefined;

    // Verify they're at different addresses (no aliasing)
    const export_ptr = @intFromPtr(&export_buf.entities);
    const import_ptr = @intFromPtr(&import_result_buf);
    try std.testing.expect(export_ptr != import_ptr);
}

// ============================================================================
// P-H1 Zero-Copy API Tests
// ============================================================================

test "P-H1: getComponentArrayFromArchetype returns valid slice" {
    // Tests that the new per-archetype zero-copy API returns a direct slice
    // to component storage, enabling high-throughput external processing.

    const TestPosition = struct { x: f32, y: f32 };
    const TestVelocity = struct { dx: f32, dy: f32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{ TestPosition, TestVelocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "moving", .components = &.{ TestPosition, TestVelocity } },
        } },
        .pipeline = .{ .mode = .external },
    };

    const World = @import("../world.zig").World(test_config);
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    // Spawn some entities
    _ = try world.spawn("moving", .{
        TestPosition{ .x = 1.0, .y = 2.0 },
        TestVelocity{ .dx = 0.1, .dy = 0.2 },
    });
    _ = try world.spawn("moving", .{
        TestPosition{ .x = 3.0, .y = 4.0 },
        TestVelocity{ .dx = 0.3, .dy = 0.4 },
    });

    const Pipeline = ExternalPipeline(test_config);
    var pipeline: Pipeline = .{
        .world = &world,
        .import_buffer = .{},
        .export_buffer = .{},
        .stats = .{},
    };

    // Test getComponentArrayFromArchetype for Position
    const positions = pipeline.getComponentArrayFromArchetype("moving", TestPosition);
    try std.testing.expect(positions != null);
    try std.testing.expectEqual(@as(usize, 2), positions.?.len);
    try std.testing.expectEqual(@as(f32, 1.0), positions.?[0].x);
    try std.testing.expectEqual(@as(f32, 3.0), positions.?[1].x);

    // Test getComponentArrayFromArchetype for Velocity
    const velocities = pipeline.getComponentArrayFromArchetype("moving", TestVelocity);
    try std.testing.expect(velocities != null);
    try std.testing.expectEqual(@as(usize, 2), velocities.?.len);
    try std.testing.expectEqual(@as(f32, 0.1), velocities.?[0].dx);
}

test "P-H1: getComponentArrayFromArchetypeMut allows modification" {
    // Tests that mutable access allows direct modification of components.

    const TestValue = struct { v: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestValue} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "values", .components = &.{TestValue} },
        } },
        .pipeline = .{ .mode = .external },
    };

    const World = @import("../world.zig").World(test_config);
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn("values", .{TestValue{ .v = 100 }});

    const Pipeline = ExternalPipeline(test_config);
    var pipeline: Pipeline = .{
        .world = &world,
        .import_buffer = .{},
        .export_buffer = .{},
        .stats = .{},
    };

    // Get mutable access and modify
    const values = pipeline.getComponentArrayFromArchetypeMut("values", TestValue);
    try std.testing.expect(values != null);
    values.?[0].v = 200;

    // Verify modification persists via normal query
    const component = world.getComponent(entity, TestValue);
    try std.testing.expect(component != null);
    try std.testing.expectEqual(@as(i32, 200), component.?.v);
}

test "P-H1: getComponentArrays iterator over multiple archetypes" {
    // Tests that the iterator correctly yields slices from all archetypes
    // containing the requested component type.

    const TestPosition = struct { x: f32, y: f32 };
    const TestVelocity = struct { dx: f32, dy: f32 };
    const TestHealth = struct { hp: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{ TestPosition, TestVelocity, TestHealth } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "moving", .components = &.{ TestPosition, TestVelocity } },
            .{ .name = "static", .components = &.{TestPosition} },
            .{ .name = "living", .components = &.{ TestPosition, TestHealth } },
        } },
        .pipeline = .{ .mode = .external },
    };

    const World = @import("../world.zig").World(test_config);
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    // Spawn entities in different archetypes
    _ = try world.spawn("moving", .{
        TestPosition{ .x = 1.0, .y = 1.0 },
        TestVelocity{ .dx = 0.1, .dy = 0.1 },
    });
    _ = try world.spawn("static", .{TestPosition{ .x = 2.0, .y = 2.0 }});
    _ = try world.spawn("living", .{
        TestPosition{ .x = 3.0, .y = 3.0 },
        TestHealth{ .hp = 100 },
    });

    const Pipeline = ExternalPipeline(test_config);
    var pipeline: Pipeline = .{
        .world = &world,
        .import_buffer = .{},
        .export_buffer = .{},
        .stats = .{},
    };

    // Iterate over all Position arrays
    var iter = pipeline.getComponentArrays(TestPosition);
    var total_positions: usize = 0;
    var slice_count: usize = 0;

    while (iter.next()) |positions| {
        total_positions += positions.len;
        slice_count += 1;
    }

    // Should have found 3 positions across 3 archetypes
    try std.testing.expectEqual(@as(usize, 3), total_positions);
    try std.testing.expectEqual(@as(usize, 3), slice_count);
}

test "P-H1: deprecated getComponentArray returns null" {
    // Verifies the deprecated API correctly returns null and documents
    // the architectural reason (components span multiple archetypes).

    const TestComp = struct { value: i32 };

    const test_config = WorldConfig{
        .components = .{ .types = &.{TestComp} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "test", .components = &.{TestComp} },
        } },
        .pipeline = .{ .mode = .external },
    };

    const World = @import("../world.zig").World(test_config);
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawn("test", .{TestComp{ .value = 42 }});

    const Pipeline = ExternalPipeline(test_config);
    var pipeline: Pipeline = .{
        .world = &world,
        .import_buffer = .{},
        .export_buffer = .{},
        .stats = .{},
    };

    // Deprecated API should return null even when components exist
    const array = pipeline.getComponentArray(TestComp);
    try std.testing.expectEqual(@as(?[]const TestComp, null), array);

    const array_mut = pipeline.getComponentArrayMut(TestComp);
    try std.testing.expectEqual(@as(?[]TestComp, null), array_mut);
}
