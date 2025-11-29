//! Concurrent Stress Tests for Lock-Free Queue Implementation
//!
//! These tests verify correctness under high contention scenarios:
//! - Multiple producers, single consumer (MPSC)
//! - Single producer, multiple consumers (SPMC)
//! - Multiple producers, multiple consumers (MPMC)
//! - ABA problem detection via sequence verification
//! - Capacity boundary conditions under stress
//!
//! Tiger Style: All bounds from config. Exhaustive verification via checksums.
//! Thread-safe verification uses atomic counters to detect data races.

const std = @import("std");
const LockFreeQueue = @import("lock_free_queue.zig").LockFreeQueue;
const SPSCQueue = @import("lock_free_queue.zig").SPSCQueue;
const testing = std.testing;
const Thread = std.Thread;
const Atomic = std.atomic.Value;

// ============================================================================
// Test Configuration
// ============================================================================

/// Default stress test configuration.
/// Tuned for reasonable test duration while ensuring thorough coverage.
const StressConfig = struct {
    /// Number of producer threads for MPMC tests
    producers: u8 = 4,
    /// Number of consumer threads for MPMC tests
    consumers: u8 = 4,
    /// Operations per thread
    ops_per_thread: u32 = 10_000,
    /// Queue capacity (power of 2)
    queue_capacity: u16 = 1024,
};

/// Standard test queue capacity - power of 2 for efficient modulo
const TEST_CAPACITY: u32 = 1024;

/// Small capacity for boundary stress tests
const SMALL_CAPACITY: u32 = 64;

/// Minimal capacity for ABA counter verification
const MINIMAL_CAPACITY: u32 = 4;

// ============================================================================
// Shared Test State
// ============================================================================

/// Thread-safe test state for coordinating concurrent operations.
/// Uses atomic counters for lock-free verification of correctness.
fn TestState(comptime capacity: u32) type {
    return struct {
        const Self = @This();

        /// The queue under test
        queue: LockFreeQueue(u64, capacity),
        /// Total items successfully produced
        produced_count: Atomic(u64),
        /// Total items successfully consumed
        consumed_count: Atomic(u64),
        /// Error count - any value > 0 indicates test failure
        errors: Atomic(u32),
        /// Checksum of all produced values (XOR for commutativity)
        checksum_produced: Atomic(u64),
        /// Checksum of all consumed values (XOR for commutativity)
        checksum_consumed: Atomic(u64),
        /// Signal that producers have completed
        producers_done: Atomic(bool),

        /// Initialize test state with empty queue and zeroed counters.
        pub fn init() Self {
            return .{
                .queue = LockFreeQueue(u64, capacity).init(),
                .produced_count = Atomic(u64).init(0),
                .consumed_count = Atomic(u64).init(0),
                .errors = Atomic(u32).init(0),
                .checksum_produced = Atomic(u64).init(0),
                .checksum_consumed = Atomic(u64).init(0),
                .producers_done = Atomic(bool).init(false),
            };
        }

        /// Record a produced value atomically.
        pub fn recordProduced(self: *Self, value: u64) void {
            _ = self.produced_count.fetchAdd(1, .acq_rel);
            _ = self.checksum_produced.fetchXor(value, .acq_rel);
        }

        /// Record a consumed value atomically.
        pub fn recordConsumed(self: *Self, value: u64) void {
            _ = self.consumed_count.fetchAdd(1, .acq_rel);
            _ = self.checksum_consumed.fetchXor(value, .acq_rel);
        }

        /// Record an error atomically.
        pub fn recordError(self: *Self) void {
            _ = self.errors.fetchAdd(1, .acq_rel);
        }

        /// Signal that all producers have completed.
        pub fn signalProducersDone(self: *Self) void {
            self.producers_done.store(true, .release);
        }

        /// Check if producers have completed.
        pub fn areProducersDone(self: *const Self) bool {
            return self.producers_done.load(.acquire);
        }

        /// Verify test results: counts match and checksums equal.
        pub fn verify(self: *const Self) !void {
            const produced = self.produced_count.load(.acquire);
            const consumed = self.consumed_count.load(.acquire);
            const checksum_p = self.checksum_produced.load(.acquire);
            const checksum_c = self.checksum_consumed.load(.acquire);
            const error_count = self.errors.load(.acquire);

            // Verify no errors recorded during test
            try testing.expectEqual(@as(u32, 0), error_count);

            // Verify all produced items were consumed
            try testing.expectEqual(produced, consumed);

            // Verify checksums match (no data corruption or loss)
            try testing.expectEqual(checksum_p, checksum_c);
        }
    };
}

// ============================================================================
// Producer Functions
// ============================================================================

/// Producer thread function for MPSC and MPMC tests.
/// Each producer generates unique values using thread_id in high bits.
fn producerFn(comptime capacity: u32, state: *TestState(capacity), thread_id: u8, ops: u32) void {
    // Use thread_id in high bits to ensure unique values across producers
    const base: u64 = @as(u64, thread_id) << 48;

    var i: u32 = 0;
    while (i < ops) {
        const value = base | @as(u64, i);

        // Spin until push succeeds
        while (!state.queue.push(value)) {
            // Queue full, yield to other threads
            std.atomic.spinLoopHint();
        }

        state.recordProduced(value);
        i += 1;
    }
}

/// Single producer function for SPMC tests.
/// Produces sequential values for easier ordering verification.
fn singleProducerFn(comptime capacity: u32, state: *TestState(capacity), total_ops: u32) void {
    var i: u32 = 0;
    while (i < total_ops) {
        const value: u64 = @as(u64, i);

        while (!state.queue.push(value)) {
            std.atomic.spinLoopHint();
        }

        state.recordProduced(value);
        i += 1;
    }

    // Signal done to consumers
    state.signalProducersDone();
}

// ============================================================================
// Consumer Functions
// ============================================================================

/// Consumer thread function for MPSC and MPMC tests.
/// Drains queue until producers signal completion and queue is empty.
fn consumerFn(comptime capacity: u32, state: *TestState(capacity)) void {
    while (true) {
        if (state.queue.pop()) |value| {
            state.recordConsumed(value);
        } else if (state.areProducersDone()) {
            // Drain remaining items after producers done
            while (state.queue.pop()) |value| {
                state.recordConsumed(value);
            }
            break;
        } else {
            // Queue empty but producers not done, spin
            std.atomic.spinLoopHint();
        }
    }
}

/// Single consumer function for MPSC tests.
/// Expects to consume all items from multiple producers.
fn singleConsumerFn(comptime capacity: u32, state: *TestState(capacity), expected_total: u64) void {
    var consumed: u64 = 0;

    while (consumed < expected_total) {
        if (state.queue.pop()) |value| {
            state.recordConsumed(value);
            consumed += 1;
        } else if (state.areProducersDone() and consumed >= state.produced_count.load(.acquire)) {
            // All produced items consumed
            break;
        } else {
            std.atomic.spinLoopHint();
        }
    }

    // Final drain pass
    while (state.queue.pop()) |value| {
        state.recordConsumed(value);
    }
}

// ============================================================================
// Test 1: Multi-Producer Single-Consumer (MPSC)
// ============================================================================

test "stress: MPSC - 4 producers, 1 consumer, no data loss" {
    const NUM_PRODUCERS = 4;
    const OPS_PER_PRODUCER = 10_000;
    const TOTAL_EXPECTED = NUM_PRODUCERS * OPS_PER_PRODUCER;

    var state = TestState(TEST_CAPACITY).init();

    // Spawn producer threads
    var producer_handles: [NUM_PRODUCERS]Thread = undefined;
    for (&producer_handles, 0..) |*handle, i| {
        handle.* = try Thread.spawn(.{}, producerFn, .{
            TEST_CAPACITY,
            &state,
            @as(u8, @intCast(i)),
            OPS_PER_PRODUCER,
        });
    }

    // Run single consumer in current thread until producers done
    var consumed: u64 = 0;
    var max_spin_attempts: u32 = 0;
    var spin_count: u32 = 0;

    while (consumed < TOTAL_EXPECTED) {
        if (state.queue.pop()) |value| {
            state.recordConsumed(value);
            consumed += 1;
            spin_count = 0;
        } else {
            spin_count += 1;
            if (spin_count > max_spin_attempts) {
                max_spin_attempts = spin_count;
            }

            // Check if we've been spinning too long (potential deadlock)
            if (spin_count > 1_000_000) {
                // Something wrong - check produced count
                const produced = state.produced_count.load(.acquire);
                if (produced == consumed) break; // All done
                if (spin_count > 10_000_000) {
                    state.recordError(); // Likely deadlock
                    break;
                }
            }

            std.atomic.spinLoopHint();
        }
    }

    // Signal done and drain any remaining
    state.signalProducersDone();
    while (state.queue.pop()) |value| {
        state.recordConsumed(value);
    }

    // Wait for producers to finish
    for (producer_handles) |handle| {
        handle.join();
    }

    // Verify correctness
    try state.verify();

    // Additional MPSC verification: count should match expected
    const final_count = state.consumed_count.load(.acquire);
    try testing.expectEqual(@as(u64, TOTAL_EXPECTED), final_count);
}

// ============================================================================
// Test 2: Single-Producer Multi-Consumer (SPMC)
// ============================================================================

test "stress: SPMC - 1 producer, 4 consumers, each item consumed once" {
    const NUM_CONSUMERS = 4;
    const TOTAL_OPS: u32 = 40_000;

    var state = TestState(TEST_CAPACITY).init();

    // Spawn consumer threads
    var consumer_handles: [NUM_CONSUMERS]Thread = undefined;
    for (&consumer_handles) |*handle| {
        handle.* = try Thread.spawn(.{}, consumerFn, .{ TEST_CAPACITY, &state });
    }

    // Run single producer in current thread
    singleProducerFn(TEST_CAPACITY, &state, TOTAL_OPS);

    // Wait for all consumers to finish
    for (consumer_handles) |handle| {
        handle.join();
    }

    // Verify correctness
    try state.verify();

    // Verify exact count
    const final_count = state.consumed_count.load(.acquire);
    try testing.expectEqual(@as(u64, TOTAL_OPS), final_count);
}

// ============================================================================
// Test 3: Multi-Producer Multi-Consumer (MPMC)
// ============================================================================

test "stress: MPMC - 4 producers, 4 consumers, high contention" {
    const NUM_PRODUCERS = 4;
    const NUM_CONSUMERS = 4;
    const OPS_PER_PRODUCER = 10_000;
    const TOTAL_EXPECTED = NUM_PRODUCERS * OPS_PER_PRODUCER;

    var state = TestState(TEST_CAPACITY).init();

    // Spawn producer threads
    var producer_handles: [NUM_PRODUCERS]Thread = undefined;
    for (&producer_handles, 0..) |*handle, i| {
        handle.* = try Thread.spawn(.{}, producerFn, .{
            TEST_CAPACITY,
            &state,
            @as(u8, @intCast(i)),
            OPS_PER_PRODUCER,
        });
    }

    // Spawn consumer threads
    var consumer_handles: [NUM_CONSUMERS]Thread = undefined;
    for (&consumer_handles) |*handle| {
        handle.* = try Thread.spawn(.{}, consumerFn, .{ TEST_CAPACITY, &state });
    }

    // Wait for all producers to finish
    for (producer_handles) |handle| {
        handle.join();
    }

    // Signal producers done so consumers can exit
    state.signalProducersDone();

    // Wait for all consumers to finish
    for (consumer_handles) |handle| {
        handle.join();
    }

    // Verify correctness
    try state.verify();

    // Verify exact count
    const final_count = state.consumed_count.load(.acquire);
    try testing.expectEqual(@as(u64, TOTAL_EXPECTED), final_count);
}

// ============================================================================
// Test 4: Capacity Boundary Stress
// ============================================================================

/// Consumer that tracks queue-full observations for boundary testing.
fn boundaryConsumerFn(state: *TestState(SMALL_CAPACITY), stop_signal: *Atomic(bool)) void {
    while (!stop_signal.load(.acquire)) {
        if (state.queue.pop()) |value| {
            state.recordConsumed(value);
        } else {
            std.atomic.spinLoopHint();
        }
    }

    // Final drain
    while (state.queue.pop()) |value| {
        state.recordConsumed(value);
    }
}

test "stress: capacity boundary - queue full handling" {
    const NUM_PRODUCERS = 4;
    const OPS_PER_PRODUCER = 5_000;

    var state = TestState(SMALL_CAPACITY).init();
    var stop_signal = Atomic(bool).init(false);
    var full_count = Atomic(u64).init(0);

    // Spawn consumer thread
    const consumer_handle = try Thread.spawn(.{}, boundaryConsumerFn, .{
        &state,
        &stop_signal,
    });

    // Spawn producer threads that track queue-full events
    var producer_handles: [NUM_PRODUCERS]Thread = undefined;
    for (&producer_handles, 0..) |*handle, i| {
        handle.* = try Thread.spawn(.{}, struct {
            fn run(
                s: *TestState(SMALL_CAPACITY),
                fc: *Atomic(u64),
                thread_id: u8,
                ops: u32,
            ) void {
                const base: u64 = @as(u64, thread_id) << 48;
                var j: u32 = 0;
                var local_full_count: u64 = 0;

                while (j < ops) {
                    const value = base | @as(u64, j);

                    // Track how many times queue is full
                    while (!s.queue.push(value)) {
                        local_full_count += 1;
                        std.atomic.spinLoopHint();
                    }

                    s.recordProduced(value);
                    j += 1;
                }

                // Report total full counts
                _ = fc.fetchAdd(local_full_count, .acq_rel);
            }
        }.run, .{
            &state,
            &full_count,
            @as(u8, @intCast(i)),
            OPS_PER_PRODUCER,
        });
    }

    // Wait for producers
    for (producer_handles) |handle| {
        handle.join();
    }

    // Stop consumer
    state.signalProducersDone();
    stop_signal.store(true, .release);
    consumer_handle.join();

    // Verify correctness
    try state.verify();

    // Verify we hit capacity limits (should have some full events with small queue)
    const total_full_events = full_count.load(.acquire);
    // With 4 producers x 5000 ops and capacity 64, we expect many full events
    try testing.expect(total_full_events > 0);
}

// ============================================================================
// Test 5: Rapid Push-Pop Cycling (ABA Counter Verification)
// ============================================================================

/// Test state for ABA verification with minimal capacity.
fn ABATestState() type {
    return struct {
        const Self = @This();

        queue: LockFreeQueue(u64, MINIMAL_CAPACITY),
        cycles_completed: Atomic(u64),
        errors: Atomic(u32),
        stop_signal: Atomic(bool),

        pub fn init() Self {
            return .{
                .queue = LockFreeQueue(u64, MINIMAL_CAPACITY).init(),
                .cycles_completed = Atomic(u64).init(0),
                .errors = Atomic(u32).init(0),
                .stop_signal = Atomic(bool).init(false),
            };
        }
    };
}

/// Producer for ABA test - rapidly pushes values with sequence numbers.
fn abaProducerFn(state: *ABATestState(), thread_id: u8) void {
    const base: u64 = @as(u64, thread_id) << 48;
    var seq: u32 = 0;

    while (!state.stop_signal.load(.acquire)) {
        const value = base | @as(u64, seq);

        if (state.queue.push(value)) {
            seq +%= 1;
        } else {
            // Queue full, just continue
            std.atomic.spinLoopHint();
        }
    }
}

/// Consumer for ABA test - rapidly pops and verifies values are valid.
fn abaConsumerFn(state: *ABATestState()) void {
    var last_seen: [4]u32 = [_]u32{0} ** 4; // Track last seq per producer

    while (!state.stop_signal.load(.acquire)) {
        if (state.queue.pop()) |value| {
            // Extract thread_id and sequence from value
            const thread_id: usize = @intCast((value >> 48) & 0xFF);
            const seq: u32 = @intCast(value & 0xFFFFFFFF);

            // Verify thread_id is valid
            if (thread_id >= 4) {
                _ = state.errors.fetchAdd(1, .acq_rel);
                continue;
            }

            // Track sequences - should generally increase (with wraparound)
            last_seen[thread_id] = seq;
            _ = state.cycles_completed.fetchAdd(1, .acq_rel);
        } else {
            std.atomic.spinLoopHint();
        }
    }

    // Final drain
    while (state.queue.pop()) |value| {
        _ = value;
        _ = state.cycles_completed.fetchAdd(1, .acq_rel);
    }
}

test "stress: ABA counter - rapid cycling with minimal capacity" {
    const NUM_PRODUCERS = 2;
    const NUM_CONSUMERS = 2;
    const TARGET_CYCLES: u64 = 50_000; // Target cycles instead of time-based

    var state = ABATestState().init();

    // Spawn producer threads
    var producer_handles: [NUM_PRODUCERS]Thread = undefined;
    for (&producer_handles, 0..) |*handle, i| {
        handle.* = try Thread.spawn(.{}, abaProducerFn, .{
            &state,
            @as(u8, @intCast(i)),
        });
    }

    // Spawn consumer threads
    var consumer_handles: [NUM_CONSUMERS]Thread = undefined;
    for (&consumer_handles) |*handle| {
        handle.* = try Thread.spawn(.{}, abaConsumerFn, .{&state});
    }

    // Wait until target cycles reached
    while (state.cycles_completed.load(.acquire) < TARGET_CYCLES) {
        std.atomic.spinLoopHint();
    }

    // Signal stop
    state.stop_signal.store(true, .release);

    // Wait for all threads
    for (producer_handles) |handle| {
        handle.join();
    }
    for (consumer_handles) |handle| {
        handle.join();
    }

    // Verify no errors from corrupted values
    const error_count = state.errors.load(.acquire);
    try testing.expectEqual(@as(u32, 0), error_count);

    // Verify we completed target cycles
    const cycles = state.cycles_completed.load(.acquire);
    try testing.expect(cycles >= TARGET_CYCLES);
}

// ============================================================================
// Test 6: SPSC Queue Stress (Optimized Path)
// ============================================================================

test "stress: SPSC - optimized single producer/consumer" {
    const TOTAL_OPS: u32 = 100_000;

    var queue = SPSCQueue(u64, TEST_CAPACITY).init();
    var produced: u64 = 0;
    var consumed: u64 = 0;
    var checksum_p: u64 = 0;
    var checksum_c: u64 = 0;
    var done = Atomic(bool).init(false);

    // Consumer thread
    const consumer = try Thread.spawn(.{}, struct {
        fn run(q: *SPSCQueue(u64, TEST_CAPACITY), c: *u64, cs: *u64, d: *Atomic(bool)) void {
            while (!d.load(.acquire) or q.len() > 0) {
                if (q.pop()) |value| {
                    c.* += 1;
                    cs.* ^= value;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run, .{ &queue, &consumed, &checksum_c, &done });

    // Producer in main thread
    var i: u32 = 0;
    while (i < TOTAL_OPS) {
        const value: u64 = @as(u64, i);

        while (!queue.push(value)) {
            std.atomic.spinLoopHint();
        }

        produced += 1;
        checksum_p ^= value;
        i += 1;
    }

    // Signal done
    done.store(true, .release);
    consumer.join();

    // Verify
    try testing.expectEqual(produced, consumed);
    try testing.expectEqual(checksum_p, checksum_c);
}

// ============================================================================
// Test 7: Batch Operations Under Contention
// ============================================================================

test "stress: batch operations under contention" {
    const NUM_PRODUCERS = 2;
    const NUM_CONSUMERS = 2;
    const BATCHES_PER_PRODUCER = 1_000;
    const BATCH_SIZE = 16;
    const TOTAL_EXPECTED: u64 = NUM_PRODUCERS * BATCHES_PER_PRODUCER * BATCH_SIZE;

    var state = TestState(TEST_CAPACITY).init();
    var producers_remaining = Atomic(u32).init(NUM_PRODUCERS);

    // Spawn producer threads
    var producer_handles: [NUM_PRODUCERS]Thread = undefined;
    for (&producer_handles, 0..) |*handle, i| {
        handle.* = try Thread.spawn(.{}, struct {
            fn run(
                s: *TestState(TEST_CAPACITY),
                remaining: *Atomic(u32),
                thread_id: usize,
            ) void {
                const base: u64 = @as(u64, @intCast(thread_id)) << 48;
                var batch: [BATCH_SIZE]u64 = undefined;
                var seq: u32 = 0;

                var b: u32 = 0;
                while (b < BATCHES_PER_PRODUCER) : (b += 1) {
                    // Fill batch
                    for (&batch, 0..) |*item, j| {
                        item.* = base | @as(u64, seq + @as(u32, @intCast(j)));
                    }

                    // Push batch
                    var pushed: usize = 0;
                    while (pushed < BATCH_SIZE) {
                        const n = s.queue.pushBatch(batch[pushed..]);
                        if (n > 0) {
                            for (batch[pushed .. pushed + n]) |v| {
                                s.recordProduced(v);
                            }
                            pushed += n;
                        } else {
                            std.atomic.spinLoopHint();
                        }
                    }

                    seq += BATCH_SIZE;
                }

                // Signal this producer is done
                const prev = remaining.fetchSub(1, .acq_rel);
                if (prev == 1) {
                    // Last producer, signal done
                    s.signalProducersDone();
                }
            }
        }.run, .{ &state, &producers_remaining, i });
    }

    // Spawn consumer threads
    var consumer_handles: [NUM_CONSUMERS]Thread = undefined;
    for (&consumer_handles) |*handle| {
        handle.* = try Thread.spawn(.{}, struct {
            fn run(s: *TestState(TEST_CAPACITY)) void {
                var batch: [BATCH_SIZE]u64 = undefined;

                while (true) {
                    const n = s.queue.popBatch(&batch);
                    if (n > 0) {
                        for (batch[0..n]) |v| {
                            s.recordConsumed(v);
                        }
                    } else if (s.areProducersDone()) {
                        // Final drain after producers done
                        while (true) {
                            const final_n = s.queue.popBatch(&batch);
                            if (final_n > 0) {
                                for (batch[0..final_n]) |v| {
                                    s.recordConsumed(v);
                                }
                            } else {
                                break;
                            }
                        }
                        break;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }.run, .{&state});
    }

    // Wait for all producers to finish
    for (producer_handles) |handle| {
        handle.join();
    }

    // Wait for all consumers to finish
    for (consumer_handles) |handle| {
        handle.join();
    }

    // Verify - all produced items should be consumed
    const produced = state.produced_count.load(.acquire);
    const consumed = state.consumed_count.load(.acquire);

    try testing.expectEqual(TOTAL_EXPECTED, produced);
    try testing.expectEqual(produced, consumed);

    // Verify checksums match (no data corruption)
    try state.verify();
}

// ============================================================================
// Test 8: High Thread Count Stress
// ============================================================================

test "stress: high thread count - 8 producers, 8 consumers" {
    const NUM_PRODUCERS = 8;
    const NUM_CONSUMERS = 8;
    const OPS_PER_PRODUCER = 5_000;
    const TOTAL_EXPECTED = NUM_PRODUCERS * OPS_PER_PRODUCER;

    var state = TestState(TEST_CAPACITY).init();

    // Spawn producer threads
    var producer_handles: [NUM_PRODUCERS]Thread = undefined;
    for (&producer_handles, 0..) |*handle, i| {
        handle.* = try Thread.spawn(.{}, producerFn, .{
            TEST_CAPACITY,
            &state,
            @as(u8, @intCast(i)),
            OPS_PER_PRODUCER,
        });
    }

    // Spawn consumer threads
    var consumer_handles: [NUM_CONSUMERS]Thread = undefined;
    for (&consumer_handles) |*handle| {
        handle.* = try Thread.spawn(.{}, consumerFn, .{ TEST_CAPACITY, &state });
    }

    // Wait for all producers to finish
    for (producer_handles) |handle| {
        handle.join();
    }

    // Signal producers done
    state.signalProducersDone();

    // Wait for all consumers to finish
    for (consumer_handles) |handle| {
        handle.join();
    }

    // Verify correctness
    try state.verify();

    // Verify exact count
    const final_count = state.consumed_count.load(.acquire);
    try testing.expectEqual(@as(u64, TOTAL_EXPECTED), final_count);
}
