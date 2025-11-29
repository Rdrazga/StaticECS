//! World Type Generator
//!
//! This module provides the `World(config)` function that generates a
//! concrete World type specialized for a given `WorldConfig`. The generated
//! type includes entity management, archetype storage, and query APIs.
//!
//! Implementation is decomposed into focused helper functions (≤70 lines each)
//! for Tiger_Style compliance.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const WorldConfig = config_mod.WorldConfig;
const WorldConfigView = config_mod.WorldConfigView;
const validateWorldConfig = config_mod.validateWorldConfig;
const LayoutMode = config_mod.LayoutMode;
const CapacityMode = config_mod.CapacityMode;

const system_context_mod = @import("system_context.zig");

const entity_mod = @import("world/entity.zig");
const EntityIdType = entity_mod.EntityIdType;
const EntityHandleType = entity_mod.EntityHandleType;
const EntityManagerType = entity_mod.EntityManagerType;
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
    CapacityExhausted,
    InvalidEntity,
    ArchetypeNotFound,
    ComponentNotFound,
    OutOfMemory,
};

/// Transition error types (shared by all World instances).
pub const TransitionError = error{
    NoValidTransition,
    InvalidEntity,
    OutOfMemory,
    ComponentAlreadyExists,
    ComponentNotFound,
};

// ============================================================================
// Comptime Helper Builders (Pure Functions)
// ============================================================================

/// Build archetype table types array from config.
/// Uses capacity_mode from config and determines max_capacity from:
/// - expected_entities_per_archetype if set (>0)
/// - Otherwise max_entities
fn buildArchetypeTables(comptime cfg: WorldConfig) [cfg.archetypes.archetypes.len]type {
    const capacity_mode = cfg.options.capacity_mode;
    const max_capacity: u32 = if (cfg.options.expected_entities_per_archetype > 0)
        cfg.options.expected_entities_per_archetype
    else
        cfg.options.max_entities;

    var tables: [cfg.archetypes.archetypes.len]type = undefined;
    for (cfg.archetypes.archetypes, 0..) |arch_def, i| {
        tables[i] = ArchetypeTable(arch_def.components, capacity_mode, max_capacity);
    }
    return tables;
}

/// Build archetype field names array from config (10 lines)
fn buildArchetypeFieldNames(comptime cfg: WorldConfig) [cfg.archetypes.archetypes.len][:0]const u8 {
    var names: [cfg.archetypes.archetypes.len][:0]const u8 = undefined;
    for (cfg.archetypes.archetypes, 0..) |arch, i| {
        names[i] = arch.name;
    }
    return names;
}

/// Get archetype index by name at compile time (12 lines)
fn getArchetypeIndex(
    comptime archetype_count: usize,
    comptime field_names: [archetype_count][:0]const u8,
    comptime name: []const u8,
) u16 {
    inline for (0..archetype_count) |i| {
        if (std.mem.eql(u8, field_names[i], name)) {
            return @intCast(i);
        }
    }
    @compileError("Archetype '" ++ name ++ "' not found in WorldConfig");
}

// ============================================================================
// Transition Comptime Helpers (65 lines)
// ============================================================================

/// Check if an archetype has a component type.
fn archetypeHasComponentComptime(comptime cfg: WorldConfig, comptime arch_idx: usize, comptime T: type) bool {
    const components = cfg.archetypes.archetypes[arch_idx].components;
    inline for (components) |C| {
        if (C == T) return true;
    }
    return false;
}

/// Check if adding T to source results in target's component set.
fn isValidAdditionTransitionComptime(comptime cfg: WorldConfig, comptime src_idx: usize, comptime tgt_idx: usize, comptime T: type) bool {
    const src_components = cfg.archetypes.archetypes[src_idx].components;
    const tgt_components = cfg.archetypes.archetypes[tgt_idx].components;

    inline for (src_components) |C| {
        if (C == T) return false;
    }

    var target_has_t = false;
    inline for (tgt_components) |C| {
        if (C == T) target_has_t = true;
    }
    if (!target_has_t) return false;

    inline for (src_components) |src_c| {
        var found = false;
        inline for (tgt_components) |tgt_c| {
            if (src_c == tgt_c) found = true;
        }
        if (!found) return false;
    }

    if (tgt_components.len != src_components.len + 1) return false;
    return true;
}

/// Check if removing T from source results in target's component set.
fn isValidRemovalTransitionComptime(comptime cfg: WorldConfig, comptime src_idx: usize, comptime tgt_idx: usize, comptime T: type) bool {
    const src_components = cfg.archetypes.archetypes[src_idx].components;
    const tgt_components = cfg.archetypes.archetypes[tgt_idx].components;

    var source_has_t = false;
    inline for (src_components) |C| {
        if (C == T) source_has_t = true;
    }
    if (!source_has_t) return false;

    inline for (tgt_components) |C| {
        if (C == T) return false;
    }

    inline for (tgt_components) |tgt_c| {
        var found = false;
        inline for (src_components) |src_c| {
            if (src_c == tgt_c) found = true;
        }
        if (!found) return false;
    }

    if (tgt_components.len != src_components.len - 1) return false;
    return true;
}

/// Find any archetype that can be the target of adding component T.
fn findAdditionTargetComptime(comptime cfg: WorldConfig, comptime T: type) ?usize {
    const archetype_count = cfg.archetypes.archetypes.len;
    for (0..archetype_count) |tgt_idx| {
        if (archetypeHasComponentComptime(cfg, tgt_idx, T)) {
            for (0..archetype_count) |src_idx| {
                if (isValidAdditionTransitionComptime(cfg, src_idx, tgt_idx, T)) {
                    return tgt_idx;
                }
            }
        }
    }
    return null;
}

/// Find any archetype that can be the target of removing component T.
fn findRemovalTargetComptime(comptime cfg: WorldConfig, comptime T: type) ?usize {
    const archetype_count = cfg.archetypes.archetypes.len;
    for (0..archetype_count) |tgt_idx| {
        if (!archetypeHasComponentComptime(cfg, tgt_idx, T)) {
            for (0..archetype_count) |src_idx| {
                if (isValidRemovalTransitionComptime(cfg, src_idx, tgt_idx, T)) {
                    return tgt_idx;
                }
            }
        }
    }
    return null;
}

// ============================================================================
// Query Iterator Builder (65 lines)
// ============================================================================

/// Build query iterator type for given world and query spec.
fn QueryIteratorBuilder(comptime WorldType: type, comptime cfg: WorldConfig, comptime Spec: type) type {
    const N = cfg.archetypes.archetypes.len;
    const R = query_mod.QueryResult(Spec);
    return struct {
        const QI = @This();
        const matches = blk: {
            var r: [N]bool = undefined;
            for (0..N) |i| r[i] = Spec.matchesArchetype(cfg.archetypes.archetypes[i].components);
            break :blk r;
        };
        world: *WorldType,
        arch: usize,
        row: u32,
        pub fn init(w: *WorldType) QI {
            return .{ .world = w, .arch = 0, .row = 0 };
        }
        pub fn next(self: *QI) ?R {
            while (self.arch < N) {
                if (matches[self.arch]) {
                    const len = self.getLen();
                    if (self.row < len) {
                        const r = self.build();
                        self.row += 1;
                        return r;
                    }
                }
                self.arch += 1;
                self.row = 0;
            }
            return null;
        }
        fn getLen(self: *QI) u32 {
            inline for (0..N) |i| if (self.arch == i) return @intCast(self.world.storage[i].len());
            return 0;
        }
        fn build(self: *QI) R {
            var r: R = undefined;
            inline for (0..N) |i| if (self.arch == i) {
                const t = &self.world.storage[i];
                const ac = cfg.archetypes.archetypes[i].components;
                r.entity_id = t.getEntityId(self.row).?;
                inline for (0..Spec.read_components.len) |ri| r.read[ri] = t.getComponentConst(Spec.read_components[ri], self.row).?;
                inline for (0..Spec.write_components.len) |wi| r.write[wi] = t.getComponent(Spec.write_components[wi], self.row).?;
                inline for (0..Spec.optional_components.len) |oi| {
                    const OT = Spec.optional_components[oi];
                    r.optional[oi] = if (Spec.archetypeHasOptional(ac, OT)) t.getComponentConst(OT, self.row) else null;
                }
                return r;
            };
            unreachable;
        }
        pub fn reset(self: *QI) void {
            self.arch = 0;
            self.row = 0;
        }
    };
}

// ============================================================================
// Main World Type Generator (70 lines - Tiger_Style compliant)
// ============================================================================

/// Generate a concrete World type from a compile-time WorldConfig.
pub fn World(comptime cfg: WorldConfig) type {
    comptime validateWorldConfig(cfg);
    comptime if (cfg.options.core_version) |p| if (!version_mod.checkVersionCompatibility(
        .{ .major = p.major, .minor = p.minor, .patch = p.patch },
    )) @compileError("WorldConfig core_version is incompatible with current ECS version");

    const N = cfg.archetypes.archetypes.len;
    const Tables = buildArchetypeTables(cfg);
    const Names = buildArchetypeFieldNames(cfg);

    return struct {
        const Self = @This();
        pub const config: WorldConfig = cfg;
        pub const config_view: WorldConfigView = WorldConfigView.init(cfg);
        pub const max_entities = cfg.options.max_entities;
        pub const entity_index_bits = cfg.options.entity_index_bits;
        pub const expected_per_archetype = cfg.options.expected_entities_per_archetype;
        pub const WorldEntityId = EntityIdType(entity_index_bits);
        pub const WorldEntityHandle = EntityHandleType(entity_index_bits);
        pub const Entities = EntityManagerType(max_entities, entity_index_bits);
        pub const ResourceStorage = system_context_mod.Resources(cfg.resources.types);
        pub const Storage = @Tuple(&Tables);
        pub const TransitionError = error{ NoValidTransition, InvalidEntity, OutOfMemory, ComponentAlreadyExists, ComponentNotFound };
        entities: Entities,
        storage: Storage,
        resources: ResourceStorage,
        allocator: Allocator,
        debug_asserts_enabled: bool,
        pub fn archIndex(comptime name: []const u8) u16 {
            return getArchetypeIndex(N, Names, name);
        }
        pub fn init(alloc: Allocator) Self {
            return initWorldImpl(Self, cfg, Tables, alloc);
        }
        pub fn deinit(self: *Self) void {
            inline for (0..N) |i| self.storage[i].deinit();
        }
        pub const spawn = EntityApiImpl(Self, cfg).spawn;
        pub const despawn = EntityApiImpl(Self, cfg).despawn;
        pub const isAlive = EntityStatusImpl(Self).isAlive;
        pub const entityCount = EntityStatusImpl(Self).entityCount;
        pub const getComponent = ComponentApiImpl(Self, cfg).getComponent;
        pub const getComponentMut = ComponentApiImpl(Self, cfg).getComponentMut;
        pub const setComponent = ComponentApiImpl(Self, cfg).setComponent;
        pub const hasComponent = ComponentApiImpl(Self, cfg).hasComponent;
        pub fn query(self: *Self, comptime Spec: type) QueryIterator(Spec) {
            return QueryIterator(Spec).init(self);
        }
        pub fn QueryIterator(comptime Spec: type) type {
            return QueryIteratorBuilder(Self, cfg, Spec);
        }
        pub const getArchetype = ResourceAccessImpl(Self, Names, N, Tables).getArchetype;
        pub const getResource = ResourceAccessImpl(Self, Names, N, Tables).getResource;
        pub const getResourceConst = ResourceAccessImpl(Self, Names, N, Tables).getResourceConst;
        pub const insertResource = ResourceAccessImpl(Self, Names, N, Tables).insertResource;
        pub const removeResource = ResourceAccessImpl(Self, Names, N, Tables).removeResource;
        pub const hasResource = ResourceAccessImpl(Self, Names, N, Tables).hasResource;
        pub const archetypeEntityCount = ResourceAccessImpl(Self, Names, N, Tables).archetypeEntityCount;
        pub const totalStoredEntities = DebugApiImpl(Self, N).totalStoredEntities;
        pub const verify = DebugApiImpl(Self, N).verify;
        pub const addComponent = TransitionApiImpl(Self, cfg).addComponent;
        pub const removeComponent = TransitionApiImpl(Self, cfg).removeComponent;
        pub const performTransition = TransitionExecutionImpl(Self, cfg).performTransition;
        pub const performTransitionRemoval = TransitionExecutionImpl(Self, cfg).performTransitionRemoval;
        pub const updateMovedEntityMetadata = TransitionExecutionImpl(Self, cfg).updateMovedEntityMetadata;
    };
}

// ============================================================================
// Implementation Helper Builders
// ============================================================================

/// World initialization helper (25 lines)
fn initWorldImpl(
    comptime Self: type,
    comptime cfg: WorldConfig,
    comptime ArchetypeTables: anytype,
    allocator: Allocator,
) Self {
    var storage: Self.Storage = undefined;

    inline for (cfg.archetypes.archetypes, 0..) |arch_def, i| {
        if (Self.expected_per_archetype > 0) {
            storage[i] = ArchetypeTables[i].initWithCapacity(
                allocator,
                arch_def.name,
                Self.expected_per_archetype,
            ) catch |err| switch (err) {
                error.OutOfMemory => @panic("Failed to pre-allocate archetype storage - out of memory"),
            };
        } else {
            storage[i] = ArchetypeTables[i].init(allocator, arch_def.name);
        }
    }

    return .{
        .entities = Self.Entities.init(),
        .storage = storage,
        .resources = Self.ResourceStorage.init(),
        .allocator = allocator,
        .debug_asserts_enabled = cfg.options.enable_debug_asserts,
    };
}

/// Entity spawn/despawn implementation (60 lines)
fn EntityApiImpl(comptime Self: type, comptime cfg: WorldConfig) type {
    const archetype_count = cfg.archetypes.archetypes.len;

    return struct {
        pub fn spawn(self: *Self, comptime archetype_name: []const u8, components: anytype) WorldError!Self.WorldEntityHandle {
            const count_before = if (self.debug_asserts_enabled) self.entityCount() else 0;
            const handle = self.entities.create() orelse return WorldError.CapacityExhausted;
            const arch_index = comptime Self.archIndex(archetype_name);
            const table = &self.storage[arch_index];

            const row = table.addEntity(handle.toId(), components) catch {
                _ = self.entities.destroy(handle);
                return WorldError.OutOfMemory;
            };
            _ = self.entities.setLocation(handle, arch_index, row);

            if (self.debug_asserts_enabled) {
                std.debug.assert(handle.isValid());
                std.debug.assert(self.isAlive(handle));
                std.debug.assert(self.entityCount() == count_before + 1);
            }
            return handle;
        }

        pub fn despawn(self: *Self, handle: Self.WorldEntityHandle) WorldError!void {
            if (self.debug_asserts_enabled) {
                std.debug.assert(handle.isValid());
            }
            const count_before = if (self.debug_asserts_enabled) self.entityCount() else 0;
            const meta = self.entities.getMetadata(handle) orelse return WorldError.InvalidEntity;

            inline for (0..archetype_count) |i| {
                if (meta.archetype_index == i) {
                    const table = &self.storage[i];
                    const moved_entity = table.removeEntityByRow(meta.archetype_row);
                    if (moved_entity) |moved_id| {
                        // Tiger_Style: Convert archetype EntityId to World's handle type for validated access
                        const moved_handle = Self.WorldEntityHandle.fromId(
                            Self.WorldEntityId.init(@intCast(moved_id.index), @intCast(moved_id.generation)),
                        );

                        // Pre-condition: moved entity must be alive with matching generation
                        if (self.debug_asserts_enabled) {
                            std.debug.assert(self.isAlive(moved_handle));
                        }

                        // Tiger_Style: Use generation-validated accessor instead of raw array access
                        // This ensures we don't corrupt data if the slot was recycled
                        var moved_meta = self.entities.getMetadataMut(moved_handle) orelse {
                            // Invariant violation: moved entity metadata not found
                            // This indicates storage corruption - archetype and entity manager are inconsistent
                            @panic("despawn: moved entity metadata not found - storage corruption detected");
                        };

                        std.debug.assert(moved_meta.alive);
                        std.debug.assert(moved_meta.archetype_index == i);
                        moved_meta.archetype_row = meta.archetype_row;

                        // Post-condition: verify metadata update is correct
                        if (self.debug_asserts_enabled) {
                            const updated_meta = self.entities.getMetadata(moved_handle);
                            std.debug.assert(updated_meta != null);
                            std.debug.assert(updated_meta.?.archetype_row == meta.archetype_row);
                        }
                    }
                    break;
                }
            }
            _ = self.entities.destroy(handle);

            if (self.debug_asserts_enabled) {
                std.debug.assert(!self.isAlive(handle));
                std.debug.assert(self.entityCount() == count_before - 1);
            }
        }
    };
}

/// Entity status implementation (10 lines)
fn EntityStatusImpl(comptime Self: type) type {
    return struct {
        pub fn isAlive(self: *const Self, handle: Self.WorldEntityHandle) bool {
            return self.entities.isAlive(handle);
        }

        pub fn entityCount(self: *const Self) u32 {
            return self.entities.count();
        }
    };
}

/// Component API implementation (35 lines)
fn ComponentApiImpl(comptime Self: type, comptime cfg: WorldConfig) type {
    const archetype_count = cfg.archetypes.archetypes.len;

    return struct {
        pub fn getComponent(self: *const Self, handle: Self.WorldEntityHandle, comptime T: type) ?*const T {
            const meta = self.entities.getMetadata(handle) orelse return null;
            inline for (0..archetype_count) |i| {
                if (meta.archetype_index == i) {
                    return self.storage[i].getComponentConst(T, meta.archetype_row);
                }
            }
            return null;
        }

        pub fn getComponentMut(self: *Self, handle: Self.WorldEntityHandle, comptime T: type) ?*T {
            const meta = self.entities.getMetadata(handle) orelse return null;
            inline for (0..archetype_count) |i| {
                if (meta.archetype_index == i) {
                    return self.storage[i].getComponent(T, meta.archetype_row);
                }
            }
            return null;
        }

        pub fn setComponent(self: *Self, handle: Self.WorldEntityHandle, comptime T: type, value: T) bool {
            if (self.getComponentMut(handle, T)) |ptr| {
                ptr.* = value;
                return true;
            }
            return false;
        }

        pub fn hasComponent(self: *const Self, handle: Self.WorldEntityHandle, comptime T: type) bool {
            return self.getComponent(handle, T) != null;
        }
    };
}

/// Resource and archetype access implementation (35 lines)
fn ResourceAccessImpl(
    comptime Self: type,
    comptime field_names: anytype,
    comptime archetype_count: usize,
    comptime ArchetypeTables: anytype,
) type {
    return struct {
        pub fn getArchetype(self: *Self, comptime name: []const u8) *ArchetypeTables[getArchetypeIndex(archetype_count, field_names, name)] {
            const idx = comptime getArchetypeIndex(archetype_count, field_names, name);
            return &self.storage[idx];
        }

        pub fn getResource(self: *Self, comptime T: type) ?*T {
            return self.resources.get(T);
        }

        pub fn getResourceConst(self: *const Self, comptime T: type) ?*const T {
            return self.resources.getConst(T);
        }

        pub fn insertResource(self: *Self, comptime T: type, value: T) bool {
            return self.resources.insert(T, value);
        }

        pub fn removeResource(self: *Self, comptime T: type) bool {
            return self.resources.remove(T);
        }

        pub fn hasResource(self: *const Self, comptime T: type) bool {
            return self.resources.has(T);
        }

        pub fn archetypeEntityCount(self: *const Self, comptime name: []const u8) usize {
            const idx = comptime getArchetypeIndex(archetype_count, field_names, name);
            return self.storage[idx].len();
        }
    };
}

/// Debug API implementation (20 lines)
fn DebugApiImpl(comptime Self: type, comptime archetype_count: usize) type {
    return struct {
        pub fn totalStoredEntities(self: *const Self) usize {
            var total: usize = 0;
            inline for (0..archetype_count) |i| {
                total += self.storage[i].len();
            }
            return total;
        }

        pub fn verify(self: *const Self) bool {
            if (!self.debug_asserts_enabled) return true;
            const manager_count = self.entities.count();
            const storage_count = self.totalStoredEntities();
            return manager_count == storage_count;
        }
    };
}

/// Transition API implementation (55 lines)
fn TransitionApiImpl(comptime Self: type, comptime cfg: WorldConfig) type {
    const archetype_count = cfg.archetypes.archetypes.len;

    return struct {
        pub fn addComponent(self: *Self, handle: Self.WorldEntityHandle, comptime T: type, value: T) TransitionError!void {
            comptime {
                if (findAdditionTargetComptime(cfg, T) == null) {
                    @compileError("No archetype exists that adds component " ++ @typeName(T) ++ " to any source archetype");
                }
            }

            const meta = self.entities.getMetadata(handle) orelse return Self.TransitionError.InvalidEntity;
            const source_arch_idx = meta.archetype_index;

            inline for (0..archetype_count) |src_idx| {
                if (source_arch_idx == src_idx) {
                    if (archetypeHasComponentComptime(cfg, src_idx, T)) {
                        return Self.TransitionError.ComponentAlreadyExists;
                    }
                    inline for (0..archetype_count) |tgt_idx| {
                        if (isValidAdditionTransitionComptime(cfg, src_idx, tgt_idx, T)) {
                            try self.performTransition(handle, meta.*, source_arch_idx, tgt_idx, T, value);
                            return;
                        }
                    }
                    return TransitionError.NoValidTransition;
                }
            }
            return TransitionError.InvalidEntity;
        }

        pub fn removeComponent(self: *Self, handle: Self.WorldEntityHandle, comptime T: type) TransitionError!void {
            comptime {
                if (findRemovalTargetComptime(cfg, T) == null) {
                    @compileError("No archetype exists that removes component " ++ @typeName(T) ++ " from any source archetype");
                }
            }

            const meta = self.entities.getMetadata(handle) orelse return Self.TransitionError.InvalidEntity;
            const source_arch_idx = meta.archetype_index;

            inline for (0..archetype_count) |src_idx| {
                if (source_arch_idx == src_idx) {
                    if (!archetypeHasComponentComptime(cfg, src_idx, T)) {
                        return Self.TransitionError.ComponentNotFound;
                    }
                    inline for (0..archetype_count) |tgt_idx| {
                        if (isValidRemovalTransitionComptime(cfg, src_idx, tgt_idx, T)) {
                            try self.performTransitionRemoval(handle, meta.*, source_arch_idx, tgt_idx, T);
                            return;
                        }
                    }
                    return TransitionError.NoValidTransition;
                }
            }
            return TransitionError.InvalidEntity;
        }
    };
}

/// Transition execution implementation (55 lines)
fn TransitionExecutionImpl(comptime Self: type, comptime cfg: WorldConfig) type {
    const N = cfg.archetypes.archetypes.len;
    return struct {
        pub fn performTransition(self: *Self, handle: Self.WorldEntityHandle, meta: Self.Entities.EntityMetadataT, src_arch: u16, tgt_arch: usize, comptime NewComp: type, new_val: NewComp) TransitionError!void {
            inline for (0..N) |si| if (src_arch == si) {
                inline for (0..N) |ti| if (tgt_arch == ti) {
                    const st = &self.storage[si];
                    const tt = &self.storage[ti];
                    const TC = cfg.archetypes.archetypes[ti].components;
                    var c: @Tuple(TC) = undefined;
                    inline for (TC, 0..) |CT, ci| c[ci] = if (CT == NewComp) new_val else st.getComponentConst(CT, meta.archetype_row).?.*;
                    const nr = tt.addEntity(handle.toId(), c) catch return TransitionError.OutOfMemory;
                    if (st.removeEntityByRow(meta.archetype_row)) |m| self.updateMovedEntityMetadata(m, si, meta.archetype_row);
                    _ = self.entities.setLocation(handle, @intCast(ti), nr);
                    return;
                };
            };
        }
        pub fn performTransitionRemoval(self: *Self, handle: Self.WorldEntityHandle, meta: Self.Entities.EntityMetadataT, src_arch: u16, tgt_arch: usize, comptime RmComp: type) TransitionError!void {
            _ = RmComp; // Target archetype doesn't contain RmComp
            inline for (0..N) |si| if (src_arch == si) {
                inline for (0..N) |ti| if (tgt_arch == ti) {
                    const st = &self.storage[si];
                    const tt = &self.storage[ti];
                    const TC = cfg.archetypes.archetypes[ti].components;
                    var c: @Tuple(TC) = undefined;
                    inline for (TC, 0..) |CT, ci| c[ci] = st.getComponentConst(CT, meta.archetype_row).?.*;
                    const nr = tt.addEntity(handle.toId(), c) catch return TransitionError.OutOfMemory;
                    if (st.removeEntityByRow(meta.archetype_row)) |m| self.updateMovedEntityMetadata(m, si, meta.archetype_row);
                    _ = self.entities.setLocation(handle, @intCast(ti), nr);
                    return;
                };
            };
        }
        pub fn updateMovedEntityMetadata(self: *Self, mid: EntityId, _: usize, nr: u32) void {
            if (mid.index < self.entities.metadata.len) self.entities.metadata[mid.index].archetype_row = nr;
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

    const entity = try world.spawn("static", .{Position{ .x = 1, .y = 2 }});
    try std.testing.expectEqual(@as(u32, 1), world.entityCount());
    try std.testing.expect(world.isAlive(entity));

    try world.despawn(entity);
    try std.testing.expectEqual(@as(u32, 0), world.entityCount());
    try std.testing.expect(!world.isAlive(entity));
}

test "World component access" {
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

    const entity = try world.spawn("static", .{Position{ .x = 1, .y = 2 }});

    const pos = world.getComponent(entity, Position);
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(@as(f32, 1), pos.?.x);
    try std.testing.expectEqual(@as(f32, 2), pos.?.y);

    try std.testing.expect(world.setComponent(entity, Position, .{ .x = 10, .y = 20 }));

    const new_pos = world.getComponent(entity, Position);
    try std.testing.expectEqual(@as(f32, 10), new_pos.?.x);
    try std.testing.expectEqual(@as(f32, 20), new_pos.?.y);

    try std.testing.expect(world.hasComponent(entity, Position));
}

test "World query" {
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

    _ = try world.spawn("static", .{Position{ .x = 1, .y = 2 }});
    _ = try world.spawn("static", .{Position{ .x = 3, .y = 4 }});

    const Q = QuerySpec(&.{Position}, &.{}, &.{}, &.{});
    var q = world.query(Q);

    var count: u32 = 0;
    while (q.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "World archetype transitions" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
        .archetypes = .{ .archetypes = &.{
            .{ .name = "static", .components = &.{Position} },
            .{ .name = "moving", .components = &.{ Position, Velocity } },
        } },
        .options = .{ .max_entities = 100 },
    };

    const TestWorld = World(cfg);
    var world = TestWorld.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn("static", .{Position{ .x = 1, .y = 2 }});
    try std.testing.expect(!world.hasComponent(entity, Velocity));

    try world.addComponent(entity, Velocity, .{ .dx = 5, .dy = 10 });
    try std.testing.expect(world.hasComponent(entity, Velocity));
    try std.testing.expect(world.hasComponent(entity, Position));

    const pos = world.getComponent(entity, Position);
    try std.testing.expectEqual(@as(f32, 1), pos.?.x);
    try std.testing.expectEqual(@as(f32, 2), pos.?.y);

    try world.removeComponent(entity, Velocity);
    try std.testing.expect(!world.hasComponent(entity, Velocity));
    try std.testing.expect(world.hasComponent(entity, Position));
}
