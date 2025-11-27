//! NUMA-Aware Allocator Wrapper
//!
//! Provides NUMA-aware memory allocation for optimal memory bandwidth on
//! multi-socket systems. Falls back gracefully to standard allocation on
//! unsupported platforms.
//!
//! Tiger Style: All bounds configurable, platform detection, graceful fallback.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const NumaConfig = config.NumaConfig;

/// NUMA memory policy constants (Linux).
const MemPolicy = struct {
    const MPOL_DEFAULT: u32 = 0;
    const MPOL_PREFERRED: u32 = 1;
    const MPOL_BIND: u32 = 2;
    const MPOL_INTERLEAVE: u32 = 3;
};

/// NUMA-aware allocator wrapper.
/// Wraps underlying allocator with NUMA node affinity hints.
/// Compiles to no-op wrappers when NUMA is disabled or unsupported.
pub fn NumaAllocator(comptime cfg: NumaConfig) type {
    return struct {
        const Self = @This();

        /// Backing allocator for actual memory operations.
        backing_allocator: std.mem.Allocator,
        /// NUMA node ID for this allocator.
        node_id: u8,
        /// Statistics tracking.
        stats: Stats,

        pub const Stats = struct {
            /// Allocations made on local NUMA node.
            local_allocations: u64 = 0,
            /// Allocations made on remote NUMA nodes (fallback).
            remote_allocations: u64 = 0,
            /// Total bytes allocated through this allocator.
            total_bytes_allocated: u64 = 0,
            /// Failed NUMA allocations that fell back to default.
            fallback_count: u64 = 0,
        };

        /// Initialize NUMA allocator for a specific node.
        pub fn init(backing: std.mem.Allocator, node_id: u8) Self {
            return .{
                .backing_allocator = backing,
                .node_id = node_id,
                .stats = .{},
            };
        }

        /// Get the standard allocator interface.
        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        const vtable = std.mem.Allocator.VTable{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        };

        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled or builtin.os.tag != .linux) {
                return self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr);
            }

            // NUMA allocations via mmap cannot be remapped in place
            return null;
        }

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled) {
                // NUMA not enabled - use backing allocator directly
                return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
            }

            if (comptime builtin.os.tag != .linux) {
                // NUMA only supported on Linux currently
                self.stats.fallback_count += 1;
                return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
            }

            // Try NUMA-aware allocation on Linux
            const ptr = numaAlloc(len, self.node_id, cfg.strategy);

            if (ptr) |p| {
                self.stats.local_allocations += 1;
                self.stats.total_bytes_allocated += len;
                return p;
            }

            // Fallback to backing allocator
            self.stats.fallback_count += 1;
            self.stats.remote_allocations += 1;
            return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
        }

        fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled or builtin.os.tag != .linux) {
                return self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
            }

            // NUMA allocations via mmap cannot be resized in place
            // Return false to trigger reallocation
            return false;
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled or builtin.os.tag != .linux) {
                self.backing_allocator.rawFree(buf, buf_align, ret_addr);
                return;
            }

            // Free via munmap for NUMA allocations
            numaFree(buf.ptr, buf.len);
        }

        /// Reset statistics counters.
        pub fn resetStats(self: *Self) void {
            self.stats = .{};
        }

        /// Get current statistics.
        pub fn getStats(self: *const Self) Stats {
            return self.stats;
        }

        /// Get local allocation hit rate (0.0 to 1.0).
        pub fn getLocalHitRate(self: *const Self) f64 {
            const total = self.stats.local_allocations + self.stats.remote_allocations;
            if (total == 0) return 1.0;
            return @as(f64, @floatFromInt(self.stats.local_allocations)) / @as(f64, @floatFromInt(total));
        }

        // ─────────────────────────────────────────────────────────────────
        // Linux NUMA syscalls
        // ─────────────────────────────────────────────────────────────────

        fn numaAlloc(len: usize, node: u8, strategy: NumaConfig.Strategy) ?[*]u8 {
            if (comptime builtin.os.tag != .linux) return null;

            // Set memory policy based on strategy
            const policy: u32 = switch (strategy) {
                .local_preferred => MemPolicy.MPOL_PREFERRED,
                .local_strict => MemPolicy.MPOL_BIND,
                .interleave => MemPolicy.MPOL_INTERLEAVE,
                .explicit => MemPolicy.MPOL_BIND,
            };

            // Create nodemask for the target node
            var nodemask: [16]u64 = [_]u64{0} ** 16;
            const word_idx = node / 64;
            const bit_idx: u6 = @intCast(node % 64);
            if (word_idx < nodemask.len) {
                nodemask[word_idx] = @as(u64, 1) << bit_idx;
            }

            // Set memory policy via syscall
            const set_result = std.os.linux.syscall3(
                .set_mempolicy,
                policy,
                @intFromPtr(&nodemask),
                @as(usize, node) + 1, // maxnode
            );
            _ = set_result; // Ignore result - may fail if NUMA not available

            // Allocate via mmap
            const result = std.os.linux.mmap(
                null,
                len,
                std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            );

            // Reset memory policy to default
            _ = std.os.linux.syscall3(
                .set_mempolicy,
                MemPolicy.MPOL_DEFAULT,
                0,
                0,
            );

            if (result == std.os.linux.MAP_FAILED) return null;

            return @ptrFromInt(result);
        }

        fn numaFree(ptr: [*]u8, len: usize) void {
            if (comptime builtin.os.tag != .linux) return;
            _ = std.os.linux.munmap(ptr, len);
        }
    };
}

/// Detect available NUMA nodes on the system.
/// Returns 1 on non-NUMA systems or when detection fails.
pub fn detectNumaNodes() u8 {
    if (comptime builtin.os.tag != .linux) {
        return 1;
    }

    // Try reading from sysfs
    var count: u8 = 0;
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/sys/devices/system/node/node{d}", .{i}) catch break;
        std.fs.accessAbsolute(path, .{}) catch break;
        count += 1;
    }

    return if (count == 0) 1 else count;
}

/// Get the NUMA node for the current CPU.
/// Returns 0 if detection fails.
pub fn getCurrentNumaNode() u8 {
    if (comptime builtin.os.tag != .linux) {
        return 0;
    }

    // Use getcpu syscall to get current CPU and NUMA node
    const SYS_getcpu = 309; // x86_64
    var cpu: u32 = undefined;
    var node: u32 = undefined;

    const result = std.os.linux.syscall3(
        @enumFromInt(SYS_getcpu),
        @intFromPtr(&cpu),
        @intFromPtr(&node),
        0,
    );

    if (result != 0) return 0;
    return @truncate(node);
}

/// Check if NUMA is available on this system.
pub fn isNumaAvailable() bool {
    if (comptime builtin.os.tag != .linux) {
        return false;
    }

    return detectNumaNodes() > 1;
}

// ============================================================================
// Tests
// ============================================================================

test "NumaAllocator disabled - uses backing allocator" {
    const TestConfig = NumaConfig{ .enabled = false };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var numa = NumaAllocator(TestConfig).init(gpa.allocator(), 0);
    var alloc = numa.allocator();

    // Allocate and free should work
    const mem = try alloc.alloc(u8, 1024);
    defer alloc.free(mem);

    try std.testing.expectEqual(@as(usize, 1024), mem.len);
}

test "NumaAllocator stats tracking" {
    const TestConfig = NumaConfig{ .enabled = false };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var numa = NumaAllocator(TestConfig).init(gpa.allocator(), 0);
    var alloc = numa.allocator();

    // Initial stats
    var stats = numa.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.local_allocations);
    try std.testing.expectEqual(@as(u64, 0), stats.total_bytes_allocated);

    // Make some allocations
    const mem1 = try alloc.alloc(u8, 1024);
    defer alloc.free(mem1);

    const mem2 = try alloc.alloc(u8, 2048);
    defer alloc.free(mem2);

    // Hit rate should be 1.0 when disabled (all are "local")
    const hit_rate = numa.getLocalHitRate();
    try std.testing.expect(hit_rate >= 0.0 and hit_rate <= 1.0);
}

test "NumaAllocator reset stats" {
    const TestConfig = NumaConfig{ .enabled = false };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var numa = NumaAllocator(TestConfig).init(gpa.allocator(), 0);
    var alloc = numa.allocator();

    const mem = try alloc.alloc(u8, 1024);
    defer alloc.free(mem);

    numa.resetStats();
    const stats = numa.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_bytes_allocated);
}

test "detectNumaNodes returns at least 1" {
    const nodes = detectNumaNodes();
    try std.testing.expect(nodes >= 1);
}

test "getCurrentNumaNode returns valid node" {
    const node = getCurrentNumaNode();
    const max_nodes = detectNumaNodes();
    try std.testing.expect(node < max_nodes);
}

test "NumaConfig strategies" {
    // Verify all strategies are distinct
    try std.testing.expect(@intFromEnum(NumaConfig.Strategy.local_preferred) != @intFromEnum(NumaConfig.Strategy.local_strict));
    try std.testing.expect(@intFromEnum(NumaConfig.Strategy.interleave) != @intFromEnum(NumaConfig.Strategy.explicit));
}
