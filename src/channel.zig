const ArrayQueue = @import("queue.zig").ArrayQueue;
const Condition = @import("Condition.zig");
const Executor = @import("executor.zig").Executor;

pub const ChannelConfig = struct {
    capacity: usize = 1,
};

pub fn Channel(comptime T: type, comptime config: ChannelConfig) type {
    const Storage = ArrayQueue(T, config.capacity);

    return struct {
        const Self = @This();

        q: Storage = .{},
        closed: bool = false,

        space_notifier: Condition,
        value_notifier: Condition,

        pub fn init(exec: *Executor) Self {
            return .{
                .space_notifier = Condition.init(exec),
                .value_notifier = Condition.init(exec),
            };
        }

        pub fn close(self: *Self) void {
            self.closed = true;
            self.value_notifier.signal();
        }

        pub fn send(self: *Self, val: T) !void {
            if (self.closed) @panic("Cannot send on closed Channel");
            while (self.q.space() == 0) self.space_notifier.wait();
            try self.q.push(val);
            self.value_notifier.signal();
        }

        pub fn recv(self: *Self) ?T {
            while (!(self.closed or self.q.len() != 0)) self.value_notifier.wait();
            if (self.closed and self.q.len() == 0) return null;
            const out = self.q.pop().?;
            self.space_notifier.signal();
            return out;
        }
    };
}
