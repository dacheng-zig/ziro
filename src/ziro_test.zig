const std = @import("std");
const ziro = @import("ziro");

fn coroFnImpl(x: *usize) usize {
    x.* += 1;
    ziro.xsuspend();
    x.* += 3;
    ziro.xsuspend();
    return x.* + 10;
}

test "with FrameT and xasync xawait" {
    const allocator = std.testing.allocator;
    const stack = try ziro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 0;

    var frame = try ziro.xasync(coroFnImpl, .{&x}, stack);

    try std.testing.expectEqual(x, 1);
    ziro.xresume(frame);
    try std.testing.expectEqual(x, 4);
    ziro.xresume(frame);
    try std.testing.expectEqual(x, 4);
    try std.testing.expectEqual(frame.status(), .Done);

    const out = ziro.xawait(frame);
    try std.testing.expectEqual(out, 14);
}

fn coroError(x: *usize) !usize {
    x.* += 1;
    ziro.xsuspend();
    if (true) return error.SomethingBad;
    return x.* + 10;
}

test "xawait error" {
    const allocator = std.testing.allocator;
    const stack = try ziro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    var x: usize = 0;
    const frame = try ziro.xasync(coroError, .{&x}, stack);
    try std.testing.expectEqual(x, 1);
    ziro.xresume(frame);
    try std.testing.expectEqual(x, 1);
    try std.testing.expectEqual(frame.status(), .Done);
    const out = ziro.xawait(frame);
    try std.testing.expectError(error.SomethingBad, out);
}

fn withSuspendBlock() void {
    const Data = struct {
        frame: ziro.Frame,
        fn block_fn(data: *@This()) void {
            std.debug.assert(data.frame.status == .Suspended);
            std.debug.assert(data.frame != ziro.xframe());
            ziro.xresume(data.frame);
        }
    };
    var data = Data{ .frame = ziro.xframe() };
    ziro.xsuspendBlock(Data.block_fn, .{&data});
}

test "suspend block" {
    const allocator = std.testing.allocator;
    const stack = try ziro.stackAlloc(allocator, null);
    defer allocator.free(stack);

    const frame = try ziro.xasync(withSuspendBlock, .{}, stack);
    try std.testing.expectEqual(frame.status(), .Done);
}

fn sender(chan: anytype, count: usize) void {
    defer chan.close();
    for (0..count) |i| chan.send(i) catch unreachable;
}

fn recvr(chan: anytype) usize {
    var sum: usize = 0;
    while (chan.recv()) |val| sum += val;
    return sum;
}

test "channel" {
    var exec = ziro.Executor.init();
    ziro.initEnv(.{ .stack_allocator = std.testing.allocator, .executor = &exec });
    const start_i = ziro.xframe().id.invocation;
    const UsizeChannel = ziro.Channel(usize, .{});
    var chan = UsizeChannel.init(&exec);
    const send_frame = try ziro.xasync(sender, .{ &chan, 6 }, null);
    defer send_frame.deinit();
    const recv_frame = try ziro.xasync(recvr, .{&chan}, null);
    defer recv_frame.deinit();

    while (exec.tick()) {}

    ziro.xawait(send_frame);
    const sum = ziro.xawait(recv_frame);
    try std.testing.expectEqual(sum, 15);
    const end_i = ziro.xframe().id.invocation;
    try std.testing.expectEqual(end_i - start_i, 12);
}

test "buffered channel" {
    var exec = ziro.Executor.init();
    ziro.initEnv(.{ .stack_allocator = std.testing.allocator, .executor = &exec });
    const start_i = ziro.xframe().id.invocation;
    const UsizeChannel = ziro.Channel(usize, .{ .capacity = 6 });
    var chan = UsizeChannel.init(&exec);
    const send_frame = try ziro.xasync(sender, .{ &chan, 6 }, null);
    defer send_frame.deinit();
    const recv_frame = try ziro.xasync(recvr, .{&chan}, null);
    defer recv_frame.deinit();

    while (exec.tick()) {}

    ziro.xawait(send_frame);
    const sum = ziro.xawait(recv_frame);
    const end_i = ziro.xframe().id.invocation;
    try std.testing.expectEqual(sum, 15);
    try std.testing.expectEqual(end_i - start_i, 2);
}
