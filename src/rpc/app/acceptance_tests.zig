//! The acceptance tests of the application layer that need a client and a
//! server: A3, A6, A7, A8 and A9 of the specification. They are written as
//! an application writes its tests, through `rpc.testing.Server` and
//! `rpc.Client`.

const std = @import("std");
const core = @import("core");
const v = @import("validator");
const rpc = @import("../root.zig");

const testing = std.testing;

fn expectFailure(failure: rpc.Failure, code: core.ErrorCode, app_code: []const u8, message: []const u8) !void {
    try testing.expectEqual(code, failure.code);
    try testing.expectEqualStrings(app_code, failure.app_code);
    try testing.expectEqualStrings(message, failure.message);
}

// A3: validation on both sides.

/// The users contract as a strict package has it: rules for requests and
/// for responses.
const strict = struct {
    pub const User = struct {
        id: u64,
        name: []const u8,

        pub const field_rules = .{ .name = v.notEmpty };
    };
    pub const CreateUserRequest = struct {
        name: []const u8,
        email: []const u8,
        tags: []const []const u8 = &.{},

        pub const field_rules = .{
            .name = .{ v.notEmpty, v.maxLength(128) },
            .email = v.email,
            .tags = v.each(v.notEmpty),
        };
    };
    pub const RenameUserRequest = struct { id: u64, new_name: []const u8 };
    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 1,
        .methods = .{
            .createUser = rpc.method(CreateUserRequest, User),
            .renameUser = rpc.method(RenameUserRequest, User),
        },
    });
};

/// The same contract without rules, as an older package of it would have
/// it: its client sends what a strict server refuses, and its server
/// answers what a strict client refuses.
const loose = struct {
    pub const User = struct { id: u64, name: []const u8 };
    pub const CreateUserRequest = struct { name: []const u8, email: []const u8, tags: []const []const u8 = &.{} };
    pub const RenameUserRequest = struct { id: u64, new_name: []const u8 };
    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 1,
        .methods = .{
            .createUser = rpc.method(CreateUserRequest, User),
            .renameUser = rpc.method(RenameUserRequest, User),
        },
    });
};

/// A handler of the users contract of `package`, `strict` or `loose`: it
/// answers with the names it gets, empty ones too.
fn Users(comptime package: type) type {
    return struct {
        const Self = @This();

        created: std.atomic.Value(u32) = .init(0),

        pub const rpc_handler = rpc.implement(package.UserApi, .{});

        pub fn createUser(self: *Self, ctx: *rpc.Context, req: package.CreateUserRequest) !package.User {
            _ = ctx;
            _ = self.created.fetchAdd(1, .monotonic);
            return .{ .id = 1, .name = req.name };
        }

        pub fn renameUser(self: *Self, ctx: *rpc.Context, req: package.RenameUserRequest) !package.User {
            _ = self;
            _ = ctx;
            return .{ .id = req.id, .name = req.new_name };
        }
    };
}

/// A client transport that counts the calls it passes on.
const Counting = struct {
    inner: rpc.ClientTransport,
    calls: std.atomic.Value(u32) = .init(0),

    pub fn call(c: *Counting, io: std.Io, request: *const rpc.transport.Request, options: rpc.ClientTransport.CallOptions) rpc.ClientTransport.CallError!rpc.Response {
        _ = c.calls.fetchAdd(1, .monotonic);
        return c.inner.call(io, request, options);
    }

    pub fn info(c: *Counting) rpc.transport.Info {
        return c.inner.info();
    }
};

test "A3: the server reports every violation of a request, and the client reads them all" {
    var users: Users(strict) = .{};
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&users} });
    defer t.deinit();
    // A client of the loose package sends what the server refuses.
    var client = try t.client(.{});
    defer client.deinit();

    var r = try client.call(testing.io, .root, loose.UserApi.createUser, .{ .name = "", .email = "nope", .tags = &.{ "a", "" } }, .{});
    defer r.deinit();
    try testing.expect(r.sent);
    try testing.expect(!r.refused);
    const failure = r.outcome.failure;
    try expectFailure(failure, .invalid_argument, "rpc.invalid_request", "Invalid request");
    try testing.expectEqualStrings("name", failure.field.?);
    try testing.expectEqual(@as(usize, 3), failure.violations.len);
    try testing.expectEqualStrings("name", failure.violations[0].field.?);
    try testing.expectEqualStrings("validation.not_empty", failure.violations[0].code);
    try testing.expectEqualStrings("email", failure.violations[1].field.?);
    try testing.expectEqualStrings("validation.email", failure.violations[1].code);
    try testing.expectEqualStrings("tags[1]", failure.violations[2].field.?);
    try testing.expect(!failure.violations_truncated);
    try testing.expectEqual(@as(u32, 0), users.created.load(.monotonic));

    // More than 100: the first 100, truncated.
    const tags: [150][]const u8 = @splat("");
    var many = try client.call(testing.io, .root, loose.UserApi.createUser, .{ .name = "Ann", .email = "ann@example.com", .tags = &tags }, .{});
    defer many.deinit();
    try testing.expectEqual(@as(usize, 100), many.outcome.failure.violations.len);
    try testing.expectEqualStrings("tags[0]", many.outcome.failure.field.?);
    try testing.expectEqualStrings("tags[99]", many.outcome.failure.violations[99].field.?);
    try testing.expect(many.outcome.failure.violations_truncated);
}

test "A3: the client does not send a request against its rules" {
    var users: Users(strict) = .{};
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&users} });
    defer t.deinit();
    var counting: Counting = .{ .inner = t.memory.clientTransport() };
    var client: rpc.Client = try .init(testing.allocator, .{ .transport = rpc.ClientTransport.init(&counting) });
    defer client.deinit();

    var r = try client.call(testing.io, .root, strict.UserApi.createUser, .{ .name = "", .email = "ann@example.com" }, .{});
    defer r.deinit();
    try testing.expect(!r.sent);
    try testing.expectEqual(@as(u32, 0), counting.calls.load(.monotonic));
    try expectFailure(r.outcome.failure, .invalid_argument, "rpc.invalid_request", "Invalid request");
    try testing.expectEqualStrings("name", r.outcome.failure.field.?);
    try testing.expectEqual(@as(usize, 1), r.outcome.failure.violations.len);

    // A request that keeps its rules goes out on the same transport.
    var ok = try client.call(testing.io, .root, strict.UserApi.createUser, .{ .name = "Ann", .email = "ann@example.com" }, .{});
    defer ok.deinit();
    try testing.expectEqual(@as(u32, 1), counting.calls.load(.monotonic));
    try testing.expectEqualStrings("Ann", ok.outcome.ok.name);
}

test "A3: a response against the rules is rpc.invalid_response on the server and InvalidResponse on the client" {
    // The strict server breaks its own contract; the details go to its log.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var strict_users: Users(strict) = .{};
    var strict_server = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&strict_users} });
    defer strict_server.deinit();
    var loose_client = try strict_server.client(.{});
    defer loose_client.deinit();
    var refused = try loose_client.call(testing.io, .root, loose.UserApi.renameUser, .{ .id = 1, .new_name = "" }, .{});
    defer refused.deinit();
    try expectFailure(refused.outcome.failure, .internal, "rpc.invalid_response", "Invalid response");

    // A loose server answers what a strict client refuses.
    var loose_users: Users(loose) = .{};
    var loose_server = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&loose_users} });
    defer loose_server.deinit();
    var strict_client = try loose_server.client(.{});
    defer strict_client.deinit();
    var d: rpc.transport.Diagnostics = .{};
    try testing.expectError(error.InvalidResponse, strict_client.call(testing.io, .root, strict.UserApi.renameUser, .{ .id = 1, .new_name = "" }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("users.v1.renameUser: the response breaks its rules at name: must not be empty (validation.not_empty)", d.message());
    var fine = try strict_client.call(testing.io, .root, strict.UserApi.renameUser, .{ .id = 1, .new_name = "Ann" }, .{});
    defer fine.deinit();
    try testing.expectEqualStrings("Ann", fine.outcome.ok.name);
}

// A6 and A7: authentication and credentials through the whole chain.

const Empty = struct {};
const Caller = struct { subject: ?[]const u8 = null };

const WhoApi = rpc.Contract(.{
    .name = "who",
    .version = 1,
    .methods = .{
        .whoami = rpc.method(Empty, Caller),
        .hello = rpc.method(Empty, Caller),
    },
});

/// `whoami` requires an identity; `hello` lets anonymous callers in. Both
/// answer with the subject of the caller.
const Who = struct {
    pub const rpc_handler = rpc.implement(WhoApi, .{
        .methods = .{ .whoami = .{ .auth = .required } },
    });

    pub fn whoami(self: *Who, ctx: *rpc.Context, req: Empty) !Caller {
        _ = self;
        _ = req;
        return .{ .subject = (ctx.identity() orelse return error.Internal).subject };
    }

    pub fn hello(self: *Who, ctx: *rpc.Context, req: Empty) !Caller {
        _ = self;
        _ = req;
        return .{ .subject = if (ctx.identity()) |identity| identity.subject else null };
    }
};

/// The same contract where every method lets anonymous callers in, for a
/// server without an authenticator.
const OpenWho = struct {
    pub const rpc_handler = rpc.implement(WhoApi, .{});

    pub fn whoami(self: *OpenWho, ctx: *rpc.Context, req: Empty) !Caller {
        return self.hello(ctx, req);
    }

    pub fn hello(self: *OpenWho, ctx: *rpc.Context, req: Empty) !Caller {
        _ = self;
        _ = req;
        return .{ .subject = if (ctx.identity()) |identity| identity.subject else null };
    }
};

/// Accepts any credentials and names the caller after them: "bearer:<token>",
/// "basic:<user>:<password>", "custom:<value>"; no credentials are anonymous.
const Echoing = struct {
    pub fn authenticate(self: *Echoing, ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView {
        _ = self;
        const arena = ctx.allocator();
        const subject = switch (ctx.credentials) {
            .none => return null,
            .bearer => |token| try std.fmt.allocPrint(arena, "bearer:{s}", .{token}),
            .basic => |basic| try std.fmt.allocPrint(arena, "basic:{s}:{s}", .{ basic.user, basic.password }),
            .custom => |value| try std.fmt.allocPrint(arena, "custom:{s}", .{value}),
            .provider => return error.InvalidCredentials,
        };
        return .{ .subject = subject };
    }
};

/// The subject the server saw for a call of `hello`.
fn helloAs(client: *rpc.Client, credentials: ?rpc.Credentials) !?[]const u8 {
    var r = try client.call(testing.io, .root, WhoApi.hello, .{}, .{ .credentials = credentials });
    defer r.deinit();
    const subject = r.outcome.ok.subject orelse return null;
    // The result's memory is gone after deinit: keep a copy.
    return @as(?[]const u8, try testing.allocator.dupe(u8, subject));
}

fn expectHello(client: *rpc.Client, credentials: ?rpc.Credentials, expected: ?[]const u8) !void {
    const subject = try helloAs(client, credentials);
    defer if (subject) |s| testing.allocator.free(s);
    if (expected) |text| {
        try testing.expectEqualStrings(text, subject orelse return error.TestExpectedSubject);
    } else try testing.expectEqual(@as(?[]const u8, null), subject);
}

test "A6 and A7: credentials of every kind reach the authenticator: the client's, the call's own, or none" {
    var who: Who = .{};
    var echoing: Echoing = .{};
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&who}, .authenticator = &echoing });
    defer t.deinit();
    var client = try t.client(.{ .credentials = .{ .basic = .{ .user = "billing", .password = "s3cret" } } });
    defer client.deinit();

    // Null: the client's credentials.
    try expectHello(&client, null, "basic:billing:s3cret");
    // `.none`: this call is anonymous.
    try expectHello(&client, .none, null);
    try expectHello(&client, .{ .bearer = "t-1" }, "bearer:t-1");
    try expectHello(&client, .{ .custom = "ApiKey k-1" }, "custom:ApiKey k-1");
    try expectHello(&client, .{ .basic = .{ .user = "ann", .password = "p:w" } }, "basic:ann:p:w");

    var anonymous = try t.client(.{});
    defer anonymous.deinit();
    try expectHello(&anonymous, null, null);
    try expectHello(&anonymous, .{ .bearer = "t-2" }, "bearer:t-2");
}

test "A6: a method that requires an identity refuses anonymous calls; an optional one lets them in" {
    var who: Who = .{};
    var echoing: Echoing = .{};
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&who}, .authenticator = &echoing });
    defer t.deinit();
    var anonymous = try t.client(.{});
    defer anonymous.deinit();
    var refused = try anonymous.call(testing.io, .root, WhoApi.whoami, .{}, .{});
    defer refused.deinit();
    try expectFailure(refused.outcome.failure, .unauthenticated, "rpc.unauthenticated", "Authentication required");
    try expectHello(&anonymous, null, null);

    var signed = try t.client(.{ .credentials = .{ .bearer = "t-1" } });
    defer signed.deinit();
    var me = try signed.call(testing.io, .root, WhoApi.whoami, .{}, .{});
    defer me.deinit();
    try testing.expectEqualStrings("bearer:t-1", me.outcome.ok.subject.?);
}

test "A6: credentials on a server without an authenticator are unauthenticated" {
    var who: OpenWho = .{};
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&who} });
    defer t.deinit();
    var client = try t.client(.{ .credentials = .{ .bearer = "t-1" } });
    defer client.deinit();
    var r = try client.call(testing.io, .root, WhoApi.hello, .{}, .{});
    defer r.deinit();
    try expectFailure(r.outcome.failure, .unauthenticated, "rpc.unauthenticated", "Invalid credentials");
    // Without credentials the call is anonymous and goes through.
    try expectHello(&client, .none, null);
}

/// Gives every call a fresh token: "token-1", "token-2", ...
const Rotating = struct {
    asked: std.atomic.Value(u32) = .init(0),

    fn credentialsProvider(r: *Rotating) rpc.CredentialsProvider {
        return .{ .ptr = r, .get = get };
    }

    fn get(ptr: *anyopaque, io: std.Io, ctx: core.Context, arena: std.mem.Allocator) (error{ Unavailable, OutOfMemory } || std.Io.Cancelable)!rpc.Credentials {
        _ = io;
        _ = ctx;
        const r: *Rotating = @ptrCast(@alignCast(ptr));
        const n = r.asked.fetchAdd(1, .monotonic) + 1;
        return .{ .bearer = try std.fmt.allocPrint(arena, "token-{d}", .{n}) };
    }
};

test "A6: a credentials provider is asked before every call" {
    var who: Who = .{};
    var echoing: Echoing = .{};
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&who}, .authenticator = &echoing });
    defer t.deinit();
    var rotating: Rotating = .{};
    var client = try t.client(.{ .credentials = .{ .provider = rotating.credentialsProvider() } });
    defer client.deinit();
    try expectHello(&client, null, "bearer:token-1");
    try expectHello(&client, null, "bearer:token-2");
    // A call with credentials of its own does not ask.
    try expectHello(&client, .{ .bearer = "own" }, "bearer:own");
    try testing.expectEqual(@as(u32, 2), rotating.asked.load(.monotonic));
}

// A7: a nested call from a handler.

const LookupRequest = struct { id: u64 };
const Person = struct { id: u64, name: []const u8 };
const ProfileRequest = struct { user_id: u64, slow: bool = false };
const Profile = struct { name: []const u8 };

const BackendApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{
        .getUser = rpc.method(LookupRequest, Person),
        .slowUser = rpc.method(LookupRequest, Person),
    },
});

const FrontApi = rpc.Contract(.{
    .name = "front",
    .version = 1,
    .methods = .{ .profile = rpc.method(ProfileRequest, Profile) },
});

/// The backend: records the deadline and the trace each call came with.
const Backend = struct {
    deadline: ?core.Deadline = null,
    trace: ?core.TraceContext = null,
    canceled: std.atomic.Value(bool) = .init(false),

    pub const rpc_handler = rpc.implement(BackendApi, .{});

    pub fn getUser(self: *Backend, ctx: *rpc.Context, req: LookupRequest) !Person {
        const operation = ctx.operation();
        self.deadline = operation.deadline;
        self.trace = operation.trace;
        return .{ .id = req.id, .name = "Ann" };
    }

    /// Waits until the call ends.
    pub fn slowUser(self: *Backend, ctx: *rpc.Context, req: LookupRequest) !Person {
        ctx.io().sleep(.fromSeconds(10), .awake) catch |err| {
            self.canceled.store(true, .release);
            return err;
        };
        return .{ .id = req.id, .name = "late" };
    }
};

/// The frontend: calls the backend from its handler with the context of
/// its own call.
const Frontend = struct {
    users: *rpc.Client,
    deadline: ?core.Deadline = null,
    span: ?core.SpanId = null,

    pub const rpc_handler = rpc.implement(FrontApi, .{});

    pub fn profile(self: *Frontend, ctx: *rpc.Context, req: ProfileRequest) !Profile {
        const operation = ctx.operation();
        self.deadline = operation.deadline;
        self.span = if (operation.trace) |trace| trace.span_id else null;
        var r = if (req.slow)
            try self.users.call(ctx.io(), operation, BackendApi.slowUser, .{ .id = req.user_id }, .{})
        else
            try self.users.call(ctx.io(), operation, BackendApi.getUser, .{ .id = req.user_id }, .{});
        defer r.deinit();
        return switch (r.outcome) {
            // The result's memory is gone after deinit: the name goes to the
            // arena of this call.
            .ok => |user| .{ .name = try ctx.allocator().dupe(u8, user.name) },
            .failure => error.Unavailable,
        };
    }
};

test "A7: a nested call with ctx.operation() keeps the caller's deadline and continues its trace" {
    const io = testing.io;
    var backend: Backend = .{};
    var users = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&backend} });
    defer users.deinit();
    var users_client = try users.client(.{});
    defer users_client.deinit();
    var frontend: Frontend = .{ .users = &users_client };
    var front = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&frontend} });
    defer front.deinit();
    var client = try front.client(.{});
    defer client.deinit();

    const caller_trace = try core.w3c.parseTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    var r = try client.call(io, core.Context.root.withTrace(caller_trace), FrontApi.profile, .{ .user_id = 7 }, .{ .timeout = .fromSeconds(1) });
    defer r.deinit();
    try testing.expectEqualStrings("Ann", r.outcome.ok.name);

    // The backend's deadline is the frontend's, not its own three seconds
    // nor the client's default: only the time in transit apart.
    const front_expires = frontend.deadline.?.expires.nanoseconds;
    const back_expires = backend.deadline.?.expires.nanoseconds;
    try testing.expect(back_expires - front_expires < std.Io.Duration.fromMilliseconds(250).nanoseconds);
    try testing.expect(front_expires - back_expires < std.Io.Duration.fromMilliseconds(250).nanoseconds);
    // One trace: the caller's, the frontend's span, the client's span in
    // it, then the backend's span.
    const back_trace = backend.trace.?;
    try testing.expectEqualSlices(u8, &caller_trace.trace_id.bytes, &back_trace.trace_id.bytes);
    try testing.expect(!std.mem.eql(u8, &back_trace.span_id.bytes, &frontend.span.?.bytes));
    try testing.expect(!std.mem.eql(u8, &back_trace.span_id.bytes, &caller_trace.span_id.bytes));

    // The caller's deadline ends the nested call too.
    const started = std.Io.Clock.awake.now(io);
    if (client.call(io, .root, FrontApi.profile, .{ .user_id = 7, .slow = true }, .{ .timeout = .fromMilliseconds(300) })) |late| {
        var result = late;
        defer result.deinit();
        try testing.expectEqual(core.ErrorCode.deadline_exceeded, result.outcome.failure.code);
    } else |err| try testing.expectEqual(error.DeadlineExceeded, err);
    const took = started.durationTo(std.Io.Clock.awake.now(io));
    try testing.expect(took.nanoseconds < std.Io.Duration.fromSeconds(5).nanoseconds);
    try front.server.shutdown(io);
    try users.server.shutdown(io);
    try testing.expect(backend.canceled.load(.acquire));
}

// A8: versions of a contract (section 5.10).

/// Version 1 of the users contract as it was first published.
const first = struct {
    pub const GetUserRequest = struct { id: u64 };
    pub const User = struct { id: u64, name: []const u8 };
    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 1,
        .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    });
};

/// Version 1 later: a new optional field in the request and one in the
/// response. Compatible, so still version 1.
const later = struct {
    pub const GetUserRequest = struct { id: u64, with_nickname: bool = false };
    pub const User = struct { id: u64, name: []const u8, nickname: ?[]const u8 = null };
    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 1,
        .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    });
};

/// Version 2: another shape, so another contract on its own routes.
const second = struct {
    pub const GetUserRequest = struct { login: []const u8 };
    pub const User = struct { login: []const u8, display_name: []const u8 };
    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 2,
        .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    });
};

const FirstUsers = struct {
    pub const rpc_handler = rpc.implement(first.UserApi, .{});

    pub fn getUser(self: *FirstUsers, ctx: *rpc.Context, req: first.GetUserRequest) !first.User {
        _ = self;
        _ = ctx;
        return .{ .id = req.id, .name = "Ann" };
    }
};

const LaterUsers = struct {
    /// What the last request asked for.
    with_nickname: ?bool = null,

    pub const rpc_handler = rpc.implement(later.UserApi, .{});

    pub fn getUser(self: *LaterUsers, ctx: *rpc.Context, req: later.GetUserRequest) !later.User {
        _ = ctx;
        self.with_nickname = req.with_nickname;
        // Always with the new field, so that an old client meets it.
        return .{ .id = req.id, .name = "Ann", .nickname = "annie" };
    }
};

const SecondUsers = struct {
    pub const rpc_handler = rpc.implement(second.UserApi, .{});

    pub fn getUser(self: *SecondUsers, ctx: *rpc.Context, req: second.GetUserRequest) !second.User {
        _ = self;
        const name = try std.fmt.allocPrint(ctx.allocator(), "User {s}", .{req.login});
        return .{ .login = req.login, .display_name = name };
    }
};

test "A8: an old client and a new server, and a new client and an old server, for a new optional field" {
    // An old client of a new server: the server takes the default of the
    // field the client does not know, the client skips the field it does
    // not know.
    var later_users: LaterUsers = .{};
    var new_server = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&later_users} });
    defer new_server.deinit();
    var old_client = try new_server.client(.{});
    defer old_client.deinit();
    var old = try old_client.call(testing.io, .root, first.UserApi.getUser, .{ .id = 1 }, .{});
    defer old.deinit();
    try testing.expectEqualStrings("Ann", old.outcome.ok.name);
    try testing.expectEqual(@as(?bool, false), later_users.with_nickname);

    // A new client of an old server: the server skips the new field of the
    // request, the client takes null for the field the server does not send.
    var first_users: FirstUsers = .{};
    var old_server = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{&first_users} });
    defer old_server.deinit();
    var new_client = try old_server.client(.{});
    defer new_client.deinit();
    var new = try new_client.call(testing.io, .root, later.UserApi.getUser, .{ .id = 1, .with_nickname = true }, .{});
    defer new.deinit();
    try testing.expectEqualStrings("Ann", new.outcome.ok.name);
    try testing.expectEqual(@as(?[]const u8, null), new.outcome.ok.nickname);

    // The new client of the new server gets the new field.
    var both_new = try new_server.client(.{});
    defer both_new.deinit();
    var full = try both_new.call(testing.io, .root, later.UserApi.getUser, .{ .id = 1, .with_nickname = true }, .{});
    defer full.deinit();
    try testing.expectEqualStrings("annie", full.outcome.ok.nickname.?);
    try testing.expectEqual(@as(?bool, true), later_users.with_nickname);
}

test "A8: two versions of a contract on one server" {
    var v1: FirstUsers = .{};
    var v2: SecondUsers = .{};
    var t = try rpc.testing.Server.init(testing.allocator, testing.io, .{ .handlers = .{ &v1, &v2 } });
    defer t.deinit();
    var client = try t.client(.{});
    defer client.deinit();

    var one = try client.call(testing.io, .root, first.UserApi.getUser, .{ .id = 1 }, .{});
    defer one.deinit();
    try testing.expectEqualStrings("Ann", one.outcome.ok.name);
    var two = try client.call(testing.io, .root, second.UserApi.getUser, .{ .login = "ann" }, .{});
    defer two.deinit();
    try testing.expectEqualStrings("User ann", two.outcome.ok.display_name);
}

// A9: the example of section 5.11, with the contract of 5.1 and the
// handler of 5.2.

/// The contract package of section 5.1.
const api = struct {
    pub const User = struct { id: u64, name: []const u8, email: []const u8 };
    pub const GetUserRequest = struct { id: u64 };
    pub const CreateUserRequest = struct {
        name: []const u8,
        email: []const u8,
        pub const field_rules = .{ .name = .{ v.notEmpty, v.maxLength(128) }, .email = v.email };
    };
    pub const DeleteUserRequest = struct { id: u64 };

    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 1,
        .methods = .{
            .getUser = rpc.method(GetUserRequest, User),
            .createUser = rpc.method(CreateUserRequest, User),
            .deleteUser = rpc.method(DeleteUserRequest, void),
        },
        // A handler's Zig error → the failure its client sees.
        .errors = .{
            .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
            .EmailTaken = .{ .code = .already_exists, .app_code = "users.email_taken", .message = "Email already taken" },
        },
    });
};

/// The service's middleware.
const mw = struct {
    /// Marks every response, to show that the handler's level ran.
    pub fn audit(ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        try ctx.setResponseMetadata("x-audited", "yes");
        return next.run();
    }

    /// Lets in only callers that hold `permission`.
    pub fn requirePermission(comptime permission: []const u8) rpc.MiddlewareFn {
        return struct {
            fn run(ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
                const identity = ctx.identity() orelse return error.Unauthenticated;
                if (!identity.hasPermission(permission)) return error.PermissionDenied;
                return next.run();
            }
        }.run;
    }
};

/// The users of the service, in memory: an implementation of the
/// application for tests. Ada is there from the start.
const UserRepository = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    users: std.ArrayList(api.User) = .empty,
    next_id: u64 = 2,

    const ada: api.User = .{ .id = 1, .name = "Ada", .email = "ada@example.com" };

    pub fn inMemory(gpa: std.mem.Allocator) UserRepository {
        return .{ .gpa = gpa };
    }

    pub fn deinit(repo: *UserRepository) void {
        for (repo.users.items) |user| repo.forget(user);
        repo.users.deinit(repo.gpa);
    }

    fn forget(repo: *UserRepository, user: api.User) void {
        repo.gpa.free(user.name);
        repo.gpa.free(user.email);
    }

    /// The user `id`, copied into `arena`.
    pub fn find(repo: *UserRepository, ctx: core.Context, io: std.Io, arena: std.mem.Allocator, id: u64) UserHandler.Error!api.User {
        try ctx.check(std.Io.Clock.awake.now(io));
        if (id == ada.id) return ada;
        try repo.mutex.lock(io);
        defer repo.mutex.unlock(io);
        for (repo.users.items) |user| {
            if (user.id == id) return .{ .id = user.id, .name = try arena.dupe(u8, user.name), .email = try arena.dupe(u8, user.email) };
        }
        return error.UserNotFound;
    }

    pub fn create(repo: *UserRepository, io: std.Io, req: api.CreateUserRequest) UserHandler.Error!api.User {
        try repo.mutex.lock(io);
        defer repo.mutex.unlock(io);
        if (std.mem.eql(u8, req.email, ada.email)) return error.EmailTaken;
        for (repo.users.items) |user| {
            if (std.mem.eql(u8, user.email, req.email)) return error.EmailTaken;
        }
        const name = try repo.gpa.dupe(u8, req.name);
        errdefer repo.gpa.free(name);
        const email = try repo.gpa.dupe(u8, req.email);
        errdefer repo.gpa.free(email);
        const user: api.User = .{ .id = repo.next_id, .name = name, .email = email };
        try repo.users.append(repo.gpa, user);
        repo.next_id += 1;
        // The caller's request holds the same name and email until the
        // response is encoded.
        return .{ .id = user.id, .name = req.name, .email = req.email };
    }

    pub fn delete(repo: *UserRepository, io: std.Io, id: u64) UserHandler.Error!void {
        try repo.mutex.lock(io);
        defer repo.mutex.unlock(io);
        for (repo.users.items, 0..) |user, i| {
            if (user.id == id) {
                repo.forget(repo.users.swapRemove(i));
                return;
            }
        }
        return error.UserNotFound;
    }
};

/// A fraud check: middleware with a dependency of its own.
const FraudCheck = struct {
    blocked: bool,
    checked: std.atomic.Value(u32) = .init(0),

    /// Without an external service.
    pub fn allowAll() FraudCheck {
        return .{ .blocked = false };
    }

    pub fn run(self: *FraudCheck, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        _ = self.checked.fetchAdd(1, .monotonic);
        if (self.blocked) return ctx.fail(.{ .code = .permission_denied, .app_code = "fraud.blocked", .message = "Blocked by the fraud check" });
        return next.run();
    }
};

/// The handler of section 5.2.
pub const UserHandler = struct {
    repo: *UserRepository,
    fraud: *FraudCheck, // middleware with dependencies for deleteUser

    pub fn init(repo: *UserRepository, fraud: *FraudCheck) UserHandler {
        return .{ .repo = repo, .fraud = fraud };
    }

    pub const rpc_handler = rpc.implement(api.UserApi, .{
        .defaults = .{ .timeout_ms = 3000, .auth = .required },
        .middleware = .{mw.audit}, // the handler's level: every method below
        .methods = .{
            .getUser = .{ .auth = .optional },
            .createUser = .{ .middleware = .{mw.requirePermission("users.write")} },
            .deleteUser = .{ .middleware = .{ mw.requirePermission("users.delete"), .fraud } },
        },
    });

    pub const Error = error{ UserNotFound, EmailTaken, OutOfMemory } || std.Io.Cancelable || core.ContextError;

    // The request is decoded and checked against its field_rules already.
    pub fn getUser(self: *UserHandler, ctx: *rpc.Context, req: api.GetUserRequest) Error!api.User {
        return self.repo.find(ctx.operation(), ctx.io(), ctx.allocator(), req.id);
    }
    pub fn createUser(self: *UserHandler, ctx: *rpc.Context, req: api.CreateUserRequest) Error!api.User {
        return self.repo.create(ctx.io(), req);
    }
    pub fn deleteUser(self: *UserHandler, ctx: *rpc.Context, req: api.DeleteUserRequest) Error!void {
        return self.repo.delete(ctx.io(), req.id);
    }
};

test "A9: getUser returns the user" {
    var repo: UserRepository = .inMemory(std.testing.allocator); // the application's implementation for tests
    defer repo.deinit();
    var fraud_check: FraudCheck = .allowAll(); // without an external service
    var users: UserHandler = .init(&repo, &fraud_check);
    var auth: rpc.testing.StaticAuthenticator = .{ .identity = .{ .subject = "u1", .permissions = &.{"users.write"} } };

    var t = try rpc.testing.Server.init(std.testing.allocator, std.testing.io, .{
        .handlers = .{&users},
        .authenticator = &auth,
    });
    defer t.deinit();

    var client = try t.client(.{ .credentials = .{ .bearer = "test" } });
    defer client.deinit();

    var r = try client.call(std.testing.io, .root, api.UserApi.getUser, .{ .id = 1 }, .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("Ada", r.outcome.ok.name);
}

test "A9: the example's handler through the whole chain: permissions, the fraud check, validation, the contract's errors" {
    const io = testing.io;
    var repo: UserRepository = .inMemory(testing.allocator);
    defer repo.deinit();
    var fraud_check: FraudCheck = .allowAll();
    var users: UserHandler = .init(&repo, &fraud_check);
    var auth: rpc.testing.StaticAuthenticator = .{ .identity = .{ .subject = "u1", .permissions = &.{"users.write"} } };
    var t = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&users}, .authenticator = &auth });
    defer t.deinit();
    var client = try t.client(.{ .credentials = .{ .bearer = "test" } });
    defer client.deinit();

    var created = try client.call(io, .root, api.UserApi.createUser, .{ .name = "Grace", .email = "grace@example.com" }, .{});
    defer created.deinit();
    try testing.expectEqual(@as(u64, 2), created.outcome.ok.id);
    try testing.expectEqualStrings("yes", created.metadata().get("x-audited").?);

    var taken = try client.call(io, .root, api.UserApi.createUser, .{ .name = "Ada", .email = "ada@example.com" }, .{});
    defer taken.deinit();
    try expectFailure(taken.outcome.failure, .already_exists, "users.email_taken", "Email already taken");

    var invalid = try client.call(io, .root, api.UserApi.createUser, .{ .name = "Grace", .email = "grace" }, .{});
    defer invalid.deinit();
    try testing.expect(!invalid.sent);
    try testing.expectEqualStrings("email", invalid.outcome.failure.field.?);

    // deleteUser needs users.delete, then passes the fraud check.
    var denied = try client.call(io, .root, api.UserApi.deleteUser, .{ .id = 2 }, .{});
    defer denied.deinit();
    try expectFailure(denied.outcome.failure, .permission_denied, "rpc.permission_denied", "Permission denied");
    try testing.expectEqual(@as(u32, 0), fraud_check.checked.load(.monotonic));
    auth.identity = .{ .subject = "u1", .permissions = &.{ "users.write", "users.delete" } };
    var deleted = try client.call(io, .root, api.UserApi.deleteUser, .{ .id = 2 }, .{});
    defer deleted.deinit();
    try testing.expect(deleted.outcome == .ok);
    try testing.expectEqual(@as(u32, 1), fraud_check.checked.load(.monotonic));
    fraud_check.blocked = true;
    var blocked = try client.call(io, .root, api.UserApi.deleteUser, .{ .id = 1 }, .{});
    defer blocked.deinit();
    try expectFailure(blocked.outcome.failure, .permission_denied, "fraud.blocked", "Blocked by the fraud check");

    var gone = try client.call(io, .root, api.UserApi.getUser, .{ .id = 2 }, .{});
    defer gone.deinit();
    try expectFailure(gone.outcome.failure, .not_found, "users.not_found", "User not found");

    // getUser lets anonymous callers in; the rest requires an identity.
    var anonymous = try t.client(.{});
    defer anonymous.deinit();
    var ada = try anonymous.call(io, .root, api.UserApi.getUser, .{ .id = 1 }, .{});
    defer ada.deinit();
    try testing.expectEqualStrings("ada@example.com", ada.outcome.ok.email);
    var refused = try anonymous.call(io, .root, api.UserApi.createUser, .{ .name = "Eve", .email = "eve@example.com" }, .{});
    defer refused.deinit();
    try expectFailure(refused.outcome.failure, .unauthenticated, "rpc.unauthenticated", "Authentication required");
}
