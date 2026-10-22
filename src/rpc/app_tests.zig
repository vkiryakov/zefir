//! `rpc.Server` under `core.App`: a factory builds the server from the
//! handlers App gives it, on a memory transport App builds too; App starts
//! the server, watches its `wait` and stops it within its deadline. The
//! transport declares `app_lifecycle = false`: the server starts and closes
//! it, App only builds and frees it.
const std = @import("std");
const core = @import("core");
const rpc = @import("root.zig");

const testing = std.testing;

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8 };

const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
    },
});

/// The users the handler serves: a provider without fields.
const UserRepository = struct {
    pub fn find(_: *UserRepository, id: u64) ?User {
        return if (id == 1) .{ .id = 1, .name = "Ada Lovelace" } else null;
    }
};

const UsersHandler = struct {
    repo: *UserRepository,

    pub const rpc_handler = rpc.implement(UserApi, .{});

    pub fn getUser(self: *UsersHandler, _: *rpc.Context, req: GetUserRequest) !User {
        return self.repo.find(req.id) orelse error.UserNotFound;
    }
};

const Root = struct {
    pub const module: core.app.Module = .{
        .providers = &.{UserRepository},
        .handlers = &.{UsersHandler},
        .factories = &.{ Bus, Servers },
    };

    pub const Bus = struct {
        pub fn memory(gpa: std.mem.Allocator) !rpc.testing.MemoryTransport {
            return .init(gpa, .{});
        }
    };

    pub const Servers = struct {
        pub fn rpcServer(gpa: std.mem.Allocator, bus: *rpc.testing.MemoryTransport, handlers: core.app.Handlers(Root)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{ .transport = bus.serverTransport() });
        }
    };
};

/// Silences the warnings of a test that makes App or the server warn.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

test "rpc.Server under core.App: a call, then a stop" {
    const io = testing.io;
    var app = try core.App(Root).init(testing.allocator, io, .{}, .{});
    defer app.deinit();
    try app.start();
    try testing.expect(app.isReady());

    var client: rpc.Client = try .init(testing.allocator, .{}, .{ .transport = app.get(rpc.testing.MemoryTransport).clientTransport() });
    defer client.deinit();
    var found = try client.call(io, .root, UserApi.getUser, .{ .id = 1 }, .{});
    defer found.deinit();
    try testing.expectEqualStrings("Ada Lovelace", found.outcome.ok.name);

    app.requestStop();
    try app.wait();
    try testing.expectEqual(core.app.State.stopped, app.state());
    try testing.expectEqual(null, app.failure());
    try testing.expectEqual(rpc.Server.State.stopped, app.get(rpc.Server).state());
}

test "a transport that breaks stops the App" {
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var app = try core.App(Root).init(testing.allocator, io, .{}, .{});
    defer app.deinit();
    try app.start();

    app.get(rpc.testing.MemoryTransport).failServer(io, error.Unavailable);
    try testing.expectError(error.Unavailable, app.wait());
    const failure = app.failure().?;
    try testing.expectEqualStrings("Root.Servers.rpcServer", failure.bean);
    try testing.expectEqual(core.app.Failure.Step.wait, failure.step);
    try testing.expectEqual(error.Unavailable, failure.err);
}

/// What the test sees of the call of `LateUsers`.
const Probe = struct { entered: std.Io.Event = .unset };

/// Holds its call until the stop cancels it, then works on for 500 ms with
/// cancelation blocked, as a handler that finishes a write it began.
const LateUsers = struct {
    probe: *Probe,

    pub const rpc_handler = rpc.implement(UserApi, .{ .defaults = .{ .timeout_ms = 30_000 } });

    pub fn getUser(self: *LateUsers, ctx: *rpc.Context, req: GetUserRequest) !User {
        const io = ctx.io();
        self.probe.entered.set(io);
        var never: std.Io.Event = .unset;
        never.wait(io) catch |err| {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            io.sleep(.fromMilliseconds(500), .awake) catch {};
            return err;
        };
        return .{ .id = req.id, .name = "never" };
    }
};

const LateRoot = struct {
    pub const module: core.app.Module = .{
        .handlers = &.{LateUsers},
        .factories = &.{ Bus, Servers },
        .values = &.{*Probe},
    };

    pub const Bus = struct {
        pub fn memory(gpa: std.mem.Allocator) !rpc.testing.MemoryTransport {
            return .init(gpa, .{});
        }
    };

    pub const Servers = struct {
        pub fn rpcServer(gpa: std.mem.Allocator, bus: *rpc.testing.MemoryTransport, handlers: core.app.Handlers(LateRoot)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{
                .transport = bus.serverTransport(),
                .shutdown_grace = .fromSeconds(10),
            });
        }
    };
};

fn callLate(client: *rpc.Client, io: std.Io) rpc.Client.CallError!rpc.Client.Result(User) {
    return client.call(io, .root, UserApi.getUser, .{ .id = 1 }, .{});
}

test "a call that ends only after its cancelation, late in its budget: the App's wait returns {}" {
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var probe: Probe = .{};
    var app = try core.App(LateRoot).init(testing.allocator, io, .{&probe}, .{ .shutdown_timeout = .fromSeconds(3) });
    defer app.deinit();
    try app.start();

    var client: rpc.Client = try .init(testing.allocator, .{}, .{ .transport = app.get(rpc.testing.MemoryTransport).clientTransport() });
    defer client.deinit();
    var pending = try io.concurrent(callLate, .{ &client, io });
    defer if (pending.await(io)) |result| {
        var r = result;
        r.deinit();
    } else |_| {};
    try probe.entered.wait(io);

    // The grace ends two seconds and 250 ms before App's deadline, 3 s
    // away, so 750 ms after the stop began, and the server gives a canceled
    // call one second more to end. This one ends 500 ms after its
    // cancelation, and the server's shutdown returns before the last
    // 250 ms. The 500 ms left of that second hold under ThreadSanitizer on
    // a busy machine, where a wake-up comes hundreds of milliseconds late.
    const asked = std.Io.Clock.awake.now(io);
    app.requestStop();
    try app.wait();
    const took = asked.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(took >= 1100 and took < 3000);
    try testing.expectEqual(core.app.State.stopped, app.state());
    try testing.expectEqual(null, app.failure());
}
