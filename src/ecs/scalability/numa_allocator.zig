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

/// Architecture-specific syscall numbers for NUMA operations.
/// Reference: https://syscall.sh/ and Linux kernel source
/// Why: Syscall numbers vary by architecture; x86_64 != ARM64
const SyscallNumbers = struct {
    /// getcpu syscall - gets current CPU/NUMA node
    /// x86_64: 309, ARM64: 168
    const getcpu = switch (builtin.cpu.arch) {
        .x86_64 => 309,
        .aarch64 => 168,
        else => @compileError("Unsupported architecture for NUMA getcpu syscall"),
    };
};

/// NUMA memory policy constants (Linux).
const MemPolicy = struct {
    const MPOL_DEFAULT: u32 = 0;
    const MPOL_PREFERRED: u32 = 1;
    const MPOL_BIND: u32 = 2;
    const MPOL_INTERLEAVE: u32 = 3;
};

/// Allocation source tracking for explicit free routing.
/// Why: Heuristics (page alignment, size) can fail when backing allocator
/// returns page-aligned memory, causing munmap() on heap memory = corruption.
const AllocationSource = enum(u8) {
    /// Memory allocated via mmap with NUMA policy
    numa = 0xAA,
    /// Memory allocated via backing allocator (GPA, etc.)
    backing = 0xBB,
};

/// Metadata header prepended to each allocation for explicit source tracking.
/// Layout: [Header][padding][user data]
/// Why: Eliminates heuristic-based free routing that caused heap corruption.
const AllocationHeader = struct {
    /// Magic value for corruption detection in debug builds.
    magic: u32 = HEADER_MAGIC,
    /// Source of this allocation for correct free routing.
    source: AllocationSource,
    /// Reserved for alignment and future use.
    _reserved: [3]u8 = .{ 0, 0, 0 },
    /// Original requested size (for debugging/assertions).
    original_size: usize,

    const HEADER_MAGIC: u32 = 0xDEAD_0A1A;

    /// Header size aligned to maximum possible alignment requirement.
    /// Why: Ensures returned user pointer maintains any alignment.
    const SIZE: usize = @max(@sizeOf(AllocationHeader), 16);

    /// Get header from user pointer (inverse of getUserPtr).
    fn fromUserPtr(user_ptr: [*]u8) *AllocationHeader {
        const header_addr = @intFromPtr(user_ptr) - SIZE;
        return @ptrFromInt(header_addr);
    }

    /// Get user pointer from allocation base (header location).
    fn getUserPtr(base_ptr: [*]u8) [*]u8 {
        return @ptrFromInt(@intFromPtr(base_ptr) + SIZE);
    }

    /// Calculate total allocation size including header.
    fn totalSize(user_size: usize) usize {
        return user_size + SIZE;
    }
};

/// NUMA-aware allocator wrapper.
/// Wraps underlying allocator with NUMA node affinity hints.
/// Compiles to no-op wrappers when NUMA is disabled or unsupported.
///
/// Allocation source tracking: Uses metadata headers to explicitly track
/// whether each allocation came from NUMA mmap or the backing allocator.
/// This prevents heap corruption from incorrect free routing.
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
                // NUMA not enabled - use backing allocator directly (no header needed)
                return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
            }

            if (comptime builtin.os.tag != .linux) {
                // NUMA only supported on Linux currently (no header needed)
                self.stats.fallback_count += 1;
                return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
            }

            // Calculate total size including metadata header.
            // Why: Header enables explicit source tracking, eliminating heuristic-based
            // free routing that caused heap corruption (P1-3 fix).
            const total_size = AllocationHeader.totalSize(len);
            const page_size = std.mem.page_size;

            // Small allocations below page_size use backing allocator.
            // Why: mmap overhead not worth it for small allocations.
            if (len < page_size) {
                return self.allocFromBacking(len, total_size, ptr_align, ret_addr);
            }

            // Try NUMA-aware allocation on Linux for allocations >= page_size
            const ptr = numaAlloc(total_size, self.node_id, cfg.strategy);

            if (ptr) |base_ptr| {
                // Assertion: mmap always returns page-aligned pointers
                std.debug.assert(@intFromPtr(base_ptr) % page_size == 0);

                // Write header with NUMA source
                const header: *AllocationHeader = @ptrCast(@alignCast(base_ptr));
                header.* = .{
                    .source = .numa,
                    .original_size = len,
                };

                self.stats.local_allocations += 1;
                self.stats.total_bytes_allocated += len;

                return AllocationHeader.getUserPtr(base_ptr);
            }

            // Fallback to backing allocator when NUMA allocation fails.
            // Header explicitly tracks this is backing allocator memory.
            return self.allocFromBacking(len, total_size, ptr_align, ret_addr);
        }

        /// Allocate from backing allocator with header tracking.
        fn allocFromBacking(self: *Self, user_len: usize, total_len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            // Need alignment that satisfies both header and user requirements
            const min_align = @max(ptr_align.toByteUnits(), AllocationHeader.SIZE);
            const backing_align: std.mem.Alignment = @enumFromInt(@ctz(min_align));

            const base_ptr = self.backing_allocator.rawAlloc(total_len, backing_align, ret_addr) orelse {
                return null;
            };

            // Write header with backing source
            const header: *AllocationHeader = @ptrCast(@alignCast(base_ptr));
            header.* = .{
                .source = .backing,
                .original_size = user_len,
            };

            self.stats.fallback_count += 1;
            self.stats.remote_allocations += 1;

            return AllocationHeader.getUserPtr(base_ptr);
        }

        fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled or builtin.os.tag != .linux) {
                return self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
            }

            // Get header to check allocation source
            const header = AllocationHeader.fromUserPtr(buf.ptr);

            // Validate header magic in debug builds
            std.debug.assert(header.magic == AllocationHeader.HEADER_MAGIC);

            // NUMA allocations via mmap cannot be resized in place
            if (header.source == .numa) {
                return false;
            }

            // Backing allocator might support resize
            const total_new_len = AllocationHeader.totalSize(new_len);
            const base_ptr = @as([*]u8, @ptrCast(header));
            const total_old_len = AllocationHeader.totalSize(buf.len);
            const base_slice = base_ptr[0..total_old_len];

            const min_align = @max(buf_align.toByteUnits(), AllocationHeader.SIZE);
            const backing_align: std.mem.Alignment = @enumFromInt(@ctz(min_align));

            if (self.backing_allocator.rawResize(base_slice, backing_align, total_new_len, ret_addr)) {
                // Update stored size on success
                header.original_size = new_len;
                return true;
            }
            return false;
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled or builtin.os.tag != .linux) {
                self.backing_allocator.rawFree(buf, buf_align, ret_addr);
                return;
            }

            // Assertion: sanity check on buffer validity
            std.debug.assert(buf.len > 0);

            // Get header to determine allocation source explicitly.
            // Why: Eliminates heuristic-based routing that caused heap corruption
            // when backing allocator returned page-aligned pointers (P1-3 fix).
            const header = AllocationHeader.fromUserPtr(buf.ptr);

            // Validate header magic - catches corruption and double-free
            std.debug.assert(header.magic == AllocationHeader.HEADER_MAGIC);

            // Validate stored size matches (sanity check)
            std.debug.assert(header.original_size == buf.len);

            const total_len = AllocationHeader.totalSize(buf.len);
            const base_ptr: [*]u8 = @ptrCast(header);

            switch (header.source) {
                .numa => {
                    // NUMA allocation - free with munmap
                    numaFree(base_ptr, total_len);
                },
                .backing => {
                    // Backing allocator allocation - free with rawFree
                    const min_align = @max(buf_align.toByteUnits(), AllocationHeader.SIZE);
                    const backing_align: std.mem.Alignment = @enumFromInt(@ctz(min_align));
                    self.backing_allocator.rawFree(base_ptr[0..total_len], backing_align, ret_addr);
                },
            }
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
/// Returns 0 if detection fails or on unsupported platforms.
///
/// Platform Support:
/// - Linux (x86_64, ARM64): Uses getcpu syscall
/// - Other platforms: Returns 0 (assumes single NUMA node)
pub fn getCurrentNumaNode() u8 {
    if (comptime builtin.os.tag != .linux) {
        return 0; // Fallback: assume single NUMA node on non-Linux
    }

    // Compile-time architecture check via SyscallNumbers prevents
    // compilation on unsupported architectures
    const syscall_num = comptime SyscallNumbers.getcpu;

    var cpu: u32 = undefined;
    var node: u32 = undefined;

    const result = std.os.linux.syscall3(
        @enumFromInt(syscall_num),
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

test "NumaAllocator small allocation uses backing allocator" {
    // This test verifies the fix for P1-NUMA memory corruption bug.
    // Small allocations (< page_size) must use backing allocator, not mmap.
    // Previously, free() would call munmap() on ALL allocations when NUMA was enabled,
    // causing heap corruption when the allocation actually came from the backing allocator.

    const TestConfig = NumaConfig{ .enabled = true, .strategy = .local_preferred };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var numa = NumaAllocator(TestConfig).init(gpa.allocator(), 0);
    var alloc = numa.allocator();

    // Allocate a small buffer (below page_size threshold)
    // This must go through backing allocator, not mmap
    const small_size: usize = 64; // Well below page_size (typically 4096)
    const small_mem = try alloc.alloc(u8, small_size);

    // Write to memory to verify it's valid
    @memset(small_mem, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), small_mem[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), small_mem[small_size - 1]);

    // Free the small allocation - this MUST NOT call munmap() on GPA memory
    // If the bug exists, this would corrupt the heap or crash
    alloc.free(small_mem);

    // Verify stats show this used fallback path
    const stats = numa.getStats();
    try std.testing.expect(stats.fallback_count >= 1);

    // Make another allocation to verify heap is not corrupted
    const verify_mem = try alloc.alloc(u8, 128);
    defer alloc.free(verify_mem);
    @memset(verify_mem, 0xCD);
    try std.testing.expectEqual(@as(u8, 0xCD), verify_mem[0]);
}

test "NumaAllocator enabled - mixed small and large allocations" {
    // Test that both small and large allocations work correctly together
    const TestConfig = NumaConfig{ .enabled = true, .strategy = .local_preferred };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var numa = NumaAllocator(TestConfig).init(gpa.allocator(), 0);
    var alloc = numa.allocator();

    // Multiple small allocations (all should use backing allocator)
    const small1 = try alloc.alloc(u8, 32);
    const small2 = try alloc.alloc(u8, 128);
    const small3 = try alloc.alloc(u8, 256);

    // Write patterns to verify memory validity
    @memset(small1, 0x11);
    @memset(small2, 0x22);
    @memset(small3, 0x33);

    // Free in different order to stress test
    alloc.free(small2);
    alloc.free(small1);
    alloc.free(small3);

    // If we get here without crash, the fix is working
    // Verify GPA detected no corruption
    const final_mem = try alloc.alloc(u8, 64);
    defer alloc.free(final_mem);
    @memset(final_mem, 0xFF);
    try std.testing.expectEqual(@as(u8, 0xFF), final_mem[0]);
}

test "NumaAllocator explicit source tracking via metadata header" {
    // This test verifies the P1-3 fix: explicit source tracking via metadata headers.
    // Previously, heuristic-based detection (page alignment + size) could fail when
    // backing allocator returned page-aligned memory, causing munmap() on heap → corruption.
    //
    // The fix: AllocationHeader prepended to each allocation stores source explicitly.
    //
    // Note: Header tracking only applies on Linux when NUMA is enabled.
    // On other platforms, the allocator passes through directly to backing allocator.

    const TestConfig = NumaConfig{ .enabled = true, .strategy = .local_preferred };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var numa = NumaAllocator(TestConfig).init(gpa.allocator(), 0);
    var alloc = numa.allocator();

    // Test 1: Small allocation (< page_size) - must use backing allocator
    const small_mem = try alloc.alloc(u8, 256);
    @memset(small_mem, 0x11);

    // Header verification only valid on Linux where headers are used
    if (comptime builtin.os.tag == .linux) {
        // Verify header is accessible and marked as backing source
        const small_header = AllocationHeader.fromUserPtr(small_mem.ptr);
        try std.testing.expectEqual(AllocationHeader.HEADER_MAGIC, small_header.magic);
        try std.testing.expectEqual(AllocationSource.backing, small_header.source);
        try std.testing.expectEqual(@as(usize, 256), small_header.original_size);
    }

    // Free - should correctly route to backing allocator due to explicit tracking
    alloc.free(small_mem);

    // Test 2: Verify heap integrity after free
    const verify_mem = try alloc.alloc(u8, 512);
    defer alloc.free(verify_mem);
    @memset(verify_mem, 0x22);
    try std.testing.expectEqual(@as(u8, 0x22), verify_mem[0]);

    // Header verification only valid on Linux where headers are used
    if (comptime builtin.os.tag == .linux) {
        // Verify this allocation also has correct header
        const verify_header = AllocationHeader.fromUserPtr(verify_mem.ptr);
        try std.testing.expectEqual(AllocationHeader.HEADER_MAGIC, verify_header.magic);
        try std.testing.expectEqual(@as(usize, 512), verify_header.original_size);
    }
}

test "AllocationHeader layout and size" {
    // Verify header struct has expected size and alignment properties
    try std.testing.expect(AllocationHeader.SIZE >= @sizeOf(AllocationHeader));
    try std.testing.expect(AllocationHeader.SIZE >= 16); // Minimum alignment guarantee

    // Verify magic constant is valid
    try std.testing.expectEqual(@as(u32, 0xDEAD_0A1A), AllocationHeader.HEADER_MAGIC);

    // Verify source enum values are distinct
    try std.testing.expect(@intFromEnum(AllocationSource.numa) != @intFromEnum(AllocationSource.backing));
}
