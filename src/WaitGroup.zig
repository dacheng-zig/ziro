//! WaitGroup waits for a collection of coroutines to finish.

const std = @import("std");

const ziro = @import("ziro.zig");
const Condition = @import("Condition.zig");

notifier: Condition,
notified: bool = false,
counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

const Self = @This();

/// Initialize a new WaitGroup
pub fn init(exec: *ziro.Executor) Self {
    return .{
        .notifier = ziro.Condition.init(exec),
    };
}

/// add delta to the WaitGroup counter.
pub fn add(self: *Self, delta: usize) void {
    _ = self.counter.fetchAdd(delta, .monotonic);
}

/// Increment the WaitGroup counter by one
pub fn inc(self: *Self) void {
    _ = self.counter.fetchAdd(1, .monotonic);
}

/// Decrement the WaitGroup counter by one
pub fn done(self: *Self) void {
    const prev = self.counter.fetchSub(1, .monotonic);

    // If this was the last counter, wake up all waiting coroutines
    if (prev == 1) {
        self.wake();
    } else if (prev == 0) {
        @panic("WaitGroup counter negative");
    }
}

/// suspend until notified due to the counter becomes zero
pub fn wait(self: *Self) void {
    // quick path
    if (self.counter.load(.monotonic) == 0) {
        return;
    }

    while (!self.notified) {
        self.notifier.wait();
    }
}

fn wake(self: *Self) void {
    self.notified = true;
}
