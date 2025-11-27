//! Event Queue - Comptime-Generated Ring Buffer for Inter-System Communication
//!
//! Provides a fixed-size ring buffer type that can be used as a component or resource
//! for efficient event passing between systems. Follows Tiger Style with config-driven
//! bounds.
//!
//! Example usage:
//! ```zig
//! const DamageEvents = EventQueue(DamageEvent, 128);
//! var queue = DamageEvents.init();
//! queue.push(.{ .target = entity, .amount = 10 });
//! for (queue.iter()) |event| {
//!     // process event
//! }
//! queue.clear();
//! ```

const std = @import("std");
const assert = std.debug.assert;

/// Error types for event queue operations.
pub const EventQueueError = error{
    /// Queue is full and cannot accept more events.
    QueueFull,
};

/// Generate a fixed-size event queue type for the given event type and capacity.
///
/// The queue uses ring buffer semantics. When full:
/// - `push()` returns `QueueFull` error
/// - `pushOrOverwrite()` overwrites the oldest event
///
/// All bounds are comptime-known, ensuring no runtime allocation.
///
/// Parameters:
/// - `T`: The event type to store
/// - `max_events`: Maximum number of events (must be > 0)
pub fn EventQueue(comptime T: type, comptime max_events: u32) type {
    if (max_events == 0) {
        @compileError("EventQueue max_events must be greater than 0");
    }

    return struct {
        const Self = @This();

        /// Maximum capacity of this queue (config-driven).
        pub const capacity: u32 = max_events;

        /// The event type stored in this queue.
        pub const EventType = T;

        /// Storage for events.
        events: [max_events]T = undefined,

        /// Index of the first (oldest) event.
        head: u32 = 0,

        /// Number of events currently in the queue.
        len: u32 = 0,

        /// Initialize an empty event queue.
        pub fn init() Self {
            return .{
                .events = undefined,
                .head = 0,
                .len = 0,
            };
        }

        /// Push an event to the queue.
        /// Returns error.QueueFull if the queue is at capacity.
        ///
        /// Precondition: None
        /// Postcondition: len increases by 1 if successful
        pub fn push(self: *Self, event: T) EventQueueError!void {
            // Precondition assertions
            assert(self.len <= max_events);
            assert(self.head < max_events);

            if (self.len >= max_events) {
                return EventQueueError.QueueFull;
            }

            const tail = (self.head + self.len) % max_events;
            self.events[tail] = event;
            self.len += 1;

            // Postcondition
            assert(self.len <= max_events);
        }

        /// Push an event, overwriting the oldest if full.
        /// This never fails - if full, the oldest event is dropped.
        ///
        /// Precondition: None
        /// Postcondition: Event is in queue; len <= capacity
        pub fn pushOrOverwrite(self: *Self, event: T) void {
            // Precondition assertions
            assert(self.len <= max_events);
            assert(self.head < max_events);

            if (self.len >= max_events) {
                // Overwrite oldest: advance head
                self.events[self.head] = event;
                self.head = (self.head + 1) % max_events;
                // len stays at max_events
            } else {
                const tail = (self.head + self.len) % max_events;
                self.events[tail] = event;
                self.len += 1;
            }

            // Postcondition
            assert(self.len <= max_events);
        }

        /// Pop the oldest event from the queue.
        /// Returns null if the queue is empty.
        ///
        /// Precondition: None
        /// Postcondition: len decreases by 1 if event was returned
        pub fn pop(self: *Self) ?T {
            assert(self.len <= max_events);

            if (self.len == 0) {
                return null;
            }

            const event = self.events[self.head];
            self.head = (self.head + 1) % max_events;
            self.len -= 1;

            // Postcondition
            assert(self.len < max_events);
            return event;
        }

        /// Peek at the oldest event without removing it.
        /// Returns null if the queue is empty.
        pub fn peek(self: *const Self) ?*const T {
            if (self.len == 0) {
                return null;
            }
            return &self.events[self.head];
        }

        /// Clear all events from the queue.
        ///
        /// Postcondition: len == 0
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;

            // Postcondition
            assert(self.len == 0);
        }

        /// Returns true if the queue is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        /// Returns true if the queue is at capacity.
        pub fn isFull(self: *const Self) bool {
            return self.len >= max_events;
        }

        /// Returns the current number of events in the queue.
        pub fn count(self: *const Self) u32 {
            return self.len;
        }

        /// Returns remaining capacity.
        pub fn remaining(self: *const Self) u32 {
            return max_events - self.len;
        }

        /// Iterator for reading events without consuming them.
        pub const Iterator = struct {
            queue: *const Self,
            index: u32,
            remaining: u32,

            pub fn next(self: *Iterator) ?*const T {
                if (self.remaining == 0) {
                    return null;
                }

                const actual_index = (self.queue.head + self.index) % max_events;
                self.index += 1;
                self.remaining -= 1;

                return &self.queue.events[actual_index];
            }

            /// Reset the iterator to the beginning.
            pub fn reset(self: *Iterator) void {
                self.index = 0;
                self.remaining = self.queue.len;
            }
        };

        /// Create an iterator over all events (oldest to newest).
        /// Does not consume events.
        pub fn iter(self: *const Self) Iterator {
            return .{
                .queue = self,
                .index = 0,
                .remaining = self.len,
            };
        }

        /// Draining iterator that consumes events as you iterate.
        pub const DrainIterator = struct {
            queue: *Self,

            pub fn next(self: *DrainIterator) ?T {
                return self.queue.pop();
            }
        };

        /// Create an iterator that consumes events (oldest to newest).
        /// Each call to next() removes the event from the queue.
        pub fn drain(self: *Self) DrainIterator {
            return .{ .queue = self };
        }

        /// Collect all events into a slice (for debugging/testing).
        /// Returns Events in order from oldest to newest.
        /// The caller provides the output buffer.
        pub fn toSlice(self: *const Self, out: []T) []T {
            const to_copy = @min(self.len, @as(u32, @intCast(out.len)));

            for (0..to_copy) |i| {
                const actual_index = (self.head + @as(u32, @intCast(i))) % max_events;
                out[i] = self.events[actual_index];
            }

            return out[0..to_copy];
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "EventQueue - basic push and pop" {
    const IntQueue = EventQueue(i32, 4);
    var queue = IntQueue.init();

    try std.testing.expectEqual(@as(u32, 0), queue.count());
    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(!queue.isFull());

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);

    try std.testing.expectEqual(@as(u32, 3), queue.count());
    try std.testing.expect(!queue.isEmpty());

    try std.testing.expectEqual(@as(i32, 1), queue.pop().?);
    try std.testing.expectEqual(@as(i32, 2), queue.pop().?);
    try std.testing.expectEqual(@as(i32, 3), queue.pop().?);
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(queue.isEmpty());
}

test "EventQueue - full queue returns error" {
    const SmallQueue = EventQueue(u8, 2);
    var queue = SmallQueue.init();

    try queue.push(1);
    try queue.push(2);

    try std.testing.expect(queue.isFull());
    try std.testing.expectError(EventQueueError.QueueFull, queue.push(3));

    // Pop one and push should work
    _ = queue.pop();
    try queue.push(3);
}

test "EventQueue - pushOrOverwrite overwrites oldest" {
    const TinyQueue = EventQueue(i32, 3);
    var queue = TinyQueue.init();

    queue.pushOrOverwrite(1);
    queue.pushOrOverwrite(2);
    queue.pushOrOverwrite(3);

    try std.testing.expect(queue.isFull());

    // Overwrite oldest (1)
    queue.pushOrOverwrite(4);

    // Should now contain 2, 3, 4
    try std.testing.expectEqual(@as(i32, 2), queue.pop().?);
    try std.testing.expectEqual(@as(i32, 3), queue.pop().?);
    try std.testing.expectEqual(@as(i32, 4), queue.pop().?);
}

test "EventQueue - iterator" {
    const Queue = EventQueue(i32, 4);
    var queue = Queue.init();

    try queue.push(10);
    try queue.push(20);
    try queue.push(30);

    // Iterate without consuming
    var iter = queue.iter();
    try std.testing.expectEqual(@as(i32, 10), iter.next().?.*);
    try std.testing.expectEqual(@as(i32, 20), iter.next().?.*);
    try std.testing.expectEqual(@as(i32, 30), iter.next().?.*);
    try std.testing.expect(iter.next() == null);

    // Queue should still have all events
    try std.testing.expectEqual(@as(u32, 3), queue.count());
}

test "EventQueue - drain iterator" {
    const Queue = EventQueue(i32, 4);
    var queue = Queue.init();

    try queue.push(100);
    try queue.push(200);

    var drain_iter = queue.drain();
    try std.testing.expectEqual(@as(i32, 100), drain_iter.next().?);
    try std.testing.expectEqual(@as(i32, 200), drain_iter.next().?);
    try std.testing.expect(drain_iter.next() == null);

    // Queue should be empty now
    try std.testing.expect(queue.isEmpty());
}

test "EventQueue - clear" {
    const Queue = EventQueue(u32, 8);
    var queue = Queue.init();

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);

    try std.testing.expectEqual(@as(u32, 3), queue.count());

    queue.clear();

    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), queue.count());
}

test "EventQueue - peek" {
    const Queue = EventQueue(i32, 4);
    var queue = Queue.init();

    try std.testing.expect(queue.peek() == null);

    try queue.push(42);
    try std.testing.expectEqual(@as(i32, 42), queue.peek().?.*);

    // Peek doesn't remove
    try std.testing.expectEqual(@as(u32, 1), queue.count());
}

test "EventQueue - wrap around" {
    const Queue = EventQueue(u8, 4);
    var queue = Queue.init();

    // Fill and empty partially to move head
    try queue.push(1);
    try queue.push(2);
    try queue.push(3);
    _ = queue.pop(); // head = 1
    _ = queue.pop(); // head = 2

    // Now push more to wrap around
    try queue.push(4);
    try queue.push(5);
    try queue.push(6);

    // Should have: 3, 4, 5, 6 (tail wrapped around)
    try std.testing.expectEqual(@as(u8, 3), queue.pop().?);
    try std.testing.expectEqual(@as(u8, 4), queue.pop().?);
    try std.testing.expectEqual(@as(u8, 5), queue.pop().?);
    try std.testing.expectEqual(@as(u8, 6), queue.pop().?);
}

test "EventQueue - struct events" {
    const Event = struct {
        target_id: u32,
        damage: i32,
        is_critical: bool,
    };

    const DamageQueue = EventQueue(Event, 16);
    var queue = DamageQueue.init();

    try queue.push(.{ .target_id = 1, .damage = 10, .is_critical = false });
    try queue.push(.{ .target_id = 2, .damage = 50, .is_critical = true });

    const e1 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 1), e1.target_id);
    try std.testing.expectEqual(@as(i32, 10), e1.damage);
    try std.testing.expect(!e1.is_critical);

    const e2 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 2), e2.target_id);
    try std.testing.expectEqual(@as(i32, 50), e2.damage);
    try std.testing.expect(e2.is_critical);
}

test "EventQueue - remaining capacity" {
    const Queue = EventQueue(i32, 5);
    var queue = Queue.init();

    try std.testing.expectEqual(@as(u32, 5), queue.remaining());

    try queue.push(1);
    try queue.push(2);

    try std.testing.expectEqual(@as(u32, 3), queue.remaining());
    try std.testing.expectEqual(@as(u32, 2), queue.count());
}

test "EventQueue - toSlice" {
    const Queue = EventQueue(i32, 8);
    var queue = Queue.init();

    try queue.push(10);
    try queue.push(20);
    try queue.push(30);

    var buf: [8]i32 = undefined;
    const slice = queue.toSlice(&buf);

    try std.testing.expectEqual(@as(usize, 3), slice.len);
    try std.testing.expectEqual(@as(i32, 10), slice[0]);
    try std.testing.expectEqual(@as(i32, 20), slice[1]);
    try std.testing.expectEqual(@as(i32, 30), slice[2]);
}
