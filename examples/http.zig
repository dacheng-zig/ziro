const std = @import("std");

const xev = @import("xev");
const ziro = @import("ziro");
const aio = ziro.asyncio;

const log = std.log.scoped(.@"ziro/http");

threadlocal var env: struct {
    allocator: std.mem.Allocator,
    executor: aio.Executor,
} = undefined;

const STACK_SIZE: usize = 1024 * 64;
const HTTP_RESPONSE = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 13\r\nContent-Type: text/plain\r\n\r\nHello World\r\n";

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create event loop
    var tp = xev.ThreadPool.init(.{});
    var loop = try xev.Loop.init(.{ .thread_pool = &tp });
    defer loop.deinit();

    // Create async io executor
    var executor = aio.Executor.init(&loop);

    aio.initEnv(.{
        .executor = &executor,
        .stack_allocator = allocator,
        .default_stack_size = STACK_SIZE,
    });

    // save to `env` for later use
    env = .{
        .allocator = allocator,
        .executor = executor,
    };

    try aio.run(&env.executor, serverFunc, .{}, null);
}

fn serverFunc() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    var server = try aio.TCP.init(&env.executor, address);

    try server.bind(address);
    try server.listen(1024);

    log.info("HTTP server listening on {}", .{address});

    while (true) {
        const conn = try server.accept();

        // spawn a new coroutine to handle http connection
        _ = ziro.xasync(handleConnection, .{conn}, null) catch |err| {
            log.err("connection error: {}", .{err});
        };
    }
}

fn handleConnection(conn: aio.TCP) !void {
    defer conn.close() catch unreachable;

    var buffer: [1024 * 8]u8 = undefined;

    // 1 tcp connection, many http request
    while (true) {
        // handle request
        {
            _ = conn.read(.{ .slice = &buffer }) catch |e| {
                log.err("read error: {}", .{e});
                return;
            };

            _ = conn.write(.{ .slice = HTTP_RESPONSE }) catch |e| {
                log.err("write error: {}", .{e});
                return;
            };
        }
    }
}
