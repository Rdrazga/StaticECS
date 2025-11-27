//! System Context and Command Buffer
//!
//! This module provides the runtime context passed to systems during execution,
//! including access to the world, timing information, and a command buffer
//! for deferred entity operations.

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
// Deferred Command Types
// ============================================================================

/// Default maximum size for inline component data in commands.
/// Tiger Style: Override via Options.max_component_data_size in config.
pub const DEFAULT_MAX_COMPONENT_DATA_SIZE: u32 = 256;

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

/// Generate a unique component type ID at compile time.
fn componentTypeId(comptime T: type) u32 {
    // Use type name hash as a simple component ID
    const name = @typeName(T);
    var hash: u32 = 0;
    for (name) |c| {
        hash = hash *% 31 +% c;
    }
    return hash;
}

/// Command buffer for collecting deferred operations during system execution.
/// Commands are executed at the end of each stage/phase to avoid iterator invalidation.
/// Tiger Style: All bounds come from config - max_commands and max_component_data_size.
pub fn CommandBufferType(comptime max_commands: usize, comptime max_data_size: u32) type {
    const CmdType = CommandType(max_data_size);
    const SpawnCmd = SpawnCommandType(max_data_size);
    const SetComponentCmd = SetComponentCommandType(max_data_size);

    return struct {
        const Self = @This();

        /// Type of commands stored in this buffer.
        pub const CommandT = CmdType;
        /// Maximum commands this buffer can hold.
        pub const max_command_count = max_commands;
        /// Maximum inline data size for commands.
        pub const max_component_data = max_data_size;

        commands: [max_commands]CmdType = undefined,
        count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn clear(self: *Self) void {
            self.count = 0;
        }

        /// Queue a despawn command.
        pub fn despawn(self: *Self, handle: EntityHandle) bool {
            if (self.count >= max_commands) return false;
            self.commands[self.count] = .{ .despawn = handle };
            self.count += 1;
            return true;
        }

        /// Queue a spawn command for a specific archetype.
        pub fn spawnInArchetype(self: *Self, archetype_index: u16) bool {
            if (self.count >= max_commands) return false;
            self.commands[self.count] = .{
                .spawn = SpawnCmd{
                    .archetype_index = archetype_index,
                },
            };
            self.count += 1;
            return true;
        }

        /// Queue a custom command.
        pub fn custom(self: *Self, id: u32, data: ?*anyopaque) bool {
            if (self.count >= max_commands) return false;
            self.commands[self.count] = .{
                .custom = .{
                    .id = id,
                    .data = data,
                },
            };
            self.count += 1;
            return true;
        }

        /// Queue a deferred component set operation (stores component data inline).
        pub fn setComponent(self: *Self, handle: EntityHandle, comptime T: type, value: T) bool {
            if (@sizeOf(T) > max_data_size) {
                @compileError("Component type exceeds max_component_data_size from config");
            }

            if (self.count >= max_commands) return false;

            var cmd = SetComponentCmd{
                .entity = handle,
                .component_id = componentTypeId(T),
                .data = undefined,
                .size = @sizeOf(T),
            };
            // Copy component data into the fixed-size buffer
            const value_bytes = std.mem.asBytes(&value);
            @memcpy(cmd.data[0..@sizeOf(T)], value_bytes);

            self.commands[self.count] = CmdType{ .set_component = cmd };
            self.count += 1;
            return true;
        }

        /// Get all queued commands.
        pub fn getCommands(self: *const Self) []const CmdType {
            return self.commands[0..self.count];
        }

        /// Check if buffer is full.
        pub fn isFull(self: *const Self) bool {
            return self.count >= max_commands;
        }

        /// Check if buffer has commands.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }
    };
}

/// Legacy CommandBuffer with default component data size.
/// Tiger Style: Prefer CommandBufferType for explicit config-based sizing.
pub fn CommandBuffer(comptime max_commands: usize) type {
    return CommandBufferType(max_commands, DEFAULT_MAX_COMPONENT_DATA_SIZE);
}

// ============================================================================
// Concurrent Command Buffers
// ============================================================================

/// Per-system command buffers for concurrent execution.
///
/// When systems run in parallel (concurrent_threadpool mode), each system
/// gets its own command buffer to avoid data races. After the stage completes,
/// all per-system buffers are merged into the main buffer in deterministic order.
///
/// Tiger Style: Buffer sizes derived from config, divided by max systems.
pub fn ConcurrentCommandBuffers(
    comptime max_systems: usize,
    comptime total_max_commands: usize,
    comptime max_data_size: u32,
) type {
    // Each system gets an equal share of the total command budget
    const commands_per_system = total_max_commands / max_systems;
    const PerSystemBuffer = CommandBufferType(commands_per_system, max_data_size);

    return struct {
        const Self = @This();

        /// Type of per-system buffer.
        pub const BufferType = PerSystemBuffer;
        /// Commands each system can hold.
        pub const commands_per_buffer = commands_per_system;
        /// Maximum number of concurrent systems.
        pub const max_concurrent_systems = max_systems;

        /// Per-system command buffers.
        buffers: [max_systems]PerSystemBuffer = .{PerSystemBuffer.init()} ** max_systems,

        /// Number of systems actively using buffers.
        active_count: u16 = 0,

        /// Initialize concurrent command buffers.
        pub fn init() Self {
            return .{};
        }

        /// Get the command buffer for a specific system index.
        ///
        /// Tiger Style: System index must be < max_systems.
        /// Precondition: system_index < max_concurrent_systems
        pub fn getForSystem(self: *Self, system_index: u16) *PerSystemBuffer {
            std.debug.assert(system_index < max_systems);
            if (system_index >= self.active_count) {
                self.active_count = system_index + 1;
            }
            return &self.buffers[system_index];
        }

        /// Merge all active per-system buffers into a target buffer.
        ///
        /// Commands are merged in system index order for deterministic results.
        /// After merge, all per-system buffers are cleared.
        ///
        /// Returns the number of commands merged, or 0 if target would overflow.
        pub fn mergeInto(self: *Self, target: anytype) usize {
            var merged_count: usize = 0;

            for (0..self.active_count) |i| {
                const src = &self.buffers[i];
                for (src.getCommands()) |cmd| {
                    // Check if target can accept more commands
                    if (target.count >= @TypeOf(target.*).max_command_count) {
                        // Target is full, stop merging
                        self.clearAll();
                        return merged_count;
                    }

                    // Copy command to target
                    target.commands[target.count] = convertCommand(cmd);
                    target.count += 1;
                    merged_count += 1;
                }
                src.clear();
            }

            self.active_count = 0;
            return merged_count;
        }

        /// Clear all per-system buffers.
        pub fn clearAll(self: *Self) void {
            for (0..self.active_count) |i| {
                self.buffers[i].clear();
            }
            self.active_count = 0;
        }

        /// Get total commands across all active buffers.
        pub fn totalCommands(self: *const Self) usize {
            var total: usize = 0;
            for (0..self.active_count) |i| {
                total += self.buffers[i].count;
            }
            return total;
        }

        /// Check if any buffer is approaching capacity.
        pub fn anyNearCapacity(self: *const Self, threshold: usize) bool {
            for (0..self.active_count) |i| {
                if (self.buffers[i].count >= threshold) {
                    return true;
                }
            }
            return false;
        }

        /// Convert command between buffer types (handles different max_data_size).
        fn convertCommand(cmd: PerSystemBuffer.CommandT) @TypeOf(cmd) {
            // Same type, just return as-is
            return cmd;
        }
    };
}

/// Create ConcurrentCommandBuffers type from WorldConfig.
///
/// Usage:
/// ```zig
/// const ConcBufs = ConcurrentCommandBuffersFromConfig(my_config);
/// var concurrent = ConcBufs.init();
/// ```
pub fn ConcurrentCommandBuffersFromConfig(comptime cfg: WorldConfig) type {
    return ConcurrentCommandBuffers(
        cfg.options.max_systems_per_stage,
        cfg.options.max_commands_per_frame,
        cfg.options.max_component_data_size,
    );
}

// ============================================================================
// Resources
// ============================================================================

/// Resources provides access to global singleton data.
/// Resources are stored externally and accessed by type.
/// Each resource is stored by value with an "initialized" flag.
pub fn Resources(comptime resource_types: []const type) type {
    return struct {
        const Self = @This();
        pub const resource_count = resource_types.len;

        // Generate field names at comptime (use r0, r1, r2... for simplicity)
        const field_names = blk: {
            var names: [resource_count][:0]const u8 = undefined;
            for (0..resource_count) |i| {
                names[i] = std.fmt.comptimePrint("r{d}", .{i});
            }
            break :blk names;
        };

        // Generate storage for each resource type using @Tuple for Zig 0.16 compatibility.
        const Storage = if (resource_count == 0) struct {} else @Tuple(resource_types);

        // Initialized flags for each resource (simple bool array).
        const InitFlags = [resource_count]bool;

        storage: Storage,
        initialized: InitFlags,

        pub fn init() Self {
            return .{
                .storage = undefined,
                .initialized = .{false} ** resource_count,
            };
        }

        /// Insert a resource by value, returning true if it replaced an existing value.
        pub fn insert(self: *Self, comptime T: type, value: T) bool {
            const idx = comptime resourceIndex(T);
            const was_initialized = self.initialized[idx];
            self.storage[idx] = value;
            self.initialized[idx] = true;
            return was_initialized;
        }

        /// Get a mutable resource pointer. Returns null if not initialized.
        pub fn get(self: *Self, comptime T: type) ?*T {
            const idx = comptime resourceIndex(T);
            if (!self.initialized[idx]) return null;
            return &self.storage[idx];
        }

        /// Get a const resource pointer. Returns null if not initialized.
        pub fn getConst(self: *const Self, comptime T: type) ?*const T {
            const idx = comptime resourceIndex(T);
            if (!self.initialized[idx]) return null;
            return &self.storage[idx];
        }

        /// Remove a resource, returning true if it was initialized.
        pub fn remove(self: *Self, comptime T: type) bool {
            const idx = comptime resourceIndex(T);
            const was_initialized = self.initialized[idx];
            self.initialized[idx] = false;
            return was_initialized;
        }

        /// Check if a resource is initialized.
        pub fn has(self: *const Self, comptime T: type) bool {
            const idx = comptime resourceIndex(T);
            return self.initialized[idx];
        }

        /// Get the comptime index for a resource type.
        fn resourceIndex(comptime T: type) usize {
            inline for (resource_types, 0..) |RT, i| {
                if (RT == T) return i;
            }
            @compileError("Resource type not found in ResourcesSpec");
        }
    };
}

// ============================================================================
// I/O Context
// ============================================================================

const io_backend = @import("io/io_backend.zig");
pub const IoBackend = io_backend.IoBackend;
pub const IoBackendError = io_backend.IoBackendError;
pub const BackendOptions = io_backend.BackendOptions;

/// Error type for I/O context operations.
pub const IoError = error{
    /// I/O context is not available (blocking execution model).
    IoNotAvailable,
    /// Concurrent async not supported (single-threaded evented model).
    ConcurrencyUnavailable,
};

/// IoContext provides I/O capabilities to systems that need them.
/// This wraps IoBackend to provide async operation scheduling.
///
/// Design follows Zig 0.16 philosophy: "Async is not concurrency"
/// - `scheduleAsync()`: Expresses asynchrony (tasks may complete out of order)
/// - `scheduleConcurrent()`: Requires concurrent execution (may fail if unavailable)
///
/// When IoBackend is not available (blocking execution model), operations either:
/// - Execute synchronously (for `scheduleAsync()`)
/// - Return an error (for `scheduleConcurrent()`)
pub const IoContext = struct {
    const Self = @This();

    /// Pointer to the underlying IoBackend.
    /// Null when in blocking mode (no async support).
    backend: ?*IoBackend = null,

    /// True if this context supports concurrent async operations.
    /// False for blocking and single-threaded evented models.
    supports_concurrency: bool = false,

    /// True if any async capabilities are available.
    /// False only in blocking_single_thread mode.
    supports_async: bool = false,

    /// Create an IoContext for blocking execution (no async support).
    pub fn blocking() Self {
        return .{
            .backend = null,
            .supports_concurrency = false,
            .supports_async = false,
        };
    }

    /// Create an IoContext from an IoBackend.
    /// Automatically determines async/concurrency support from backend capabilities.
    pub fn fromBackend(backend: *IoBackend) Self {
        return .{
            .backend = backend,
            .supports_concurrency = backend.supportsConcurrency(),
            .supports_async = backend.supportsAsync(),
        };
    }

    /// Create an IoContext for evented execution (async but no concurrency).
    /// Deprecated: Use fromBackend() with an evented IoBackend.
    pub fn evented(io_ptr: *anyopaque) Self {
        _ = io_ptr;
        return .{
            .backend = null, // Legacy: will be removed when fully migrated
            .supports_concurrency = false,
            .supports_async = true,
        };
    }

    /// Create an IoContext for concurrent execution (full async + concurrency).
    /// Deprecated: Use fromBackend() with a threadpool IoBackend.
    pub fn concurrent(io_ptr: *anyopaque) Self {
        _ = io_ptr;
        return .{
            .backend = null, // Legacy: will be removed when fully migrated
            .supports_concurrency = true,
            .supports_async = true,
        };
    }

    /// Check if async operations are available.
    pub fn hasAsync(self: *const Self) bool {
        return self.supports_async;
    }

    /// Check if concurrent async operations are available.
    pub fn hasConcurrency(self: *const Self) bool {
        return self.supports_concurrency;
    }

    /// Get the IoBackend for direct access.
    /// Returns null if in blocking mode.
    pub fn getBackend(self: *Self) ?*IoBackend {
        return self.backend;
    }

    /// Schedule an async operation through the backend.
    ///
    /// In blocking mode: Executes immediately and synchronously.
    /// In evented mode: Queues for event loop execution.
    /// In threadpool mode: Queues for parallel execution.
    pub fn scheduleAsync(
        self: *Self,
        comptime callback: anytype,
        context: anytype,
    ) IoBackendError!void {
        if (self.backend) |b| {
            return b.scheduleAsync(callback, context);
        } else {
            // Blocking fallback: execute synchronously
            callback(context);
        }
    }

    /// Schedule an operation that requires concurrent execution.
    ///
    /// Returns error.ConcurrencyUnavailable if backend doesn't support
    /// concurrent execution (blocking or evented mode).
    pub fn scheduleConcurrent(
        self: *Self,
        comptime callback: anytype,
        context: anytype,
    ) IoBackendError!void {
        if (self.backend) |b| {
            return b.scheduleConcurrent(callback, context);
        } else {
            return error.ConcurrencyUnavailable;
        }
    }

    /// Poll for completed operations.
    /// Returns the number of operations completed.
    pub fn poll(self: *Self) u32 {
        if (self.backend) |b| {
            return b.poll();
        }
        return 0;
    }

    /// Poll with timeout.
    /// Blocks up to timeout_ns nanoseconds waiting for events.
    pub fn pollWithTimeout(self: *Self, timeout_ns: u64) u32 {
        if (self.backend) |b| {
            return b.pollWithTimeout(timeout_ns);
        }
        return 0;
    }
};

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
// Tests
// ============================================================================

test "CommandBuffer basic operations" {
    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    try std.testing.expect(buf.isEmpty());
    try std.testing.expect(!buf.isFull());

    const handle = EntityHandle.fromId(EntityId.init(42, 7));
    try std.testing.expect(buf.despawn(handle));
    try std.testing.expect(!buf.isEmpty());

    try std.testing.expect(buf.spawnInArchetype(0));
    try std.testing.expect(buf.custom(99, null));

    try std.testing.expectEqual(@as(usize, 3), buf.count);

    const cmds = buf.getCommands();
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqual(Command.despawn, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(Command.spawn, std.meta.activeTag(cmds[1]));
    try std.testing.expectEqual(Command.custom, std.meta.activeTag(cmds[2]));

    buf.clear();
    try std.testing.expect(buf.isEmpty());
}

test "CommandBuffer overflow protection" {
    const CmdBuf = CommandBuffer(2);
    var buf = CmdBuf.init();

    const handle = EntityHandle.fromId(EntityId.init(1, 0));
    try std.testing.expect(buf.despawn(handle));
    try std.testing.expect(buf.despawn(handle));
    try std.testing.expect(!buf.despawn(handle)); // Should fail - full
    try std.testing.expect(buf.isFull());
}

test "CommandBuffer setComponent" {
    const CmdBuf = CommandBuffer(10);
    var buf = CmdBuf.init();

    const TestComponent = struct { x: i32, y: i32 };
    const handle = EntityHandle.fromId(EntityId.init(5, 1));

    try std.testing.expect(buf.setComponent(handle, TestComponent, .{ .x = 10, .y = 20 }));
    try std.testing.expectEqual(@as(usize, 1), buf.count);

    const cmds = buf.getCommands();
    try std.testing.expectEqual(Command.set_component, std.meta.activeTag(cmds[0]));

    const set_cmd = cmds[0].set_component;
    try std.testing.expectEqual(handle.id.toU32(), set_cmd.entity.id.toU32());
    try std.testing.expectEqual(@as(usize, @sizeOf(TestComponent)), set_cmd.size);
}

test "Resources basic operations" {
    const GameState = struct { level: u32, score: u64 };
    const Config = struct { difficulty: u8, volume: f32 };

    const ResourceStore = Resources(&.{ GameState, Config });
    var resources = ResourceStore.init();

    // Initially no resources
    try std.testing.expect(!resources.has(GameState));
    try std.testing.expect(!resources.has(Config));
    try std.testing.expect(resources.get(GameState) == null);
    try std.testing.expect(resources.getConst(Config) == null);

    // Insert game state
    const was_replaced = resources.insert(GameState, .{ .level = 1, .score = 0 });
    try std.testing.expect(!was_replaced);
    try std.testing.expect(resources.has(GameState));

    // Get and verify
    const state_ptr = resources.get(GameState).?;
    try std.testing.expectEqual(@as(u32, 1), state_ptr.level);
    try std.testing.expectEqual(@as(u64, 0), state_ptr.score);

    // Modify through pointer
    state_ptr.level = 5;
    state_ptr.score = 1000;

    // Get const and verify modification
    const state_const = resources.getConst(GameState).?;
    try std.testing.expectEqual(@as(u32, 5), state_const.level);
    try std.testing.expectEqual(@as(u64, 1000), state_const.score);

    // Insert Config
    _ = resources.insert(Config, .{ .difficulty = 3, .volume = 0.8 });
    try std.testing.expect(resources.has(Config));

    // Replace existing resource
    const was_replaced2 = resources.insert(GameState, .{ .level = 10, .score = 5000 });
    try std.testing.expect(was_replaced2);

    const new_state = resources.get(GameState).?;
    try std.testing.expectEqual(@as(u32, 10), new_state.level);

    // Remove resource
    const was_removed = resources.remove(GameState);
    try std.testing.expect(was_removed);
    try std.testing.expect(!resources.has(GameState));
    try std.testing.expect(resources.get(GameState) == null);

    // Remove again should return false
    const was_removed2 = resources.remove(GameState);
    try std.testing.expect(!was_removed2);
}

test "Resources empty spec" {
    const EmptyResources = Resources(&.{});
    const resources = EmptyResources.init();
    _ = resources;
    // Just verify it compiles and can be instantiated
}

test "ConcurrentCommandBuffers basic operations" {
    const ConcurrentBufs = ConcurrentCommandBuffers(4, 40, 64);
    var bufs = ConcurrentBufs.init();

    // Get first two buffers - buffers start empty
    const buf0 = bufs.getForSystem(0);
    const buf1 = bufs.getForSystem(1);
    try std.testing.expectEqual(@as(usize, 0), buf0.count);
    try std.testing.expectEqual(@as(usize, 0), buf1.count);

    // Add commands to different buffers
    const handle0 = EntityHandle.fromId(EntityId.init(1, 0));
    const handle1 = EntityHandle.fromId(EntityId.init(2, 0));

    try std.testing.expect(buf0.despawn(handle0));
    try std.testing.expect(buf1.despawn(handle1));

    try std.testing.expectEqual(@as(usize, 1), buf0.count);
    try std.testing.expectEqual(@as(usize, 1), buf1.count);

    // Clear all
    bufs.clearAll();
    try std.testing.expectEqual(@as(usize, 0), bufs.getForSystem(0).count);
    try std.testing.expectEqual(@as(usize, 0), bufs.getForSystem(1).count);
}

test "ConcurrentCommandBuffers merge operations" {
    // Use matching data sizes (64 bytes) between concurrent and target buffers
    const ConcurrentBufs = ConcurrentCommandBuffers(3, 30, 64);
    const SingleBuf = CommandBufferType(30, 64);

    var concurrent = ConcurrentBufs.init();
    var target = SingleBuf.init();

    // Add commands to each concurrent buffer
    const handle0 = EntityHandle.fromId(EntityId.init(10, 0));
    const handle1 = EntityHandle.fromId(EntityId.init(20, 0));
    const handle2 = EntityHandle.fromId(EntityId.init(30, 0));

    const buf0 = concurrent.getForSystem(0);
    const buf1 = concurrent.getForSystem(1);
    const buf2 = concurrent.getForSystem(2);

    _ = buf0.despawn(handle0);
    _ = buf0.spawnInArchetype(0);
    _ = buf1.despawn(handle1);
    _ = buf2.despawn(handle2);
    _ = buf2.custom(99, null);

    // Total: 5 commands across 3 buffers
    try std.testing.expectEqual(@as(usize, 2), concurrent.getForSystem(0).count);
    try std.testing.expectEqual(@as(usize, 1), concurrent.getForSystem(1).count);
    try std.testing.expectEqual(@as(usize, 2), concurrent.getForSystem(2).count);

    // Merge into target
    const merge_count = concurrent.mergeInto(&target);
    try std.testing.expectEqual(@as(usize, 5), merge_count);
    try std.testing.expectEqual(@as(usize, 5), target.count);

    // Verify command order (deterministic by system index)
    // Note: Use SingleBuf.CommandT enum for type-safe tag comparison
    const CmdTag = @typeInfo(SingleBuf.CommandT).@"union".tag_type.?;
    const cmds = target.getCommands();
    try std.testing.expectEqual(CmdTag.despawn, std.meta.activeTag(cmds[0])); // from buf 0
    try std.testing.expectEqual(CmdTag.spawn, std.meta.activeTag(cmds[1])); // from buf 0
    try std.testing.expectEqual(CmdTag.despawn, std.meta.activeTag(cmds[2])); // from buf 1
    try std.testing.expectEqual(CmdTag.despawn, std.meta.activeTag(cmds[3])); // from buf 2
    try std.testing.expectEqual(CmdTag.custom, std.meta.activeTag(cmds[4])); // from buf 2

    // Merge clears concurrent buffers
    try std.testing.expectEqual(@as(usize, 0), concurrent.getForSystem(0).count);
    try std.testing.expectEqual(@as(usize, 0), concurrent.getForSystem(1).count);
    try std.testing.expectEqual(@as(usize, 0), concurrent.getForSystem(2).count);
}

test "IoContext creation and properties" {
    // Create blocking context (the standard way)
    var io_ctx = IoContext.blocking();
    try std.testing.expect(!io_ctx.hasAsync());
    try std.testing.expect(!io_ctx.hasConcurrency());
    try std.testing.expect(io_ctx.getBackend() == null);
    try std.testing.expect(!io_ctx.supports_async);
    try std.testing.expect(!io_ctx.supports_concurrency);
}

test "IoContext async/concurrent capability reporting" {
    // Async-only context (evented mode)
    const async_ctx = IoContext{
        .backend = null,
        .supports_async = true,
        .supports_concurrency = false,
    };
    try std.testing.expect(async_ctx.hasAsync());
    try std.testing.expect(!async_ctx.hasConcurrency());

    // Full concurrent context (threadpool mode)
    const concurrent_ctx = IoContext{
        .backend = null,
        .supports_async = true,
        .supports_concurrency = true,
    };
    try std.testing.expect(concurrent_ctx.hasAsync());
    try std.testing.expect(concurrent_ctx.hasConcurrency());
}
