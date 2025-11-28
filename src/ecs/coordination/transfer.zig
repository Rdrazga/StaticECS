//! Entity Transfer Protocol
//!
//! Defines the serialization format and operations for transferring entities
//! between worlds in a multi-world ECS pipeline.
//!
//! ## Features
//!
//! - **Fixed-size transfers**: Compatible with lock-free queues
//! - **Component packing**: Serialize all components into byte buffer
//! - **Zero-copy where possible**: Minimal data movement
//! - **Comptime-generated**: Types generated from WorldConfig
//!
//! Tiger Style: All sizes computed at comptime. No dynamic allocation.

const std = @import("std");

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;

// ============================================================================
// Transfer Marker Component
// ============================================================================

/// Marker component for entities pending transfer.
/// Add this to an entity to mark it for transfer during the next tick.
///
/// Usage in systems:
/// ```zig
/// fn markForTransfer(ctx: *SystemContext) !void {
///     var iter = ctx.world.query(.{ RequestComplete });
///     while (iter.next()) |entity| {
///         ctx.world.setComponent(entity, TransferMarker{
///             .target_world = 1,  // Target I/O world
///         });
///     }
/// }
/// ```
pub const TransferMarker = struct {
    /// Target world ID for this entity
    target_world: u8,
    /// High priority transfer (processed first)
    priority: bool = false,
    /// Destroy entity in source world after transfer
    destroy_on_transfer: bool = true,
};

// ============================================================================
// Transfer Flags
// ============================================================================

/// Transfer operation flags (packed for space efficiency)
pub const TransferFlags = packed struct {
    /// Entity should be destroyed in source world after transfer
    destroy_on_arrive: bool = false,
    /// High priority transfer (processed before normal priority)
    priority: bool = false,
    /// Transfer includes all components (vs selective)
    full_transfer: bool = true,
    /// Reserved for future use
    _padding: u5 = 0,
};

// ============================================================================
// Entity Transfer Type Generator
// ============================================================================

/// Generate an EntityTransfer type for a specific WorldConfig.
///
/// The generated type contains:
/// - Source/target world IDs
/// - Entity generation for validation
/// - Flag bits for transfer behavior
/// - Packed component data
///
/// Tiger Style: All sizes comptime-computed from config.
pub fn EntityTransfer(comptime cfg: WorldConfig) type {
    // Calculate maximum component data size
    const max_component_size = comptime blk: {
        var size: usize = 0;
        for (cfg.components.types) |T| {
            size += @sizeOf(T);
        }
        // Add some padding for alignment
        break :blk if (size == 0) 64 else size + 16;
    };

    // Component count must fit in mask
    const component_count = cfg.components.types.len;
    const ComponentMask = if (component_count <= 8)
        u8
    else if (component_count <= 16)
        u16
    else if (component_count <= 32)
        u32
    else
        u64;

    return struct {
        const Self = @This();

        /// Source world ID
        source_world: u8,
        /// Target world ID
        target_world: u8,
        /// Entity generation (for validation after transfer)
        generation: u16,
        /// Transfer flags
        flags: TransferFlags,
        /// Reserved for alignment
        _reserved: u8 = 0,
        /// Component presence bitmask
        component_mask: ComponentMask,
        /// Packed component data
        data: [max_component_size]u8,
        /// Actual data length used
        data_len: u16,

        /// Maximum size of component data buffer
        pub const max_data_size = max_component_size;

        /// Number of component types in this config
        pub const num_components = component_count;

        /// Initialize an empty transfer packet
        pub fn init(source: u8, target: u8) Self {
            return .{
                .source_world = source,
                .target_world = target,
                .generation = 0,
                .flags = .{},
                .component_mask = 0,
                .data = undefined,
                .data_len = 0,
            };
        }

        /// Pack a component into the transfer data.
        /// Uses FIXED OFFSET based on component index (not call order) to ensure
        /// correct pack/unpack regardless of the order components are packed.
        /// Returns false if component type is invalid or buffer overflow would occur.
        ///
        /// Tiger Style: Fixed offsets computed at comptime ensure deterministic layout.
        pub fn packComponent(self: *Self, comptime T: type, value: T) bool {
            const comp_idx = comptime getComponentIndex(T);
            if (comp_idx == null) return false;

            // Use fixed offset based on component index, not current data_len
            const offset = comptime getComponentOffset(T);
            const size = @sizeOf(T);

            // Assert: offset + size must fit in buffer (comptime-verified but runtime check for safety)
            std.debug.assert(offset + size <= max_component_size);
            // Assert: component should not already be packed (double-pack is a logic error)
            std.debug.assert((self.component_mask & (@as(ComponentMask, 1) << @intCast(comp_idx.?))) == 0);

            // Copy component bytes at fixed offset
            const bytes = std.mem.asBytes(&value);
            @memcpy(self.data[offset..][0..size], bytes);

            // Track maximum extent of data written for serialization efficiency
            const end_pos: u16 = @intCast(offset + size);
            if (end_pos > self.data_len) {
                self.data_len = end_pos;
            }

            // Set bit in mask
            self.component_mask |= @as(ComponentMask, 1) << @intCast(comp_idx.?);
            return true;
        }

        /// Check if a component type is present in this transfer
        pub fn hasComponent(self: *const Self, comptime T: type) bool {
            const comp_idx = comptime getComponentIndex(T);
            if (comp_idx == null) return false;
            return (self.component_mask & (@as(ComponentMask, 1) << @intCast(comp_idx.?))) != 0;
        }

        /// Unpack a component from transfer data.
        /// Uses FIXED OFFSET based on component index to ensure correct data retrieval
        /// regardless of the order components were packed.
        /// Returns null if component not present in this transfer.
        ///
        /// Tiger Style: Fixed offsets ensure pack order independence.
        pub fn unpackComponent(self: *const Self, comptime T: type) ?T {
            const comp_idx = comptime getComponentIndex(T);
            if (comp_idx == null) return null;

            // Check if component is present via mask
            if ((self.component_mask & (@as(ComponentMask, 1) << @intCast(comp_idx.?))) == 0) {
                return null;
            }

            // Use fixed offset based on component index (matches packComponent)
            const offset = comptime getComponentOffset(T);
            const size = @sizeOf(T);

            // Assert: offset + size must be within buffer bounds
            std.debug.assert(offset + size <= max_component_size);
            // Assert: data_len should cover this component's range (it was packed)
            std.debug.assert(offset + size <= self.data_len);

            return std.mem.bytesAsValue(T, self.data[offset..][0..size]).*;
        }

        /// Get the component index for a type (comptime)
        fn getComponentIndex(comptime T: type) ?usize {
            inline for (cfg.components.types, 0..) |CompT, i| {
                if (CompT == T) return i;
            }
            return null;
        }

        /// Get the fixed byte offset for a component type (comptime).
        /// Each component has a predetermined offset based on its index,
        /// calculated by summing sizes of ALL components with lower indices.
        /// This ensures pack/unpack order independence.
        ///
        /// Tiger Style: Comptime computation guarantees zero runtime overhead.
        fn getComponentOffset(comptime T: type) usize {
            const comp_idx = getComponentIndex(T) orelse @compileError("Unknown component type");
            var offset: usize = 0;
            inline for (cfg.components.types, 0..) |CompT, i| {
                if (i >= comp_idx) break;
                offset += @sizeOf(CompT);
            }
            return offset;
        }

        /// Get total size of this transfer packet
        pub fn totalSize(self: *const Self) usize {
            // Header size + actual data
            return @sizeOf(Self) - max_component_size + self.data_len;
        }

        /// Reset transfer for reuse (keeps source/target)
        pub fn reset(self: *Self) void {
            self.generation = 0;
            self.flags = .{};
            self.component_mask = 0;
            self.data_len = 0;
        }
    };
}

// ============================================================================
// Transfer Queue Type Alias
// ============================================================================

const lock_free_queue = @import("lock_free_queue.zig");

/// Create a transfer queue type for a specific config
pub fn TransferQueue(comptime cfg: WorldConfig) type {
    const Transfer = EntityTransfer(cfg);
    const capacity = cfg.coordination.transfer_queue.capacity;
    return lock_free_queue.LockFreeQueue(Transfer, capacity);
}

/// Create an SPSC transfer queue type for a specific config
pub fn SPSCTransferQueue(comptime cfg: WorldConfig) type {
    const Transfer = EntityTransfer(cfg);
    const capacity = cfg.coordination.transfer_queue.capacity;
    return lock_free_queue.SPSCQueue(Transfer, capacity);
}

// ============================================================================
// Tests
// ============================================================================

test "TransferMarker fields" {
    const marker = TransferMarker{
        .target_world = 2,
        .priority = true,
    };
    try std.testing.expectEqual(@as(u8, 2), marker.target_world);
    try std.testing.expect(marker.priority);
    try std.testing.expect(marker.destroy_on_transfer);
}

test "TransferFlags packing" {
    const flags = TransferFlags{
        .destroy_on_arrive = true,
        .priority = true,
        .full_transfer = false,
    };
    try std.testing.expect(flags.destroy_on_arrive);
    try std.testing.expect(flags.priority);
    try std.testing.expect(!flags.full_transfer);

    // Verify it's 1 byte
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(TransferFlags));
}

test "EntityTransfer basic" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
    };

    const Transfer = EntityTransfer(cfg);
    var transfer = Transfer.init(0, 1);

    try std.testing.expectEqual(@as(u8, 0), transfer.source_world);
    try std.testing.expectEqual(@as(u8, 1), transfer.target_world);
    try std.testing.expectEqual(@as(u16, 0), transfer.data_len);
}

test "EntityTransfer pack/unpack" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity } },
    };

    const Transfer = EntityTransfer(cfg);
    var transfer = Transfer.init(0, 1);

    // Pack components
    try std.testing.expect(transfer.packComponent(Position, .{ .x = 10.0, .y = 20.0 }));
    try std.testing.expect(transfer.packComponent(Velocity, .{ .dx = 1.0, .dy = 2.0 }));

    // Verify presence
    try std.testing.expect(transfer.hasComponent(Position));
    try std.testing.expect(transfer.hasComponent(Velocity));

    // Unpack and verify
    const pos = transfer.unpackComponent(Position).?;
    try std.testing.expectApproxEqRel(@as(f32, 10.0), pos.x, 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 20.0), pos.y, 0.001);

    const vel = transfer.unpackComponent(Velocity).?;
    try std.testing.expectApproxEqRel(@as(f32, 1.0), vel.dx, 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 2.0), vel.dy, 0.001);
}

test "EntityTransfer partial components" {
    const A = struct { a: u32 };
    const B = struct { b: u64 };
    const C = struct { c: bool };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ A, B, C } },
    };

    const Transfer = EntityTransfer(cfg);
    var transfer = Transfer.init(1, 2);

    // Only pack A and C, not B
    try std.testing.expect(transfer.packComponent(A, .{ .a = 42 }));
    try std.testing.expect(transfer.packComponent(C, .{ .c = true }));

    // Verify presence
    try std.testing.expect(transfer.hasComponent(A));
    try std.testing.expect(!transfer.hasComponent(B));
    try std.testing.expect(transfer.hasComponent(C));

    // Unpack
    const a = transfer.unpackComponent(A).?;
    try std.testing.expectEqual(@as(u32, 42), a.a);

    try std.testing.expectEqual(@as(?B, null), transfer.unpackComponent(B));

    const c = transfer.unpackComponent(C).?;
    try std.testing.expect(c.c);
}

test "EntityTransfer reset" {
    const Data = struct { value: i32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Data} },
    };

    const Transfer = EntityTransfer(cfg);
    var transfer = Transfer.init(0, 1);

    try std.testing.expect(transfer.packComponent(Data, .{ .value = 100 }));
    try std.testing.expect(transfer.hasComponent(Data));
    try std.testing.expect(transfer.data_len > 0);

    transfer.reset();

    try std.testing.expect(!transfer.hasComponent(Data));
    try std.testing.expectEqual(@as(u16, 0), transfer.data_len);
    // Source/target preserved
    try std.testing.expectEqual(@as(u8, 0), transfer.source_world);
    try std.testing.expectEqual(@as(u8, 1), transfer.target_world);
}

test "EntityTransfer max data size" {
    const Large = struct { data: [128]u8 };
    const Small = struct { x: u8 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Large, Small } },
    };

    const Transfer = EntityTransfer(cfg);

    // Max data size should accommodate all components
    try std.testing.expect(Transfer.max_data_size >= @sizeOf(Large) + @sizeOf(Small));
}

test "Transfer: out-of-order pack/unpack" {
    // This test verifies the fix for P1-TRANSFER bug where packing components
    // out of index order would cause data corruption during unpack.
    //
    // Components: A (index 0), B (index 1), C (index 2)
    // Pack order: C first, then A (out of index order)
    // Expected: Unpack should correctly retrieve A and C values

    const A = struct { value: u32 };
    const B = struct { value: u64 };
    const C = struct { value: u16, flag: bool };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ A, B, C } },
    };

    const Transfer = EntityTransfer(cfg);

    // Test 1: Pack out of index order (C first, then A)
    {
        var transfer = Transfer.init(0, 1);

        // Pack C (index 2) FIRST
        try std.testing.expect(transfer.packComponent(C, .{ .value = 0xCAFE, .flag = true }));
        // Pack A (index 0) SECOND - out of order!
        try std.testing.expect(transfer.packComponent(A, .{ .value = 0xDEADBEEF }));

        // Verify presence
        try std.testing.expect(transfer.hasComponent(A));
        try std.testing.expect(!transfer.hasComponent(B));
        try std.testing.expect(transfer.hasComponent(C));

        // Unpack A - should get correct value despite being packed second
        const a = transfer.unpackComponent(A).?;
        try std.testing.expectEqual(@as(u32, 0xDEADBEEF), a.value);

        // Unpack C - should get correct value despite being packed first
        const c = transfer.unpackComponent(C).?;
        try std.testing.expectEqual(@as(u16, 0xCAFE), c.value);
        try std.testing.expect(c.flag);

        // B should not be present
        try std.testing.expectEqual(@as(?B, null), transfer.unpackComponent(B));
    }

    // Test 2: Pack in reverse index order (C, B, A)
    {
        var transfer = Transfer.init(1, 2);

        // Pack in complete reverse order
        try std.testing.expect(transfer.packComponent(C, .{ .value = 333, .flag = false }));
        try std.testing.expect(transfer.packComponent(B, .{ .value = 222 }));
        try std.testing.expect(transfer.packComponent(A, .{ .value = 111 }));

        // Unpack in index order and verify
        const a = transfer.unpackComponent(A).?;
        try std.testing.expectEqual(@as(u32, 111), a.value);

        const b = transfer.unpackComponent(B).?;
        try std.testing.expectEqual(@as(u64, 222), b.value);

        const c = transfer.unpackComponent(C).?;
        try std.testing.expectEqual(@as(u16, 333), c.value);
        try std.testing.expect(!c.flag);
    }

    // Test 3: Pack middle component only
    {
        var transfer = Transfer.init(2, 3);

        // Only pack B (middle component)
        try std.testing.expect(transfer.packComponent(B, .{ .value = 0x123456789ABCDEF0 }));

        try std.testing.expect(!transfer.hasComponent(A));
        try std.testing.expect(transfer.hasComponent(B));
        try std.testing.expect(!transfer.hasComponent(C));

        const b = transfer.unpackComponent(B).?;
        try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), b.value);
    }
}

test "TransferQueue creation" {
    const Pos = struct { x: f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Pos} },
        .coordination = .{
            .role = .io,
            .transfer_queue = .{ .capacity = 64 },
        },
    };

    // Just verify the type can be created
    const QueueType = TransferQueue(cfg);
    const queue = QueueType.init();
    try std.testing.expect(queue.getCapacity() == 64);
}

// ============================================================================
// Extended Transfer Tests (Task: Add Coordination Module Tests)
// ============================================================================

test "EntityTransfer: full round-trip serialization" {
    // Test complete entity transfer cycle with multiple components.
    // Simulates transfer from world 0 (accept) to world 1 (io).
    const Position = struct { x: f32, y: f32, z: f32 };
    const Velocity = struct { dx: f32, dy: f32, dz: f32 };
    const Health = struct { current: u32, max: u32 };
    const Name = struct { id: u64, len: u8 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Position, Velocity, Health, Name } },
    };

    const Transfer = EntityTransfer(cfg);

    // Step 1: Create transfer with source/target world IDs
    var transfer = Transfer.init(0, 1);
    try std.testing.expectEqual(@as(u8, 0), transfer.source_world);
    try std.testing.expectEqual(@as(u8, 1), transfer.target_world);

    // Step 2: Pack multiple components with various data
    const pos = Position{ .x = 100.5, .y = 200.25, .z = -50.0 };
    const vel = Velocity{ .dx = 1.0, .dy = -0.5, .dz = 0.0 };
    const health = Health{ .current = 80, .max = 100 };

    try std.testing.expect(transfer.packComponent(Position, pos));
    try std.testing.expect(transfer.packComponent(Velocity, vel));
    try std.testing.expect(transfer.packComponent(Health, health));
    // Note: Name is NOT packed (simulating partial transfer)

    // Step 3: Verify component mask is correct
    try std.testing.expect(transfer.hasComponent(Position));
    try std.testing.expect(transfer.hasComponent(Velocity));
    try std.testing.expect(transfer.hasComponent(Health));
    try std.testing.expect(!transfer.hasComponent(Name)); // Not packed

    // Step 4: Unpack each component
    const unpacked_pos = transfer.unpackComponent(Position).?;
    const unpacked_vel = transfer.unpackComponent(Velocity).?;
    const unpacked_health = transfer.unpackComponent(Health).?;

    // Step 5: Verify all data matches original values
    try std.testing.expectApproxEqRel(@as(f32, 100.5), unpacked_pos.x, 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 200.25), unpacked_pos.y, 0.001);
    try std.testing.expectApproxEqRel(@as(f32, -50.0), unpacked_pos.z, 0.001);

    try std.testing.expectApproxEqRel(@as(f32, 1.0), unpacked_vel.dx, 0.001);
    try std.testing.expectApproxEqRel(@as(f32, -0.5), unpacked_vel.dy, 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 0.0), unpacked_vel.dz, 0.001);

    try std.testing.expectEqual(@as(u32, 80), unpacked_health.current);
    try std.testing.expectEqual(@as(u32, 100), unpacked_health.max);

    // Step 6: Verify unpacking non-packed components returns null
    try std.testing.expectEqual(@as(?Name, null), transfer.unpackComponent(Name));
}

test "EntityTransfer: transfer flags behavior" {
    // Test that transfer flags are properly set and preserved.
    const Data = struct { value: u32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Data} },
    };

    const Transfer = EntityTransfer(cfg);
    var transfer = Transfer.init(0, 1);

    // Default flags
    try std.testing.expect(!transfer.flags.destroy_on_arrive);
    try std.testing.expect(!transfer.flags.priority);
    try std.testing.expect(transfer.flags.full_transfer);

    // Modify flags
    transfer.flags.destroy_on_arrive = true;
    transfer.flags.priority = true;
    transfer.flags.full_transfer = false;

    // Set generation for validation
    transfer.generation = 42;

    // Pack some data
    _ = transfer.packComponent(Data, .{ .value = 123 });

    // Verify flags persist
    try std.testing.expect(transfer.flags.destroy_on_arrive);
    try std.testing.expect(transfer.flags.priority);
    try std.testing.expect(!transfer.flags.full_transfer);
    try std.testing.expectEqual(@as(u16, 42), transfer.generation);

    // Reset clears flags but preserves source/target
    transfer.reset();
    try std.testing.expect(!transfer.flags.destroy_on_arrive);
    try std.testing.expect(!transfer.flags.priority);
    try std.testing.expect(transfer.flags.full_transfer);
    try std.testing.expectEqual(@as(u16, 0), transfer.generation);
    try std.testing.expectEqual(@as(u8, 0), transfer.source_world);
    try std.testing.expectEqual(@as(u8, 1), transfer.target_world);
}

test "EntityTransfer: component size boundaries" {
    // Test transfers with components of various sizes.
    const Tiny = struct { byte: u8 };
    const Small = struct { x: u16, y: u16 };
    const Medium = struct { data: [16]u8 };
    const Large = struct { matrix: [4][4]f32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ Tiny, Small, Medium, Large } },
    };

    const Transfer = EntityTransfer(cfg);
    var transfer = Transfer.init(2, 3);

    // Pack all components
    try std.testing.expect(transfer.packComponent(Tiny, .{ .byte = 0xFF }));
    try std.testing.expect(transfer.packComponent(Small, .{ .x = 1000, .y = 2000 }));
    try std.testing.expect(transfer.packComponent(Medium, .{ .data = [_]u8{0xAA} ** 16 }));

    var matrix: [4][4]f32 = undefined;
    for (&matrix, 0..) |*row, i| {
        for (row, 0..) |*val, j| {
            val.* = @floatFromInt(i * 4 + j);
        }
    }
    try std.testing.expect(transfer.packComponent(Large, .{ .matrix = matrix }));

    // Unpack and verify
    const tiny = transfer.unpackComponent(Tiny).?;
    try std.testing.expectEqual(@as(u8, 0xFF), tiny.byte);

    const small = transfer.unpackComponent(Small).?;
    try std.testing.expectEqual(@as(u16, 1000), small.x);
    try std.testing.expectEqual(@as(u16, 2000), small.y);

    const medium = transfer.unpackComponent(Medium).?;
    try std.testing.expectEqual(@as(u8, 0xAA), medium.data[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), medium.data[15]);

    const large = transfer.unpackComponent(Large).?;
    try std.testing.expectApproxEqRel(@as(f32, 0.0), large.matrix[0][0], 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 15.0), large.matrix[3][3], 0.001);
}

test "EntityTransfer: totalSize calculation" {
    // Test that totalSize correctly reports the effective transfer size.
    const A = struct { a: u32 };
    const B = struct { b: u64 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{ A, B } },
    };

    const Transfer = EntityTransfer(cfg);
    var transfer = Transfer.init(0, 1);

    // Initial size (header only, no data)
    const initial_size = transfer.totalSize();
    try std.testing.expectEqual(@as(u16, 0), transfer.data_len);

    // Pack A - size should increase
    _ = transfer.packComponent(A, .{ .a = 1 });
    try std.testing.expect(transfer.data_len > 0);
    try std.testing.expect(transfer.totalSize() > initial_size);

    // Pack B - size should increase more
    const size_after_a = transfer.totalSize();
    _ = transfer.packComponent(B, .{ .b = 2 });
    try std.testing.expect(transfer.totalSize() > size_after_a);
}

test "SPSCTransferQueue creation" {
    // Test SPSC queue variant for single producer/consumer scenarios.
    const Data = struct { id: u32 };

    const cfg = WorldConfig{
        .components = .{ .types = &.{Data} },
        .coordination = .{
            .transfer_queue = .{ .capacity = 32 },
        },
    };

    const SPSCQueueType = SPSCTransferQueue(cfg);
    var queue = SPSCQueueType.init();

    try std.testing.expectEqual(@as(usize, 32), queue.getCapacity());
    try std.testing.expect(queue.isEmpty());

    // Push a transfer
    const Transfer = EntityTransfer(cfg);
    var t = Transfer.init(0, 1);
    _ = t.packComponent(Data, .{ .id = 999 });
    try std.testing.expect(queue.push(t));

    // Pop and verify
    const received = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 999), received.unpackComponent(Data).?.id);
}
