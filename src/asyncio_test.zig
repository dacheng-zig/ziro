const std = @import("std");

const xev = @import("xev");
const ziro = @import("ziro");
const aio = ziro.asyncio;

threadlocal var env: struct { allocator: std.mem.Allocator, exec: *aio.Executor } = undefined;

const AioTest = struct {
    allocator: std.mem.Allocator,
    exec: *aio.Executor,
    stacks: []u8,

    fn init() !@This() {
        const allocator = std.testing.allocator;

        // init async io executor, this needs stable memory pointer
        const exec = try allocator.create(aio.Executor);
        exec.* = try aio.Executor.init(allocator);

        const stack_size = 1024 * 128;
        const num_stacks = 5;
        const stacks = try allocator.alignedAlloc(u8, ziro.stack_alignment, num_stacks * stack_size);

        // Thread-local env
        env = .{
            .allocator = allocator,
            .exec = exec,
        };

        aio.initEnv(.{
            .executor = exec,
            .stack_allocator = allocator,
            .default_stack_size = stack_size,
        });

        return .{
            .allocator = allocator,
            .exec = exec,
            .stacks = stacks,
        };
    }

    fn deinit(self: @This()) void {
        self.exec.deinit(self.allocator);
        self.allocator.free(self.stacks);
        self.allocator.destroy(self.exec);
    }

    fn run(self: @This(), func: anytype) !void {
        const stack = try ziro.stackAlloc(self.allocator, 1024 * 32);
        defer self.allocator.free(stack);
        try aio.run(self.exec, func, .{}, stack);
    }
};

test "aio sleep top-level" {
    const t = try AioTest.init();
    defer t.deinit();
    try aio.sleep(t.exec, 10);
}

fn sleep(ms: u64) !i64 {
    try aio.sleep(env.exec, ms);
    try std.testing.expect(ziro.remainingStackSize() > 1024 * 2);
    return std.time.milliTimestamp();
}

test "aio sleep run" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack = try ziro.stackAlloc(
        t.allocator,
        null,
    );
    defer t.allocator.free(stack);
    const before = std.time.milliTimestamp();
    const after = try aio.run(t.exec, sleep, .{10}, stack);

    try std.testing.expect(after > (before + 7));
    try std.testing.expect(after < (before + 13));
}

fn sleepTask() !void {
    const stack1 = try ziro.stackAlloc(
        env.allocator,
        null,
    );
    defer env.allocator.free(stack1);
    const sleep1 = try ziro.xasync(sleep, .{10}, stack1);

    const stack2 = try ziro.stackAlloc(
        env.allocator,
        null,
    );
    defer env.allocator.free(stack2);
    const sleep2 = try ziro.xasync(sleep, .{20}, stack2);

    const after1 = try ziro.xawait(sleep1);
    const after2 = try ziro.xawait(sleep2);

    try std.testing.expect(after2 > (after1 + 7));
    try std.testing.expect(after2 < (after1 + 13));
}

test "aio concurrent sleep" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack = try ziro.stackAlloc(
        t.allocator,
        1024 * 8,
    );
    defer t.allocator.free(stack);
    const before = std.time.milliTimestamp();
    try aio.run(t.exec, sleepTask, .{}, stack);
    const after = std.time.milliTimestamp();

    try std.testing.expect(after > (before + 17));
    try std.testing.expect(after < (before + 23));
}

const TickState = struct {
    slow: usize = 0,
    fast: usize = 0,
};

fn tickLoop(tick: usize, state: *TickState) !void {
    const amfast = tick == 10;
    for (0..10) |i| {
        try aio.sleep(env.exec, tick);
        if (amfast) {
            state.fast += 1;
        } else {
            state.slow += 1;
        }
        if (!amfast and i >= 6) {
            try std.testing.expectEqual(state.fast, 10);
        }
    }
}

fn aioTimersMain() !void {
    const stack_size: usize = 1024 * 16;

    var tick_state = TickState{};

    // 2 parallel timer loops, one fast, one slow
    const stack1 = try ziro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    const co1 = try ziro.xasync(tickLoop, .{ 10, &tick_state }, stack1);
    const stack2 = try ziro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    const co2 = try ziro.xasync(tickLoop, .{ 20, &tick_state }, stack2);

    try ziro.xawait(co1);
    try ziro.xawait(co2);
}

test "aio timers" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(aioTimersMain);
}

const ServerInfo = struct {
    addr: std.net.Address = undefined,
};

fn tcpServer(info: *ServerInfo) !void {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try aio.TCP.init(env.exec, address);

    try server.bind(address);
    try server.listen(1);

    var sock_len = address.getOsSockLen();
    try std.posix.getsockname(server.tcp.fd, &address.any, &sock_len);
    info.addr = address;

    const conn = try server.accept();
    defer conn.close() catch unreachable;
    try server.close();

    var recv_buf: [128]u8 = undefined;
    const recv_len = try conn.read(.{ .slice = &recv_buf });
    const send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    try std.testing.expect(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
}

fn tcpClient(info: *ServerInfo) !void {
    const address = info.addr;
    const client = try aio.TCP.init(env.exec, address);
    defer client.close() catch unreachable;
    _ = try client.connect(address);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try client.write(.{ .slice = &send_buf });
    try std.testing.expectEqual(send_len, 7);
}

fn tcpMain() !void {
    const stack_size = 1024 * 32;

    var info: ServerInfo = .{};

    var server = try ziro.xasync(tcpServer, .{&info}, stack_size);
    defer server.deinit();

    var client = try ziro.xasync(tcpClient, .{&info}, stack_size);
    defer client.deinit();

    try ziro.xawait(server);
    try ziro.xawait(client);
}

test "aio tcp" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(tcpMain);
}

fn udpServer(info: *ServerInfo) !void {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try aio.UDP.init(env.exec, address);

    try server.bind(address);

    var sock_len = address.getOsSockLen();
    try std.posix.getsockname(server.udp.fd, &address.any, &sock_len);
    info.addr = address;

    var recv_buf: [128]u8 = undefined;
    const recv_len = try server.read(.{ .slice = &recv_buf });
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    try std.testing.expectEqual(recv_len, send_buf.len);
    try std.testing.expect(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
    try server.close();
}

fn udpClient(info: *ServerInfo) !void {
    const client = try aio.UDP.init(env.exec, info.addr);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try client.write(info.addr, .{ .slice = &send_buf });
    try std.testing.expectEqual(send_len, 7);
    try client.close();
}

fn udpMain() !void {
    const stack_size = 1024 * 32;
    var info: ServerInfo = .{};

    const stack1 = try ziro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    const server_co = try ziro.xasync(udpServer, .{&info}, stack1);

    const stack2 = try ziro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    const client_co = try ziro.xasync(udpClient, .{&info}, stack2);

    try ziro.xawait(server_co);
    try ziro.xawait(client_co);
}

test "aio udp" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(udpMain);
}

fn fileRW() !void {
    const path = "test_watcher_file";
    const f = try std.fs.cwd().createFile(path, .{
        .read = true,
        .truncate = true,
    });
    defer f.close();
    defer std.fs.cwd().deleteFile(path) catch {};
    const file = try aio.File.init(env.exec, f);
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const write_len = try file.write(.{ .slice = &write_buf });
    try std.testing.expectEqual(write_len, write_buf.len);
    try f.sync();
    const f2 = try std.fs.cwd().openFile(path, .{});
    defer f2.close();
    const file2 = try aio.File.init(env.exec, f2);
    var read_buf: [128]u8 = undefined;
    const read_len = try file2.read(.{ .slice = &read_buf });
    try std.testing.expectEqual(write_len, read_len);
    try std.testing.expect(std.mem.eql(u8, &write_buf, read_buf[0..read_len]));
}

test "aio file" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(fileRW);
}

fn processTest() !void {
    const alloc = std.heap.c_allocator;
    var child = std.process.Child.init(&.{ "sh", "-c", "exit 0" }, alloc);
    try child.spawn();

    var p = try aio.Process.init(env.exec, child.id);
    defer p.deinit();
    const rc = try p.wait();
    try std.testing.expectEqual(rc, 0);
}

test "aio process" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(processTest);
}

const NotifierState = struct {
    notifier: aio.AsyncNotification,
    notified: bool = false,
};

fn asyncTest(state: *NotifierState) !void {
    try state.notifier.wait();
    state.notified = true;
}

fn asyncNotifier(state: *NotifierState) !void {
    try state.notifier.notify();
    try aio.sleep(env.exec, 10);
    try std.testing.expect(state.notified);
}

fn asyncMain() !void {
    const stack_size = 1024 * 32;
    var nstate = NotifierState{ .notifier = try aio.AsyncNotification.init(env.exec) };
    defer nstate.notifier.deinit();

    const stack1 = try ziro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    const co = try ziro.xasync(asyncTest, .{&nstate}, stack1);

    const stack2 = try ziro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    const nco = try ziro.xasync(asyncNotifier, .{&nstate}, stack2);

    try ziro.xawait(co);
    try ziro.xawait(nco);
}

test "aio async" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(asyncMain);
}

test "aio sleep env" {
    const t = try AioTest.init();
    defer t.deinit();

    const before = std.time.milliTimestamp();
    const after = try aio.run(null, sleep, .{10}, null);

    try std.testing.expect(after > (before + 7));
    try std.testing.expect(after < (before + 13));
}

fn sleepTaskEnv() !void {
    var sleep1 = try ziro.xasync(sleep, .{10}, null);
    defer sleep1.deinit();
    var sleep2 = try ziro.xasync(sleep, .{20}, null);
    defer sleep2.deinit();

    const after = try ziro.xawait(sleep1);
    const after2 = try ziro.xawait(sleep2);

    try std.testing.expect(after2 > (after + 7));
    try std.testing.expect(after2 < (after + 13));
}

test "aio concurrent sleep env" {
    const t = try AioTest.init();
    defer t.deinit();

    const before = std.time.milliTimestamp();
    try aio.run(null, sleepTaskEnv, .{}, null);
    const after = std.time.milliTimestamp();

    try std.testing.expect(after > (before + 17));
    try std.testing.expect(after < (before + 23));
}

const UsizeChannel = ziro.sync.Channel(usize, .{ .capacity = 10 });

fn sender(chan: *UsizeChannel, count: usize) !void {
    defer chan.close();
    for (0..count) |i| {
        try chan.send(i);
        try aio.sleep(null, 10);
    }
}

fn recvr(chan: *UsizeChannel) usize {
    var sum: usize = 0;
    while (chan.recv()) |val| sum += val;
    return sum;
}

fn chanMain() !usize {
    var chan = UsizeChannel.init(&env.exec.exec);
    const send_frame = try ziro.xasync(sender, .{ &chan, 6 }, null);
    defer send_frame.deinit();
    const recv_frame = try ziro.xasync(recvr, .{&chan}, null);
    defer recv_frame.deinit();

    try ziro.xawait(send_frame);
    return ziro.xawait(recv_frame);
}

test "aio mix channels" {
    const t = try AioTest.init();
    defer t.deinit();

    const sum = try aio.run(null, chanMain, .{}, null);
    try std.testing.expectEqual(sum, 15);
}

const TaskState = struct {
    called: bool = false,
};

fn notifyAfterBlockingSleep(notifcation: *aio.AsyncNotification, state: *NotifierState) void {
    std.time.sleep(20 * std.time.ns_per_ms);
    notifcation.notifier.notify() catch unreachable;
    state.notified = true;
}

fn asyncRecurseSleepAndNotification() !void {
    const pool: *std.Thread.Pool = try env.allocator.create(std.Thread.Pool);
    defer env.allocator.destroy(pool);

    try std.Thread.Pool.init(pool, .{ .allocator = env.allocator });
    defer pool.deinit();

    var nstate = NotifierState{ .notifier = try aio.AsyncNotification.init(env.exec) };
    defer nstate.notifier.deinit();
    var tstate = TaskState{};

    var notification = try aio.AsyncNotification.init(env.exec);
    defer notification.notifier.deinit();

    const asyncTaskDoingAsyncSleep = try ziro.xasync(struct {
        fn call(exec: *aio.Executor, state: *TaskState) !void {
            try aio.sleep(exec, 1);
            state.called = true;
        }
    }.call, .{ env.exec, &tstate }, null);
    defer asyncTaskDoingAsyncSleep.deinit();

    try pool.spawn(notifyAfterBlockingSleep, .{ &notification, &nstate });

    try notification.wait();
    try ziro.xawait(asyncTaskDoingAsyncSleep);

    try std.testing.expect(nstate.notified);
    try std.testing.expect(tstate.called);
}

test "aio mix async recurse in sleep and notification" {
    const t = try AioTest.init();
    defer t.deinit();

    try t.run(asyncRecurseSleepAndNotification);
}
