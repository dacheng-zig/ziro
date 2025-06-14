const std = @import("std");

const xev = @import("xev");

const ziro = @import("lib.zig");
const Frame = ziro.Frame;

const Env = struct {
    exec: ?*Executor = null,
};
pub const EnvArg = struct {
    executor: ?*Executor = null,
    stack_allocator: ?std.mem.Allocator = null,
    default_stack_size: ?usize = null,
};
threadlocal var env: Env = .{};
pub fn initEnv(e: EnvArg) void {
    env = .{ .exec = e.executor };
    ziro.initEnv(.{
        .stack_allocator = e.stack_allocator,
        .default_stack_size = e.default_stack_size,
        .executor = if (e.executor) |ex| &ex.exec else null,
    });
}

/// Async IO executor, wraps coroutine executor.
pub const Executor = struct {
    loop: *xev.Loop,
    tp: ?*xev.ThreadPool = null,
    exec: ziro.Executor = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const tp = try allocator.create(xev.ThreadPool);
        tp.* = xev.ThreadPool.init(.{});

        const loop = try allocator.create(xev.Loop);
        loop.* = try xev.Loop.init(.{ .thread_pool = tp });

        return .{
            .loop = loop,
            .tp = tp,
        };
    }

    pub fn deinit(self: *Executor, allocator: std.mem.Allocator) void {
        if (self.tp) |tp| {
            tp.shutdown();
            tp.deinit();
            allocator.destroy(tp);
        }

        {
            self.loop.deinit();
            allocator.destroy(self.loop);
        }
    }

    fn tick(self: *@This()) !void {
        try self.loop.run(.once);
        _ = self.exec.tick();
    }
};

fn getExec(exec: ?*Executor) *Executor {
    if (exec != null) return exec.?;
    if (env.exec == null) @panic("No explicit Executor passed and no default Executor available.");
    return env.exec.?;
}

/// Run a coroutine to completion.
/// Must be called from "root", outside of any created coroutine.
pub fn run(
    exec: ?*Executor,
    func: anytype,
    args: anytype,
    stack: anytype,
) !RunT(func) {
    std.debug.assert(!ziro.inCoro());
    const frame = try ziro.xasync(func, args, stack);
    defer frame.deinit();
    try runCoro(exec, frame);
    return ziro.xawait(frame);
}

/// Run a coroutine to completion.
/// Must be called from "root", outside of any created coroutine.
fn runCoro(exec: ?*Executor, frame: anytype) !void {
    const f = frame.frame();
    if (f.status == .Start) ziro.xresume(f);
    const exec_ = getExec(exec);
    while (f.status != .Done) try exec_.tick();
}

const SleepResult = xev.Timer.RunError!void;
pub fn sleep(exec: ?*Executor, ms: u64) !void {
    const loop = getExec(exec).loop;
    const Data = XCallback(SleepResult);

    var data = Data.init();
    const w = try xev.Timer.init();
    defer w.deinit();
    var c: xev.Completion = .{};
    w.run(loop, &c, ms, Data, &data, &Data.callback);

    try waitForCompletion(exec, &c);

    return data.result;
}

fn waitForCompletion(exec: ?*Executor, c: *xev.Completion) !void {
    const exec_ = getExec(exec);
    if (ziro.inCoro()) {
        // In a coroutine; wait for it to be resumed
        while (c.state() != .dead) ziro.xsuspend();
    } else {
        // Not in a coroutine, blocking call
        while (c.state() != .dead) try exec_.tick();
    }
}

pub const TCP = struct {
    const Self = @This();

    exec: ?*Executor,
    tcp: xev.TCP,

    pub usingnamespace Stream(Self, xev.TCP, .{
        .poll = true,
        .close = true,
        .read = .recv,
        .write = .send,
    });

    pub fn init(exec: ?*Executor, addr: std.net.Address) !Self {
        return .{ .exec = exec, .tcp = try xev.TCP.init(addr) };
    }

    pub fn bind(self: Self, addr: std.net.Address) !void {
        return self.tcp.bind(addr);
    }

    pub fn listen(self: Self, backlog: u31) !void {
        return self.tcp.listen(backlog);
    }

    fn stream(self: Self) xev.TCP {
        return self.tcp;
    }

    pub fn accept(self: Self) !Self {
        const AcceptResult = xev.AcceptError!xev.TCP;
        const Data = XCallback(AcceptResult);

        const loop = getExec(self.exec).loop;

        var data = Data.init();
        var c: xev.Completion = .{};
        self.tcp.accept(loop, &c, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        const result = try data.result;
        return .{ .exec = self.exec, .tcp = result };
    }

    const ConnectResult = xev.ConnectError!void;
    pub fn connect(self: Self, addr: std.net.Address) !void {
        const ResultT = ConnectResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: xev.TCP,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) ziro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var data: Data = .{ .frame = ziro.xframe() };
        const loop = getExec(self.exec).loop;
        var c: xev.Completion = .{};
        self.tcp.connect(loop, &c, addr, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        return data.result;
    }

    const ShutdownResult = xev.TCP.ShutdownError!void;
    pub fn shutdown(self: Self) ShutdownResult {
        const ResultT = ShutdownResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: xev.TCP,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) ziro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var data: Data = .{ .frame = ziro.xframe() };
        const loop = getExec(self.exec).loop;
        var c: xev.Completion = .{};
        self.tcp.shutdown(loop, &c, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        return data.result;
    }
};

pub const UDP = struct {
    const Self = @This();

    exec: ?*Executor,
    udp: xev.UDP,

    pub usingnamespace Stream(Self, xev.UDP, .{
        .poll = true,
        .close = true,
        .read = .none,
        .write = .none,
    });

    pub fn init(exec: ?*Executor, addr: std.net.Address) !Self {
        return .{ .exec = exec, .udp = try xev.UDP.init(addr) };
    }

    pub fn bind(self: Self, addr: std.net.Address) !void {
        return self.udp.bind(addr);
    }

    pub fn stream(self: Self) xev.UDP {
        return self.udp;
    }

    const ReadResult = xev.ReadError!usize;
    pub fn read(self: Self, buf: xev.ReadBuffer) !usize {
        const ResultT = ReadResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: *xev.UDP.State,
                addr: std.net.Address,
                udp: xev.UDP,
                b: xev.ReadBuffer,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                _ = addr;
                _ = udp;
                _ = b;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) ziro.xresume(data.frame.?);
                return .disarm;
            }
        };

        const loop = getExec(self.exec).loop;
        var s: xev.UDP.State = undefined;
        var c: xev.Completion = .{};
        var data: Data = .{ .frame = ziro.xframe() };
        self.udp.read(loop, &c, &s, buf, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        return data.result;
    }

    const WriteResult = xev.WriteError!usize;
    pub fn write(self: Self, addr: std.net.Address, buf: xev.WriteBuffer) !usize {
        const ResultT = WriteResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: *xev.UDP.State,
                udp: xev.UDP,
                b: xev.WriteBuffer,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                _ = udp;
                _ = b;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) ziro.xresume(data.frame.?);
                return .disarm;
            }
        };

        const loop = getExec(self.exec).loop;
        var s: xev.UDP.State = undefined;
        var c: xev.Completion = .{};
        var data: Data = .{ .frame = ziro.xframe() };
        self.udp.write(loop, &c, &s, addr, buf, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        return data.result;
    }
};

fn Stream(comptime T: type, comptime StreamT: type, comptime options: xev.stream.Options) type {
    return struct {
        pub usingnamespace if (options.close) Closeable(T, StreamT) else struct {};
        pub usingnamespace if (options.read != .none) Readable(T, StreamT) else struct {};
        pub usingnamespace if (options.write != .none) Writeable(T, StreamT) else struct {};
    };
}

fn Closeable(comptime T: type, comptime StreamT: type) type {
    return struct {
        const Self = T;
        const CloseResult = xev.CloseError!void;
        pub fn close(self: Self) !void {
            const ResultT = CloseResult;
            const Data = struct {
                result: ResultT = undefined,
                frame: ?Frame = null,

                fn callback(
                    userdata: ?*@This(),
                    l: *xev.Loop,
                    c: *xev.Completion,
                    s: StreamT,
                    result: ResultT,
                ) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    _ = s;
                    const data = userdata.?;
                    data.result = result;
                    if (data.frame != null) ziro.xresume(data.frame.?);
                    return .disarm;
                }
            };

            var data: Data = .{ .frame = ziro.xframe() };

            const loop = getExec(self.exec).loop;
            var c: xev.Completion = .{};
            self.stream().close(loop, &c, Data, &data, &Data.callback);

            try waitForCompletion(self.exec, &c);

            return data.result;
        }
    };
}

fn Readable(comptime T: type, comptime StreamT: type) type {
    return struct {
        const Self = T;
        const ReadResult = xev.ReadError!usize;
        pub fn read(self: Self, buf: xev.ReadBuffer) !usize {
            const ResultT = ReadResult;
            const Data = struct {
                result: ResultT = undefined,
                frame: ?Frame = null,

                fn callback(
                    userdata: ?*@This(),
                    l: *xev.Loop,
                    c: *xev.Completion,
                    s: StreamT,
                    b: xev.ReadBuffer,
                    result: ResultT,
                ) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    _ = s;
                    _ = b;
                    const data = userdata.?;
                    data.result = result;
                    if (data.frame != null) ziro.xresume(data.frame.?);
                    return .disarm;
                }
            };

            var data: Data = .{ .frame = ziro.xframe() };

            const loop = getExec(self.exec).loop;
            var c: xev.Completion = .{};
            self.stream().read(loop, &c, buf, Data, &data, &Data.callback);

            try waitForCompletion(self.exec, &c);

            return data.result;
        }
    };
}

fn Writeable(comptime T: type, comptime StreamT: type) type {
    return struct {
        const Self = T;
        const WriteResult = xev.WriteError!usize;
        pub fn write(self: Self, buf: xev.WriteBuffer) !usize {
            const ResultT = WriteResult;
            const Data = struct {
                result: ResultT = undefined,
                frame: ?Frame = null,

                fn callback(
                    userdata: ?*@This(),
                    l: *xev.Loop,
                    c: *xev.Completion,
                    s: StreamT,
                    b: xev.WriteBuffer,
                    result: ResultT,
                ) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    _ = s;
                    _ = b;
                    const data = userdata.?;
                    data.result = result;
                    if (data.frame != null) ziro.xresume(data.frame.?);
                    return .disarm;
                }
            };

            var data: Data = .{ .frame = ziro.xframe() };

            const loop = getExec(self.exec).loop;
            var c: xev.Completion = .{};
            self.stream().write(loop, &c, buf, Data, &data, &Data.callback);

            try waitForCompletion(self.exec, &c);
            return data.result;
        }
    };
}

pub const File = struct {
    const Self = @This();

    exec: ?*Executor,
    file: xev.File,

    pub usingnamespace Stream(Self, xev.File, .{
        .poll = true,
        .close = true,
        .read = .read,
        .write = .write,
        .threadpool = true,
    });

    pub fn init(exec: ?*Executor, file: std.fs.File) !Self {
        return .{ .exec = exec, .file = try xev.File.init(file) };
    }

    fn stream(self: Self) xev.File {
        return self.file;
    }

    const PReadResult = xev.ReadError!usize;
    pub fn pread(self: Self, buf: xev.ReadBuffer, offset: u64) PReadResult {
        const ResultT = PReadResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: xev.File,
                b: xev.ReadBuffer,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                _ = b;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) ziro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var data: Data = .{ .frame = ziro.xframe() };

        const loop = getExec(self.exec).loop;
        var c: xev.Completion = .{};
        self.file.pread(loop, &c, buf, offset, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        return data.result;
    }

    const PWriteResult = xev.WriteError!usize;
    pub fn pwrite(self: Self, buf: xev.WriteBuffer, offset: u64) PWriteResult {
        const ResultT = PWriteResult;
        const Data = struct {
            result: ResultT = undefined,
            frame: ?Frame = null,

            fn callback(
                userdata: ?*@This(),
                l: *xev.Loop,
                c: *xev.Completion,
                s: xev.File,
                b: xev.WriteBuffer,
                result: ResultT,
            ) xev.CallbackAction {
                _ = l;
                _ = c;
                _ = s;
                _ = b;
                const data = userdata.?;
                data.result = result;
                if (data.frame != null) ziro.xresume(data.frame.?);
                return .disarm;
            }
        };

        var data: Data = .{ .frame = ziro.xframe() };

        const loop = getExec(self.exec).loop;
        var c: xev.Completion = .{};
        self.file.pwrite(loop, &c, buf, offset, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        return data.result;
    }
};

pub const Process = struct {
    const Self = @This();

    exec: ?*Executor,
    p: xev.Process,

    pub fn init(exec: ?*Executor, pid: std.posix.pid_t) !Self {
        return .{ .exec = exec, .p = try xev.Process.init(pid) };
    }

    pub fn deinit(self: *Self) void {
        self.p.deinit();
    }

    const WaitResult = xev.Process.WaitError!u32;
    pub fn wait(self: Self) !u32 {
        const Data = XCallback(WaitResult);
        var c: xev.Completion = .{};
        var data = Data.init();
        const loop = getExec(self.exec).loop;
        self.p.wait(loop, &c, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        return data.result;
    }
};

pub const AsyncNotification = struct {
    const Self = @This();

    exec: ?*Executor,
    notifier: xev.Async,

    pub fn init(exec: ?*Executor) !Self {
        return .{ .exec = exec, .notifier = try xev.Async.init() };
    }

    pub fn deinit(self: *Self) void {
        return self.notifier.deinit();
    }

    const WaitResult = xev.Async.WaitError!void;
    pub fn wait(self: Self) !void {
        const Data = XCallback(WaitResult);

        const loop = getExec(self.exec).loop;
        var c: xev.Completion = .{};
        var data = Data.init();

        self.notifier.wait(loop, &c, Data, &data, &Data.callback);

        try waitForCompletion(self.exec, &c);

        return data.result;
    }

    pub fn notify(self: Self) !void {
        return self.notifier.notify();
    }
};

fn RunT(comptime Func: anytype) type {
    const T = @typeInfo(@TypeOf(Func)).@"fn".return_type.?;
    return switch (@typeInfo(T)) {
        .error_union => |E| E.payload,
        else => T,
    };
}

fn XCallback(comptime ResultT: type) type {
    return struct {
        frame: ?Frame = null,
        result: ResultT = undefined,

        fn init() @This() {
            return .{ .frame = ziro.xframe() };
        }

        fn callback(
            userdata: ?*@This(),
            _: *xev.Loop,
            _: *xev.Completion,
            result: ResultT,
        ) xev.CallbackAction {
            const data = userdata.?;
            data.result = result;
            if (data.frame != null) ziro.xresume(data.frame.?);
            return .disarm;
        }
    };
}
