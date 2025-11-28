//! Lock-Free Queue for Entity Transfers
//!
//! Bounded MPMC (Multi-Producer Multi-Consumer) queue using lock-free atomics.
//! Designed for inter-world entity transfer in multi-world ECS pipelines.
//!
//! ## Features
//!
//! - **Lock-free**: No mutex contention, predictable latency
//! - **Bounded**: Fixed capacity, no dynamic allocation after init
//! - **Power-of-2 capacity**: Efficient modulo via bitmask
//! - **Batch operations**: Amortized overhead for bulk transfers
//!
//! ## Algorithm
//!
//! Uses sequence numbers per slot to coordinate producers and consumers.
//! Each slot tracks its "turn" - producers wait for even turns, consumers for odd.
//!
//! Tiger Style: All bounds from config. Zero allocations after init.

const std = @import("std");
const Atomic = std.atomic.Value;

// ============================================================================
// Lock-Free MPMC Queue
// ============================================================================

/// Bounded multi-producer multi-consumer lock-free queue.
///
/// Uses sequence numbers per slot for coordination:
/// - Even sequence = slot available for write
/// - Odd sequence = slot contains data ready to read
///
/// Tiger Style: Capacity must be power of 2. All bounds compile-time checked.
pub fn LockFreeQueue(comptime T: type, comptime capacity: u32) type {
    comptime {
        // Capacity must be power of 2 for efficient modulo
        if (!std.math.isPowerOfTwo(capacity)) {
            @compileError("Queue capacity must be power of 2");
        }
        // Minimum capacity of 2
        if (capacity < 2) {
            @compileError("Queue capacity must be at least 2");
        }
    }

    return struct {
        const Self = @This();

        /// Index type - use u32 for atomic compatibility.
        /// u32 provides enough range for any reasonable queue capacity.
        const Index = u32;

        /// Bitmask for efficient modulo
        const mask: Index = capacity - 1;

        /// Slot holding data and sequence number
        const Slot = struct {
            sequence: Atomic(Index),
            data: T,
        };

        /// Ring buffer of slots
        buffer: [capacity]Slot,
        /// Producer position (tail)
        tail: Atomic(Index),
        /// Consumer position (head)
        head: Atomic(Index),

        /// Initialize an empty queue.
        pub fn init() Self {
            var self: Self = .{
                .buffer = undefined,
                .tail = Atomic(Index).init(0),
                .head = Atomic(Index).init(0),
            };

            // Initialize each slot's sequence to its index
            for (&self.buffer, 0..) |*slot, i| {
                slot.sequence = Atomic(Index).init(@intCast(i));
            }

            return self;
        }

        /// Try to push an item to the queue.
        /// Returns true on success, false if queue is full.
        ///
        /// Thread-safe: multiple producers can call concurrently.
        pub fn push(self: *Self, item: T) bool {
            var pos = self.tail.load(.acquire);

            while (true) {
                const slot = &self.buffer[pos & mask];
                const seq = slot.sequence.load(.acquire);

                // Calculate difference to determine slot state
                const pos_i32: i32 = @intCast(pos);
                const seq_i32: i32 = @intCast(seq);
                const diff = seq_i32 - pos_i32;

                if (diff == 0) {
                    // Slot is available for writing
                    // Try to claim it by advancing tail
                    if (self.tail.cmpxchgWeak(pos, pos +% 1, .acq_rel, .acquire)) |updated_pos| {
                        // Failed, someone else claimed it - retry with updated position
                        pos = updated_pos;
                    } else {
                        // Success - we claimed this slot
                        slot.data = item;
                        // Mark slot as containing data (odd sequence = pos + 1)
                        slot.sequence.store(pos +% 1, .release);
                        return true;
                    }
                } else if (diff < 0) {
                    // Queue is full (consumer hasn't caught up)
                    return false;
                } else {
                    // Slot was already claimed by another producer, reload tail
                    pos = self.tail.load(.acquire);
                }
            }
        }

        /// Try to pop an item from the queue.
        /// Returns the item on success, null if queue is empty.
        ///
        /// Thread-safe: multiple consumers can call concurrently.
        pub fn pop(self: *Self) ?T {
            var pos = self.head.load(.acquire);

            while (true) {
                const slot = &self.buffer[pos & mask];
                const seq = slot.sequence.load(.acquire);

                // Calculate expected sequence for a readable slot
                const expected_seq = pos +% 1;
                const seq_i32: i32 = @intCast(seq);
                const expected_i32: i32 = @intCast(expected_seq);
                const diff = seq_i32 - expected_i32;

                if (diff == 0) {
                    // Slot contains data ready to read
                    // Try to claim it by advancing head
                    if (self.head.cmpxchgWeak(pos, pos +% 1, .acq_rel, .acquire)) |updated_pos| {
                        // Failed, someone else claimed it - retry with updated position
                        pos = updated_pos;
                    } else {
                        // Success - we claimed this slot
                        const data = slot.data;
                        // Mark slot as available for next write cycle
                        slot.sequence.store(pos +% capacity, .release);
                        return data;
                    }
                } else if (diff < 0) {
                    // Queue is empty (producer hasn't written yet)
                    return null;
                } else {
                    // Slot not ready yet, reload head
                    pos = self.head.load(.acquire);
                }
            }
        }

        /// Try to push multiple items at once.
        /// Returns the number of items successfully pushed.
        ///
        /// More efficient than individual pushes when batching.
        pub fn pushBatch(self: *Self, items: []const T) usize {
            var pushed: usize = 0;
            for (items) |item| {
                if (self.push(item)) {
                    pushed += 1;
                } else {
                    break; // Queue full
                }
            }
            return pushed;
        }

        /// Try to pop multiple items at once.
        /// Returns the number of items successfully popped.
        ///
        /// More efficient than individual pops when batching.
        pub fn popBatch(self: *Self, out: []T) usize {
            var popped: usize = 0;
            while (popped < out.len) {
                if (self.pop()) |item| {
                    out[popped] = item;
                    popped += 1;
                } else {
                    break; // Queue empty
                }
            }
            return popped;
        }

        /// Get current approximate length.
        /// Note: May be inaccurate under concurrent access.
        pub fn len(self: *const Self) usize {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            return @intCast(t -% h);
        }

        /// Check if queue is approximately empty.
        /// Note: May be inaccurate under concurrent access.
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        /// Check if queue is approximately full.
        /// Note: May be inaccurate under concurrent access.
        pub fn isFull(self: *const Self) bool {
            return self.len() >= capacity;
        }

        /// Get the queue's capacity.
        pub fn getCapacity(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

// ============================================================================
// SPSC Optimized Queue
// ============================================================================

/// Single-Producer Single-Consumer optimized lock-free queue.
///
/// Uses relaxed atomics where safe for better performance.
/// Only use when exactly one producer and one consumer access the queue.
///
/// Tiger Style: Compile-time capacity. Zero overhead pattern matching.
pub fn SPSCQueue(comptime T: type, comptime capacity: u32) type {
    comptime {
        if (!std.math.isPowerOfTwo(capacity)) {
            @compileError("Queue capacity must be power of 2");
        }
        if (capacity < 2) {
            @compileError("Queue capacity must be at least 2");
        }
    }

    return struct {
        const Self = @This();
        /// Index type - use u32 for atomic compatibility.
        const Index = u32;
        const mask: Index = capacity - 1;

        buffer: [capacity]T,
        /// Write position (only producer modifies)
        write_pos: Atomic(Index) align(64), // Cache line alignment
        /// Read position (only consumer modifies)
        read_pos: Atomic(Index) align(64), // Separate cache line

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .write_pos = Atomic(Index).init(0),
                .read_pos = Atomic(Index).init(0),
            };
        }

        /// Push (producer only).
        /// Returns true on success, false if full.
        pub fn push(self: *Self, item: T) bool {
            const write = self.write_pos.load(.monotonic);
            const read = self.read_pos.load(.acquire);

            // Check if full
            if (write -% read >= capacity) {
                return false;
            }

            self.buffer[write & mask] = item;
            self.write_pos.store(write +% 1, .release);
            return true;
        }

        /// Pop (consumer only).
        /// Returns item on success, null if empty.
        pub fn pop(self: *Self) ?T {
            const read = self.read_pos.load(.monotonic);
            const write = self.write_pos.load(.acquire);

            // Check if empty
            if (read == write) {
                return null;
            }

            const item = self.buffer[read & mask];
            self.read_pos.store(read +% 1, .release);
            return item;
        }

        /// Batch push (producer only).
        pub fn pushBatch(self: *Self, items: []const T) usize {
            var pushed: usize = 0;
            for (items) |item| {
                if (self.push(item)) {
                    pushed += 1;
                } else {
                    break;
                }
            }
            return pushed;
        }

        /// Batch pop (consumer only).
        pub fn popBatch(self: *Self, out: []T) usize {
            var popped: usize = 0;
            while (popped < out.len) {
                if (self.pop()) |item| {
                    out[popped] = item;
                    popped += 1;
                } else {
                    break;
                }
            }
            return popped;
        }

        pub fn len(self: *const Self) usize {
            const write = self.write_pos.load(.acquire);
            const read = self.read_pos.load(.acquire);
            return @intCast(write -% read);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() >= capacity;
        }

        pub fn getCapacity(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "LockFreeQueue basic push/pop" {
    var queue = LockFreeQueue(u32, 8).init();

    // Push items
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    // Pop items in order
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());
    try std.testing.expectEqual(@as(?u32, 3), queue.pop());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "LockFreeQueue full queue" {
    var queue = LockFreeQueue(u32, 4).init();

    // Fill the queue
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));
    try std.testing.expect(queue.push(4));

    // Should be full now
    try std.testing.expect(!queue.push(5));
    try std.testing.expect(queue.isFull());

    // Pop one, should be able to push again
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expect(queue.push(5));
}

test "LockFreeQueue batch operations" {
    var queue = LockFreeQueue(u32, 8).init();

    // Batch push
    const items = [_]u32{ 10, 20, 30, 40, 50 };
    const pushed = queue.pushBatch(&items);
    try std.testing.expectEqual(@as(usize, 5), pushed);

    // Batch pop
    var out: [10]u32 = undefined;
    const popped = queue.popBatch(&out);
    try std.testing.expectEqual(@as(usize, 5), popped);
    try std.testing.expectEqual(@as(u32, 10), out[0]);
    try std.testing.expectEqual(@as(u32, 50), out[4]);
}

test "LockFreeQueue len tracking" {
    var queue = LockFreeQueue(u32, 8).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.len());

    _ = queue.push(1);
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    _ = queue.push(2);
    try std.testing.expectEqual(@as(usize, 2), queue.len());

    _ = queue.pop();
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    _ = queue.pop();
    try std.testing.expect(queue.isEmpty());
}

test "LockFreeQueue wraparound" {
    var queue = LockFreeQueue(u32, 4).init();

    // Fill and drain multiple times to test wraparound
    for (0..3) |cycle| {
        // Fill
        for (0..4) |i| {
            try std.testing.expect(queue.push(@intCast(cycle * 4 + i)));
        }

        // Drain
        for (0..4) |i| {
            try std.testing.expectEqual(
                @as(?u32, @intCast(cycle * 4 + i)),
                queue.pop(),
            );
        }
    }
}

test "SPSCQueue basic operations" {
    var queue = SPSCQueue(u32, 8).init();

    // Push items
    try std.testing.expect(queue.push(100));
    try std.testing.expect(queue.push(200));

    // Pop items
    try std.testing.expectEqual(@as(?u32, 100), queue.pop());
    try std.testing.expectEqual(@as(?u32, 200), queue.pop());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "SPSCQueue full/empty states" {
    var queue = SPSCQueue(u32, 4).init();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(!queue.isFull());

    // Fill completely
    _ = queue.push(1);
    _ = queue.push(2);
    _ = queue.push(3);
    _ = queue.push(4);

    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.isEmpty());
    try std.testing.expect(!queue.push(5)); // Should fail

    // Empty completely
    _ = queue.pop();
    _ = queue.pop();
    _ = queue.pop();
    _ = queue.pop();

    try std.testing.expect(queue.isEmpty());
}

test "SPSCQueue batch operations" {
    var queue = SPSCQueue(u32, 16).init();

    const items = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const pushed = queue.pushBatch(&items);
    try std.testing.expectEqual(@as(usize, 8), pushed);

    var out: [10]u32 = undefined;
    const popped = queue.popBatch(&out);
    try std.testing.expectEqual(@as(usize, 8), popped);

    for (0..8) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), out[i]);
    }
}

test "LockFreeQueue struct data" {
    const TestData = struct {
        id: u32,
        value: f32,
        flag: bool,
    };

    var queue = LockFreeQueue(TestData, 8).init();

    try std.testing.expect(queue.push(.{ .id = 1, .value = 3.14, .flag = true }));
    try std.testing.expect(queue.push(.{ .id = 2, .value = 2.71, .flag = false }));

    const item1 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 1), item1.id);
    try std.testing.expectApproxEqRel(@as(f32, 3.14), item1.value, 0.001);
    try std.testing.expect(item1.flag);

    const item2 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 2), item2.id);
    try std.testing.expect(!item2.flag);
}

test "getCapacity" {
    var queue = LockFreeQueue(u32, 64).init();
    try std.testing.expectEqual(@as(usize, 64), queue.getCapacity());

    var spsc = SPSCQueue(u32, 128).init();
    try std.testing.expectEqual(@as(usize, 128), spsc.getCapacity());
}

// ============================================================================
// Extended Queue Tests (Task: Add Coordination Module Tests)
// ============================================================================

test "LockFreeQueue: FIFO ordering verification" {
    // Verifies the Vyukov-style sequence-based algorithm maintains FIFO order.
    // Push items 1..10, verify len(), pop all and verify FIFO ordering.
    var queue = LockFreeQueue(u32, 16).init();

    // Push items 1..10
    for (1..11) |i| {
        try std.testing.expect(queue.push(@intCast(i)));
    }

    // Verify len() reports 10
    try std.testing.expectEqual(@as(usize, 10), queue.len());

    // Pop all items in order - verify FIFO (1 comes out first)
    for (1..11) |expected| {
        const item = queue.pop();
        try std.testing.expect(item != null);
        try std.testing.expectEqual(@as(u32, @intCast(expected)), item.?);
    }

    // Verify queue is empty after all pops
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "LockFreeQueue: empty queue pop behavior" {
    // Test that empty queue correctly returns null on pop.
    var queue = LockFreeQueue(u32, 8).init();

    // Pop from empty queue - should return null
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
    try std.testing.expect(queue.isEmpty());

    // Push one item
    try std.testing.expect(queue.push(42));
    try std.testing.expect(!queue.isEmpty());

    // Pop - should return item
    try std.testing.expectEqual(@as(?u32, 42), queue.pop());

    // Pop again - should return null
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
    try std.testing.expect(queue.isEmpty());
}

test "LockFreeQueue: capacity boundary stress" {
    // Test behavior exactly at capacity boundaries with push after pop.
    var queue = LockFreeQueue(u32, 4).init();

    // Fill to capacity
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));
    try std.testing.expect(queue.push(4));

    // Verify full (5th push should fail)
    try std.testing.expect(queue.isFull());
    try std.testing.expect(!queue.push(5));
    try std.testing.expectEqual(@as(usize, 4), queue.len());

    // Pop one, verify can push again
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expect(!queue.isFull());
    try std.testing.expect(queue.push(5));
    try std.testing.expect(queue.isFull());

    // Verify remaining items in FIFO order
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());
    try std.testing.expectEqual(@as(?u32, 3), queue.pop());
    try std.testing.expectEqual(@as(?u32, 4), queue.pop());
    try std.testing.expectEqual(@as(?u32, 5), queue.pop());
    try std.testing.expect(queue.isEmpty());
}

test "LockFreeQueue: batch partial fill" {
    // Test pushBatch when queue can only accept partial batch.
    var queue = LockFreeQueue(u32, 4).init();

    // Fill 2 slots first
    try std.testing.expect(queue.push(100));
    try std.testing.expect(queue.push(200));

    // Try to batch push 4 items - should only accept 2
    const items = [_]u32{ 1, 2, 3, 4 };
    const pushed = queue.pushBatch(&items);
    try std.testing.expectEqual(@as(usize, 2), pushed);
    try std.testing.expect(queue.isFull());

    // Verify all items in order
    try std.testing.expectEqual(@as(?u32, 100), queue.pop());
    try std.testing.expectEqual(@as(?u32, 200), queue.pop());
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());
}

test "SPSCQueue: FIFO ordering verification" {
    // Test the cache-line optimized SPSC queue maintains FIFO order.
    var queue = SPSCQueue(u32, 16).init();

    // Push several items (single producer)
    for (1..9) |i| {
        try std.testing.expect(queue.push(@intCast(i)));
    }

    // Pop items and verify order (single consumer)
    for (1..9) |expected| {
        const item = queue.pop();
        try std.testing.expect(item != null);
        try std.testing.expectEqual(@as(u32, @intCast(expected)), item.?);
    }

    // Verify empty
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "SPSCQueue: interleaved push/pop" {
    // Test SPSC queue with interleaved producer/consumer access.
    var queue = SPSCQueue(u32, 8).init();

    // Interleaved push/pop
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());

    try std.testing.expect(queue.push(3));
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());
    try std.testing.expectEqual(@as(?u32, 3), queue.pop());

    // Push more after partial drain
    try std.testing.expect(queue.push(4));
    try std.testing.expect(queue.push(5));
    try std.testing.expectEqual(@as(usize, 2), queue.len());

    try std.testing.expectEqual(@as(?u32, 4), queue.pop());
    try std.testing.expectEqual(@as(?u32, 5), queue.pop());
    try std.testing.expect(queue.isEmpty());
}
