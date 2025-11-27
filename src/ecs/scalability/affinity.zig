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

    fn detectNumaNodeCountLinux() u8 {
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

    fn detectTopology(cpu_count: u16) !CpuTopology {
        // Initialize all CPUs as both physical and logical
        // A more sophisticated implementation would parse /sys/devices/system/cpu/
        // to detect hyperthreading
        var i: u16 = 0;
        while (i < cpu_count and i < CpuTopology.MAX_CPUS) : (i += 1) {
            CpuTopology.physical_buffer[i] = i;
            CpuTopology.logical_buffer[i] = i;
        }

        // Detect NUMA topology
        const numa_count = detectNumaNodeCount();
        var node: u8 = 0;
        while (node < numa_count and node < CpuTopology.MAX_NUMA_NODES) : (node += 1) {
            // Simple round-robin assignment for now
            // A real implementation would parse /sys/devices/system/node/nodeX/cpulist
            var cpu: u16 = 0;
            var node_cpu_count: usize = 0;
            while (cpu < cpu_count) : (cpu += 1) {
                if (cpu % numa_count == node) {
                    CpuTopology.numa_buffer[node][node_cpu_count] = cpu;
                    node_cpu_count += 1;
                }
            }
            CpuTopology.numa_sizes[node] = node_cpu_count;
        }

        // Build slices
        var numa_slices: [CpuTopology.MAX_NUMA_NODES][]const u16 = undefined;
        node = 0;
        while (node < numa_count) : (node += 1) {
            numa_slices[node] = CpuTopology.numa_buffer[node][0..CpuTopology.numa_sizes[node]];
        }

        return .{
            .physical_cores = CpuTopology.physical_buffer[0..cpu_count],
            .logical_cores = CpuTopology.logical_buffer[0..cpu_count],
            .numa_nodes = numa_slices[0..numa_count],
        };
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

    // Use getcpu syscall
    var cpu: u32 = undefined;
    var node: u32 = undefined;

    // SYS_getcpu = 309 on x86_64
    const SYS_getcpu = 309;
    const result = std.os.linux.syscall3(
        @enumFromInt(SYS_getcpu),
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
