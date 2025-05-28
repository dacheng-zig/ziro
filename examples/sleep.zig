const std = @import("std");

const xev = @import("xev");
const ziro = @import("ziro");
const aio = ziro.asyncio;

pub fn main() !void {
    // init allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // init async io executor and env
    var executor = try aio.Executor.init(allocator);
    defer executor.deinit(allocator);
    aio.initEnv(.{
        .executor = &executor,
        .stack_allocator = allocator,
        .default_stack_size = 1024 * 8,
    });

    // run main coroutine
    try aio.run(&executor, mainTask, .{allocator}, null);
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
