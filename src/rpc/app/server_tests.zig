//! Tests of `rpc.Server` end to end: calls go through the memory transport
//! and `rpc.RawClient` with JSON bodies written by hand, so each test sees
//! the exact bytes and failures a client gets.

const std = @import("std");
const core = @import("core");
const v = @import("validator");
const model = @import("../model.zig");
const failures = @import("../failures.zig");
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
    var server: Server = try .init(testing.allocator, .{ .transport = f.memory.serverTransport(), .handlers = .{&accounts} });
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
    var server: Server = try .init(testing.allocator, .{ .transport = f.memory.serverTransport(), .handlers = .{&accounts} });
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

test "a response against the server's own rules is internal, with the details only in the server's log" {
    const io = testing.io;
    var f: Fixture = undefined;
    try f.open();
    defer f.close(io);
    var accounts: Accounts = .{};
    var server: Server = try .init(testing.allocator, .{ .transport = f.memory.serverTransport(), .handlers = .{&accounts} });
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
        .transport = f.memory.serverTransport(),
        .handlers = .{&accounts},
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
        .transport = f.memory.serverTransport(),
        .handlers = .{&shop},
        .middleware = .{ marker("server-fn"), &limiter },
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
}

/// Copies what middleware sees of the bodies of the last call.
const Peek = struct {
    request: [64]u8 = undefined,
    request_len: usize = 0,
    response: [64]u8 = undefined,
    response_len: ?usize = null,
    failure: ?model.Failure = null,
    violations: usize = 0,

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
        .transport = f.memory.serverTransport(),
        .handlers = .{&accounts},
        .middleware = .{&peek},
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
    var server: Server = try .init(testing.allocator, .{ .transport = f.memory.serverTransport(), .handlers = .{&rules_handler} });
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
