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
        /// Returns false if buffer is full.
        pub fn packComponent(self: *Self, comptime T: type, value: T) bool {
            const comp_idx = comptime getComponentIndex(T);
            if (comp_idx == null) return false;

            const size = @sizeOf(T);
            if (self.data_len + size > max_component_size) return false;

            // Copy component bytes
            const bytes = std.mem.asBytes(&value);
            @memcpy(self.data[self.data_len..][0..size], bytes);
            self.data_len += @intCast(size);

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
        /// Returns null if component not present.
        pub fn unpackComponent(self: *const Self, comptime T: type) ?T {
            const comp_idx = comptime getComponentIndex(T);
            if (comp_idx == null) return null;

            // Check if component is present
            if ((self.component_mask & (@as(ComponentMask, 1) << @intCast(comp_idx.?))) == 0) {
                return null;
            }

            // Calculate offset by summing sizes of preceding components
            var offset: usize = 0;
            inline for (cfg.components.types, 0..) |CompT, i| {
                if (i >= comp_idx.?) break;
                if ((self.component_mask & (@as(ComponentMask, 1) << @intCast(i))) != 0) {
                    offset += @sizeOf(CompT);
                }
            }

            // Read component
            const size = @sizeOf(T);
            if (offset + size > self.data_len) return null;

            return std.mem.bytesAsValue(T, self.data[offset..][0..size]).*;
        }

        /// Get the component index for a type (comptime)
        fn getComponentIndex(comptime T: type) ?usize {
            inline for (cfg.components.types, 0..) |CompT, i| {
                if (CompT == T) return i;
            }
            return null;
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
