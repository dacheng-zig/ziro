const std = @import("std");

const ziro = @import("../ziro.zig");

state: std.atomic.Value(u8) = std.atomic.Value(u8).init(unset),

const unset = 0;
const waiting = 1;
const is_set = 2;

const Self = @This();

pub fn init() Self {
    return .{};
}

pub fn isSet(self: *Self) bool {
    return self.state.load(.acquire) == is_set;
}

pub fn wait(self: *Self) void {
    while (!self.isSet()) {
        self.waitUntilSet();
    }
}

fn waitUntilSet(self: *Self) void {
    var state = self.state.load(.acquire);
    if (state == unset) {
        state = self.state.cmpxchgStrong(state, waiting, .acquire, .acquire) orelse waiting;
    }

    if (state == waiting) {
        ziro.xsuspend();
    }
}

pub fn set(self: *Self) void {
    if (self.state.load(.monotonic) == is_set) {
        return;
    }

    _ = self.state.swap(is_set, .release);
}

pub fn reset(self: *Self) void {
    self.state.store(unset, .monotonic);
}
