const std = @import("std");
const http = std.http;

const xev = @import("xev");
const ziro = @import("ziro");
const aio = ziro.asyncio;

var env: struct { allocator: std.mem.Allocator, exec: *aio.Executor } = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // init thread pool (used by xev event loop)
    var tp = try allocator.create(xev.ThreadPool);
    defer {
        tp.shutdown();
        tp.deinit();
        allocator.destroy(tp);
    }
    tp.* = xev.ThreadPool.init(.{});

    // init xev event loop
    var loop = try allocator.create(xev.Loop);
    defer {
        loop.deinit();
        allocator.destroy(loop);
    }
    loop.* = try xev.Loop.init(.{ .thread_pool = tp });

    // init async io executor and async io env
    const executor = try allocator.create(aio.Executor);
    defer allocator.destroy(executor);
    executor.* = aio.Executor.init(loop);
    aio.initEnv(.{
        .executor = executor,
        .stack_allocator = allocator,
        .default_stack_size = 1024 * 8,
    });

    try aio.run(executor, mainTask, .{allocator}, null);
}

fn mainTask(allocator: std.mem.Allocator) !void {
    var wg = ziro.sync.WaitGroup.init();

    const num_tasks: usize = 4;

    const tasks = try allocator.alloc(ziro.Frame, num_tasks);
    defer {
        for (tasks) |t| t.deinit();
        allocator.free(tasks);
    }

    for (0..num_tasks) |i| {
        wg.start();

        const id: u32 = @as(u32, @intCast(i + 1));
        const delay_ms: u64 = if (i < num_tasks / 2) 2 else 1;
        std.debug.print("Task-{} starting, will sleep for {}ms\n", .{ id, delay_ms });
        const t = try ziro.xasync(task, .{ &wg, id, delay_ms }, null);
        tasks[i] = t.frame();
    }

    std.debug.print("------------------------\n", .{});

    wg.wait();
}

fn task(wg: *ziro.sync.WaitGroup, id: u32, delay_ms: u64) !void {
    defer wg.finish();

    try aio.sleep(null, delay_ms);
    std.debug.print("Task-{} completed after {}ms\n", .{ id, delay_ms });
}
