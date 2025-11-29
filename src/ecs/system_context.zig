//! System Context and Command Buffer
//!
//! This module provides the runtime context passed to systems during execution,
//! including access to the world, timing information, and a command buffer
//! for deferred entity operations.
//!
//! The implementation is split across focused modules in context/:
//! - command_types.zig: Command type definitions
//! - command_buffer.zig: Command buffer implementation
//! - concurrent_commands.zig: Thread-safe parallel command buffers
//! - resources.zig: Type-safe resource storage
//! - io_context.zig: I/O capability wrapper

const std = @import("std");
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const WorldConfig = config_mod.WorldConfig;

const entity_mod = @import("world/entity.zig");
const EntityId = entity_mod.EntityId;
const EntityHandle = entity_mod.EntityHandle;

const error_types = @import("error/error_types.zig");
const FrameError = error_types.FrameError;

// ============================================================================
// Re-exports from context/ modules for backwards compatibility
// ============================================================================

// Import the context module
const context = @import("context/mod.zig");

// Command Types
pub const DEFAULT_MAX_COMPONENT_DATA_SIZE = context.DEFAULT_MAX_COMPONENT_DATA_SIZE;
pub const CommandType = context.CommandType;
pub const SpawnCommandType = context.SpawnCommandType;
pub const SetComponentCommandType = context.SetComponentCommandType;
pub const CustomCommand = context.CustomCommand;
pub const Command = context.Command;

// Command Buffer
pub const CommandBufferType = context.CommandBufferType;
pub const CommandBuffer = context.CommandBuffer;

// Concurrent Commands
pub const ConcurrentCommandBuffers = context.ConcurrentCommandBuffers;
pub const ConcurrentCommandBuffersFromConfig = context.ConcurrentCommandBuffersFromConfig;

// Resources
pub const Resources = context.Resources;

// I/O Context
pub const IoContext = context.IoContext;
pub const IoError = context.IoError;
pub const IoBackend = context.IoBackend;
pub const IoBackendError = context.IoBackendError;
pub const BackendOptions = context.BackendOptions;

// Private helper
const componentTypeId = context.componentTypeId;

// ============================================================================
// System Context
// ============================================================================

/// SystemContext is the runtime context passed to system functions.
/// It provides access to the world, timing, commands, resources, and queries.
/// Tiger Style: All bounds come from WorldConfig.options.
pub fn SystemContext(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const max_commands = cfg.options.max_commands_per_frame;
    const max_data_size = cfg.options.max_component_data_size;
    const ResourceTypes = Resources(cfg.resources.types);

    return struct {
        const Self = @This();
        /// Command buffer type with config-based sizing.
        pub const CmdBuf = CommandBufferType(max_commands, max_data_size);
        /// Command type with config-based data size.
        pub const CmdType = CmdBuf.CommandT;
        pub const Config = cfg;
        pub const World = WorldType;

        /// Configuration limits exposed for introspection.
        pub const max_commands_per_frame = max_commands;
        pub const max_component_data_size = max_data_size;

        /// Reference to the world.
        world: *WorldType,

        /// Reference to global resources.
        resources: *ResourceTypes,

        /// Time since last frame in seconds.
        delta_time: f64,

        /// Current tick/frame index.
        tick: u64,

        /// Current time in nanoseconds (from frame start).
        time_ns: u64,

        /// Command buffer for deferred operations.
        commands: *CmdBuf,

        /// User-provided allocator for dynamic allocations.
        allocator: Allocator,

        /// Optional I/O context for async operations.
        /// Null if the system doesn't need I/O or execution model is blocking.
        io: ?*IoContext = null,

        /// Initialize SystemContext with all required fields.
        /// I/O context is optional and defaults to null.
        pub fn init(
            world: *WorldType,
            resources: *ResourceTypes,
            delta_time: f64,
            tick: u64,
            time_ns: u64,
            commands: *CmdBuf,
            allocator: Allocator,
        ) Self {
            return .{
                .world = world,
                .resources = resources,
                .delta_time = delta_time,
                .tick = tick,
                .time_ns = time_ns,
                .commands = commands,
                .allocator = allocator,
                .io = null,
            };
        }

        /// Initialize SystemContext with I/O context.
        /// Use this for systems that have declared needs_io = true.
        pub fn initWithIo(
            world: *WorldType,
            resources: *ResourceTypes,
            delta_time: f64,
            tick: u64,
            time_ns: u64,
            commands: *CmdBuf,
            allocator: Allocator,
            io: *IoContext,
        ) Self {
            return .{
                .world = world,
                .resources = resources,
                .delta_time = delta_time,
                .tick = tick,
                .time_ns = time_ns,
                .commands = commands,
                .allocator = allocator,
                .io = io,
            };
        }

        // ====================================================================
        // I/O Access
        // ====================================================================

        /// Get the I/O context for async operations.
        /// Returns null if I/O is not available.
        /// Use hasIo() first to check availability, or getIoRequired() for systems
        /// that must have I/O support.
        pub fn getIo(self: *Self) ?*IoContext {
            return self.io;
        }

        /// Get the I/O context, asserting it must be available.
        /// Tiger Style: Use this in systems that declared needs_io = true.
        /// Precondition: System was initialized with I/O context.
        pub fn getIoRequired(self: *Self) *IoContext {
            return self.io orelse @panic("System requires I/O but IoContext not available. Ensure needs_io = true in SystemDef.");
        }

        /// Check if I/O context is available.
        pub fn hasIo(self: *const Self) bool {
            return self.io != null;
        }

        /// Check if async operations are supported.
        pub fn hasAsync(self: *const Self) bool {
            if (self.io) |io| {
                return io.supports_async;
            }
            return false;
        }

        /// Check if concurrent async operations are supported.
        pub fn hasConcurrency(self: *const Self) bool {
            if (self.io) |io| {
                return io.supports_concurrency;
            }
            return false;
        }

        // ====================================================================
        // World Access
        // ====================================================================

        /// Spawn an entity in the specified archetype.
        pub fn spawn(self: *Self, comptime archetype_name: []const u8, components: anytype) !EntityHandle {
            return self.world.spawn(archetype_name, components);
        }

        /// Despawn an entity immediately.
        pub fn despawn(self: *Self, handle: EntityHandle) !void {
            return self.world.despawn(handle);
        }

        /// Check if an entity is alive.
        pub fn isAlive(self: *const Self, handle: EntityHandle) bool {
            return self.world.isAlive(handle);
        }

        /// Get the number of alive entities.
        pub fn entityCount(self: *const Self) u32 {
            return self.world.entityCount();
        }

        /// Get a component from an entity.
        pub fn getComponent(self: *const Self, handle: EntityHandle, comptime T: type) ?*const T {
            return self.world.getComponent(handle, T);
        }

        /// Get a mutable component from an entity.
        pub fn getComponentMut(self: *Self, handle: EntityHandle, comptime T: type) ?*T {
            return self.world.getComponentMut(handle, T);
        }

        /// Set a component value on an entity.
        pub fn setComponent(self: *Self, handle: EntityHandle, comptime T: type, value: T) bool {
            return self.world.setComponent(handle, T, value);
        }

        /// Check if an entity has a specific component.
        pub fn hasComponent(self: *const Self, handle: EntityHandle, comptime T: type) bool {
            return self.world.hasComponent(handle, T);
        }

        // ====================================================================
        // Query Access
        // ====================================================================

        /// Create a query iterator for the specified query spec.
        pub fn query(self: *Self, comptime Spec: type) WorldType.QueryIterator(Spec) {
            return self.world.query(Spec);
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

        /// Insert or replace a resource value.
        pub fn insertResource(self: *Self, comptime T: type, value: T) void {
            _ = self.resources.insert(T, value);
        }

        /// Check if a resource is initialized.
        pub fn hasResource(self: *const Self, comptime T: type) bool {
            return self.resources.has(T);
        }

        // ====================================================================
        // Deferred Commands
        // ====================================================================

        /// Queue a deferred despawn.
        pub fn despawnDeferred(self: *Self, handle: EntityHandle) bool {
            return self.commands.despawn(handle);
        }

        /// Queue a deferred spawn for a specific archetype by index.
        pub fn spawnDeferred(self: *Self, archetype_index: u16) bool {
            return self.commands.spawnInArchetype(archetype_index);
        }

        /// Queue a deferred component set operation.
        pub fn setComponentDeferred(self: *Self, handle: EntityHandle, comptime T: type, value: T) bool {
            return self.commands.setComponent(handle, T, value);
        }

        /// Queue a custom command.
        pub fn customCommand(self: *Self, id: u32, data: ?*anyopaque) bool {
            return self.commands.custom(id, data);
        }

        /// Check if command buffer is full.
        pub fn isCommandBufferFull(self: *const Self) bool {
            return self.commands.isFull();
        }
    };
}

// ============================================================================
// System Function Signature
// ============================================================================

/// The standard system function signature.
/// Systems receive a context and return an optional error.
pub fn SystemFn(comptime cfg: WorldConfig, comptime WorldType: type) type {
    const Ctx = SystemContext(cfg, WorldType);
    return *const fn (*Ctx) FrameError!void;
}

// ============================================================================
// Tests - Run tests from extracted modules
// ============================================================================

test {
    // Run all context module tests
    _ = context;
    // Run SystemContext unit tests
    _ = @import("system_context_test.zig");
}
