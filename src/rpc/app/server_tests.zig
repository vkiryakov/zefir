//! Tests of `rpc.Server` end to end: calls go through the memory transport
//! and `rpc.RawClient` with JSON bodies written by hand, so each test sees
//! the exact bytes and failures a client gets.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const failures = @import("../failures.zig");
const contract = @import("contract.zig");
const method = @import("method.zig");
const Server = @import("Server.zig");
const RawServer = @import("../engine/RawServer.zig");
const RawClient = @import("../engine/RawClient.zig");
const Context = @import("../engine/Context.zig").Context;
const MemoryTransport = @import("../testing/MemoryTransport.zig");
const ServerTransport = @import("../ServerTransport.zig");

const testing = std.testing;

const GetUserRequest = struct { id: u64 };
const User = struct { id: u64, name: []const u8, email: ?[]const u8 = null };
const DeleteUserRequest = struct { id: u64 };
const Empty = struct {};
const Stats = struct { ratio: f64 };
const BlobRequest = struct { size: u32 };

const UserApi = contract.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{
        .getUser = contract.method(GetUserRequest, User),
        .deleteUser = contract.method(DeleteUserRequest, void),
        .stats = contract.method(Empty, Stats),
        .blob = contract.method(BlobRequest, []const u8),
    },
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
    },
});

const UserHandler = struct {
    deleted: std.atomic.Value(u64) = .init(0),
    /// What `stats` answers.
    ratio: f64 = 0.5,

    pub const rpc_handler = contract.implement(UserApi, .{
        .methods = .{ .stats = .{ .timeout_ms = 1500 } },
    });

    pub fn getUser(self: *UserHandler, ctx: *Context, req: GetUserRequest) !User {
        _ = self;
        return switch (req.id) {
            404 => error.UserNotFound,
            500 => error.DatabaseConnectionRefused,
            else => .{ .id = req.id, .name = try std.fmt.allocPrint(ctx.allocator(), "user-{d}", .{req.id}) },
        };
    }

    pub fn deleteUser(self: *UserHandler, ctx: *Context, req: DeleteUserRequest) !void {
        _ = ctx;
        self.deleted.store(req.id, .release);
    }

    pub fn stats(self: *UserHandler, ctx: *Context, req: Empty) !Stats {
        _ = ctx;
        _ = req;
        return .{ .ratio = self.ratio };
    }

    pub fn blob(self: *UserHandler, ctx: *Context, req: BlobRequest) ![]const u8 {
        _ = self;
        const bytes = try ctx.allocator().alloc(u8, req.size);
        @memset(bytes, 'a');
        return bytes;
    }
};

/// The memory transport and a client on it; servers are built on
/// `memory.serverTransport()`. Set up in place: the client points into it.
const Fixture = struct {
    memory: MemoryTransport,
    client: RawClient,

    fn open(f: *Fixture) !void {
        f.memory = try .init(testing.allocator, .{});
        errdefer f.memory.deinit(testing.io);
        f.client = try .init(testing.allocator, .{ .transport = f.memory.clientTransport() });
    }

    fn close(f: *Fixture, io: std.Io) void {
        f.client.deinit();
        f.memory.deinit(io);
    }

    fn call(f: *Fixture, io: std.Io, route: model.Route, body: []const u8) !RawClient.Result {
        return f.client.call(io, .root, route, body, .{ .timeout = .fromSeconds(10) });
    }
};

fn usersRoute(name: []const u8) model.Route {
    return .{ .service = "users", .version = 1, .method = name };
}

fn expectBody(result: *RawClient.Result, expected: []const u8) !void {
    defer result.deinit();
    switch (result.response.status) {
        .ok => try testing.expectEqualStrings(expected, result.response.body),
        .failure => |failure| {
            std.debug.print("unexpected failure {s}: {s}\n", .{ failure.app_code, failure.message });
            return error.TestUnexpectedResult;
        },
    }
}

/// The failure of `result`, its field and its body, as the client got them.
fn expectFailure(result: *RawClient.Result, expected: model.Failure, body: []const u8) !void {
    defer result.deinit();
    switch (result.response.status) {
        .ok => {
            std.debug.print("unexpected success: {s}\n", .{result.response.body});
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            try testing.expectEqual(expected.code, failure.code);
            try testing.expectEqualStrings(expected.app_code, failure.app_code);
            try testing.expectEqualStrings(expected.message, failure.message);
            if (expected.field) |field| {
                try testing.expectEqualStrings(field, failure.field orelse return error.TestExpectedField);
            } else try testing.expectEqual(@as(?[]const u8, null), failure.field);
            try testing.expectEqualStrings(body, result.response.body);
        },
    }
}

test "a call decodes the request, runs the method and encodes its response" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{ .transport = f.memory.serverTransport(), .handlers = .{&users} });
    defer server.deinit(io);
    try server.start(io);

    var got = try f.call(io, usersRoute("getUser"), "{\"id\":\"42\"}");
    try expectBody(&got, "{\"id\":\"42\",\"name\":\"user-42\",\"email\":null}");
    // A void response is an empty object.
    var deleted = try f.call(io, usersRoute("deleteUser"), "{\"id\":\"7\"}");
    try expectBody(&deleted, "{}");
    try testing.expectEqual(@as(u64, 7), users.deleted.load(.acquire));
    var stats = try f.call(io, usersRoute("stats"), "{}");
    try expectBody(&stats, "{\"ratio\":0.5}");
    var blob = try f.call(io, usersRoute("blob"), "{\"size\":3}");
    try expectBody(&blob, "\"aaa\"");
}

test "the methods of the engine carry the routes, the settings and the contract's errors" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{ .transport = memory.serverTransport(), .handlers = .{&users} });
    defer server.deinit(io);

    const methods = server.engine.methods;
    try testing.expectEqual(@as(usize, 4), methods.len);
    for (methods, [_][]const u8{ "getUser", "deleteUser", "stats", "blob" }) |m, name| {
        try testing.expectEqualStrings("users", m.route.service);
        try testing.expectEqual(@as(u16, 1), m.route.version);
        try testing.expectEqualStrings(name, m.route.method);
        try testing.expectEqual(RawServer.Method.Auth.optional, m.auth);
        try testing.expectEqualStrings("users.not_found", m.map_error.?(error.UserNotFound).?.app_code);
        try testing.expect(m.handler.ptr == @as(*anyopaque, &users));
    }
    try testing.expectEqual(@as(i64, 3000), methods[0].timeout.?.toMilliseconds());
    try testing.expectEqual(@as(i64, 1500), methods[2].timeout.?.toMilliseconds());
}

test "a body that does not decode is refused with what is wrong and where" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{ .transport = f.memory.serverTransport(), .handlers = .{&users} });
    defer server.deinit(io);
    try server.start(io);

    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "{\"id\":42}", "wrong type", "id" },
        .{ "{}", "missing required field", "id" },
        .{ "{\"id\":\"042\"}", "not a canonical integer", "id" },
        .{ "{\"id\":", "invalid JSON", "id" },
        .{ "[]", "wrong type", null },
        .{ "", "invalid JSON", null },
        .{ "{\"id\":\"1\",\"id\":\"2\"}", "duplicate key", "id" },
    };
    for (cases) |case| {
        errdefer std.debug.print("body: {s}\n", .{case[0]});
        var result = try f.call(io, usersRoute("getUser"), case[0]);
        try expectFailure(&result, .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = case[1], .field = case[2] }, "");
    }
}

test "the decoder keeps the server's limits of depth and items" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{
        .transport = f.memory.serverTransport(),
        .handlers = .{&users},
        .limits = .{ .max_json_depth = 2, .max_container_items = 3 },
    });
    defer server.deinit(io);
    try server.start(io);

    var deep = try f.call(io, usersRoute("getUser"), "{\"id\":\"1\",\"x\":{\"y\":{}}}");
    try expectFailure(&deep, .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "too deep", .field = "x.y" }, "");
    var wide = try f.call(io, usersRoute("getUser"), "{\"id\":\"1\",\"x\":[1,2,3,4]}");
    try expectFailure(&wide, .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "too many items", .field = "x" }, "");
    var fits = try f.call(io, usersRoute("getUser"), "{\"id\":\"1\",\"x\":[1,2,3]}");
    try expectBody(&fits, "{\"id\":\"1\",\"name\":\"user-1\",\"email\":null}");
}

test "the errors of a method map through the contract, the framework's names, else internal" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{ .transport = f.memory.serverTransport(), .handlers = .{&users} });
    defer server.deinit(io);
    try server.start(io);

    var missing = try f.call(io, usersRoute("getUser"), "{\"id\":\"404\"}");
    try expectFailure(&missing, .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" }, "");
    // The name of an unknown error does not leave the server.
    var broken = try f.call(io, usersRoute("getUser"), "{\"id\":\"500\"}");
    try expectFailure(&broken, failures.internal, "");
}

test "a response that JSON cannot carry or that is too large is refused by its stage" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var users: UserHandler = .{ .ratio = std.math.nan(f64) };
    var server: Server = try .init(testing.allocator, .{
        .transport = f.memory.serverTransport(),
        .handlers = .{&users},
        .limits = .{ .max_response_bytes = 1024 },
    });
    defer server.deinit(io);
    try server.start(io);
    // The server logs what was wrong with the response.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;

    var nan = try f.call(io, usersRoute("stats"), "{}");
    try expectFailure(&nan, method.invalid_response, "");
    users.ratio = std.math.inf(f64);
    var inf = try f.call(io, usersRoute("stats"), "{}");
    try expectFailure(&inf, method.invalid_response, "");

    // A string of 1022 bytes and its quotes fit exactly; one more does not.
    var fits = try f.call(io, usersRoute("blob"), "{\"size\":1022}");
    defer fits.deinit();
    try testing.expectEqual(@as(usize, 1024), fits.response.body.len);
    var large = try f.call(io, usersRoute("blob"), "{\"size\":1023}");
    try expectFailure(&large, failures.response_too_large, "");
    var huge = try f.call(io, usersRoute("blob"), "{\"size\":1000000}");
    try expectFailure(&huge, failures.response_too_large, "");
}

const UserApiV2 = contract.Contract(.{
    .name = "users",
    .version = 2,
    .methods = .{ .getUser = contract.method(GetUserRequest, struct { id: u64, display_name: []const u8 }) },
});

const UserHandlerV2 = struct {
    pub const rpc_handler = contract.implement(UserApiV2, .{});

    pub fn getUser(self: *UserHandlerV2, ctx: *Context, req: GetUserRequest) !@TypeOf(UserApiV2.getUser).Response {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .display_name = "Ann" };
    }
};

test "one server serves two versions of a contract, each on its own routes" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var v1: UserHandler = .{};
    var v2: UserHandlerV2 = .{};
    var server: Server = try .init(testing.allocator, .{ .transport = f.memory.serverTransport(), .handlers = .{ &v1, &v2 } });
    defer server.deinit(io);
    try server.start(io);

    var old = try f.call(io, usersRoute("getUser"), "{\"id\":\"1\"}");
    try expectBody(&old, "{\"id\":\"1\",\"name\":\"user-1\",\"email\":null}");
    var new = try f.call(io, .{ .service = "users", .version = 2, .method = "getUser" }, "{\"id\":\"1\"}");
    try expectBody(&new, "{\"id\":\"1\",\"display_name\":\"Ann\"}");
    var unknown = try f.call(io, .{ .service = "users", .version = 2, .method = "deleteUser" }, "{\"id\":\"1\"}");
    try expectFailure(&unknown, failures.unknown_method, "");
}

test "init refuses limits that cannot work, and frees what it took when memory runs out" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var users: UserHandler = .{};
    try testing.expectError(error.InvalidConfiguration, Server.init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .handlers = .{&users},
        .limits = .{ .max_active_tasks = 0 },
    }));
    try testing.expectError(error.InvalidConfiguration, Server.init(testing.allocator, .{
        .transport = memory.serverTransport(),
        .handlers = .{&users},
        .shutdown_grace = std.Io.Duration.fromMilliseconds(-1),
    }));
    // Every allocation fails once; the test's allocator reports a leak.
    // (checkAllAllocationFailures does not fit: the engine's arena may grow
    // a block in place on one run and allocate a new one on another.)
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        var server = Server.init(failing.allocator(), .{ .transport = memory.serverTransport(), .handlers = .{&users} }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        server.deinit(io);
        break;
    }
    try testing.expect(fail_index > 1);
}
