const std = @import("std");

const ziro = @import("ziro.zig");
const Executor = @import("executor.zig").Executor;
const CoroResumer = @import("executor.zig").CoroResumer;
const Queue = @import("queue.zig").Queue;

const Self = @This();

exec: *Executor,
waiters: Queue(Executor.Func) = .{},

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