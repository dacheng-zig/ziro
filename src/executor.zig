const std = @import("std");

const ziro = @import("ziro.zig");
const ziro_options = @import("ziro_options");
const Queue = @import("queue.zig").Queue;

pub const Executor = struct {
    const Self = @This();

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

    /// ready queue
    readyq: Queue(Func) = .{},

    pub fn init() Self {
        return .{};
    }

    pub fn runSoon(self: *Self, func: *Func) void {
        self.readyq.push(func);
    }

    pub fn runAllSoon(self: *Self, funcs: Queue(Func)) void {
        self.readyq.pushAll(funcs);
    }

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

pub const CoroResumer = struct {
    const Self = @This();

    coro: ziro.Frame,

    pub fn init() Self {
        return .{ .coro = ziro.xframe() };
    }

    pub fn func(self: *Self) Executor.Func {
        return .{ .func = Self.callback, .userdata = self };
    }

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
