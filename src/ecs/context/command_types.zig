//! Command Types for Deferred Operations
//!
//! This module defines the command types used for deferred entity operations.
//! Commands are queued during system execution and applied after iteration
//! to avoid iterator invalidation.

const entity_mod = @import("../world/entity.zig");
const EntityHandle = entity_mod.EntityHandle;

// ============================================================================
// Constants
// ============================================================================

/// Default maximum size for inline component data in commands.
/// Tiger Style: Override via Options.max_component_data_size in config.
pub const DEFAULT_MAX_COMPONENT_DATA_SIZE: u32 = 256;

// ============================================================================
// Command Type Definitions
// ============================================================================

/// A deferred command to be executed after system iteration.
/// Tiger Style: Data size is configurable via CommandType().
pub fn CommandType(comptime max_data_size: u32) type {
    return union(enum) {
        const Self = @This();

        /// Maximum inline data size for this command type.
        pub const max_component_data_size = max_data_size;

        /// Spawn an entity in a named archetype with component data.
        spawn: SpawnCommandType(max_data_size),
        /// Despawn an entity.
        despawn: EntityHandle,
        /// Set a component value on an entity.
        set_component: SetComponentCommandType(max_data_size),
        /// Custom user command (id + optional data pointer).
        custom: CustomCommand,
    };
}

/// Spawn command with configurable data size.
pub fn SpawnCommandType(comptime max_data_size: u32) type {
    return struct {
        archetype_index: u16,
        /// Packed component data (layout depends on archetype).
        data: [max_data_size]u8 = .{0} ** max_data_size,
        data_size: usize = 0,
    };
}

/// Set component command with configurable data size.
pub fn SetComponentCommandType(comptime max_data_size: u32) type {
    return struct {
        entity: EntityHandle,
        component_id: u32,
        data: [max_data_size]u8 = .{0} ** max_data_size,
        size: usize = 0,
    };
}

/// Custom command type (size-independent).
pub const CustomCommand = struct {
    id: u32,
    data: ?*anyopaque = null,
};

/// Legacy type alias for backward compatibility with default size.
pub const Command = CommandType(DEFAULT_MAX_COMPONENT_DATA_SIZE);

// ============================================================================
// Helper Functions
// ============================================================================

/// Generate a unique component type ID at compile time.
pub fn componentTypeId(comptime T: type) u32 {
    // Use type name hash as a simple component ID
    const name = @typeName(T);
    var hash: u32 = 0;
    for (name) |c| {
        hash = hash *% 31 +% c;
    }
    return hash;
}
