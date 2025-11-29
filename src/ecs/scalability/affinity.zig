//! Thread Affinity Manager
//!
//! Provides thread-to-CPU pinning for improved cache locality and
//! predictable latency. Supports multiple affinity strategies and
//! platform-specific implementations.
//!
//! Tiger Style: Strategy-based configuration, graceful fallback on unsupported platforms.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const AffinityConfig = config.AffinityConfig;

/// Architecture-specific syscall numbers for affinity operations.
/// Reference: https://syscall.sh/ and Linux kernel source
/// Why: Syscall numbers vary by architecture; x86_64 != ARM64
const SyscallNumbers = struct {
    /// getcpu syscall - gets current CPU/NUMA node
    /// x86_64: 309, ARM64: 168
    const getcpu = switch (builtin.cpu.arch) {
        .x86_64 => 309,
        .aarch64 => 168,
        else => @compileError("Unsupported architecture for affinity getcpu syscall"),
    };
};

/// Thread affinity manager.
/// Handles CPU topology detection and thread pinning.
pub const AffinityManager = struct {
    const Self = @This();

    /// Total CPU count on the system.
    cpu_count: u16,
    /// Number of NUMA nodes detected.
    numa_node_count: u8,
    /// CPU topology information.
    topology: CpuTopology,
    /// Affinity configuration.
    cfg: AffinityConfig,

    /// CPU topology structure.
    pub const CpuTopology = struct {
        /// Physical core IDs (no hyperthreads).
        physical_cores: []const u16,
        /// All logical core IDs (including hyperthreads).
        logical_cores: []const u16,
        /// NUMA node to CPU mapping.
        numa_nodes: []const []const u16,

        /// Static buffer for topology data.
        const MAX_CPUS = 256;
        const MAX_NUMA_NODES = 64;

        var physical_buffer: [MAX_CPUS]u16 = undefined;
        var logical_buffer: [MAX_CPUS]u16 = undefined;
        var numa_buffer: [MAX_NUMA_NODES][MAX_CPUS]u16 = undefined;
        var numa_sizes: [MAX_NUMA_NODES]usize = undefined;
    };

    /// Initialize affinity manager with automatic topology detection.
    pub fn init(cfg: AffinityConfig) !Self {
        const cpu_count: u16 = @intCast(std.Thread.getCpuCount() catch 1);
        const numa_count = detectNumaNodeCount();
        const topology = try detectTopology(cpu_count);

        return .{
            .cpu_count = cpu_count,
            .numa_node_count = numa_count,
            .topology = topology,
            .cfg = cfg,
        };
    }

    /// Pin the current thread to a specific CPU.
    pub fn pinThread(cpu_id: u16) !void {
        if (comptime builtin.os.tag == .linux) {
            try pinThreadLinux(cpu_id);
        } else if (comptime builtin.os.tag == .windows) {
            try pinThreadWindows(cpu_id);
        } else if (comptime builtin.os.tag == .macos) {
            // macOS doesn't support true CPU affinity
            // We return success but the pinning is advisory
        }
    }

    /// Pin a specific thread handle to a CPU.
    pub fn pinThreadHandle(handle: std.Thread, cpu_id: u16) !void {
        _ = handle;
        // For now, just pin current thread
        // Full implementation would use platform-specific thread handle APIs
        try pinThread(cpu_id);
    }

    /// Get optimal CPU for a thread based on configured strategy.
    pub fn getCpuForThread(self: *const Self, thread_id: u16) u16 {
        if (self.cfg.cpu_bindings) |bindings| {
            // Check explicit bindings first
            for (bindings) |binding| {
                if (binding.thread_id == thread_id) {
                    return binding.cpu_id;
                }
            }
        }

        return switch (self.cfg.strategy) {
            .sequential => self.getSequentialCpu(thread_id),
            .physical_only => self.getPhysicalOnlyCpu(thread_id),
            .numa_spread => self.getNumaSpreadCpu(thread_id),
            .explicit => {
                // No binding found, fall back to sequential
                return self.getSequentialCpu(thread_id);
            },
        };
    }

    /// Pin thread according to strategy.
    pub fn pinThreadByStrategy(self: *const Self, thread_id: u16) !void {
        if (!self.cfg.enabled) return;

        const cpu_id = self.getCpuForThread(thread_id);
        try pinThread(cpu_id);
    }

    /// Get sequential CPU assignment.
    fn getSequentialCpu(self: *const Self, thread_id: u16) u16 {
        return thread_id % self.cpu_count;
    }

    /// Get physical-core-only CPU assignment.
    fn getPhysicalOnlyCpu(self: *const Self, thread_id: u16) u16 {
        if (self.topology.physical_cores.len == 0) {
            return self.getSequentialCpu(thread_id);
        }
        const idx = thread_id % @as(u16, @intCast(self.topology.physical_cores.len));
        return self.topology.physical_cores[idx];
    }

    /// Get NUMA-spread CPU assignment.
    fn getNumaSpreadCpu(self: *const Self, thread_id: u16) u16 {
        if (self.numa_node_count <= 1 or self.topology.numa_nodes.len == 0) {
            return self.getSequentialCpu(thread_id);
        }

        // Distribute threads across NUMA nodes first, then within nodes
        const node_idx = thread_id % self.numa_node_count;
        const node_cores = self.topology.numa_nodes[node_idx];

        if (node_cores.len == 0) {
            return self.getSequentialCpu(thread_id);
        }

        const core_idx = (thread_id / self.numa_node_count) % @as(u16, @intCast(node_cores.len));
        return node_cores[core_idx];
    }

    /// Get the CPU count.
    pub fn getCpuCount(self: *const Self) u16 {
        return self.cpu_count;
    }

    /// Get the NUMA node count.
    pub fn getNumaNodeCount(self: *const Self) u8 {
        return self.numa_node_count;
    }

    /// Check if affinity is supported on this platform.
    pub fn isSupported() bool {
        return builtin.os.tag == .linux or builtin.os.tag == .windows;
    }

    // ─────────────────────────────────────────────────────────────────
    // Platform-specific implementations
    // ─────────────────────────────────────────────────────────────────

    fn pinThreadLinux(cpu_id: u16) !void {
        if (comptime builtin.os.tag != .linux) return;

        // Use CPU_SET equivalent
        var mask = [_]usize{0} ** 16; // Enough for 1024 CPUs
        const word_idx = cpu_id / @bitSizeOf(usize);
        const bit_idx: u6 = @intCast(cpu_id % @bitSizeOf(usize));

        if (word_idx >= mask.len) {
            return error.CpuIdOutOfRange;
        }

        mask[word_idx] = @as(usize, 1) << bit_idx;

        const result = std.os.linux.syscall3(
            .sched_setaffinity,
            0, // current thread
            @sizeOf(@TypeOf(mask)),
            @intFromPtr(&mask),
        );

        if (result != 0) {
            return error.SetAffinityFailed;
        }
    }

    fn pinThreadWindows(cpu_id: u16) !void {
        if (comptime builtin.os.tag != .windows) return;

        // Windows SetThreadAffinityMask
        const mask = @as(usize, 1) << @intCast(cpu_id);

        // Use Windows API
        const handle = std.os.windows.kernel32.GetCurrentThread();
        const result = std.os.windows.kernel32.SetThreadAffinityMask(handle, mask);

        if (result == 0) {
            return error.SetAffinityFailed;
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Topology detection
    // ─────────────────────────────────────────────────────────────────

    fn detectNumaNodeCount() u8 {
        if (comptime builtin.os.tag == .linux) {
            return detectNumaNodeCountLinux();
        }
        return 1;
    }

    /// Get actual NUMA node count from sysfs.
    /// Counts /sys/devices/system/node/node* directories.
    fn detectNumaNodeCountLinux() u8 {
        var count: u8 = 0;
        var i: u8 = 0;
        while (i < CpuTopology.MAX_NUMA_NODES) : (i += 1) {
            var buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "/sys/devices/system/node/node{d}", .{i}) catch break;
            std.fs.accessAbsolute(path, .{}) catch break;
            count += 1;
        }
        return if (count == 0) 1 else count;
    }

    fn detectTopology(cpu_count: u16) !CpuTopology {
        if (comptime builtin.os.tag == .linux) {
            return detectTopologyLinux(cpu_count);
        }
        // Fallback for non-Linux: treat all cores as physical
        return detectTopologyFallback(cpu_count);
    }

    /// Detect topology from Linux sysfs.
    /// Reads /sys/devices/system/cpu/cpuN/topology/core_id to distinguish
    /// physical cores from hyperthreads, and /sys/devices/system/node/nodeM/cpulist
    /// for accurate NUMA node mapping.
    fn detectTopologyLinux(cpu_count: u16) !CpuTopology {
        // Track which physical core IDs we've seen to identify hyperthreads.
        // Key: (package_id << 16) | core_id, Value: first CPU with this core
        var seen_cores: [CpuTopology.MAX_CPUS]u32 = undefined;
        var seen_cores_count: usize = 0;

        var physical_count: usize = 0;
        var logical_count: usize = 0;

        // Process each CPU
        var cpu: u16 = 0;
        while (cpu < cpu_count and cpu < CpuTopology.MAX_CPUS) : (cpu += 1) {
            CpuTopology.logical_buffer[logical_count] = cpu;
            logical_count += 1;

            // Read core_id from sysfs
            const core_info = getLinuxCoreInfo(cpu);
            const core_key = (@as(u32, core_info.package_id) << 16) | core_info.core_id;

            // Check if we've seen this physical core before
            var is_hyperthread = false;
            for (seen_cores[0..seen_cores_count]) |seen| {
                if (seen == core_key) {
                    is_hyperthread = true;
                    break;
                }
            }

            if (!is_hyperthread) {
                // First thread on this physical core
                if (seen_cores_count < CpuTopology.MAX_CPUS) {
                    seen_cores[seen_cores_count] = core_key;
                    seen_cores_count += 1;
                }
                CpuTopology.physical_buffer[physical_count] = cpu;
                physical_count += 1;
            }
        }

        // Detect NUMA topology from sysfs
        const numa_count = detectNumaNodeCount();
        var node: u8 = 0;
        while (node < numa_count and node < CpuTopology.MAX_NUMA_NODES) : (node += 1) {
            const node_cpu_count = getLinuxNodeCpus(node, cpu_count, &CpuTopology.numa_buffer[node]);
            CpuTopology.numa_sizes[node] = node_cpu_count;
        }

        // Build NUMA slices
        var numa_slices: [CpuTopology.MAX_NUMA_NODES][]const u16 = undefined;
        node = 0;
        while (node < numa_count) : (node += 1) {
            numa_slices[node] = CpuTopology.numa_buffer[node][0..CpuTopology.numa_sizes[node]];
        }

        return .{
            .physical_cores = CpuTopology.physical_buffer[0..physical_count],
            .logical_cores = CpuTopology.logical_buffer[0..logical_count],
            .numa_nodes = numa_slices[0..numa_count],
        };
    }

    /// Fallback topology detection for non-Linux platforms.
    /// Treats all CPUs as physical cores (no hyperthread detection).
    fn detectTopologyFallback(cpu_count: u16) CpuTopology {
        var i: u16 = 0;
        while (i < cpu_count and i < CpuTopology.MAX_CPUS) : (i += 1) {
            CpuTopology.physical_buffer[i] = i;
            CpuTopology.logical_buffer[i] = i;
        }

        // Single NUMA node for non-Linux
        var j: u16 = 0;
        while (j < cpu_count) : (j += 1) {
            CpuTopology.numa_buffer[0][j] = j;
        }
        CpuTopology.numa_sizes[0] = cpu_count;

        var numa_slices: [CpuTopology.MAX_NUMA_NODES][]const u16 = undefined;
        numa_slices[0] = CpuTopology.numa_buffer[0][0..cpu_count];

        return .{
            .physical_cores = CpuTopology.physical_buffer[0..cpu_count],
            .logical_cores = CpuTopology.logical_buffer[0..cpu_count],
            .numa_nodes = numa_slices[0..1],
        };
    }

    // ─────────────────────────────────────────────────────────────────
    // Linux sysfs helpers
    // ─────────────────────────────────────────────────────────────────

    /// Core info from sysfs topology.
    const CoreInfo = struct {
        core_id: u16,
        package_id: u16,
    };

    /// Get physical core ID and package ID for a CPU from sysfs.
    /// Returns (0, 0) if sysfs unavailable (fallback behavior).
    fn getLinuxCoreInfo(cpu_id: u16) CoreInfo {
        if (comptime builtin.os.tag != .linux) {
            return .{ .core_id = cpu_id, .package_id = 0 };
        }

        var path_buf: [128]u8 = undefined;

        // Read core_id: /sys/devices/system/cpu/cpu{N}/topology/core_id
        const core_path = std.fmt.bufPrint(
            &path_buf,
            "/sys/devices/system/cpu/cpu{d}/topology/core_id",
            .{cpu_id},
        ) catch return .{ .core_id = cpu_id, .package_id = 0 };

        const core_id = readSysfsInt(core_path) orelse cpu_id;

        // Read package_id: /sys/devices/system/cpu/cpu{N}/topology/physical_package_id
        const pkg_path = std.fmt.bufPrint(
            &path_buf,
            "/sys/devices/system/cpu/cpu{d}/topology/physical_package_id",
            .{cpu_id},
        ) catch return .{ .core_id = core_id, .package_id = 0 };

        const package_id = readSysfsInt(pkg_path) orelse 0;

        return .{ .core_id = core_id, .package_id = package_id };
    }

    /// Get list of CPUs belonging to a NUMA node from sysfs.
    /// Parses /sys/devices/system/node/node{N}/cpulist format (e.g., "0-7,16-23").
    /// Returns number of CPUs written to output buffer.
    fn getLinuxNodeCpus(node_id: u8, max_cpu: u16, output: []u16) usize {
        if (comptime builtin.os.tag != .linux) {
            return 0;
        }

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/sys/devices/system/node/node{d}/cpulist",
            .{node_id},
        ) catch return 0;

        var file_buf: [256]u8 = undefined;
        const content = readSysfsString(path, &file_buf) orelse return fallbackNodeCpus(node_id, max_cpu, output);

        return parseCpuList(content, max_cpu, output);
    }

    /// Fallback: distribute CPUs round-robin across nodes when sysfs unavailable.
    fn fallbackNodeCpus(node_id: u8, max_cpu: u16, output: []u16) usize {
        const numa_count = detectNumaNodeCount();
        var count: usize = 0;
        var cpu: u16 = 0;
        while (cpu < max_cpu and count < output.len) : (cpu += 1) {
            if (cpu % numa_count == node_id) {
                output[count] = cpu;
                count += 1;
            }
        }
        return count;
    }

    /// Read an integer from a sysfs path.
    fn readSysfsInt(path: []const u8) ?u16 {
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        var buf: [64]u8 = undefined;
        const len = file.readAll(&buf) catch return null;
        if (len == 0) return null;

        // Trim trailing newline and whitespace
        var end: usize = len;
        while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == ' ' or buf[end - 1] == '\r')) {
            end -= 1;
        }
        if (end == 0) return null;

        return std.fmt.parseInt(u16, buf[0..end], 10) catch null;
    }

    /// Read a string from a sysfs path into provided buffer.
    fn readSysfsString(path: []const u8, buf: []u8) ?[]const u8 {
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const len = file.readAll(buf) catch return null;
        if (len == 0) return null;

        // Trim trailing newline
        var end: usize = len;
        while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == ' ' or buf[end - 1] == '\r')) {
            end -= 1;
        }

        return buf[0..end];
    }

    /// Parse a cpulist format string (e.g., "0-7,16-23") into CPU IDs.
    /// Returns number of CPUs written to output buffer.
    fn parseCpuList(cpulist: []const u8, max_cpu: u16, output: []u16) usize {
        var count: usize = 0;
        var pos: usize = 0;

        while (pos < cpulist.len and count < output.len) {
            // Skip leading whitespace
            while (pos < cpulist.len and (cpulist[pos] == ' ' or cpulist[pos] == '\t')) {
                pos += 1;
            }
            if (pos >= cpulist.len) break;

            // Parse first number
            const start_num_start = pos;
            while (pos < cpulist.len and cpulist[pos] >= '0' and cpulist[pos] <= '9') {
                pos += 1;
            }
            if (pos == start_num_start) break;

            const start_num = std.fmt.parseInt(u16, cpulist[start_num_start..pos], 10) catch break;

            // Check for range
            if (pos < cpulist.len and cpulist[pos] == '-') {
                pos += 1; // Skip '-'
                const end_num_start = pos;
                while (pos < cpulist.len and cpulist[pos] >= '0' and cpulist[pos] <= '9') {
                    pos += 1;
                }
                const end_num = std.fmt.parseInt(u16, cpulist[end_num_start..pos], 10) catch break;

                // Add range
                var cpu = start_num;
                while (cpu <= end_num and cpu < max_cpu and count < output.len) : (cpu += 1) {
                    output[count] = cpu;
                    count += 1;
                }
            } else {
                // Single CPU
                if (start_num < max_cpu) {
                    output[count] = start_num;
                    count += 1;
                }
            }

            // Skip comma separator
            if (pos < cpulist.len and cpulist[pos] == ',') {
                pos += 1;
            }
        }

        return count;
    }
};

/// Get the current CPU the calling thread is running on.
pub fn getCurrentCpu() ?u16 {
    if (comptime builtin.os.tag == .linux) {
        return getCurrentCpuLinux();
    }
    return null;
}

fn getCurrentCpuLinux() ?u16 {
    if (comptime builtin.os.tag != .linux) return null;

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

    if (result != 0) return null;
    return @truncate(cpu);
}

/// Check if the current thread is pinned to a specific CPU.
pub fn isThreadPinned() bool {
    if (comptime builtin.os.tag == .linux) {
        return isThreadPinnedLinux();
    }
    return false;
}

fn isThreadPinnedLinux() bool {
    if (comptime builtin.os.tag != .linux) return false;

    var mask = [_]usize{0} ** 16;

    const result = std.os.linux.syscall3(
        .sched_getaffinity,
        0, // current thread
        @sizeOf(@TypeOf(mask)),
        @intFromPtr(&mask),
    );

    if (result != 0) return false;

    // Count set bits - if only one bit is set, thread is pinned
    var count: u32 = 0;
    for (mask) |word| {
        count += @popCount(word);
    }

    return count == 1;
}

// ============================================================================
// Tests
// ============================================================================

test "AffinityManager init" {
    const cfg = AffinityConfig{ .enabled = false };
    const manager = try AffinityManager.init(cfg);

    try std.testing.expect(manager.cpu_count >= 1);
    try std.testing.expect(manager.numa_node_count >= 1);
}

test "AffinityManager getCpuForThread sequential" {
    const cfg = AffinityConfig{
        .enabled = true,
        .strategy = .sequential,
    };
    const manager = try AffinityManager.init(cfg);

    // Sequential should cycle through CPUs
    const cpu0 = manager.getCpuForThread(0);
    const cpu1 = manager.getCpuForThread(1);

    try std.testing.expect(cpu0 < manager.cpu_count);
    try std.testing.expect(cpu1 < manager.cpu_count);

    if (manager.cpu_count > 1) {
        try std.testing.expect(cpu0 != cpu1);
    }
}

test "AffinityManager getCpuForThread wraps around" {
    const cfg = AffinityConfig{
        .enabled = true,
        .strategy = .sequential,
    };
    const manager = try AffinityManager.init(cfg);

    // Thread ID > cpu_count should wrap
    const cpu = manager.getCpuForThread(manager.cpu_count + 5);
    try std.testing.expect(cpu < manager.cpu_count);
}

test "AffinityManager explicit bindings" {
    const bindings = [_]AffinityConfig.CpuBinding{
        .{ .thread_id = 0, .cpu_id = 3 },
        .{ .thread_id = 5, .cpu_id = 7 },
    };

    const cfg = AffinityConfig{
        .enabled = true,
        .strategy = .explicit,
        .cpu_bindings = &bindings,
    };
    const manager = try AffinityManager.init(cfg);

    // Explicit binding should return specified CPU
    const cpu0 = manager.getCpuForThread(0);
    try std.testing.expectEqual(@as(u16, 3), cpu0);

    const cpu5 = manager.getCpuForThread(5);
    try std.testing.expectEqual(@as(u16, 7), cpu5);

    // Non-bound thread should fall back to sequential
    const cpu10 = manager.getCpuForThread(10);
    try std.testing.expect(cpu10 < manager.cpu_count);
}

test "AffinityManager isSupported" {
    const supported = AffinityManager.isSupported();
    // Should be true on Linux and Windows
    if (builtin.os.tag == .linux or builtin.os.tag == .windows) {
        try std.testing.expect(supported);
    }
}

test "getCurrentCpu returns valid value or null" {
    const cpu = getCurrentCpu();
    if (cpu) |c| {
        const manager = try AffinityManager.init(.{});
        try std.testing.expect(c < manager.cpu_count);
    }
}

test "AffinityConfig strategies are distinct" {
    try std.testing.expect(@intFromEnum(AffinityConfig.Strategy.sequential) != @intFromEnum(AffinityConfig.Strategy.physical_only));
    try std.testing.expect(@intFromEnum(AffinityConfig.Strategy.numa_spread) != @intFromEnum(AffinityConfig.Strategy.explicit));
}

test "parseCpuList single CPU" {
    var output: [16]u16 = undefined;
    const count = AffinityManager.parseCpuList("5", 32, &output);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u16, 5), output[0]);
}

test "parseCpuList range" {
    var output: [16]u16 = undefined;
    const count = AffinityManager.parseCpuList("0-3", 32, &output);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u16, 0), output[0]);
    try std.testing.expectEqual(@as(u16, 1), output[1]);
    try std.testing.expectEqual(@as(u16, 2), output[2]);
    try std.testing.expectEqual(@as(u16, 3), output[3]);
}

test "parseCpuList mixed ranges and singles" {
    var output: [32]u16 = undefined;
    const count = AffinityManager.parseCpuList("0-2,5,8-10", 32, &output);
    try std.testing.expectEqual(@as(usize, 7), count);
    try std.testing.expectEqual(@as(u16, 0), output[0]);
    try std.testing.expectEqual(@as(u16, 1), output[1]);
    try std.testing.expectEqual(@as(u16, 2), output[2]);
    try std.testing.expectEqual(@as(u16, 5), output[3]);
    try std.testing.expectEqual(@as(u16, 8), output[4]);
    try std.testing.expectEqual(@as(u16, 9), output[5]);
    try std.testing.expectEqual(@as(u16, 10), output[6]);
}

test "parseCpuList respects max_cpu" {
    var output: [16]u16 = undefined;
    // Range 0-10 but max_cpu is 4, so only 0-3 added
    const count = AffinityManager.parseCpuList("0-10", 4, &output);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u16, 3), output[3]);
}

test "parseCpuList empty string" {
    var output: [16]u16 = undefined;
    const count = AffinityManager.parseCpuList("", 32, &output);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "AffinityManager physical_only strategy" {
    const cfg = AffinityConfig{
        .enabled = true,
        .strategy = .physical_only,
    };
    const manager = try AffinityManager.init(cfg);

    // Physical-only should only use physical cores
    const cpu0 = manager.getCpuForThread(0);
    try std.testing.expect(cpu0 < manager.cpu_count);

    // Verify physical cores are valid
    for (manager.topology.physical_cores) |core| {
        try std.testing.expect(core < manager.cpu_count);
    }

    // Physical cores should be subset of all CPUs
    try std.testing.expect(manager.topology.physical_cores.len <= manager.cpu_count);
    try std.testing.expect(manager.topology.physical_cores.len >= 1);
}

test "AffinityManager topology detection" {
    const cfg = AffinityConfig{ .enabled = false };
    const manager = try AffinityManager.init(cfg);

    // Logical cores should include all CPUs
    try std.testing.expectEqual(manager.cpu_count, @as(u16, @intCast(manager.topology.logical_cores.len)));

    // Physical cores should be <= logical cores
    try std.testing.expect(manager.topology.physical_cores.len <= manager.topology.logical_cores.len);

    // Should have at least one NUMA node
    try std.testing.expect(manager.topology.numa_nodes.len >= 1);

    // NUMA node should have CPUs
    if (manager.topology.numa_nodes.len > 0) {
        var total_numa_cpus: usize = 0;
        for (manager.topology.numa_nodes) |node_cpus| {
            total_numa_cpus += node_cpus.len;
        }
        // All CPUs should be assigned to some NUMA node
        try std.testing.expect(total_numa_cpus >= manager.cpu_count);
    }
}
