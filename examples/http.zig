const std = @import("std");

const xev = @import("xev");
const ziro = @import("ziro");
const aio = ziro.asyncio;

const log = std.log.scoped(.@"ziro/example/http");

const STACK_SIZE: usize = 1024 * 64;
const HTTP_RESPONSE = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 13\r\nContent-Type: text/plain\r\n\r\nHello World\r\n";

pub fn main() !void {
    // init allocator
    var dbgalloc = std.heap.DebugAllocator(.{}).init;
    defer _ = dbgalloc.deinit();
    const allocator = dbgalloc.allocator();

    // init async io executor and env
    var executor = try aio.Executor.init(allocator);
    defer executor.deinit(allocator);
    aio.initEnv(.{
        .executor = &executor,
        .stack_allocator = allocator,
        .default_stack_size = STACK_SIZE,
    });

    // server listen
    const address = try std.net.Address.parseIp("127.0.0.1", 8008);
    var server = try aio.TCP.init(&executor, address);
    try server.bind(address);
    try server.listen(1024);
    log.info("HTTP server listening on {}", .{address});

    // run main coroutine
    try aio.run(&executor, serve, .{server}, null);
}

fn serve(server: aio.TCP) !void {
    while (true) {
        // try to accept, wait when no connection comes in
        const conn = try server.accept();

        // spawn a new coroutine to handle http connection
        _ = ziro.xasync(handle, .{conn}, null) catch |err| {
            log.err("connection error: {}", .{err});
        };
    }
}

fn handle(conn: aio.TCP) !void {
    defer conn.close() catch unreachable;

    var buffer: [1024 * 8]u8 = undefined;

    // one tcp connection, may come with many http requests
    while (true) {
        // handle each request: one read, one write
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
