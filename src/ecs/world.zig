//! World Type Generator
//!
//! This module provides the `World(config)` function that generates a
//! concrete World type specialized for a given `WorldConfig`. The generated
//! type includes entity management, archetype storage, and query APIs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const WorldConfig = config_mod.WorldConfig;
const WorldConfigView = config_mod.WorldConfigView;
const validateWorldConfig = config_mod.validateWorldConfig;
const LayoutMode = config_mod.LayoutMode;

const system_context_mod = @import("system_context.zig");

const entity_mod = @import("world/entity.zig");
// Use configurable entity types
const EntityIdType = entity_mod.EntityIdType;
const EntityHandleType = entity_mod.EntityHandleType;
const EntityManagerType = entity_mod.EntityManagerType;
// Legacy types for backward compatibility (default 20-bit index)
const EntityId = entity_mod.EntityId;
const EntityHandle = entity_mod.EntityHandle;

const archetype_table = @import("world/archetype_table.zig");
const ArchetypeTable = archetype_table.ArchetypeTable;

const query_mod = @import("world/query.zig");
pub const Query = query_mod.Query;
pub const QuerySpec = query_mod.QuerySpec;

const version_mod = @import("version.zig");

/// World error types.
pub const WorldError = error{
    /// Entity capacity has been reached.
    CapacityExhausted,
    /// Entity handle is invalid or stale.
    InvalidEntity,
    /// Archetype not found for the given component set.
    ArchetypeNotFound,
    /// Component type not found in archetype.
    ComponentNotFound,
    /// Memory allocation failed.
    OutOfMemory,
};

/// Generate a concrete World type from a compile-time WorldConfig.
///
/// The returned type provides:
/// - Entity creation/deletion with generation-checked handles
/// - Storage for all configured archetypes
/// - Component access APIs (get, set, has)
/// - A minimal structured query API
pub fn World(comptime cfg: WorldConfig) type {
    // Validate configuration at compile time
    comptime {
        validateWorldConfig(cfg);

        // Check version compatibility if pinned
        if (cfg.options.core_version) |pin| {
            if (!version_mod.checkVersionCompatibility(.{
                .major = pin.major,
                .minor = pin.minor,
                .patch = pin.patch,
            })) {
                @compileError("WorldConfig core_version is incompatible with current ECS version");
            }
        }
    }

    return struct {
        const Self = @This();

        /// The configuration this world was created from.
        pub const config: WorldConfig = cfg;

        /// Stable read-only view over the configuration.
        pub const config_view: WorldConfigView = WorldConfigView.init(cfg);

        /// Number of archetypes in this world.
        pub const archetype_count = cfg.archetypes.archetypes.len;

        /// Maximum entity count.
        pub const max_entities = cfg.options.max_entities;

        /// Entity index bit width from config.
        pub const entity_index_bits = cfg.options.entity_index_bits;

        // ====================================================================
        // Type Definitions
        // ====================================================================

        /// EntityId type for this world (config-based bit widths).
        pub const WorldEntityId = EntityIdType(entity_index_bits);

        /// EntityHandle type for this world (config-based bit widths).
        pub const WorldEntityHandle = EntityHandleType(entity_index_bits);

        /// Entity manager for this world (config-based bit widths).
        const Entities = EntityManagerType(max_entities, entity_index_bits);

        /// Resource storage type.
        pub const ResourceStorage = system_context_mod.Resources(cfg.resources.types);

        /// Archetype table types - one per configured archetype.
        const ArchetypeTables = blk: {
            var tables: [archetype_count]type = undefined;
            for (cfg.archetypes.archetypes, 0..) |arch_def, i| {
                tables[i] = ArchetypeTable(arch_def.components);
            }
            break :blk tables;
        };

        /// Storage struct containing all archetype tables.
        // Build sentinel-terminated field names for archetypes
        const archetype_field_names = blk: {
            var names: [archetype_count][:0]const u8 = undefined;
            for (cfg.archetypes.archetypes, 0..) |arch, i| {
                names[i] = arch.name;
            }
            break :blk names;
        };

        /// Storage type containing all archetype tables - using @Tuple for Zig 0.16 compatibility.
        const Storage = @Tuple(&ArchetypeTables);

        // ====================================================================
        // Instance Fields
        // ====================================================================

        /// Entity manager instance.
        entities: Entities,

        /// Archetype storage.
        storage: Storage,

        /// Global resource storage.
        resources: ResourceStorage,

        /// Memory allocator used by this world.
        allocator: Allocator,

        /// Debug flag from config.
        debug_asserts_enabled: bool,

        // ====================================================================
        // Lifecycle
        // ====================================================================

        /// Expected entities per archetype from config.
        pub const expected_per_archetype = cfg.options.expected_entities_per_archetype;

        /// Initialize a new world instance.
        /// If `expected_entities_per_archetype > 0`, pre-allocates storage for Tiger Style compliance.
        pub fn init(allocator: Allocator) Self {
            var storage: Storage = undefined;

            // Initialize each archetype table
            inline for (cfg.archetypes.archetypes, 0..) |arch_def, i| {
                if (expected_per_archetype > 0) {
                    // Pre-allocate for Tiger Style (no dynamic allocation after init)
                    storage[i] = ArchetypeTables[i].initWithCapacity(
                        allocator,
                        arch_def.name,
                        expected_per_archetype,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => @panic("Failed to pre-allocate archetype storage - out of memory"),
                    };
                } else {
                    storage[i] = ArchetypeTables[i].init(allocator, arch_def.name);
                }
            }

            return .{
                .entities = Entities.init(),
                .storage = storage,
                .resources = ResourceStorage.init(),
                .allocator = allocator,
                .debug_asserts_enabled = cfg.options.enable_debug_asserts,
            };
        }

        /// Deinitialize and free all world resources.
        pub fn deinit(self: *Self) void {
            inline for (0..archetype_count) |i| {
                self.storage[i].deinit();
            }
        }

        // ====================================================================
        // Entity Management
        // ====================================================================

        /// Create a new entity in the specified archetype with initial component values.
        /// Precondition: World must not be at entity capacity.
        /// Postcondition: Entity count increases by 1, returned handle is valid.
        pub fn spawn(self: *Self, comptime archetype_name: []const u8, components: anytype) WorldError!WorldEntityHandle {
            // Tiger Style: Track count for postcondition
            const count_before = if (self.debug_asserts_enabled) self.entityCount() else 0;

            // Create entity
            const handle = self.entities.create() orelse return WorldError.CapacityExhausted;

            // Add to archetype storage
            const arch_index = comptime archIndex(archetype_name);
            const table = &self.storage[arch_index];

            const row = table.addEntity(handle.toId(), components) catch {
                // Rollback entity creation on storage failure
                _ = self.entities.destroy(handle);
                return WorldError.OutOfMemory;
            };

            // Update entity metadata
            _ = self.entities.setLocation(handle, arch_index, row);

            // Tiger Style: Postcondition assertions
            if (self.debug_asserts_enabled) {
                std.debug.assert(handle.isValid()); // Handle must be valid
                std.debug.assert(self.isAlive(handle)); // Entity must be alive
                std.debug.assert(self.entityCount() == count_before + 1); // Count increased by 1
            }

            return handle;
        }

        /// Destroy an entity.
        /// Precondition: Handle must reference a valid, alive entity.
        /// Postcondition: Entity count decreases by 1, handle no longer valid.
        pub fn despawn(self: *Self, handle: WorldEntityHandle) WorldError!void {
            // Tiger Style: Precondition assertions
            if (self.debug_asserts_enabled) {
                std.debug.assert(handle.isValid()); // Handle must not be INVALID sentinel
            }

            // Tiger Style: Track count for postcondition
            const count_before = if (self.debug_asserts_enabled) self.entityCount() else 0;

            const meta = self.entities.getMetadata(handle) orelse return WorldError.InvalidEntity;

            // Remove from archetype storage
            inline for (0..archetype_count) |i| {
                if (meta.archetype_index == i) {
                    const table = &self.storage[i];
                    const moved_entity = table.removeEntityByRow(meta.archetype_row);

                    // If another entity was moved, update its metadata
                    // O(1) direct lookup using the moved entity's index (not O(n) linear search)
                    if (moved_entity) |moved_id| {
                        const moved_index = moved_id.index;
                        var moved_meta = &self.entities.metadata[moved_index];

                        // Tiger Style: Assert invariants before update
                        std.debug.assert(moved_meta.alive); // Moved entity must be alive
                        std.debug.assert(moved_meta.archetype_index == i); // Must be in same archetype

                        // Update to point to the vacated row (where despawned entity was)
                        moved_meta.archetype_row = meta.archetype_row;
                    }
                    break;
                }
            }

            // Destroy entity record
            _ = self.entities.destroy(handle);

            // Tiger Style: Postcondition assertions
            if (self.debug_asserts_enabled) {
                std.debug.assert(!self.isAlive(handle)); // Entity must no longer be alive
                std.debug.assert(self.entityCount() == count_before - 1); // Count decreased by 1
            }
        }

        /// Check if an entity is alive.
        pub fn isAlive(self: *const Self, handle: WorldEntityHandle) bool {
            return self.entities.isAlive(handle);
        }

        /// Get the number of alive entities.
        pub fn entityCount(self: *const Self) u32 {
            return self.entities.count();
        }

        // ====================================================================
        // Component Access
        // ====================================================================

        /// Get a read-only pointer to an entity's component.
        pub fn getComponent(self: *const Self, handle: WorldEntityHandle, comptime T: type) ?*const T {
            const meta = self.entities.getMetadata(handle) orelse return null;

            inline for (0..archetype_count) |i| {
                if (meta.archetype_index == i) {
                    const table = &self.storage[i];
                    return table.getComponentConst(T, meta.archetype_row);
                }
            }

            return null;
        }

        /// Get a mutable pointer to an entity's component.
        pub fn getComponentMut(self: *Self, handle: WorldEntityHandle, comptime T: type) ?*T {
            const meta = self.entities.getMetadata(handle) orelse return null;

            inline for (0..archetype_count) |i| {
                if (meta.archetype_index == i) {
                    const table = &self.storage[i];
                    return table.getComponent(T, meta.archetype_row);
                }
            }

            return null;
        }

        /// Set a component value on an entity.
        pub fn setComponent(self: *Self, handle: WorldEntityHandle, comptime T: type, value: T) bool {
            if (self.getComponentMut(handle, T)) |ptr| {
                ptr.* = value;
                return true;
            }
            return false;
        }

        /// Check if an entity has a specific component type.
        pub fn hasComponent(self: *const Self, handle: WorldEntityHandle, comptime T: type) bool {
            return self.getComponent(handle, T) != null;
        }

        // ====================================================================
        // Query API
        // ====================================================================

        /// Create a query iterator for the specified query type.
        /// The query iterates over all matching archetypes.
        pub fn query(self: *Self, comptime Spec: type) QueryIterator(Spec) {
            return QueryIterator(Spec).init(self);
        }

        /// Query iterator type for a given QuerySpec.
        pub fn QueryIterator(comptime Spec: type) type {
            return struct {
                const QI = @This();
                const Result = query_mod.QueryResult(Spec);

                // Precompute which archetypes match this query at comptime
                const matching_archetypes = blk: {
                    var result: [archetype_count]bool = undefined;
                    for (0..archetype_count) |i| {
                        result[i] = Spec.matchesArchetype(cfg.archetypes.archetypes[i].components);
                    }
                    break :blk result;
                };

                world: *Self,
                current_archetype: usize,
                current_row: u32,

                pub fn init(w: *Self) QI {
                    return .{
                        .world = w,
                        .current_archetype = 0,
                        .current_row = 0,
                    };
                }

                pub fn next(self: *QI) ?Result {
                    while (self.current_archetype < archetype_count) {
                        // Check if this archetype matches the query using precomputed array
                        if (matching_archetypes[self.current_archetype]) {
                            const table_len = self.getTableLen();

                            if (self.current_row < table_len) {
                                const result = self.buildResult();
                                self.current_row += 1;
                                return result;
                            }
                        }

                        self.current_archetype += 1;
                        self.current_row = 0;
                    }

                    return null;
                }

                fn getTableLen(self: *QI) u32 {
                    inline for (0..archetype_count) |i| {
                        if (self.current_archetype == i) {
                            const table = &self.world.storage[i];
                            return @intCast(table.len());
                        }
                    }
                    return 0;
                }

                fn buildResult(self: *QI) Result {
                    var result: Result = undefined;

                    inline for (0..archetype_count) |i| {
                        if (self.current_archetype == i) {
                            const table = &self.world.storage[i];
                            // Get archetype's component types for optional component checks
                            const arch_components = cfg.archetypes.archetypes[i].components;

                            result.entity_id = table.getEntityId(self.current_row).?;

                            // Required read components - always present (query matched)
                            inline for (0..Spec.read_components.len) |read_idx| {
                                const T = Spec.read_components[read_idx];
                                result.read[read_idx] = table.getComponentConst(T, self.current_row).?;
                            }

                            // Required write components - always present (query matched)
                            inline for (0..Spec.write_components.len) |write_idx| {
                                const T = Spec.write_components[write_idx];
                                result.write[write_idx] = table.getComponent(T, self.current_row).?;
                            }

                            // Optional components - may or may not be present in this archetype.
                            // Unlike required components, optional components don't affect query matching,
                            // so we must check each archetype individually and return null if absent.
                            inline for (0..Spec.optional_components.len) |opt_idx| {
                                const T = Spec.optional_components[opt_idx];
                                if (Spec.archetypeHasOptional(arch_components, T)) {
                                    result.optional[opt_idx] = table.getComponentConst(T, self.current_row);
                                } else {
                                    result.optional[opt_idx] = null;
                                }
                            }

                            return result;
                        }
                    }

                    unreachable;
                }

                pub fn reset(self: *QI) void {
                    self.current_archetype = 0;
                    self.current_row = 0;
                }
            };
        }

        // ====================================================================
        // Archetype Access
        // ====================================================================

        /// Get direct access to an archetype table by name.
        pub fn getArchetype(self: *Self, comptime name: []const u8) *ArchetypeTables[archIndex(name)] {
            const idx = comptime archIndex(name);
            return &self.storage[idx];
        }

        // ====================================================================
        // Resource Access
        // ====================================================================

        /// Get a mutable resource pointer. Returns null if not initialized.
        pub fn getResource(self: *Self, comptime T: type) ?*T {
            return self.resources.get(T);
        }

        /// Get a const resource pointer. Returns null if not initialized.
        pub fn getResourceConst(self: *const Self, comptime T: type) ?*const T {
            return self.resources.getConst(T);
        }

        /// Insert or replace a resource value. Returns true if it replaced an existing value.
        pub fn insertResource(self: *Self, comptime T: type, value: T) bool {
            return self.resources.insert(T, value);
        }

        /// Remove a resource. Returns true if it was initialized.
        pub fn removeResource(self: *Self, comptime T: type) bool {
            return self.resources.remove(T);
        }

        /// Check if a resource is initialized.
        pub fn hasResource(self: *const Self, comptime T: type) bool {
            return self.resources.has(T);
        }

        /// Get the number of entities in a specific archetype.
        pub fn archetypeEntityCount(self: *const Self, comptime name: []const u8) usize {
            const idx = comptime archIndex(name);
            return self.storage[idx].len();
        }

        // ====================================================================
        // Debug and Introspection
        // ====================================================================

        /// Get total entity count across all archetypes.
        pub fn totalStoredEntities(self: *const Self) usize {
            var total: usize = 0;
            inline for (0..archetype_count) |i| {
                total += self.storage[i].len();
            }
            return total;
        }

        /// Verify world invariants (debug mode only).
        pub fn verify(self: *const Self) bool {
            if (!self.debug_asserts_enabled) return true;

            // Check entity count consistency
            const manager_count = self.entities.count();
            const storage_count = self.totalStoredEntities();

            if (manager_count != storage_count) {
                return false;
            }

            return true;
        }

        // ====================================================================
        // Archetype Transitions
        // ====================================================================

        /// Error returned when no valid transition archetype exists.
        pub const TransitionError = error{
            /// No archetype exists with the required component set.
            NoValidTransition,
            /// Entity handle is invalid or stale.
            InvalidEntity,
            /// Memory allocation failed during transition.
            OutOfMemory,
            /// Entity already has the component (for addComponent).
            ComponentAlreadyExists,
            /// Entity doesn't have the component (for removeComponent).
            ComponentNotFound,
        };

        /// Add a component to an entity, moving it to a new archetype.
        /// The target archetype must exist in the WorldConfig and have all
        /// the entity's current components plus the new component T.
        ///
        /// Precondition: Entity must be alive and not already have component T.
        /// Postcondition: Entity moves to target archetype with new component.
        pub fn addComponent(self: *Self, handle: WorldEntityHandle, comptime T: type, value: T) TransitionError!void {
            // Compile-time check: at least one valid transition must exist
            comptime {
                if (findAdditionTarget(T) == null) {
                    @compileError("No archetype exists that adds component " ++ @typeName(T) ++ " to any source archetype");
                }
            }

            // Get entity metadata
            const meta = self.entities.getMetadata(handle) orelse return TransitionError.InvalidEntity;

            const source_arch_idx = meta.archetype_index;

            // Check if entity already has this component and find the valid target
            // We need to check all targets for EACH source archetype
            inline for (0..archetype_count) |src_idx| {
                if (source_arch_idx == src_idx) {
                    // Check if source already has T
                    if (archetypeHasComponent(src_idx, T)) {
                        return TransitionError.ComponentAlreadyExists;
                    }

                    // Find the target archetype that matches: src + T
                    inline for (0..archetype_count) |tgt_idx| {
                        if (isValidAdditionTransition(src_idx, tgt_idx, T)) {
                            // Found valid target - perform transition
                            try self.performTransition(handle, meta.*, source_arch_idx, tgt_idx, T, value);
                            return;
                        }
                    }

                    // No valid target found for this source
                    return TransitionError.NoValidTransition;
                }
            }

            // Source archetype not found (shouldn't happen with valid entity)
            return TransitionError.InvalidEntity;
        }

        /// Remove a component from an entity, moving it to a simpler archetype.
        /// The target archetype must exist in the WorldConfig and have all
        /// the entity's current components minus the removed component T.
        ///
        /// Precondition: Entity must be alive and have component T.
        /// Postcondition: Entity moves to target archetype without component T.
        pub fn removeComponent(self: *Self, handle: WorldEntityHandle, comptime T: type) TransitionError!void {
            // Compile-time check: at least one valid transition must exist
            comptime {
                if (findRemovalTarget(T) == null) {
                    @compileError("No archetype exists that removes component " ++ @typeName(T) ++ " from any source archetype");
                }
            }

            // Get entity metadata
            const meta = self.entities.getMetadata(handle) orelse return TransitionError.InvalidEntity;

            const source_arch_idx = meta.archetype_index;

            // Check if entity has this component and find the valid target
            inline for (0..archetype_count) |src_idx| {
                if (source_arch_idx == src_idx) {
                    // Check if source has T
                    if (!archetypeHasComponent(src_idx, T)) {
                        return TransitionError.ComponentNotFound;
                    }

                    // Find the target archetype that matches: src - T
                    inline for (0..archetype_count) |tgt_idx| {
                        if (isValidRemovalTransition(src_idx, tgt_idx, T)) {
                            // Found valid target - perform transition
                            try self.performTransitionRemoval(handle, meta.*, source_arch_idx, tgt_idx, T);
                            return;
                        }
                    }

                    // No valid target found for this source
                    return TransitionError.NoValidTransition;
                }
            }

            // Source archetype not found (shouldn't happen with valid entity)
            return TransitionError.InvalidEntity;
        }

        /// Internal: Perform a component addition transition.
        fn performTransition(
            self: *Self,
            handle: WorldEntityHandle,
            meta: Entities.EntityMetadataT,
            source_arch_idx: u16,
            target_arch_idx: usize,
            comptime NewComponent: type,
            new_value: NewComponent,
        ) TransitionError!void {
            const source_row = meta.archetype_row;

            // This needs to be done with inline for to access the correct table types
            inline for (0..archetype_count) |src_i| {
                if (source_arch_idx == src_i) {
                    inline for (0..archetype_count) |tgt_i| {
                        if (target_arch_idx == tgt_i) {
                            const source_table = &self.storage[src_i];
                            const target_table = &self.storage[tgt_i];

                            // Build component tuple for target archetype
                            const TargetComponents = cfg.archetypes.archetypes[tgt_i].components;
                            var components: ComponentTuple(TargetComponents) = undefined;

                            // Copy existing components from source
                            inline for (TargetComponents, 0..) |CompType, comp_idx| {
                                if (CompType == NewComponent) {
                                    components[comp_idx] = new_value;
                                } else {
                                    // Copy from source
                                    const src_ptr = source_table.getComponentConst(CompType, source_row);
                                    if (src_ptr) |ptr| {
                                        components[comp_idx] = ptr.*;
                                    }
                                }
                            }

                            // Add to target archetype
                            const new_row = target_table.addEntity(handle.toId(), components) catch {
                                return TransitionError.OutOfMemory;
                            };

                            // Remove from source archetype
                            const moved_entity = source_table.removeEntityByRow(source_row);

                            // Update moved entity's metadata if swap-remove moved another entity
                            if (moved_entity) |moved_id| {
                                self.updateMovedEntityMetadata(moved_id, src_i, source_row);
                            }

                            // Update this entity's metadata
                            _ = self.entities.setLocation(handle, @intCast(tgt_i), new_row);
                            return;
                        }
                    }
                }
            }
        }

        /// Internal: Perform a component removal transition.
        fn performTransitionRemoval(
            self: *Self,
            handle: WorldEntityHandle,
            meta: Entities.EntityMetadataT,
            source_arch_idx: u16,
            target_arch_idx: usize,
            comptime RemovedComponent: type,
        ) TransitionError!void {
            const source_row = meta.archetype_row;

            inline for (0..archetype_count) |src_i| {
                if (source_arch_idx == src_i) {
                    inline for (0..archetype_count) |tgt_i| {
                        if (target_arch_idx == tgt_i) {
                            const source_table = &self.storage[src_i];
                            const target_table = &self.storage[tgt_i];

                            // Build component tuple for target archetype (excluding removed component)
                            const TargetComponents = cfg.archetypes.archetypes[tgt_i].components;
                            var components: ComponentTuple(TargetComponents) = undefined;

                            // Copy components that exist in target (all except RemovedComponent)
                            inline for (TargetComponents, 0..) |CompType, comp_idx| {
                                if (CompType != RemovedComponent) {
                                    const src_ptr = source_table.getComponentConst(CompType, source_row);
                                    if (src_ptr) |ptr| {
                                        components[comp_idx] = ptr.*;
                                    }
                                }
                            }

                            // Add to target archetype
                            const new_row = target_table.addEntity(handle.toId(), components) catch {
                                return TransitionError.OutOfMemory;
                            };

                            // Remove from source archetype
                            const moved_entity = source_table.removeEntityByRow(source_row);

                            // Update moved entity's metadata if swap-remove moved another entity
                            if (moved_entity) |moved_id| {
                                self.updateMovedEntityMetadata(moved_id, src_i, source_row);
                            }

                            // Update this entity's metadata
                            _ = self.entities.setLocation(handle, @intCast(tgt_i), new_row);
                            return;
                        }
                    }
                }
            }
        }

        /// Helper to update metadata for an entity that was moved by swap-remove.
        /// The moved_id contains the index directly into the metadata array.
        fn updateMovedEntityMetadata(self: *Self, moved_id: EntityId, arch_idx: usize, new_row: u32) void {
            _ = arch_idx; // Not needed - we use moved_id.index directly

            // The moved_id.index is the direct index into the metadata array
            const meta_index = moved_id.index;
            if (meta_index < self.entities.metadata.len) {
                self.entities.metadata[meta_index].archetype_row = new_row;
            }
        }

        /// Comptime helper: check if an archetype has a component type.
        fn archetypeHasComponent(comptime arch_idx: usize, comptime T: type) bool {
            const components = cfg.archetypes.archetypes[arch_idx].components;
            inline for (components) |C| {
                if (C == T) return true;
            }
            return false;
        }

        /// Comptime helper: find any archetype that can be the target of adding component T.
        fn findAdditionTarget(comptime T: type) ?usize {
            // Find an archetype that has T and for which there exists a source without T
            for (0..archetype_count) |tgt_idx| {
                if (archetypeHasComponent(tgt_idx, T)) {
                    // Check if any source archetype can transition here
                    for (0..archetype_count) |src_idx| {
                        if (isValidAdditionTransition(src_idx, tgt_idx, T)) {
                            return tgt_idx;
                        }
                    }
                }
            }
            return null;
        }

        /// Comptime helper: find any archetype that can be the target of removing component T.
        fn findRemovalTarget(comptime T: type) ?usize {
            // Find an archetype without T and for which there exists a source with T
            for (0..archetype_count) |tgt_idx| {
                if (!archetypeHasComponent(tgt_idx, T)) {
                    // Check if any source archetype can transition here
                    for (0..archetype_count) |src_idx| {
                        if (isValidRemovalTransition(src_idx, tgt_idx, T)) {
                            return tgt_idx;
                        }
                    }
                }
            }
            return null;
        }

        /// Comptime helper: check if adding T to source results in target's component set.
        fn isValidAdditionTransition(comptime src_idx: usize, comptime tgt_idx: usize, comptime T: type) bool {
            const src_components = cfg.archetypes.archetypes[src_idx].components;
            const tgt_components = cfg.archetypes.archetypes[tgt_idx].components;

            // Source must not have T
            inline for (src_components) |C| {
                if (C == T) return false;
            }

            // Target must have T
            var target_has_t = false;
            inline for (tgt_components) |C| {
                if (C == T) target_has_t = true;
            }
            if (!target_has_t) return false;

            // Target must have exactly source components + T
            // Check that target has all source components
            inline for (src_components) |src_c| {
                var found = false;
                inline for (tgt_components) |tgt_c| {
                    if (src_c == tgt_c) found = true;
                }
                if (!found) return false;
            }

            // Check that target has exactly len(source) + 1 components
            if (tgt_components.len != src_components.len + 1) return false;

            return true;
        }

        /// Comptime helper: check if removing T from source results in target's component set.
        fn isValidRemovalTransition(comptime src_idx: usize, comptime tgt_idx: usize, comptime T: type) bool {
            const src_components = cfg.archetypes.archetypes[src_idx].components;
            const tgt_components = cfg.archetypes.archetypes[tgt_idx].components;

            // Source must have T
            var source_has_t = false;
            inline for (src_components) |C| {
                if (C == T) source_has_t = true;
            }
            if (!source_has_t) return false;

            // Target must not have T
            inline for (tgt_components) |C| {
                if (C == T) return false;
            }

            // Target must have exactly source components - T
            // Check that all target components exist in source
            inline for (tgt_components) |tgt_c| {
                var found = false;
                inline for (src_components) |src_c| {
                    if (src_c == tgt_c) found = true;
                }
                if (!found) return false;
            }

            // Check that target has exactly len(source) - 1 components
            if (tgt_components.len != src_components.len - 1) return false;

            return true;
        }

        /// Generate a tuple type for holding component values.
        /// Uses @Tuple for Zig 0.16 compatibility.
        fn ComponentTuple(comptime components: []const type) type {
            return @Tuple(components);
        }

        // ====================================================================
        // Helpers
        // ====================================================================

        /// Get archetype index by name at compile time.
        fn archIndex(comptime name: []const u8) u16 {
            inline for (0..archetype_count) |i| {
                // Compare using the stored field names which match the config names
                if (std.mem.eql(u8, archetype_field_names[i], name)) {
                    return @intCast(i);
                }
            }
            @compileError("Archetype '" ++ name ++ "' not found in WorldConfig");
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "World basic creation" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        } },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = World(cfg);
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    try std.testing.expectEqual(@as(u32, 0), world.entityCount());
}

test "World spawn and despawn" {
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = World(cfg);
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    // Spawn entity
    const e1 = try world.spawn("static", .{Position{ .x = 10.0, .y = 20.0 }});
    try std.testing.expectEqual(@as(u32, 1), world.entityCount());
    try std.testing.expect(world.isAlive(e1));

    // Get component
    const pos = world.getComponent(e1, Position).?;
    try std.testing.expectEqual(@as(f32, 10.0), pos.x);
    try std.testing.expectEqual(@as(f32, 20.0), pos.y);

    // Despawn
    try world.despawn(e1);
    try std.testing.expectEqual(@as(u32, 0), world.entityCount());
    try std.testing.expect(!world.isAlive(e1));
}

test "World query iteration" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        } },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = World(cfg);
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    // Spawn some entities
    _ = try world.spawn("moving", .{
        Position{ .x = 1.0, .y = 2.0 },
        Velocity{ .dx = 0.1, .dy = 0.2 },
    });
    _ = try world.spawn("moving", .{
        Position{ .x = 3.0, .y = 4.0 },
        Velocity{ .dx = 0.3, .dy = 0.4 },
    });

    // Query with read access to Position
    const Q = Query(.{ .read = &.{Position} });
    var iter = world.query(Q);

    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(u32, 2), count);
}

test "World component modification" {
    const Value = struct { v: i32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Value} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "data", .components = &.{Value} },
        } },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = World(cfg);
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn("data", .{Value{ .v = 42 }});

    // Modify via pointer
    const ptr = world.getComponentMut(e, Value).?;
    ptr.v = 100;

    // Verify change
    try std.testing.expectEqual(@as(i32, 100), world.getComponent(e, Value).?.v);

    // Modify via setComponent
    try std.testing.expect(world.setComponent(e, Value, .{ .v = 200 }));
    try std.testing.expectEqual(@as(i32, 200), world.getComponent(e, Value).?.v);
}

test "World: despawn swap-remove metadata correctness" {
    // Regression test for P1-DESPAWN bug fix
    // When despawning an entity in the middle, swap-remove moves the last entity
    // into the vacated slot. The moved entity's metadata must be updated correctly.
    const Position = struct { x: f32, y: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Position} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
        } },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = World(cfg);
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    // Spawn 3 entities: e1, e2, e3 (in that order)
    // Storage layout: [e1:row0, e2:row1, e3:row2]
    const e1 = try world.spawn("static", .{Position{ .x = 1.0, .y = 1.0 }});
    const e2 = try world.spawn("static", .{Position{ .x = 2.0, .y = 2.0 }});
    const e3 = try world.spawn("static", .{Position{ .x = 3.0, .y = 3.0 }});

    try std.testing.expectEqual(@as(u32, 3), world.entityCount());

    // Verify initial positions
    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);
    try std.testing.expectEqual(@as(f32, 2.0), world.getComponent(e2, Position).?.x);
    try std.testing.expectEqual(@as(f32, 3.0), world.getComponent(e3, Position).?.x);

    // Despawn e2 - this triggers swap-remove
    // e3 (last) should be moved into e2's slot (row 1)
    // Storage layout after: [e1:row0, e3:row1]
    try world.despawn(e2);

    // Tiger Style: Postcondition assertions
    try std.testing.expectEqual(@as(u32, 2), world.entityCount());

    // e2 is now invalid
    try std.testing.expect(!world.isAlive(e2));
    try std.testing.expectEqual(@as(?*const Position, null), world.getComponent(e2, Position));

    // CRITICAL: e3 must still be accessible with correct data
    // This is the core regression test - if metadata update is wrong, this fails
    try std.testing.expect(world.isAlive(e3));
    const e3_pos = world.getComponent(e3, Position);
    try std.testing.expect(e3_pos != null);
    try std.testing.expectEqual(@as(f32, 3.0), e3_pos.?.x);
    try std.testing.expectEqual(@as(f32, 3.0), e3_pos.?.y);

    // e1 should be unchanged
    try std.testing.expect(world.isAlive(e1));
    try std.testing.expectEqual(@as(f32, 1.0), world.getComponent(e1, Position).?.x);

    // Verify world consistency
    try std.testing.expect(world.verify());
}

test "World: despawn first entity swap-remove" {
    // Test despawning the first entity to verify edge case handling
    const Health = struct { hp: i32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Health} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "units", .components = &.{Health} },
        } },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = World(cfg);
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    // Spawn 3 entities
    const e1 = try world.spawn("units", .{Health{ .hp = 100 }});
    const e2 = try world.spawn("units", .{Health{ .hp = 200 }});
    const e3 = try world.spawn("units", .{Health{ .hp = 300 }});

    // Despawn first entity - e3 moves to row 0
    try world.despawn(e1);

    try std.testing.expectEqual(@as(u32, 2), world.entityCount());
    try std.testing.expect(!world.isAlive(e1));

    // e2 and e3 should still be accessible with correct data
    try std.testing.expect(world.isAlive(e2));
    try std.testing.expect(world.isAlive(e3));
    try std.testing.expectEqual(@as(i32, 200), world.getComponent(e2, Health).?.hp);
    try std.testing.expectEqual(@as(i32, 300), world.getComponent(e3, Health).?.hp);

    // Verify world consistency
    try std.testing.expect(world.verify());
}

test "World: despawn last entity no swap" {
    // Test despawning the last entity - no swap should occur
    const Tag = struct { id: u32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Tag} },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "tagged", .components = &.{Tag} },
        } },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = World(cfg);
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    // Spawn 3 entities
    const e1 = try world.spawn("tagged", .{Tag{ .id = 1 }});
    const e2 = try world.spawn("tagged", .{Tag{ .id = 2 }});
    const e3 = try world.spawn("tagged", .{Tag{ .id = 3 }});

    // Despawn last entity - no swap needed
    try world.despawn(e3);

    try std.testing.expectEqual(@as(u32, 2), world.entityCount());
    try std.testing.expect(!world.isAlive(e3));

    // e1 and e2 should be unchanged
    try std.testing.expect(world.isAlive(e1));
    try std.testing.expect(world.isAlive(e2));
    try std.testing.expectEqual(@as(u32, 1), world.getComponent(e1, Tag).?.id);
    try std.testing.expectEqual(@as(u32, 2), world.getComponent(e2, Tag).?.id);

    // Verify world consistency
    try std.testing.expect(world.verify());
}
