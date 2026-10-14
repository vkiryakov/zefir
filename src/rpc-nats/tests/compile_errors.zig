//! Adapters that must not compile, one test each. `zig build test` compiles
//! every test on its own and checks its error message; the list of
//! messages is in build.zig.

const std = @import("std");
const rpc_nats = @import("rpc-nats");
const Conn = rpc_nats.Conn;

/// An adapter with every method right.
const Adapter = struct {
    published: u32 = 0,

    pub fn publish(self: *Adapter, io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
        _ = io;
        _ = msg;
        _ = timeout;
        self.published += 1;
    }
    pub fn subscribe(self: *Adapter, io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
        _ = io;
        _ = subject;
        _ = queue;
        _ = timeout;
        return self;
    }
    pub fn next(self: *Adapter, io: std.Io, sub: Conn.Sub, timeout: std.Io.Timeout) Conn.Error!?Conn.InMsg {
        _ = self;
        _ = io;
        _ = sub;
        _ = timeout;
        return null;
    }
    pub fn drain(self: *Adapter, io: std.Io, sub: Conn.Sub) Conn.Error!void {
        _ = self;
        _ = io;
        _ = sub;
    }
    pub fn unsubscribe(self: *Adapter, io: std.Io, sub: Conn.Sub) void {
        _ = self;
        _ = io;
        _ = sub;
    }
    pub fn flush(self: *Adapter, io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
        _ = self;
        _ = io;
        _ = timeout;
    }
};

test "adapter without next" {
    const NoNext = struct {
        inner: Adapter = .{},
        pub fn publish(self: *@This(), io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
            return self.inner.publish(io, msg, timeout);
        }
        pub fn subscribe(self: *@This(), io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
            return self.inner.subscribe(io, subject, queue, timeout);
        }
        pub fn drain(self: *@This(), io: std.Io, sub: Conn.Sub) Conn.Error!void {
            return self.inner.drain(io, sub);
        }
        pub fn unsubscribe(self: *@This(), io: std.Io, sub: Conn.Sub) void {
            self.inner.unsubscribe(io, sub);
        }
        pub fn flush(self: *@This(), io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
            return self.inner.flush(io, timeout);
        }
    };
    var adapter: NoNext = .{};
    _ = Conn.init(&adapter);
}

test "next with another signature" {
    const NextWithoutTimeout = struct {
        inner: Adapter = .{},
        pub fn publish(self: *@This(), io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
            return self.inner.publish(io, msg, timeout);
        }
        pub fn subscribe(self: *@This(), io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
            return self.inner.subscribe(io, subject, queue, timeout);
        }
        pub fn next(self: *@This(), io: std.Io, sub: Conn.Sub) Conn.Error!?Conn.InMsg {
            return self.inner.next(io, sub, .none);
        }
        pub fn drain(self: *@This(), io: std.Io, sub: Conn.Sub) Conn.Error!void {
            return self.inner.drain(io, sub);
        }
        pub fn unsubscribe(self: *@This(), io: std.Io, sub: Conn.Sub) void {
            self.inner.unsubscribe(io, sub);
        }
        pub fn flush(self: *@This(), io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
            return self.inner.flush(io, timeout);
        }
    };
    var adapter: NextWithoutTimeout = .{};
    _ = Conn.init(&adapter);
}

test "isConnected with another signature" {
    const ConnectedWithIo = struct {
        inner: Adapter = .{},
        pub fn publish(self: *@This(), io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
            return self.inner.publish(io, msg, timeout);
        }
        pub fn subscribe(self: *@This(), io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
            return self.inner.subscribe(io, subject, queue, timeout);
        }
        pub fn next(self: *@This(), io: std.Io, sub: Conn.Sub, timeout: std.Io.Timeout) Conn.Error!?Conn.InMsg {
            return self.inner.next(io, sub, timeout);
        }
        pub fn drain(self: *@This(), io: std.Io, sub: Conn.Sub) Conn.Error!void {
            return self.inner.drain(io, sub);
        }
        pub fn unsubscribe(self: *@This(), io: std.Io, sub: Conn.Sub) void {
            self.inner.unsubscribe(io, sub);
        }
        pub fn flush(self: *@This(), io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
            return self.inner.flush(io, timeout);
        }
        pub fn isConnected(self: *@This(), io: std.Io) bool {
            _ = self;
            _ = io;
            return true;
        }
    };
    var adapter: ConnectedWithIo = .{};
    _ = Conn.init(&adapter);
}

test "init with a value" {
    const adapter: Adapter = .{};
    _ = Conn.init(adapter);
}

test "init with a pointer to a constant" {
    const adapter: Adapter = .{};
    _ = Conn.init(&adapter);
}
