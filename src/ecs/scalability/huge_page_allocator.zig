//! Huge Page Allocator
//!
//! Provides huge page allocation for reduced TLB misses on large allocations.
//! Supports 2MB and 1GB huge pages on Linux, Windows large pages (with privileges),
//! and macOS superpages, with automatic fallback to regular pages when unavailable.
//!
//! Tiger Style: Configurable thresholds, graceful fallback, platform detection.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const HugePageConfig = config.HugePageConfig;

// ─────────────────────────────────────────────────────────────────
// Windows API declarations for large page support
// ─────────────────────────────────────────────────────────────────

/// Windows-specific constants and extern declarations for large page allocation.
/// These are only used when comptime builtin.os.tag == .windows.
const WindowsLargePages = struct {
    // Memory allocation flags
    const MEM_LARGE_PAGES: u32 = 0x20000000;
    const MEM_COMMIT: u32 = 0x00001000;
    const MEM_RESERVE: u32 = 0x00002000;
    const MEM_RELEASE: u32 = 0x00008000;

    // Page protection
    const PAGE_READWRITE: u32 = 0x04;

    // Windows BOOL type
    const BOOL = c_int;

    // Extern function declarations using .winapi calling convention
    extern "kernel32" fn GetLargePageMinimum() callconv(.winapi) usize;
    extern "kernel32" fn VirtualAlloc(
        lpAddress: ?*anyopaque,
        dwSize: usize,
        flAllocationType: u32,
        flProtect: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn VirtualFree(
        lpAddress: *anyopaque,
        dwSize: usize,
        dwFreeType: u32,
    ) callconv(.winapi) BOOL;

    /// Get the system's large page minimum size.
    /// Returns 0 if large pages are not supported.
    fn getLargePageSize() usize {
        return GetLargePageMinimum();
    }

    /// Allocate memory using Windows large pages.
    /// Returns null if allocation fails (typically due to missing SeLockMemoryPrivilege).
    fn allocate(size: usize) ?[*]u8 {
        const large_page_size = getLargePageSize();
        if (large_page_size == 0) {
            // Large pages not supported on this system
            return null;
        }

        // Round up to large page boundary
        const aligned_size = std.mem.alignForward(usize, size, large_page_size);

        // Attempt allocation with MEM_LARGE_PAGES
        // This will fail with ERROR_PRIVILEGE_NOT_HELD if SeLockMemoryPrivilege is not enabled
        const result = VirtualAlloc(
            null, // Let system choose address
            aligned_size,
            MEM_COMMIT | MEM_RESERVE | MEM_LARGE_PAGES,
            PAGE_READWRITE,
        );

        if (result) |ptr| {
            return @ptrCast(ptr);
        }

        // Allocation failed - likely ERROR_PRIVILEGE_NOT_HELD (1314)
        // or ERROR_NO_SYSTEM_RESOURCES (1450)
        // Caller should fall back to regular allocation
        return null;
    }

    /// Free memory allocated with Windows large pages.
    fn deallocate(ptr: [*]u8) void {
        // For MEM_RELEASE, dwSize must be 0
        _ = VirtualFree(@ptrCast(ptr), 0, MEM_RELEASE);
    }

    /// Check if large pages appear to be available.
    /// Note: This checks if the system supports large pages, but actual allocation
    /// may still fail if SeLockMemoryPrivilege is not granted to the process.
    fn isAvailable() bool {
        return getLargePageSize() > 0;
    }
};

/// Huge page allocator wrapper.
/// Routes large allocations through huge pages for reduced TLB pressure.
/// Compiles to no-op wrappers when huge pages are disabled.
pub fn HugePageAllocator(comptime cfg: HugePageConfig) type {
    return struct {
        const Self = @This();

        /// Backing allocator for regular and fallback allocations.
        backing_allocator: std.mem.Allocator,
        /// Configured huge page size.
        huge_page_size: usize,
        /// Statistics tracking.
        stats: Stats,

        pub const Stats = struct {
            /// Number of allocations using huge pages.
            huge_allocations: u64 = 0,
            /// Number of allocations using regular pages.
            regular_allocations: u64 = 0,
            /// Total bytes allocated via huge pages.
            total_huge_bytes: u64 = 0,
            /// Total bytes allocated via regular pages.
            total_regular_bytes: u64 = 0,
            /// Huge page allocation failures (fell back to regular).
            huge_failures: u64 = 0,
        };

        /// Initialize huge page allocator.
        pub fn init(backing: std.mem.Allocator) Self {
            return .{
                .backing_allocator = backing,
                .huge_page_size = @intFromEnum(cfg.size),
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

            if (comptime !cfg.enabled) {
                return self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr);
            }

            // Huge page allocations cannot be remapped in place
            if (memory.len >= cfg.threshold) {
                return null;
            }

            return self.backing_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled) {
                // Huge pages not enabled - use backing allocator directly
                return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
            }

            // Only use huge pages for allocations meeting threshold
            if (len < cfg.threshold) {
                self.stats.regular_allocations += 1;
                self.stats.total_regular_bytes += len;
                return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
            }

            // Round up to huge page boundary
            const aligned_len = std.mem.alignForward(usize, len, self.huge_page_size);

            // Try huge page allocation
            const ptr = hugeAlloc(aligned_len, cfg.size);

            if (ptr) |p| {
                self.stats.huge_allocations += 1;
                self.stats.total_huge_bytes += aligned_len;
                return p;
            }

            // Fallback to regular pages if configured
            if (cfg.fallback) {
                self.stats.huge_failures += 1;
                self.stats.regular_allocations += 1;
                self.stats.total_regular_bytes += len;
                return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
            }

            return null;
        }

        fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled) {
                return self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
            }

            // Huge page allocations cannot be resized in place
            // Return false to trigger reallocation
            if (buf.len >= cfg.threshold) {
                return false;
            }

            return self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime !cfg.enabled) {
                self.backing_allocator.rawFree(buf, buf_align, ret_addr);
                return;
            }

            // Check if this was a huge page allocation
            if (buf.len >= cfg.threshold) {
                hugeFree(buf.ptr, std.mem.alignForward(usize, buf.len, self.huge_page_size));
                return;
            }

            self.backing_allocator.rawFree(buf, buf_align, ret_addr);
        }

        /// Reset statistics counters.
        pub fn resetStats(self: *Self) void {
            self.stats = .{};
        }

        /// Get current statistics.
        pub fn getStats(self: *const Self) Stats {
            return self.stats;
        }

        /// Get huge page utilization rate (0.0 to 1.0).
        /// Returns ratio of huge page allocations to total large allocations.
        pub fn getHugePageRate(self: *const Self) f64 {
            const total = self.stats.huge_allocations + self.stats.huge_failures;
            if (total == 0) return 1.0;
            return @as(f64, @floatFromInt(self.stats.huge_allocations)) / @as(f64, @floatFromInt(total));
        }

        // ─────────────────────────────────────────────────────────────────
        // Platform-specific huge page allocation
        // ─────────────────────────────────────────────────────────────────

        fn hugeAlloc(len: usize, page_size: HugePageConfig.PageSize) ?[*]u8 {
            if (comptime builtin.os.tag == .linux) {
                return hugeAllocLinux(len, page_size);
            } else if (comptime builtin.os.tag == .windows) {
                return hugeAllocWindows(len);
            } else if (comptime builtin.os.tag == .macos) {
                return hugeAllocMacos(len);
            }
            return null;
        }

        fn hugeFree(ptr: [*]u8, len: usize) void {
            if (comptime builtin.os.tag == .linux) {
                _ = std.os.linux.munmap(ptr, len);
            } else if (comptime builtin.os.tag == .windows) {
                hugeFreeWindows(ptr);
            } else if (comptime builtin.os.tag == .macos) {
                hugeFreeMacos(ptr, len);
            }
        }

        fn hugeAllocLinux(len: usize, page_size: HugePageConfig.PageSize) ?[*]u8 {
            // Build flags with huge page hint
            const huge_flag: u32 = switch (page_size) {
                .@"2MB" => 21 << 26, // MAP_HUGE_2MB
                .@"1GB" => 30 << 26, // MAP_HUGE_1GB
            };

            const result = std.os.linux.mmap(
                null,
                len,
                std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
                .{
                    .TYPE = .PRIVATE,
                    .ANONYMOUS = true,
                    .HUGETLB = true,
                    ._7 = @truncate(huge_flag >> 26), // Encode size in flags
                },
                -1,
                0,
            );

            if (result == std.os.linux.MAP_FAILED) return null;
            return @ptrFromInt(result);
        }

        fn hugeAllocWindows(len: usize) ?[*]u8 {
            // Windows large page allocation via VirtualAlloc with MEM_LARGE_PAGES.
            // Requirements:
            // 1. SeLockMemoryPrivilege must be granted to the user
            //    (via Local Security Policy → User Rights → Lock pages in memory)
            // 2. Process must have sufficient virtual address space
            //
            // If privilege is not available, allocation fails gracefully and
            // returns null, allowing caller to fall back to regular pages.
            if (comptime builtin.os.tag != .windows) return null;

            return WindowsLargePages.allocate(len);
        }

        fn hugeFreeWindows(ptr: [*]u8) void {
            // Free Windows large page allocation using VirtualFree
            if (comptime builtin.os.tag != .windows) return;

            WindowsLargePages.deallocate(ptr);
        }

        fn hugeAllocMacos(len: usize) ?[*]u8 {
            // macOS superpage allocation via mmap with VM_FLAGS_SUPERPAGE_SIZE_2MB
            if (comptime builtin.os.tag != .macos) return null;

            // VM_FLAGS_SUPERPAGE_SIZE_2MB = 0x10000
            const VM_FLAGS_SUPERPAGE_SIZE_2MB: u32 = 0x10000;

            const result = std.os.darwin.mmap(
                null,
                len,
                std.os.darwin.PROT.READ | std.os.darwin.PROT.WRITE,
                std.os.darwin.MAP.PRIVATE | std.os.darwin.MAP.ANONYMOUS | VM_FLAGS_SUPERPAGE_SIZE_2MB,
                -1,
                0,
            );

            if (result == std.os.darwin.MAP.FAILED) return null;
            return @ptrFromInt(result);
        }

        fn hugeFreeMacos(ptr: [*]u8, len: usize) void {
            if (comptime builtin.os.tag != .macos) return;
            _ = std.os.darwin.munmap(ptr, len);
        }
    };
}

/// Check if huge pages are available on this system.
pub fn areHugePagesAvailable(page_size: HugePageConfig.PageSize) bool {
    if (comptime builtin.os.tag == .linux) {
        return checkLinuxHugePages(page_size);
    } else if (comptime builtin.os.tag == .windows) {
        return checkWindowsLargePages();
    } else if (comptime builtin.os.tag == .macos) {
        return checkMacosSuperpages();
    }
    return false;
}

fn checkLinuxHugePages(page_size: HugePageConfig.PageSize) bool {
    // Check /sys/kernel/mm/hugepages/hugepages-XXXkB/nr_hugepages
    const size_kb: usize = switch (page_size) {
        .@"2MB" => 2048,
        .@"1GB" => 1048576,
    };

    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/kernel/mm/hugepages/hugepages-{d}kB/nr_hugepages", .{size_kb}) catch return false;

    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    var buf: [32]u8 = undefined;
    const bytes_read = file.read(&buf) catch return false;
    if (bytes_read == 0) return false;

    const count = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace), 10) catch return false;

    return count > 0;
}

fn checkWindowsLargePages() bool {
    // Check if Windows large pages are available.
    // This verifies GetLargePageMinimum() returns a non-zero value.
    // Note: Even if this returns true, actual allocation may fail if
    // SeLockMemoryPrivilege is not granted to the process user.
    if (comptime builtin.os.tag != .windows) return false;

    return WindowsLargePages.isAvailable();
}

fn checkMacosSuperpages() bool {
    // macOS always supports superpages for aligned allocations
    return builtin.os.tag == .macos;
}

/// Get the system's minimum huge page size.
/// On Windows, queries GetLargePageMinimum() for the actual system value.
/// On other platforms, returns the known default (typically 2MB).
pub fn getMinimumHugePageSize() usize {
    if (comptime builtin.os.tag == .linux) {
        // Most Linux systems support 2MB
        return 2 * 1024 * 1024;
    } else if (comptime builtin.os.tag == .windows) {
        // Query actual Windows large page size
        const size = WindowsLargePages.getLargePageSize();
        // If large pages not supported, return typical value for compatibility
        return if (size > 0) size else 2 * 1024 * 1024;
    } else if (comptime builtin.os.tag == .macos) {
        // macOS superpage size is 2MB
        return 2 * 1024 * 1024;
    }
    return 4096; // Standard page size fallback
}

// ============================================================================
// Tests
// ============================================================================

test "HugePageAllocator disabled - uses backing allocator" {
    const TestConfig = HugePageConfig{ .enabled = false };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var huge = HugePageAllocator(TestConfig).init(gpa.allocator());
    var alloc = huge.allocator();

    // Allocate and free should work
    const mem = try alloc.alloc(u8, 1024);
    defer alloc.free(mem);

    try std.testing.expectEqual(@as(usize, 1024), mem.len);
}

test "HugePageAllocator threshold - small allocs use regular pages" {
    const TestConfig = HugePageConfig{
        .enabled = true,
        .threshold = 4096,
        .fallback = true,
    };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var huge = HugePageAllocator(TestConfig).init(gpa.allocator());
    var alloc = huge.allocator();

    // Small allocation should use regular pages
    const mem = try alloc.alloc(u8, 1024);
    defer alloc.free(mem);

    const stats = huge.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.regular_allocations);
    try std.testing.expectEqual(@as(u64, 0), stats.huge_allocations);
}

test "HugePageAllocator stats tracking" {
    const TestConfig = HugePageConfig{ .enabled = false };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var huge = HugePageAllocator(TestConfig).init(gpa.allocator());
    var alloc = huge.allocator();

    // Initial stats
    var stats = huge.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.regular_allocations);

    const mem = try alloc.alloc(u8, 1024);
    defer alloc.free(mem);

    // Hit rate calculation
    const rate = huge.getHugePageRate();
    try std.testing.expect(rate >= 0.0 and rate <= 1.0);
}

test "HugePageAllocator reset stats" {
    const TestConfig = HugePageConfig{ .enabled = false };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var huge = HugePageAllocator(TestConfig).init(gpa.allocator());
    var alloc = huge.allocator();

    const mem = try alloc.alloc(u8, 1024);
    defer alloc.free(mem);

    huge.resetStats();
    const stats = huge.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.total_regular_bytes);
}

test "getMinimumHugePageSize returns reasonable value" {
    const size = getMinimumHugePageSize();
    try std.testing.expect(size >= 4096);
    try std.testing.expect(size <= 2 * 1024 * 1024 * 1024); // 2GB max
}

test "HugePageConfig page size values" {
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), @intFromEnum(HugePageConfig.PageSize.@"2MB"));
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 1024), @intFromEnum(HugePageConfig.PageSize.@"1GB"));
}
