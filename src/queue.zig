pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,

        pub fn pop(self: *Self) ?*T {
            switch (self.state()) {
                .empty => {
                    return null;
                },
                .one => {
                    const out = self.head.?;
                    self.head = null;
                    self.tail = null;
                    return out;
                },
                .many => {
                    const out = self.head.?;
                    self.head = out.next;
                    return out;
                },
            }
        }

        pub fn push(self: *Self, val: *T) void {
            val.next = null;
            switch (self.state()) {
                .empty => {
                    self.head = val;
                    self.tail = val;
                },
                .one => {
                    self.head.?.next = val;
                    self.tail = val;
                },
                .many => {
                    self.tail.?.next = val;
                    self.tail = val;
                },
            }
        }

        pub fn pushAll(self: *Self, vals: Self) void {
            switch (self.state()) {
                .empty => {
                    self.head = vals.head;
                    self.tail = vals.tail;
                },
                .one => {
                    switch (vals.state()) {
                        .empty => {},
                        .one => {
                            self.head.?.next = vals.head;
                            self.tail = vals.head;
                        },
                        .many => {
                            self.head.?.next = vals.head;
                            self.tail = vals.tail;
                        },
                    }
                },
                .many => {
                    switch (vals.state()) {
                        .empty => {},
                        .one => {
                            self.tail.?.next = vals.head;
                            self.tail = vals.head;
                        },
                        .many => {
                            self.tail.?.next = vals.head;
                            self.tail = vals.tail;
                        },
                    }
                },
            }
        }

        pub fn len(self: Self) usize {
            var current = self.head;
            var size: usize = 0;
            while (current != null) {
                current = current.?.next;
                size += 1;
            }
            return size;
        }

        const State = enum { empty, one, many };
        inline fn state(self: Self) State {
            if (self.head == null) return .empty;
            if (self.head.? == self.tail.?) return .one;
            return .many;
        }
    };
}

pub fn ArrayQueue(comptime T: type, comptime size: usize) type {
    return struct {
        const Self = @This();

        vals: [size]T = undefined,
        head: ?usize = null,
        tail: ?usize = null,

        pub fn init() Self {
            return .{};
        }

        pub fn len(self: Self) usize {
            switch (self.state()) {
                .empty => return 0,
                .one => return 1,
                .many => {
                    const head = self.head.?;
                    const tail = self.tail.?;
                    if (tail > head) return tail - head + 1;
                    return size - head + tail + 1;
                },
            }
        }

        pub fn space(self: Self) usize {
            return size - self.len();
        }

        pub fn push(self: *@This(), val: T) !void {
            if (self.space() < 1) return error.QueueFull;
            switch (self.state()) {
                .empty => {
                    self.head = 0;
                    self.tail = 0;
                    self.vals[0] = val;
                },
                .one, .many => {
                    const tail = self.tail.?;
                    const new_tail = (tail + 1) % size;
                    self.vals[new_tail] = val;
                    self.tail = new_tail;
                },
            }
        }

        pub fn pop(self: *Self) ?T {
            switch (self.state()) {
                .empty => return null,
                .one => {
                    const out = self.vals[self.head.?];
                    self.head = null;
                    self.tail = null;
                    return out;
                },
                .many => {
                    const out = self.vals[self.head.?];
                    self.head = (self.head.? + 1) % size;
                    return out;
                },
            }
        }

        const State = enum { empty, one, many };
        inline fn state(self: Self) State {
            if (self.head == null) return .empty;
            if (self.head.? == self.tail.?) return .one;
            return .many;
        }
    };
}
