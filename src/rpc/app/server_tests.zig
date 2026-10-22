//! Tests of `rpc.Server` end to end: calls go through the memory transport
//! and `rpc.RawClient` with JSON bodies written by hand, so each test sees
//! the exact bytes and failures a client gets.

const std = @import("std");
const core = @import("core");
const v = @import("validator");
const model = @import("../model.zig");
const failures = @import("../failures.zig");
const auth = @import("../auth.zig");
const contract = @import("contract.zig");
const method = @import("method.zig");
const Server = @import("Server.zig");
const RawServer = @import("../engine/RawServer.zig");
const RawClient = @import("../engine/RawClient.zig");
const Context = @import("../engine/Context.zig").Context;
const Next = @import("../middleware.zig").Next;
const MiddlewareFn = @import("../middleware.zig").MiddlewareFn;
const MemoryTransport = @import("../testing/MemoryTransport.zig");
const ServerTransport = @import("../ServerTransport.zig");

const testing = std.testing;
const far = @import("../wait.zig").far;

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
    /// The byte `blob` repeats.
    fill: u8 = 'a',

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
        const bytes = try ctx.allocator().alloc(u8, req.size);
        @memset(bytes, self.fill);
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
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{ .transport = f.memory.serverTransport() });
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
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{ .transport = memory.serverTransport() });
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

test "rpc.Server takes typed options" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{
        .transport = f.memory.serverTransport(),
        .shutdown_grace = .fromSeconds(10),
        .limits = .{ .max_active_tasks = 1024 },
    });
    defer server.deinit(io);
    try testing.expectEqual(@as(u32, 1024), server.engine.limits.max_active_tasks);
    try server.start(io);
    var got = try f.call(io, usersRoute("getUser"), "{\"id\":\"42\"}");
    try expectBody(&got, "{\"id\":\"42\",\"name\":\"user-42\",\"email\":null}");
}

test "limits with a max_timeout below the default timeout still build a server" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var users: UserHandler = .{};
    // The default timeout is for methods of the engine without a limit of
    // their own; rpc.Server has none, and lowers it to the maximum.
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{
        .transport = memory.serverTransport(),
        .limits = .{ .max_timeout = .fromSeconds(1) },
    });
    defer server.deinit(io);
    try testing.expectEqual(@as(i64, 1000), server.engine.limits.default_timeout.toMilliseconds());
    try testing.expectEqual(@as(i64, 1000), server.engine.limits.max_timeout.toMilliseconds());
    // Both written: the default comes down to the maximum as well.
    var both: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{
        .transport = memory.serverTransport(),
        .limits = .{ .default_timeout = .fromSeconds(5), .max_timeout = .fromSeconds(1) },
    });
    defer both.deinit(io);
    try testing.expectEqual(@as(i64, 1000), both.engine.limits.default_timeout.toMilliseconds());
}

test "a body that does not decode is refused with what is wrong and where" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{ .transport = f.memory.serverTransport() });
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
        .handlers = .{&users},
    }, .{
        .transport = f.memory.serverTransport(),
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
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{ .transport = f.memory.serverTransport() });
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
        .handlers = .{&users},
    }, .{
        .transport = f.memory.serverTransport(),
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
    users.fill = 0xff;
    var not_utf8 = try f.call(io, usersRoute("blob"), "{\"size\":3}");
    try expectFailure(&not_utf8, method.invalid_response, "");
    users.fill = 'a';

    // A string of 1022 bytes and its quotes fit exactly; one more does not.
    var fits = try f.call(io, usersRoute("blob"), "{\"size\":1022}");
    defer fits.deinit();
    try testing.expectEqual(@as(usize, 1024), fits.response.body.len);
    var large = try f.call(io, usersRoute("blob"), "{\"size\":1023}");
    try expectFailure(&large, failures.response_too_large, "");
    var huge = try f.call(io, usersRoute("blob"), "{\"size\":1000000}");
    try expectFailure(&huge, failures.response_too_large, "");
}

const CreateAccountRequest = struct {
    name: []const u8,
    email: []const u8,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .name = v.notEmpty,
        .email = v.email,
        .tags = v.each(v.notEmpty),
    };
};

const Account = struct {
    id: u64,
    name: []const u8,

    pub const field_rules = .{ .name = v.notEmpty };
};

const Period = struct {
    start: u32,
    end: u32,

    pub fn validateSelf(period: *const Period) ?v.Violation {
        if (period.end < period.start) return v.fail(Period, null, "accounts.end_before_start", "must not end before it starts");
        return null;
    }
};

/// A small body whose value takes a lot of memory: each null is 808 bytes.
const Bulk = struct { items: []const ?[100]u64 };

const AccountApi = contract.Contract(.{
    .name = "accounts",
    .version = 1,
    .methods = .{
        .create = contract.method(CreateAccountRequest, Account),
        .report = contract.method(Period, void),
        .bulk = contract.method(Bulk, void),
    },
});

const Accounts = struct {
    runs: std.atomic.Value(u32) = .init(0),

    pub const rpc_handler = contract.implement(AccountApi, .{});

    pub fn create(self: *Accounts, ctx: *Context, req: CreateAccountRequest) !Account {
        _ = ctx;
        _ = self.runs.fetchAdd(1, .acq_rel);
        // The server's own mistake: a name its contract does not allow.
        return .{ .id = 1, .name = if (std.mem.eql(u8, req.name, "nameless")) "" else req.name };
    }

    pub fn report(self: *Accounts, ctx: *Context, req: Period) !void {
        _ = ctx;
        _ = req;
        _ = self.runs.fetchAdd(1, .acq_rel);
    }

    pub fn bulk(self: *Accounts, ctx: *Context, req: Bulk) !void {
        _ = ctx;
        _ = req;
        _ = self.runs.fetchAdd(1, .acq_rel);
    }
};

fn accountsRoute(name: []const u8) model.Route {
    return .{ .service = "accounts", .version = 1, .method = name };
}

const invalid_request: model.Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "Invalid request" };

test "a request against its rules is refused with every violation, and the method does not run" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var accounts: Accounts = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&accounts} }, .{ .transport = f.memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);

    var refused = try f.call(io, accountsRoute("create"), "{\"name\":\"\",\"email\":\"not an email\",\"tags\":[\"a\",\"\"]}");
    var expected = invalid_request;
    expected.field = "name";
    try expectFailure(&refused, expected, "{\"violations\":[" ++
        "{\"field\":\"name\",\"code\":\"validation.not_empty\",\"message\":\"must not be empty\"}," ++
        "{\"field\":\"email\",\"code\":\"validation.email\",\"message\":\"must be a valid email address\"}," ++
        "{\"field\":\"tags[1]\",\"code\":\"validation.not_empty\",\"message\":\"must not be empty\"}]}");
    // A rule of the whole request has no field.
    var backwards = try f.call(io, accountsRoute("report"), "{\"start\":5,\"end\":1}");
    try expectFailure(&backwards, invalid_request, "{\"violations\":[{\"field\":null,\"code\":\"accounts.end_before_start\",\"message\":\"must not end before it starts\"}]}");
    try testing.expectEqual(@as(u32, 0), accounts.runs.load(.acquire));

    var good = try f.call(io, accountsRoute("create"), "{\"name\":\"Ann\",\"email\":\"ann@example.com\"}");
    try expectBody(&good, "{\"id\":\"1\",\"name\":\"Ann\"}");
    var forward = try f.call(io, accountsRoute("report"), "{\"start\":1,\"end\":5}");
    try expectBody(&forward, "{}");
    try testing.expectEqual(@as(u32, 2), accounts.runs.load(.acquire));
}

test "more than 100 violations: the first 100 and truncated" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var accounts: Accounts = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&accounts} }, .{ .transport = f.memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"name\":\"Ann\",\"email\":\"ann@example.com\",\"tags\":[\"\"");
    for (0..149) |_| try body.appendSlice(testing.allocator, ",\"\"");
    try body.appendSlice(testing.allocator, "]}");
    var result = try f.call(io, accountsRoute("create"), body.items);
    defer result.deinit();
    const failure = result.response.status.failure;
    try testing.expectEqualStrings("rpc.invalid_request", failure.app_code);
    try testing.expectEqualStrings("tags[0]", failure.field.?);
    // Transports carry no violations in the failure: they are in the body.
    try testing.expectEqual(@as(usize, 0), failure.violations.len);
    const sent = result.response.body;
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, sent, "\"code\":\"validation.not_empty\""));
    try testing.expect(std.mem.indexOf(u8, sent, "{\"field\":\"tags[99]\",") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "tags[100]") == null);
    try testing.expect(std.mem.endsWith(u8, sent, "}],\"truncated\":true}"));
    try testing.expectEqual(@as(u32, 0), accounts.runs.load(.acquire));
}

/// The failure of `result`; an error for a success.
fn failureOf(result: *const RawClient.Result) !model.Failure {
    return switch (result.response.status) {
        .ok => error.TestUnexpectedResult,
        .failure => |failure| failure,
    };
}

test "violations over max_response_bytes: the first that fit and truncated, and the failure stays" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var accounts: Accounts = .{};
    var peek: Peek = .{};
    var server: Server = try .init(testing.allocator, .{
        .handlers = .{&accounts},
        .middleware = .{&peek},
    }, .{
        .transport = f.memory.serverTransport(),
        .limits = .{ .max_response_bytes = 1024 },
    });
    defer server.deinit(io);
    try server.start(io);

    // 30 empty tags: 30 violations of about 80 bytes, 2.4 KB of body.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"name\":\"Ann\",\"email\":\"ann@example.com\",\"tags\":[\"\"");
    for (0..29) |_| try body.appendSlice(testing.allocator, ",\"\"");
    try body.appendSlice(testing.allocator, "]}");
    var result = try f.call(io, accountsRoute("create"), body.items);
    defer result.deinit();
    const failure = try failureOf(&result);
    try testing.expectEqualStrings("rpc.invalid_request", failure.app_code);
    try testing.expectEqualStrings("tags[0]", failure.field.?);
    // 12 violations and the frame take 995 bytes; a 13th would pass 1024.
    const sent = result.response.body;
    try testing.expectEqual(@as(usize, 995), sent.len);
    try testing.expectEqual(@as(usize, 12), std.mem.count(u8, sent, "\"code\":\"validation.not_empty\""));
    try testing.expect(std.mem.indexOf(u8, sent, "{\"field\":\"tags[11]\",") != null);
    try testing.expect(std.mem.endsWith(u8, sent, "}],\"truncated\":true}"));
    // Middleware sees the violations that were sent.
    try testing.expectEqual(@as(usize, 12), peek.violations);
    try testing.expect(peek.truncated);
}

test "a response against the server's own rules is internal, with the details only in the server's log" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var accounts: Accounts = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&accounts} }, .{ .transport = f.memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;

    var result = try f.call(io, accountsRoute("create"), "{\"name\":\"nameless\",\"email\":\"ann@example.com\"}");
    try expectFailure(&result, method.invalid_response, "");
    try testing.expectEqual(@as(u32, 1), accounts.runs.load(.acquire));
}

test "a request whose value outgrows the memory of a call is refused with resource_exhausted" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var accounts: Accounts = .{};
    var server: Server = try .init(testing.allocator, .{
        .handlers = .{&accounts},
    }, .{
        .transport = f.memory.serverTransport(),
        .limits = .{ .max_request_bytes = 16 * 1024, .max_request_memory_bytes = 64 * 1024 },
    });
    defer server.deinit(io);
    try server.start(io);

    // 2000 nulls: 10 KB of JSON, 1.6 MB of memory.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"items\":[null");
    for (0..1999) |_| try body.appendSlice(testing.allocator, ",null");
    try body.appendSlice(testing.allocator, "]}");
    var result = try f.call(io, accountsRoute("bulk"), body.items);
    try expectFailure(&result, failures.out_of_memory, "");
    var small = try f.call(io, accountsRoute("bulk"), "{\"items\":[null,null]}");
    try expectBody(&small, "{}");
    try testing.expectEqual(@as(u32, 1), accounts.runs.load(.acquire));
}

/// What links and methods did, in order. A call ends before its client
/// has the response, so the test reads it after the call.
const Trail = struct {
    entries: [32][]const u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),

    fn add(t: *Trail, entry: []const u8) void {
        const i = t.len.fetchAdd(1, .acq_rel);
        if (i < t.entries.len) t.entries[i] = entry;
    }

    fn clear(t: *Trail) void {
        t.len.store(0, .release);
    }

    fn expect(t: *const Trail, expected: []const []const u8) !void {
        const written = t.entries[0..@min(t.len.load(.acquire), t.entries.len)];
        errdefer for (written) |entry| std.debug.print("  {s}\n", .{entry});
        try testing.expectEqual(expected.len, written.len);
        for (expected, written) |e, w| try testing.expectEqualStrings(e, w);
    }
};

/// Shared by the middleware functions of the tests, which have no state.
var trail: Trail = .{};

/// A middleware function that marks the trail around the rest of the
/// chain: one per name, built at compile time.
fn marker(comptime name: []const u8) MiddlewareFn {
    return struct {
        fn run(ctx: *Context, next: *Next) anyerror!void {
            _ = ctx;
            trail.add(name ++ ">");
            defer trail.add("<" ++ name);
            return next.run();
        }
    }.run;
}

/// The same as an object with state of its own.
const Marker = struct {
    before: []const u8,
    after: []const u8,

    pub fn run(self: *Marker, ctx: *Context, next: *Next) anyerror!void {
        _ = ctx;
        trail.add(self.before);
        defer trail.add(self.after);
        return next.run();
    }
};

const PlaceOrder = struct { item: []const u8 };
const Receipt = struct { item: []const u8 };

const ShopApi = contract.Contract(.{
    .name = "shop",
    .version = 1,
    .methods = .{
        .place = contract.method(PlaceOrder, Receipt),
        .cancel = contract.method(PlaceOrder, void),
    },
});

const Shop = struct {
    /// Points to an object: the handler's level.
    audit: *Marker,
    /// Holds an object: the level of `place`.
    fraud: Marker,

    pub const rpc_handler = contract.implement(ShopApi, .{
        .middleware = .{ marker("handler-fn"), .audit },
        .methods = .{ .place = .{ .middleware = .{ marker("method-fn"), .fraud } } },
    });

    pub fn place(self: *Shop, ctx: *Context, req: PlaceOrder) !Receipt {
        _ = self;
        _ = ctx;
        trail.add("place");
        return .{ .item = req.item };
    }

    pub fn cancel(self: *Shop, ctx: *Context, req: PlaceOrder) !void {
        _ = self;
        _ = ctx;
        _ = req;
        trail.add("cancel");
    }
};

fn shopRoute(name: []const u8) model.Route {
    return .{ .service = "shop", .version = 1, .method = name };
}

test "middleware runs server, handler, method, each level left to right, and unwinds in reverse" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var audit: Marker = .{ .before = "audit>", .after = "<audit" };
    var shop: Shop = .{ .audit = &audit, .fraud = .{ .before = "fraud>", .after = "<fraud" } };
    var limiter: Marker = .{ .before = "server-object>", .after = "<server-object" };
    var server: Server = try .init(testing.allocator, .{
        .handlers = .{&shop},
        .middleware = .{ marker("server-fn"), &limiter },
    }, .{
        .transport = f.memory.serverTransport(),
    });
    defer server.deinit(io);
    try server.start(io);

    trail.clear();
    var placed = try f.call(io, shopRoute("place"), "{\"item\":\"tea\"}");
    try expectBody(&placed, "{\"item\":\"tea\"}");
    try trail.expect(&.{
        "server-fn>", "server-object>", "handler-fn>", "audit>", "method-fn>",  "fraud>",
        "place",      "<fraud",         "<method-fn",  "<audit", "<handler-fn", "<server-object",
        "<server-fn",
    });
    // The links of one method do not run for another.
    trail.clear();
    var canceled = try f.call(io, shopRoute("cancel"), "{\"item\":\"tea\"}");
    try expectBody(&canceled, "{}");
    try trail.expect(&.{ "server-fn>", "server-object>", "handler-fn>", "audit>", "cancel", "<audit", "<handler-fn", "<server-object", "<server-fn" });
    // A field that holds an object is the handler's own: the server sees
    // what the handler has now.
    shop.fraud.before = "fraud again>";
    trail.clear();
    var again = try f.call(io, shopRoute("place"), "{\"item\":\"tea\"}");
    try expectBody(&again, "{\"item\":\"tea\"}");
    try testing.expectEqualStrings("fraud again>", trail.entries[5]);
    // A field that points to an object is read on every call: the handler
    // may point it elsewhere after init.
    var other: Marker = .{ .before = "other audit>", .after = "<other audit" };
    shop.audit = &other;
    trail.clear();
    var audited = try f.call(io, shopRoute("cancel"), "{\"item\":\"tea\"}");
    try expectBody(&audited, "{}");
    try trail.expect(&.{ "server-fn>", "server-object>", "handler-fn>", "other audit>", "cancel", "<other audit", "<handler-fn", "<server-object", "<server-fn" });
}

/// Copies what middleware sees of the bodies of the last call.
const Peek = struct {
    request: [64]u8 = undefined,
    request_len: usize = 0,
    response: [64]u8 = undefined,
    response_len: ?usize = null,
    failure: ?model.Failure = null,
    violations: usize = 0,
    truncated: bool = false,

    pub fn run(self: *Peek, ctx: *Context, next: *Next) anyerror!void {
        const request = ctx.requestBody();
        self.request_len = @min(request.len, self.request.len);
        @memcpy(self.request[0..self.request_len], request[0..self.request_len]);
        self.response_len = null;
        self.failure = null;
        next.run() catch |err| {
            // Static strings of the framework; the field is not kept.
            if (ctx.failure()) |failure| {
                self.failure = .{ .code = failure.code, .app_code = failure.app_code, .message = failure.message };
                self.violations = failure.violations.len;
                self.truncated = failure.violations_truncated;
            }
            return err;
        };
        if (ctx.responseBody()) |response| {
            const len = @min(response.len, self.response.len);
            @memcpy(self.response[0..len], response[0..len]);
            self.response_len = len;
        }
    }
};

test "middleware sees the request as the client encoded it, the encoded response, and the failure of a stage" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var accounts: Accounts = .{};
    var peek: Peek = .{};
    var server: Server = try .init(testing.allocator, .{
        .handlers = .{&accounts},
        .middleware = .{&peek},
    }, .{
        .transport = f.memory.serverTransport(),
    });
    defer server.deinit(io);
    try server.start(io);

    const request = "{ \"email\" : \"ann@example.com\", \"name\":\"Ann\" }";
    var created = try f.call(io, accountsRoute("create"), request);
    try expectBody(&created, "{\"id\":\"1\",\"name\":\"Ann\"}");
    try testing.expectEqualStrings(request, peek.request[0..peek.request_len]);
    try testing.expectEqualStrings("{\"id\":\"1\",\"name\":\"Ann\"}", peek.response[0..peek.response_len.?]);

    var refused = try f.call(io, accountsRoute("create"), "{\"name\":\"\",\"email\":\"x\"}");
    refused.deinit();
    try testing.expectEqual(@as(?usize, null), peek.response_len);
    try testing.expectEqualStrings("rpc.invalid_request", peek.failure.?.app_code);
    try testing.expectEqual(@as(usize, 2), peek.violations);
}

const RulesApi = contract.Contract(.{
    .name = "rules",
    .version = 1,
    .methods = .{
        .twice = contract.method(Empty, Empty),
        .skip = contract.method(Empty, Empty),
        .refuse = contract.method(Empty, Empty),
        .swallow = contract.method(Empty, Empty),
    },
});

fn callNextTwice(ctx: *Context, next: *Next) anyerror!void {
    _ = ctx;
    next.run() catch {};
    return next.run();
}

fn skipNext(ctx: *Context, next: *Next) anyerror!void {
    _ = ctx;
    _ = next;
}

fn refuseWithoutNext(ctx: *Context, next: *Next) anyerror!void {
    _ = ctx;
    _ = next;
    return error.PermissionDenied;
}

fn swallowError(ctx: *Context, next: *Next) anyerror!void {
    _ = ctx;
    next.run() catch {};
}

const Rules = struct {
    runs: std.atomic.Value(u32) = .init(0),

    pub const rpc_handler = contract.implement(RulesApi, .{ .methods = .{
        .twice = .{ .middleware = .{callNextTwice} },
        .skip = .{ .middleware = .{skipNext} },
        .refuse = .{ .middleware = .{refuseWithoutNext} },
        .swallow = .{ .middleware = .{swallowError} },
    } });

    fn ran(self: *Rules) void {
        _ = self.runs.fetchAdd(1, .acq_rel);
    }

    pub fn twice(self: *Rules, ctx: *Context, req: Empty) !Empty {
        _ = ctx;
        self.ran();
        return req;
    }

    pub fn skip(self: *Rules, ctx: *Context, req: Empty) !Empty {
        _ = ctx;
        self.ran();
        return req;
    }

    pub fn refuse(self: *Rules, ctx: *Context, req: Empty) !Empty {
        _ = ctx;
        self.ran();
        return req;
    }

    pub fn swallow(self: *Rules, ctx: *Context, req: Empty) !Empty {
        _ = ctx;
        _ = req;
        self.ran();
        return error.Unavailable;
    }
};

test "the rules of next.run() hold for the links of handlers and methods" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var rules_handler: Rules = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&rules_handler} }, .{ .transport = f.memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);
    // The engine warns about links that break the rules.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;

    // A second next.run() fails the call, whatever the link does with it;
    // the method ran once.
    var twice = try f.call(io, rulesRoute("twice"), "{}");
    try expectFailure(&twice, failures.internal, "");
    try testing.expectEqual(@as(u32, 1), rules_handler.runs.swap(0, .acq_rel));
    // Success without next.run() is a bug of the link.
    var skip = try f.call(io, rulesRoute("skip"), "{}");
    try expectFailure(&skip, failures.internal, "");
    // An error without next.run() is the outcome.
    var refused = try f.call(io, rulesRoute("refuse"), "{}");
    try expectFailure(&refused, failures.permission_denied, "");
    try testing.expectEqual(@as(u32, 0), rules_handler.runs.load(.acquire));
    // An error the link swallows stays the outcome.
    var swallowed = try f.call(io, rulesRoute("swallow"), "{}");
    try expectFailure(&swallowed, failures.unavailable, "");
    try testing.expectEqual(@as(u32, 1), rules_handler.runs.load(.acquire));
}

fn rulesRoute(name: []const u8) model.Route {
    return .{ .service = "rules", .version = 1, .method = name };
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
    var server: Server = try .init(testing.allocator, .{ .handlers = .{ &v1, &v2 } }, .{ .transport = f.memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);

    var old = try f.call(io, usersRoute("getUser"), "{\"id\":\"1\"}");
    try expectBody(&old, "{\"id\":\"1\",\"name\":\"user-1\",\"email\":null}");
    var new = try f.call(io, .{ .service = "users", .version = 2, .method = "getUser" }, "{\"id\":\"1\"}");
    try expectBody(&new, "{\"id\":\"1\",\"display_name\":\"Ann\"}");
    var unknown = try f.call(io, .{ .service = "users", .version = 2, .method = "deleteUser" }, "{\"id\":\"1\"}");
    try expectFailure(&unknown, failures.unknown_method, "");
}

const Ticket = struct { id: u32 };

const TicketApi = contract.Contract(.{
    .name = "tickets",
    .version = 1,
    .methods = .{
        .get = contract.method(Ticket, Ticket),
        .reserved = contract.method(Ticket, Ticket),
        .open = contract.method(CreateAccountRequest, Ticket),
    },
    .errors = .{
        .TicketClosed = .{ .code = .failed_precondition, .app_code = "tickets.closed", .message = "Ticket is closed" },
    },
});

/// The framework's names that `reserved` returns, by the ticket's id.
const reserved_names = [_]struct { anyerror, model.Failure }{
    .{ error.InvalidArgument, failures.invalid_argument },
    .{ error.Unauthenticated, failures.unauthenticated },
    .{ error.PermissionDenied, failures.permission_denied },
    .{ error.ResourceExhausted, failures.resource_exhausted },
    .{ error.OutOfMemory, failures.resource_exhausted },
    .{ error.Unavailable, failures.unavailable },
    .{ error.DeadlineExceeded, failures.deadline_exceeded },
    .{ error.Cancelled, failures.cancelled },
    .{ error.Internal, failures.internal },
};

const Tickets = struct {
    pub const rpc_handler = contract.implement(TicketApi, .{});

    pub fn get(self: *Tickets, ctx: *Context, req: Ticket) !Ticket {
        _ = self;
        return switch (req.id) {
            1 => error.TicketClosed,
            // An exact failure, field included.
            2 => ctx.fail(.{ .code = .out_of_range, .app_code = "tickets.too_old", .message = "Ticket is too old", .field = "id" }),
            // RpcFailure without ctx.fail is the handler's bug.
            3 => error.RpcFailure,
            // Violations the handler found itself, as a check in a
            // database does: the body of the failure.
            4 => ctx.fail(.{
                .code = .invalid_argument,
                .app_code = "tickets.taken",
                .message = "Ticket is taken",
                .field = "id",
                .violations = &.{.{ .field = "id", .code = "tickets.taken", .message = "is taken" }},
            }),
            else => req,
        };
    }

    pub fn reserved(self: *Tickets, ctx: *Context, req: Ticket) !Ticket {
        _ = self;
        _ = ctx;
        if (req.id >= reserved_names.len) return req;
        return reserved_names[req.id][0];
    }

    pub fn open(self: *Tickets, ctx: *Context, req: CreateAccountRequest) !Ticket {
        _ = self;
        _ = ctx;
        _ = req;
        return .{ .id = 1 };
    }
};

fn ticketsRoute(name: []const u8) model.Route {
    return .{ .service = "tickets", .version = 1, .method = name };
}

test "a handler's errors: ctx.fail exactly, the contract's table, the framework's names, else internal" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var tickets: Tickets = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&tickets} }, .{ .transport = f.memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);

    var closed = try f.call(io, ticketsRoute("get"), "{\"id\":1}");
    try expectFailure(&closed, .{ .code = .failed_precondition, .app_code = "tickets.closed", .message = "Ticket is closed" }, "");
    var old = try f.call(io, ticketsRoute("get"), "{\"id\":2}");
    try expectFailure(&old, .{ .code = .out_of_range, .app_code = "tickets.too_old", .message = "Ticket is too old", .field = "id" }, "");
    var bare = try f.call(io, ticketsRoute("get"), "{\"id\":3}");
    try expectFailure(&bare, failures.internal, "");
    var taken = try f.call(io, ticketsRoute("get"), "{\"id\":4}");
    try expectFailure(&taken, .{ .code = .invalid_argument, .app_code = "tickets.taken", .message = "Ticket is taken", .field = "id" }, "{\"violations\":[{\"field\":\"id\",\"code\":\"tickets.taken\",\"message\":\"is taken\"}]}");
    for (reserved_names, 0..) |case, i| {
        errdefer std.debug.print("error.{t}\n", .{case[0]});
        var body: [16]u8 = undefined;
        var result = try f.call(io, ticketsRoute("reserved"), try std.fmt.bufPrint(&body, "{{\"id\":{d}}}", .{i}));
        try expectFailure(&result, case[1], "");
    }
}

const Seat = struct { row: u32 };

const SeatApi = contract.Contract(.{
    .name = "seats",
    .version = 1,
    .methods = .{ .book = contract.method(Seat, Seat) },
});

/// Fails `book` with violations it found itself; the row says which.
const Seats = struct {
    pub const rpc_handler = contract.implement(SeatApi, .{});

    pub fn book(self: *Seats, ctx: *Context, req: Seat) !Seat {
        _ = self;
        var failure: model.Failure = .{ .code = .already_exists, .app_code = "seats.taken", .message = "Seat is taken", .field = "row" };
        switch (req.row) {
            // 150 violations: the first 100 go out.
            1 => {
                const list = try ctx.allocator().alloc(model.Violation, 150);
                for (list, 0..) |*violation, i| {
                    violation.* = .{ .field = try std.fmt.allocPrint(ctx.allocator(), "seats[{d}]", .{i}), .code = "seats.taken", .message = "is taken" };
                }
                failure.violations = list;
            },
            // The handler says there were more.
            2 => {
                failure.violations = &.{.{ .field = "row", .code = "seats.taken", .message = "is taken" }};
                failure.violations_truncated = true;
            },
            // A path with a line break goes out as null, like a path of
            // validation.
            3 => failure.violations = &.{.{ .field = "row\n", .code = "seats.taken", .message = "is taken" }},
            // JSON cannot carry a message that is not UTF-8.
            4 => failure.violations = &.{.{ .field = "row", .code = "seats.taken", .message = "\xff" }},
            else => return req,
        }
        return ctx.fail(failure);
    }
};

fn seatsRoute() model.Route {
    return .{ .service = "seats", .version = 1, .method = "book" };
}

test "the violations of ctx.fail in a method: at most 100, paths as in validation, and only what JSON carries" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var seats: Seats = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&seats} }, .{ .transport = f.memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);
    const taken: model.Failure = .{ .code = .already_exists, .app_code = "seats.taken", .message = "Seat is taken", .field = "row" };

    var many = try f.call(io, seatsRoute(), "{\"row\":1}");
    defer many.deinit();
    const failure = try failureOf(&many);
    try testing.expectEqualStrings("seats.taken", failure.app_code);
    try testing.expectEqualStrings("row", failure.field.?);
    const sent = many.response.body;
    try testing.expectEqual(@as(usize, 100), std.mem.count(u8, sent, "\"code\":\"seats.taken\""));
    try testing.expect(std.mem.indexOf(u8, sent, "{\"field\":\"seats[99]\",") != null);
    try testing.expect(std.mem.endsWith(u8, sent, "}],\"truncated\":true}"));

    var more = try f.call(io, seatsRoute(), "{\"row\":2}");
    try expectFailure(&more, taken, "{\"violations\":[{\"field\":\"row\",\"code\":\"seats.taken\",\"message\":\"is taken\"}],\"truncated\":true}");
    var bad_path = try f.call(io, seatsRoute(), "{\"row\":3}");
    try expectFailure(&bad_path, taken, "{\"violations\":[{\"field\":null,\"code\":\"seats.taken\",\"message\":\"is taken\"}]}");
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var not_utf8 = try f.call(io, seatsRoute(), "{\"row\":4}");
    try expectFailure(&not_utf8, method.invalid_response, "");
}

/// Fails every call before the rest of the chain, exactly. The violations
/// of middleware are not sent: only a method's go out, in the body.
fn closedForMaintenance(ctx: *Context, next: *Next) anyerror!void {
    _ = next;
    return ctx.fail(.{
        .code = .unavailable,
        .app_code = "tickets.maintenance",
        .message = "Down for maintenance",
        .violations = &.{.{ .field = null, .code = "tickets.maintenance", .message = "is closed" }},
    });
}

/// Turns any failure of the rest of the chain into success: the failure
/// stays the outcome.
fn swallowAll(ctx: *Context, next: *Next) anyerror!void {
    _ = ctx;
    next.run() catch {};
}

/// Replaces any failure of the rest of the chain with an error of its
/// own: the outcome is that error, and a body of the failure is dropped.
fn replaceWithDenied(ctx: *Context, next: *Next) anyerror!void {
    _ = ctx;
    next.run() catch return error.PermissionDenied;
}

/// Replaces any failure with an exact failure of its own.
fn replaceWithExact(ctx: *Context, next: *Next) anyerror!void {
    next.run() catch return ctx.fail(.{ .code = .aborted, .app_code = "tickets.retry", .message = "Try again" });
}

const all_violations = "{\"violations\":[{\"field\":\"name\",\"code\":\"validation.not_empty\",\"message\":\"must not be empty\"}]}";
const bad_account = "{\"name\":\"\",\"email\":\"ann@example.com\"}";

test "middleware fails a call exactly with ctx.fail" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var tickets: Tickets = .{};
    var server: Server = try .init(testing.allocator, .{
        .handlers = .{&tickets},
        .middleware = .{closedForMaintenance},
    }, .{
        .transport = f.memory.serverTransport(),
    });
    defer server.deinit(io);
    try server.start(io);
    var result = try f.call(io, ticketsRoute("get"), "{\"id\":7}");
    try expectFailure(&result, .{ .code = .unavailable, .app_code = "tickets.maintenance", .message = "Down for maintenance" }, "");
}

test "a failure of a stage that middleware swallows stays the outcome, with its body" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var tickets: Tickets = .{};
    var server: Server = try .init(testing.allocator, .{
        .handlers = .{&tickets},
        .middleware = .{swallowAll},
    }, .{
        .transport = f.memory.serverTransport(),
    });
    defer server.deinit(io);
    try server.start(io);
    var refused = try f.call(io, ticketsRoute("open"), bad_account);
    var expected = invalid_request;
    expected.field = "name";
    try expectFailure(&refused, expected, all_violations);
    var undecoded = try f.call(io, ticketsRoute("get"), "{}");
    try expectFailure(&undecoded, .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "missing required field", .field = "id" }, "");
}

test "a failure of a stage that middleware replaces: the outcome is its error, and the body is dropped" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var tickets: Tickets = .{};
    var denied_server: Server = try .init(testing.allocator, .{
        .handlers = .{&tickets},
        .middleware = .{replaceWithDenied},
    }, .{
        .transport = f.memory.serverTransport(),
    });
    defer denied_server.deinit(io);
    try denied_server.start(io);
    var denied = try f.call(io, ticketsRoute("open"), bad_account);
    try expectFailure(&denied, failures.permission_denied, "");
    // The contract's errors are replaced the same way.
    var closed = try f.call(io, ticketsRoute("get"), "{\"id\":1}");
    try expectFailure(&closed, failures.permission_denied, "");
    denied_server.requestStop(io);
    try denied_server.wait(io);

    var exact_memory: MemoryTransport = try .init(testing.allocator, .{});
    defer exact_memory.deinit(io);
    var exact_server: Server = try .init(testing.allocator, .{
        .handlers = .{&tickets},
        .middleware = .{replaceWithExact},
    }, .{
        .transport = exact_memory.serverTransport(),
    });
    defer exact_server.deinit(io);
    try exact_server.start(io);
    var client: RawClient = try .init(testing.allocator, .{ .transport = exact_memory.clientTransport() });
    defer client.deinit();
    var retried = try client.call(io, .root, ticketsRoute("open"), bad_account, .{ .timeout = .fromSeconds(10) });
    try expectFailure(&retried, .{ .code = .aborted, .app_code = "tickets.retry", .message = "Try again" }, "");
}

const Who = struct {
    pub const rpc_handler = contract.implement(TicketApi, .{
        .defaults = .{ .auth = .required },
        .methods = .{ .get = .{ .auth = .optional } },
    });

    /// Answers with the id of the ticket, or 0 for an anonymous caller.
    pub fn get(self: *Who, ctx: *Context, req: Ticket) !Ticket {
        _ = self;
        return .{ .id = if (ctx.identity() == null) 0 else req.id };
    }

    pub fn reserved(self: *Who, ctx: *Context, req: Ticket) !Ticket {
        _ = self;
        const identity = ctx.identity() orelse return error.Internal;
        return .{ .id = if (std.mem.eql(u8, identity.subject, "alice")) req.id else 0 };
    }

    pub fn open(self: *Who, ctx: *Context, req: CreateAccountRequest) !Ticket {
        _ = self;
        _ = ctx;
        _ = req;
        return .{ .id = 1 };
    }
};

/// Knows the bearer token "alice".
const Alice = struct {
    pub fn authenticate(self: *Alice, ctx: *const auth.AuthContext) auth.AuthError!?auth.IdentityView {
        _ = self;
        return switch (ctx.credentials) {
            .none => null,
            .bearer => |token| if (std.mem.eql(u8, token, "alice")) .{ .subject = "alice" } else error.InvalidCredentials,
            else => error.InvalidCredentials,
        };
    }
};

test "the authenticator of rpc.Server and the auth of each method" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var who: Who = .{};
    var alice: Alice = .{};
    var server: Server = try .init(testing.allocator, .{
        .handlers = .{&who},
        .authenticator = &alice,
    }, .{
        .transport = f.memory.serverTransport(),
    });
    defer server.deinit(io);
    try server.start(io);
    try testing.expectEqual(RawServer.Method.Auth.optional, server.engine.methods[0].auth);
    try testing.expectEqual(RawServer.Method.Auth.required, server.engine.methods[1].auth);

    var anonymous = try f.call(io, ticketsRoute("get"), "{\"id\":5}");
    try expectBody(&anonymous, "{\"id\":0}");
    var required = try f.call(io, ticketsRoute("reserved"), "{\"id\":5}");
    try expectFailure(&required, failures.authentication_required, "");
    var known = try f.client.call(io, .root, ticketsRoute("reserved"), "{\"id\":5}", .{ .credentials = .{ .bearer = "alice" } });
    try expectBody(&known, "{\"id\":5}");
    var wrong = try f.client.call(io, .root, ticketsRoute("get"), "{\"id\":5}", .{ .credentials = .{ .bearer = "mallory" } });
    try expectFailure(&wrong, failures.invalid_credentials, "");
}

fn passThrough(ctx: *Context, next: *Next) anyerror!void {
    _ = ctx;
    return next.run();
}

fn ManyLinks(comptime n: usize) type {
    return @Tuple(&@as([n]type, @splat(MiddlewareFn)));
}

/// `n` links of `passThrough`.
fn manyLinks(comptime n: usize) ManyLinks(n) {
    @setEvalBranchQuota(10 * n);
    var links: ManyLinks(n) = undefined;
    inline for (0..n) |i| links[i] = passThrough;
    return links;
}

const BusyApi = contract.Contract(.{
    .name = "busy",
    .version = 1,
    .methods = .{
        .first = contract.method(Empty, Empty),
        .second = contract.method(Empty, Empty),
    },
});

/// Two methods with 1100 links each: more than a thousand steps for the
/// compiler, with its default quota of a thousand.
const Busy = struct {
    pub const rpc_handler = contract.implement(BusyApi, .{ .middleware = manyLinks(1100) });

    pub fn first(self: *Busy, ctx: *Context, req: Empty) !Empty {
        _ = self;
        _ = ctx;
        return req;
    }

    pub fn second(self: *Busy, ctx: *Context, req: Empty) !Empty {
        _ = self;
        _ = ctx;
        return req;
    }
};

test "a server with more than a thousand links builds without a quota of the application's" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var busy: Busy = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&busy} }, .{ .transport = f.memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);
    try testing.expectEqual(@as(usize, 1100), server.engine.methods[1].middleware.len);
    var result = try f.call(io, .{ .service = "busy", .version = 1, .method = "second" }, "{}");
    try expectBody(&result, "{}");
}

fn runServer(server: *Server, io: std.Io) (Server.StartError || Server.WaitError)!void {
    return server.run(io);
}

test "rpc.Server has the lifecycle of the engine" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{ .transport = memory.serverTransport() });
    defer server.deinit(io);
    try testing.expectEqual(Server.State.configured, server.state());
    try testing.expect(!server.isReady());
    try testing.expectError(error.InvalidState, server.wait(io));

    var runner = try io.concurrent(runServer, .{ &server, io });
    // Canceling the wait leaves the server running; deinit stops it.
    defer runner.cancel(io) catch {};
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(10));
    while (server.state() != .running) {
        if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(server.isReady());
    try testing.expectError(error.InvalidState, server.start(io));
    server.requestStop(io);
    try runner.await(io);
    try testing.expectEqual(Server.State.stopped, server.state());
    try testing.expect(!server.isReady());
    try server.shutdown(io, far(io));
    try server.wait(io);
}

test "init refuses limits that cannot work, and frees what it took when memory runs out" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var users: UserHandler = .{};
    try testing.expectError(error.InvalidConfiguration, Server.init(testing.allocator, .{
        .handlers = .{&users},
    }, .{
        .transport = memory.serverTransport(),
        .limits = .{ .max_active_tasks = 0 },
    }));
    try testing.expectError(error.InvalidConfiguration, Server.init(testing.allocator, .{
        .handlers = .{&users},
    }, .{
        .transport = memory.serverTransport(),
        .shutdown_grace = std.Io.Duration.fromMilliseconds(-1),
    }));
    // Every allocation fails once; the test's allocator reports a leak.
    // (checkAllAllocationFailures does not fit: the engine's arena may grow
    // a block in place on one run and allocate a new one on another.)
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        var server = Server.init(failing.allocator(), .{ .handlers = .{&users} }, .{ .transport = memory.serverTransport() }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        server.deinit(io);
        break;
    }
    try testing.expect(fail_index > 1);
}

const NapApi = contract.Contract(.{
    .name = "naps",
    .version = 1,
    .methods = .{
        .nap = contract.method(Empty, Empty),
        .late = contract.method(Empty, Empty),
    },
});

/// Sleeps past the deadline of `late` with cancelation blocked, then goes
/// on: by then the deadline has ended the call.
fn sleepPastDeadline(ctx: *Context, next: *Next) anyerror!void {
    const io = ctx.io();
    const protection = io.swapCancelProtection(.blocked);
    io.sleep(.fromMilliseconds(600), .awake) catch {};
    _ = io.swapCancelProtection(protection);
    return next.run();
}

const Naps = struct {
    naps: std.atomic.Value(u32) = .init(0),
    /// `nap` saw the cancelation of its sleep.
    canceled: std.atomic.Value(bool) = .init(false),
    late_runs: std.atomic.Value(u32) = .init(0),

    pub const rpc_handler = contract.implement(NapApi, .{ .methods = .{
        .nap = .{ .timeout_ms = 300 },
        .late = .{ .timeout_ms = 200, .middleware = .{sleepPastDeadline} },
    } });

    /// Sleeps for 10 seconds, unless the call is canceled.
    pub fn nap(self: *Naps, ctx: *Context, req: Empty) !Empty {
        _ = self.naps.fetchAdd(1, .acq_rel);
        ctx.io().sleep(.fromSeconds(10), .awake) catch |err| {
            self.canceled.store(true, .release);
            return err;
        };
        return req;
    }

    pub fn late(self: *Naps, ctx: *Context, req: Empty) !Empty {
        _ = ctx;
        _ = self.late_runs.fetchAdd(1, .acq_rel);
        return req;
    }
};

fn napsRoute(name: []const u8) model.Route {
    return .{ .service = "naps", .version = 1, .method = name };
}

test "the deadline cancels a method that waits, and the server does not wait out its sleep" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var naps: Naps = .{};
    const started = std.Io.Clock.awake.now(io);
    var replied: std.Io.Timestamp = undefined;
    var stopped: std.Io.Timestamp = undefined;
    {
        var server: Server = try .init(testing.allocator, .{ .handlers = .{&naps} }, .{ .transport = f.memory.serverTransport() });
        defer {
            // deinit waits for the end of the method.
            server.deinit(io);
            stopped = std.Io.Clock.awake.now(io);
        }
        try server.start(io);
        var result = try f.call(io, napsRoute("nap"), "{}");
        replied = std.Io.Clock.awake.now(io);
        try expectFailure(&result, failures.deadline_exceeded, "");
    }
    try testing.expectEqual(@as(u32, 1), naps.naps.load(.acquire));
    try testing.expect(naps.canceled.load(.acquire));
    // Far from the 10 seconds of the nap, with room for slow machines.
    try testing.expect(started.durationTo(replied).toMilliseconds() < 5000);
    try testing.expect(replied.durationTo(stopped).toMilliseconds() < 5000);
}

test "a call that ended while its middleware ran does not run the method" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var naps: Naps = .{};
    {
        var server: Server = try .init(testing.allocator, .{ .handlers = .{&naps} }, .{ .transport = f.memory.serverTransport() });
        defer server.deinit(io);
        try server.start(io);
        var result = try f.call(io, napsRoute("late"), "{}");
        try expectFailure(&result, failures.deadline_exceeded, "");
    }
    // deinit waited for the handler's task: a method that ran has counted.
    try testing.expectEqual(@as(u32, 0), naps.late_runs.load(.acquire));
}
