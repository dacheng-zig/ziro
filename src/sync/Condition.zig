const std = @import("std");

const ziro = @import("../ziro.zig");
const Executor = ziro.Executor;

const Self = @This();

waiters: ziro.Queue(Executor.Func) = .{},
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
    var resumer = ziro.CoroResumer.init();
    var func = resumer.func();
    self.waiters.push(&func);
    ziro.xsuspend();
}
