//! WaitGroup waits for a collection of coroutines to finish.

const std = @import("std");

const Executor = @import("executor.zig").Executor;
const ResetEvent = @import("ResetEvent.zig");

counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
event: ResetEvent,

const Self = @This();

pub fn init(exec: *Executor) Self {
    return .{
        .event = ResetEvent.init(exec),
    };
}

pub fn start(self: *Self) void {
    _ = self.counter.fetchAdd(1, .monotonic);
}

pub fn startMany(self: *Self, delta: usize) void {
    _ = self.counter.fetchAdd(delta, .monotonic);
}

pub fn finish(self: *Self) void {
    const prev = self.counter.fetchSub(1, .monotonic);

    if (prev == 1) {
        self.event.set();
    } else if (prev == 0) {
        @panic("WaitGroup counter negative");
    }
}

pub fn wait(self: *Self) void {
    if (self.counter.load(.monotonic) == 0) {
        return;
    }

    self.event.wait();
}

pub fn reset(self: *Self) void {
    self.counter.store(0, .monotonic);
    self.event.reset();
}

pub fn isDone(self: *Self) bool {
    return self.counter.load(.monotonic) == 0;
}
