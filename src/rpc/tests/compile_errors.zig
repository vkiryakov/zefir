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

test "authenticator without authenticate" {
    const NoAuthenticate = struct {
        calls: u32 = 0,
        pub fn check(self: *@This(), ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView {
            _ = ctx;
            self.calls += 1;
            return null;
        }
    };
    var authenticator: NoAuthenticate = .{};
    _ = rpc.Authenticator.init(&authenticator);
}

test "authenticate with an inferred error set" {
    const Inferred = struct {
        calls: u32 = 0,
        pub fn authenticate(self: *@This(), ctx: *const rpc.AuthContext) !?rpc.IdentityView {
            _ = ctx;
            self.calls += 1;
            if (self.calls > 1) return error.InvalidCredentials;
            return null;
        }
    };
    var authenticator: Inferred = .{};
    _ = rpc.Authenticator.init(&authenticator);
}

/// A middleware object with `run` right.
const Counter = struct {
    runs: u32 = 0,

    pub fn run(self: *Counter, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        _ = ctx;
        self.runs += 1;
        return next.run();
    }
};

test "middleware object without run" {
    const NoRun = struct {
        runs: u32 = 0,
        pub fn handle(self: *@This(), ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
            _ = ctx;
            self.runs += 1;
            return next.run();
        }
    };
    var link: NoRun = .{};
    _ = rpc.Middleware.of(&link);
}

test "middleware object by value" {
    var counter: Counter = .{};
    _ = rpc.Middleware.of(counter);
    counter.runs += 1;
}

fn inferredLink(ctx: *rpc.Context, next: *rpc.Next) !void {
    _ = ctx;
    return next.run();
}

test "middleware function with an inferred error set" {
    _ = rpc.Middleware.of(inferredLink);
}

test "middleware object behind a const pointer" {
    const counter: Counter = .{};
    _ = rpc.Middleware.of(&counter);
}

test "middleware run with an inferred error set" {
    const Inferred = struct {
        runs: u32 = 0,
        pub fn run(self: *@This(), ctx: *rpc.Context, next: *rpc.Next) !void {
            _ = ctx;
            self.runs += 1;
            return next.run();
        }
    };
    var link: Inferred = .{};
    _ = rpc.Middleware.of(&link);
}

test "client middleware with the server's signature" {
    const ServerSide = struct {
        runs: u32 = 0,
        pub fn run(self: *@This(), ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
            _ = ctx;
            self.runs += 1;
            return next.run();
        }
    };
    var link: ServerSide = .{};
    _ = rpc.ClientMiddleware.of(&link);
}

/// A conformance harness with both methods.
const Harness = struct {
    memory: rpc.testing.MemoryTransport = undefined,

    pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator) !rpc.testing.conformance.Pair {
        _ = io;
        h.memory = try .init(gpa, .{});
        return .{ .client = h.memory.clientTransport(), .server = h.memory.serverTransport() };
    }

    pub fn tearDown(h: *Harness, io: std.Io, pair: rpc.testing.conformance.Pair) void {
        _ = pair;
        h.memory.deinit(io);
    }
};

test "conformance harness by value" {
    const harness: Harness = .{};
    var report = try rpc.testing.conformance.run(std.testing.io, std.testing.allocator, harness, .{});
    report.deinit();
}

test "conformance harness without tearDown" {
    const NoTearDown = struct {
        memory: rpc.testing.MemoryTransport = undefined,
        pub fn setUp(h: *@This(), io: std.Io, gpa: std.mem.Allocator) !rpc.testing.conformance.Pair {
            _ = io;
            h.memory = try .init(gpa, .{});
            return .{ .client = h.memory.clientTransport(), .server = h.memory.serverTransport() };
        }
    };
    var harness: NoTearDown = .{};
    var report = try rpc.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    report.deinit();
}

test "conformance harness behind a const pointer" {
    const harness: Harness = .{};
    var report = try rpc.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    report.deinit();
}

test "conformance harness without setUp" {
    const NoSetUp = struct {
        memory: rpc.testing.MemoryTransport = undefined,
        pub fn tearDown(h: *@This(), io: std.Io, pair: rpc.testing.conformance.Pair) void {
            _ = pair;
            h.memory.deinit(io);
        }
    };
    var harness: NoSetUp = .{};
    var report = try rpc.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    report.deinit();
}

test "conformance hook with another signature" {
    const FailingBreak = struct {
        memory: rpc.testing.MemoryTransport = undefined,
        pub fn setUp(h: *@This(), io: std.Io, gpa: std.mem.Allocator) !rpc.testing.conformance.Pair {
            _ = io;
            h.memory = try .init(gpa, .{});
            return .{ .client = h.memory.clientTransport(), .server = h.memory.serverTransport() };
        }
        pub fn tearDown(h: *@This(), io: std.Io, pair: rpc.testing.conformance.Pair) void {
            _ = pair;
            h.memory.deinit(io);
        }
        /// Returns an error union: the suite expects void.
        pub fn breakLink(h: *@This(), io: std.Io, pair: rpc.testing.conformance.Pair) !void {
            _ = pair;
            h.memory.breakLink(io);
        }
    };
    var harness: FailingBreak = .{};
    var report = try rpc.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
    report.deinit();
}
