//! Concurrent Command Buffers - Thread-Safe Parallel Command Collection
//!
//! This module provides per-system command buffers for concurrent execution.
//! When systems run in parallel, each system gets its own command buffer to
//! avoid data races. After the stage completes, all per-system buffers are
//! merged into the main buffer in deterministic order.
//!
//! ## Thread Safety Contract
//!
//! This module enforces a two-phase access pattern:
//!
//! **Phase 1 - Collection Phase (parallel safe):**
//! - Multiple threads can call `acquireBuffer()` or `getForSystem()` concurrently
//! - Each thread MUST use a unique `system_index` (enforced by caller)
//! - Threads MUST call `releaseBuffer()` when done (if using acquire pattern)
//! - `mergeInto()`/`clearAll()` are FORBIDDEN during this phase
//!
//! **Phase 2 - Exclusive Phase (single-threaded only):**
//! - Only ONE thread may call `mergeInto()` or `clearAll()`
//! - ALL collection phase operations MUST be complete first
//! - `acquireBuffer()`/`getForSystem()` are FORBIDDEN during this phase
//!
//! ## Enforcement Mechanism
//!
//! - `active_accessors`: Atomic counter tracking buffers currently in use
//! - `in_exclusive_phase`: Atomic flag set during merge/clear operations
//! - Fail-fast assertions detect contract violations in debug builds
//! - Release builds still use atomic operations for memory ordering
//!
//! ## Usage Patterns
//!
//! **Safe pattern (recommended):**
//! ```zig
//! // Collection phase - multiple threads
//! var guard = concurrent_bufs.acquireBuffer(system_index);
//! defer guard.release();
//! guard.buffer.despawn(handle);
//!
//! // ... synchronization barrier ...
//!
//! // Exclusive phase - single thread
//! _ = concurrent_bufs.mergeInto(&target);
//! ```
//!
//! **Legacy pattern (for existing code):**
//! ```zig
//! // Collection phase - caller must ensure proper lifecycle
//! const buf = concurrent_bufs.getForSystem(system_index);
//! buf.despawn(handle);
//!
//! // ... synchronization barrier (caller responsibility) ...
//!
//! // Exclusive phase - caller must ensure no concurrent access
//! _ = concurrent_bufs.mergeInto(&target);
//! ```
//!
//! Tiger Style: Buffer sizes derived from config, divided by max systems.
//! Fail-fast on detected contract violations.

const std = @import("std");

const command_buffer = @import("command_buffer.zig");
const CommandBufferType = command_buffer.CommandBufferType;

const config_mod = @import("../config.zig");
const WorldConfig = config_mod.WorldConfig;

const entity_mod = @import("../world/entity.zig");
const EntityHandle = entity_mod.EntityHandle;
const EntityId = entity_mod.EntityId;

// ============================================================================
// Concurrent Command Buffers
// ============================================================================

/// Per-system command buffers for concurrent execution.
///
/// When systems run in parallel (concurrent_threadpool mode), each system
/// gets its own command buffer to avoid data races. After the stage completes,
/// all per-system buffers are merged into the main buffer in deterministic order.
///
/// ## Thread Safety
///
/// This type enforces a two-phase access contract:
/// 1. **Collection phase**: Multiple threads acquire unique buffers via `acquireBuffer()`
/// 2. **Exclusive phase**: Single thread merges/clears via `mergeInto()`/`clearAll()`
///
/// Contract violations trigger fail-fast assertions in debug builds.
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

        // ====================================================================
        // Thread Safety State
        // ====================================================================

        /// Per-system command buffers.
        buffers: [max_systems]PerSystemBuffer = .{PerSystemBuffer.init()} ** max_systems,

        /// Highest system index that has been accessed + 1.
        /// Used to track which buffers need merging/clearing.
        /// Atomic to prevent race conditions when concurrent systems call getForSystem().
        active_count: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

        /// Number of threads currently holding buffer references.
        /// Must be 0 before entering exclusive phase.
        /// Tiger Style: Enforces collection/exclusive phase contract.
        active_accessors: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),

        /// Flag indicating exclusive phase is active (merge/clear in progress).
        /// Prevents new buffer acquisitions during exclusive operations.
        /// Tiger Style: Fail-fast on contract violations.
        in_exclusive_phase: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        // ====================================================================
        // RAII Guard for Safe Buffer Access
        // ====================================================================

        /// RAII guard for safe buffer access. Automatically releases the buffer
        /// when the guard goes out of scope.
        ///
        /// Tiger Style: Use defer pattern for exception-safe resource management.
        pub const BufferGuard = struct {
            /// Reference to the parent concurrent buffers.
            parent: *Self,
            /// The acquired buffer for this system.
            buffer: *PerSystemBuffer,
            /// System index for this buffer (for debugging/assertions).
            system_index: u16,
            /// Whether this guard has been released.
            released: bool = false,

            /// Release the buffer, signaling this accessor is done.
            /// Safe to call multiple times (subsequent calls are no-ops).
            pub fn release(self: *BufferGuard) void {
                if (!self.released) {
                    self.released = true;
                    // Decrement active accessor count with release ordering
                    // to ensure all buffer writes are visible before decrement.
                    const prev = self.parent.active_accessors.fetchSub(1, .release);
                    // Invariant: active_accessors should never underflow
                    std.debug.assert(prev > 0);
                }
            }

            /// Destructor ensures release is called.
            pub fn deinit(self: *BufferGuard) void {
                self.release();
            }
        };

        // ====================================================================
        // Initialization
        // ====================================================================

        /// Initialize concurrent command buffers.
        pub fn init() Self {
            return .{};
        }

        // ====================================================================
        // Collection Phase API (Thread-Safe)
        // ====================================================================

        /// Acquire a command buffer for a specific system index (RECOMMENDED).
        ///
        /// Returns a BufferGuard that MUST be released when the system is done
        /// writing commands. Use with defer for automatic cleanup:
        ///
        /// ```zig
        /// var guard = concurrent_bufs.acquireBuffer(system_index);
        /// defer guard.release();
        /// guard.buffer.despawn(handle);
        /// ```
        ///
        /// ## Thread Safety
        /// - Thread-safe: Multiple threads can acquire different buffers concurrently
        /// - Precondition: system_index < max_concurrent_systems
        /// - Precondition: Not in exclusive phase (asserts in debug, UB in release)
        /// - Contract: Each thread must use a unique system_index
        ///
        /// Tiger Style: Fail-fast assertion on phase violation.
        pub fn acquireBuffer(self: *Self, system_index: u16) BufferGuard {
            // Assert not in exclusive phase (would cause data race)
            const in_exclusive = self.in_exclusive_phase.load(.acquire);
            std.debug.assert(!in_exclusive); // Thread safety contract violation!

            std.debug.assert(system_index < max_systems);

            // Increment accessor count with acquire ordering
            _ = self.active_accessors.fetchAdd(1, .acquire);

            // Double-check: ensure exclusive phase didn't start between check and increment
            // This is a TOCTOU check - if exclusive phase started, we must abort
            if (self.in_exclusive_phase.load(.acquire)) {
                // Race detected: exclusive phase started after our first check
                // Roll back our increment and fail
                _ = self.active_accessors.fetchSub(1, .release);
                std.debug.panic("Thread safety violation: acquireBuffer called during exclusive phase", .{});
            }

            // Update highest system index seen
            _ = self.active_count.fetchMax(system_index + 1, .release);

            return BufferGuard{
                .parent = self,
                .buffer = &self.buffers[system_index],
                .system_index = system_index,
            };
        }

        /// Get the command buffer for a specific system index (LEGACY API).
        ///
        /// **Warning**: This API does not track buffer lifecycle. The caller is
        /// responsible for ensuring no concurrent access during merge/clear.
        /// Prefer `acquireBuffer()` for safer usage.
        ///
        /// ## Thread Safety
        /// - Thread-safe for concurrent read access to different buffers
        /// - Precondition: system_index < max_concurrent_systems
        /// - Precondition: Not in exclusive phase (asserts in debug)
        /// - Contract: Caller must ensure all buffer usage is complete before merge
        ///
        /// Tiger Style: System index must be < max_systems.
        pub fn getForSystem(self: *Self, system_index: u16) *PerSystemBuffer {
            // Assert not in exclusive phase (would cause data race)
            const in_exclusive = self.in_exclusive_phase.load(.acquire);
            std.debug.assert(!in_exclusive); // Thread safety contract violation!

            std.debug.assert(system_index < max_systems);

            // Atomically update active_count to max(active_count, system_index + 1)
            // This ensures thread-safe tracking of highest system index used.
            _ = self.active_count.fetchMax(system_index + 1, .release);
            return &self.buffers[system_index];
        }

        // ====================================================================
        // Exclusive Phase API (Single-Threaded Only)
        // ====================================================================

        /// Merge all active per-system buffers into a target buffer.
        ///
        /// Commands are merged in system index order for deterministic results.
        /// After merge, all per-system buffers are cleared.
        ///
        /// ## Thread Safety
        /// - **NOT thread-safe**: Must be called from a single thread only
        /// - Precondition: All acquireBuffer() guards MUST be released first
        /// - Precondition: No concurrent getForSystem() calls in progress
        /// - Postcondition: All per-system buffers are cleared
        ///
        /// ## Returns
        /// The number of commands merged, or 0 if target would overflow.
        ///
        /// Tiger Style: Fail-fast assertion if accessors still active.
        pub fn mergeInto(self: *Self, target: anytype) usize {
            // Enter exclusive phase - fail-fast if already in exclusive phase
            const was_exclusive = self.in_exclusive_phase.swap(true, .acq_rel);
            std.debug.assert(!was_exclusive); // Concurrent exclusive operations!

            // Verify no active accessors (collection phase must be complete)
            const accessor_count = self.active_accessors.load(.acquire);
            std.debug.assert(accessor_count == 0); // Thread safety contract violation: buffers still in use!

            // Perform merge operation (now safe - exclusive access guaranteed)
            var merged_count: usize = 0;
            const current_active = self.active_count.load(.acquire);

            for (0..current_active) |i| {
                const src = &self.buffers[i];
                for (src.getCommands()) |cmd| {
                    // Check if target can accept more commands
                    if (target.count >= @TypeOf(target.*).max_command_count) {
                        // Target is full, stop merging
                        self.clearAllInternal(current_active);
                        self.in_exclusive_phase.store(false, .release);
                        return merged_count;
                    }

                    // Copy command to target
                    target.commands[target.count] = convertCommand(cmd);
                    target.count += 1;
                    merged_count += 1;
                }
                src.clear();
            }

            self.active_count.store(0, .release);

            // Exit exclusive phase
            self.in_exclusive_phase.store(false, .release);
            return merged_count;
        }

        /// Clear all per-system buffers.
        ///
        /// ## Thread Safety
        /// - **NOT thread-safe**: Must be called from a single thread only
        /// - Precondition: All acquireBuffer() guards MUST be released first
        /// - Precondition: No concurrent getForSystem() calls in progress
        ///
        /// Tiger Style: Fail-fast assertion if accessors still active.
        pub fn clearAll(self: *Self) void {
            // Enter exclusive phase - fail-fast if already in exclusive phase
            const was_exclusive = self.in_exclusive_phase.swap(true, .acq_rel);
            std.debug.assert(!was_exclusive); // Concurrent exclusive operations!

            // Verify no active accessors (collection phase must be complete)
            const accessor_count = self.active_accessors.load(.acquire);
            std.debug.assert(accessor_count == 0); // Thread safety contract violation: buffers still in use!

            // Perform clear operation (now safe - exclusive access guaranteed)
            const current_active = self.active_count.load(.acquire);
            self.clearAllInternal(current_active);

            // Exit exclusive phase
            self.in_exclusive_phase.store(false, .release);
        }

        /// Internal clear helper - does not manage exclusive phase.
        fn clearAllInternal(self: *Self, count: usize) void {
            for (0..count) |i| {
                self.buffers[i].clear();
            }
            self.active_count.store(0, .release);
        }

        // ====================================================================
        // Query API (Read-Only, Collection Phase Safe)
        // ====================================================================

        /// Get total commands across all active buffers.
        ///
        /// ## Thread Safety
        /// - Safe to call during collection phase (provides snapshot)
        /// - Result may be stale if buffers are being modified concurrently
        /// - For accurate count, call only after collection phase is complete
        pub fn totalCommands(self: *const Self) usize {
            var total: usize = 0;
            const current_active = self.active_count.load(.acquire);
            for (0..current_active) |i| {
                total += self.buffers[i].count;
            }
            return total;
        }

        /// Check if any buffer is approaching capacity.
        ///
        /// ## Thread Safety
        /// - Safe to call during collection phase (provides snapshot)
        /// - Result may be stale if buffers are being modified concurrently
        pub fn anyNearCapacity(self: *const Self, threshold: usize) bool {
            const current_active = self.active_count.load(.acquire);
            for (0..current_active) |i| {
                if (self.buffers[i].count >= threshold) {
                    return true;
                }
            }
            return false;
        }

        /// Check if currently in exclusive phase.
        /// Useful for debugging and contract verification.
        pub fn isInExclusivePhase(self: *const Self) bool {
            return self.in_exclusive_phase.load(.acquire);
        }

        /// Get count of active buffer accessors.
        /// Useful for debugging and contract verification.
        pub fn getActiveAccessorCount(self: *const Self) u16 {
            return self.active_accessors.load(.acquire);
        }

        // ====================================================================
        // Internal Helpers
        // ====================================================================

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
// Tests
// ============================================================================

test "ConcurrentCommandBuffers basic operations with legacy API" {
    const ConcurrentBufs = ConcurrentCommandBuffers(4, 40, 64);
    var bufs = ConcurrentBufs.init();

    // Verify initial state
    try std.testing.expect(!bufs.isInExclusivePhase());
    try std.testing.expectEqual(@as(u16, 0), bufs.getActiveAccessorCount());

    // Get first two buffers using legacy API - buffers start empty
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

    // Clear all (legacy API doesn't track accessors, so we can call this)
    bufs.clearAll();
    try std.testing.expectEqual(@as(usize, 0), bufs.getForSystem(0).count);
    try std.testing.expectEqual(@as(usize, 0), bufs.getForSystem(1).count);
}

test "ConcurrentCommandBuffers BufferGuard pattern" {
    const ConcurrentBufs = ConcurrentCommandBuffers(4, 40, 64);
    var bufs = ConcurrentBufs.init();

    // Verify initial state
    try std.testing.expectEqual(@as(u16, 0), bufs.getActiveAccessorCount());

    const handle0 = EntityHandle.fromId(EntityId.init(1, 0));
    const handle1 = EntityHandle.fromId(EntityId.init(2, 0));

    // Use BufferGuard pattern (recommended)
    {
        var guard0 = bufs.acquireBuffer(0);
        try std.testing.expectEqual(@as(u16, 1), bufs.getActiveAccessorCount());

        var guard1 = bufs.acquireBuffer(1);
        try std.testing.expectEqual(@as(u16, 2), bufs.getActiveAccessorCount());

        // Add commands through guards
        try std.testing.expect(guard0.buffer.despawn(handle0));
        try std.testing.expect(guard1.buffer.despawn(handle1));

        // Release buffers
        guard0.release();
        try std.testing.expectEqual(@as(u16, 1), bufs.getActiveAccessorCount());

        guard1.release();
        try std.testing.expectEqual(@as(u16, 0), bufs.getActiveAccessorCount());

        // Double release is safe (no-op)
        guard0.release();
        guard1.release();
        try std.testing.expectEqual(@as(u16, 0), bufs.getActiveAccessorCount());
    }

    // Verify commands were added (2 despawn commands)
    try std.testing.expectEqual(@as(usize, 2), bufs.totalCommands());

    // Now safe to merge
    bufs.clearAll();
}

test "ConcurrentCommandBuffers merge operations" {
    // Use matching data sizes (64 bytes) between concurrent and target buffers
    const ConcurrentBufs = ConcurrentCommandBuffers(3, 30, 64);
    const SingleBuf = CommandBufferType(30, 64);

    var concurrent = ConcurrentBufs.init();
    var target = SingleBuf.init();

    // Add commands to each concurrent buffer using legacy API
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
    try std.testing.expectEqual(@as(usize, 5), concurrent.totalCommands());

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

test "ConcurrentCommandBuffers exclusive phase tracking" {
    const ConcurrentBufs = ConcurrentCommandBuffers(4, 40, 64);
    var bufs = ConcurrentBufs.init();

    // Initially not in exclusive phase
    try std.testing.expect(!bufs.isInExclusivePhase());

    // Add a command
    const handle = EntityHandle.fromId(EntityId.init(1, 0));
    _ = bufs.getForSystem(0).despawn(handle);

    // clearAll enters and exits exclusive phase
    bufs.clearAll();
    try std.testing.expect(!bufs.isInExclusivePhase());

    // Verify buffers were cleared
    try std.testing.expectEqual(@as(usize, 0), bufs.totalCommands());
}

test "ConcurrentCommandBuffers merge with BufferGuard workflow" {
    const ConcurrentBufs = ConcurrentCommandBuffers(3, 30, 64);
    const SingleBuf = CommandBufferType(30, 64);

    var concurrent = ConcurrentBufs.init();
    var target = SingleBuf.init();

    // Simulate collection phase with BufferGuard
    {
        var guard0 = concurrent.acquireBuffer(0);
        var guard1 = concurrent.acquireBuffer(1);
        var guard2 = concurrent.acquireBuffer(2);

        const handle0 = EntityHandle.fromId(EntityId.init(10, 0));
        const handle1 = EntityHandle.fromId(EntityId.init(20, 0));
        const handle2 = EntityHandle.fromId(EntityId.init(30, 0));

        _ = guard0.buffer.despawn(handle0);
        _ = guard1.buffer.despawn(handle1);
        _ = guard2.buffer.despawn(handle2);

        // Release all guards before merge
        guard0.release();
        guard1.release();
        guard2.release();
    }

    // Verify all accessors released
    try std.testing.expectEqual(@as(u16, 0), concurrent.getActiveAccessorCount());

    // Now safe to merge
    const merge_count = concurrent.mergeInto(&target);
    try std.testing.expectEqual(@as(usize, 3), merge_count);
    try std.testing.expectEqual(@as(usize, 3), target.count);
}

test "ConcurrentCommandBuffers anyNearCapacity" {
    const ConcurrentBufs = ConcurrentCommandBuffers(2, 20, 64);
    var bufs = ConcurrentBufs.init();

    // Initially no buffers near capacity
    try std.testing.expect(!bufs.anyNearCapacity(5));

    // Add commands to first buffer
    const buf0 = bufs.getForSystem(0);
    const handle = EntityHandle.fromId(EntityId.init(1, 0));

    for (0..5) |_| {
        _ = buf0.despawn(handle);
    }

    // Now buffer 0 is at threshold
    try std.testing.expect(bufs.anyNearCapacity(5));
    try std.testing.expect(!bufs.anyNearCapacity(6));

    bufs.clearAll();
}
