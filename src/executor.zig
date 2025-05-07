const std = @import("std");

const ziro = @import("ziro.zig");
const ziro_options = @import("ziro_options");
const Queue = @import("queue.zig").Queue;

pub const Executor = struct {
    const Self = @This();

    /// a wrapper contains user func and args;
    /// also the pointer to next node within a data structure.
    pub const Func = struct {
        const FuncFn = *const fn (userdata: ?*anyopaque) void;
        func: FuncFn,
        userdata: ?*anyopaque = null,
        next: ?*@This() = null,

        pub fn init(func: FuncFn, userdata: ?*anyopaque) @This() {
            return .{ .func = func, .userdata = userdata };
        }

        fn run(self: @This()) void {
            @call(.auto, self.func, .{self.userdata});
        }
    };

    /// store Funcs that will run on next tick.
    readyq: Queue(Func) = .{},

    pub fn init() Self {
        return .{};
    }

    /// push a Func to readyq that will run on next tick.
    pub fn runSoon(self: *Self, func: *Func) void {
        self.readyq.push(func);
    }

    /// push Funcs to readyq that will run on next tick.
    pub fn runAllSoon(self: *Self, funcs: Queue(Func)) void {
        self.readyq.pushAll(funcs);
    }

    /// run all Funcs from readyq.
    pub fn tick(self: *Self) bool {
        // Reset readyq so that adds run on next tick.
        var now = self.readyq;
        self.readyq = .{};

        if (ziro_options.debug_log_level >= 3) std.debug.print("Executor.tick readyq_len={d}\n", .{now.len()});

        var count: usize = 0;
        while (now.pop()) |func| : (count += 1) func.run();

        if (ziro_options.debug_log_level >= 3) std.debug.print("Executor.tick done\n", .{});

        return count > 0;
    }
};

/// serve as a bridge between the Executor's callback-based execution model
/// and the coroutine-based execution model.
pub const CoroResumer = struct {
    const Self = @This();

    coro: ziro.Frame,

    /// construct a CoroResumer by capturing the current coroutine,
    /// so that the coroutine can be resumed later.
    pub fn init() Self {
        return .{ .coro = ziro.xframe() };
    }

    /// construct a Func that will resume the coroutine.
    pub fn func(self: *Self) Executor.Func {
        return .{ .func = Self.callback, .userdata = self };
    }

    /// resume the coroutine.
    pub fn callback(ud: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ud));
        ziro.xresume(self.coro);
    }
};

fn getExec(exec: ?*Executor) *Executor {
    if (exec != null) return exec.?;
    if (ziro.getEnv().executor) |x| return x;
    @panic("No explicit Executor passed and no default Executor available");
}
