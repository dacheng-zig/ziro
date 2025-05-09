const std = @import("std");

const CoroResumer = @import("executor.zig").CoroResumer;
const Executor = @import("executor.zig").Executor;
const Queue = @import("queue.zig").Queue;
const ziro = @import("ziro.zig");

const Self = @This();

waiters: Queue(Executor.Func) = .{},
exec: *Executor,

pub fn init(exec: *Executor) Self {
    return .{ .exec = exec };
}

pub fn broadcast(self: *Self) void {
    const waiters = self.waiters;
    self.waiters = .{};
    self.exec.runAllSoon(waiters);
}

pub fn signal(self: *Self) void {
    if (self.waiters.pop()) |waiter| self.exec.runSoon(waiter);
}

pub fn wait(self: *Self) void {
    var resumer = CoroResumer.init();
    var func = resumer.func();
    self.waiters.push(&func);
    ziro.xsuspend();
}
