//! Transports that must not compile, one test each. `zig build test`
//! compiles every test on its own and checks its error message; the list
//! of messages is in build.zig.

const std = @import("std");
const rpc = @import("rpc");

/// A client transport with both methods right.
const Echo = struct {
    calls: u32 = 0,

    pub fn call(self: *Echo, io: std.Io, request: *const rpc.transport.Request, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError!rpc.Response {
        _ = self;
        _ = io;
        _ = request;
        _ = options;
        return .{ .status = .ok };
    }

    pub fn info(self: *Echo) rpc.transport.Info {
        _ = self;
        return .{ .name = "echo" };
    }
};

test "client transport without call" {
    const NoCall = struct {
        calls: u32 = 0,
        pub fn info(self: *@This()) rpc.transport.Info {
            _ = self;
            return .{ .name = "x" };
        }
    };
    var transport: NoCall = .{};
    _ = rpc.ClientTransport.init(&transport);
}

test "call with another response type" {
    const WrongResponse = struct {
        calls: u32 = 0,
        pub fn call(self: *@This(), io: std.Io, request: *const rpc.transport.Request, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError![]const u8 {
            _ = self;
            _ = io;
            _ = request;
            _ = options;
            return "";
        }
        pub fn info(self: *@This()) rpc.transport.Info {
            _ = self;
            return .{ .name = "x" };
        }
    };
    var transport: WrongResponse = .{};
    _ = rpc.ClientTransport.init(&transport);
}

test "client transport without info" {
    const NoInfo = struct {
        calls: u32 = 0,
        pub fn call(self: *@This(), io: std.Io, request: *const rpc.transport.Request, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError!rpc.Response {
            _ = self;
            _ = io;
            _ = request;
            _ = options;
            return .{ .status = .ok };
        }
    };
    var transport: NoInfo = .{};
    _ = rpc.ClientTransport.init(&transport);
}

test "server transport without drain" {
    const NoDrain = struct {
        started: bool = false,
        pub fn start(self: *@This(), io: std.Io, dispatcher: rpc.transport.Dispatcher) rpc.ServerTransport.StartError!void {
            _ = io;
            _ = dispatcher;
            self.started = true;
        }
        pub fn close(self: *@This(), io: std.Io) void {
            _ = self;
            _ = io;
        }
        pub fn info(self: *@This()) rpc.transport.Info {
            _ = self;
            return .{ .name = "x" };
        }
    };
    var transport: NoDrain = .{};
    _ = rpc.ServerTransport.init(&transport);
}

test "isReady with another signature" {
    const ReadyWithIo = struct {
        started: bool = false,
        pub fn start(self: *@This(), io: std.Io, dispatcher: rpc.transport.Dispatcher) rpc.ServerTransport.StartError!void {
            _ = io;
            _ = dispatcher;
            self.started = true;
        }
        pub fn drain(self: *@This(), io: std.Io) void {
            _ = self;
            _ = io;
        }
        pub fn close(self: *@This(), io: std.Io) void {
            _ = self;
            _ = io;
        }
        pub fn info(self: *@This()) rpc.transport.Info {
            _ = self;
            return .{ .name = "x" };
        }
        pub fn isReady(self: *@This(), io: std.Io) bool {
            _ = io;
            return self.started;
        }
    };
    var transport: ReadyWithIo = .{};
    _ = rpc.ServerTransport.init(&transport);
}

test "release with another signature" {
    const ReleaseWithoutDisposition = struct {
        sent: bool = false,
        pub fn send(self: *@This(), io: std.Io, response: *const rpc.Response) rpc.transport.Reply.SendError!void {
            _ = io;
            _ = response;
            self.sent = true;
        }
        pub fn release(self: *@This(), io: std.Io) void {
            _ = io;
            self.sent = false;
        }
    };
    var reply: ReleaseWithoutDisposition = .{};
    _ = rpc.transport.Reply.init(&reply);
}

test "init with a value" {
    var transport: Echo = .{};
    _ = rpc.ClientTransport.init(transport);
    transport.calls += 1;
}

test "init with a pointer to a constant" {
    const transport: Echo = .{};
    _ = rpc.ClientTransport.init(&transport);
}

test "init with a pointer to a number" {
    var number: u8 = 0;
    _ = rpc.ServerTransport.init(&number);
}
