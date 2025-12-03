//! Resources - Type-Safe Global Singleton Storage
//!
//! This module provides type-safe access to global singleton data (resources).
//! Resources are stored by type with initialization tracking.

const std = @import("std");

// ============================================================================
// Resources Type
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
        /// Per TigerStyle: zeros memory to prevent information leakage and
        /// make use-after-free bugs more detectable.
        pub fn remove(self: *Self, comptime T: type) bool {
            const idx = comptime resourceIndex(T);
            const was_initialized = self.initialized[idx];

            // Zero the memory regardless of initialization state for security
            // This prevents information leakage and makes use-after-free detectable
            const resource_ptr: *T = &self.storage[idx];
            const byte_ptr: [*]u8 = @ptrCast(resource_ptr);
            const bytes: []u8 = byte_ptr[0..@sizeOf(T)];
            @memset(bytes, 0);

            // Assert memory is zeroed (TigerStyle: exhaustive assertions)
            for (bytes) |byte| {
                std.debug.assert(byte == 0);
            }

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
// Tests
// ============================================================================

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

test "Resources remove zeros memory" {
    // Use a struct with distinct non-zero byte patterns
    const SensitiveData = struct {
        secret_key: u64,
        password_hash: u128,
        token: [16]u8,
    };

    const ResourceStore = Resources(&.{SensitiveData});
    var resources = ResourceStore.init();

    // Insert data with non-zero values (simulating sensitive data)
    const sensitive = SensitiveData{
        .secret_key = 0xDEADBEEF_CAFEBABE,
        .password_hash = 0x12345678_9ABCDEF0_FEDCBA98_76543210,
        .token = .{ 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00 },
    };
    _ = resources.insert(SensitiveData, sensitive);

    // Verify data is stored correctly before removal
    const stored = resources.get(SensitiveData).?;
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF_CAFEBABE), stored.secret_key);

    // Get raw pointer to storage before removal (to verify zeroing)
    // We access the underlying storage directly to check after removal
    const storage_ptr: *SensitiveData = &resources.storage[0];
    const byte_ptr: [*]const u8 = @ptrCast(storage_ptr);
    const bytes: []const u8 = byte_ptr[0..@sizeOf(SensitiveData)];

    // Verify at least some bytes are non-zero before removal
    var non_zero_count: usize = 0;
    for (bytes) |byte| {
        if (byte != 0) non_zero_count += 1;
    }
    try std.testing.expect(non_zero_count > 0);

    // Remove the resource
    const was_removed = resources.remove(SensitiveData);
    try std.testing.expect(was_removed);

    // Verify ALL bytes are now zero (security: no information leakage)
    for (bytes, 0..) |byte, i| {
        try std.testing.expectEqual(@as(u8, 0), byte);
        _ = i; // Index available for debugging if needed
    }

    // Verify resource is no longer accessible through normal API
    try std.testing.expect(!resources.has(SensitiveData));
    try std.testing.expect(resources.get(SensitiveData) == null);
}
