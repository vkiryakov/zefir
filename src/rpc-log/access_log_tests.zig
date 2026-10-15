//! A10 of the specification: the access logs of the server and of the
//! client write one record per call with the fields of section 5.12, and
//! never a body, a credential or metadata outside the list. The tests are
//! written as an application writes its code: a contract, a handler,
//! `rpc.testing.Server`, and a logger whose records land in memory.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const log = @import("log");
const rpc_log = @import("root.zig");

const testing = std.testing;

const api = struct {
    pub const User = struct { id: u64, name: []const u8 };
    pub const GetUserRequest = struct { id: u64, note: []const u8 = "" };
    pub const WaitRequest = struct { ms: u32 };

    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 1,
        .methods = .{
            .getUser = rpc.method(GetUserRequest, User),
            .crash = rpc.method(GetUserRequest, void),
            .wait = rpc.method(WaitRequest, void),
            .overstay = rpc.method(WaitRequest, void),
        },
        .errors = .{
            .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
        },
    });
};

/// The same contract as a client that expects one more field: what the
/// server sends does not decode.
const stricter = struct {
    pub const User = struct { id: u64, name: []const u8, email: []const u8 };

    pub const UserApi = rpc.Contract(.{
        .name = "users",
        .version = 1,
        .methods = .{
            .getUser = rpc.method(api.GetUserRequest, User),
        },
    });
};

const UserHandler = struct {
    pub const rpc_handler = rpc.implement(api.UserApi, .{ .defaults = .{ .auth = .optional } });

    pub fn getUser(_: *UserHandler, _: *rpc.Context, req: api.GetUserRequest) error{UserNotFound}!api.User {
        if (req.id != 1) return error.UserNotFound;
        return .{ .id = 1, .name = "Ada Lovelace" };
    }

    /// An error the contract does not list: the client gets `internal`.
    pub fn crash(_: *UserHandler, _: *rpc.Context, _: api.GetUserRequest) error{DiskOnFire}!void {
        return error.DiskOnFire;
    }

    /// Waits; the deadline cancels it.
    pub fn wait(_: *UserHandler, ctx: *rpc.Context, req: api.WaitRequest) std.Io.Cancelable!void {
        try ctx.io().sleep(.fromMilliseconds(req.ms), .awake);
    }

    /// Waits deaf to cancelation, then succeeds: long after the engine
    /// has answered at the deadline.
    pub fn overstay(_: *UserHandler, ctx: *rpc.Context, req: api.WaitRequest) error{}!void {
        const io = ctx.io();
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        io.sleep(.fromMilliseconds(req.ms), .awake) catch {};
    }
};

/// A logger whose records land in memory, one JSON line each.
const Capture = struct {
    out: std.Io.Writer.Allocating,
    logger: log.Logger,

    /// `c` must stay put: the logger writes to `c.out`.
    fn open(c: *Capture, level: log.Level) !void {
        c.out = .init(testing.allocator);
        errdefer c.out.deinit();
        c.logger = try .init(testing.allocator, testing.io, .{ .level = level, .output = .{ .writer = &c.out.writer } });
    }

    fn close(c: *Capture) void {
        c.logger.deinit();
        c.out.deinit();
    }

    /// The records written so far. Read once no call is in flight.
    fn records(c: *Capture, arena: std.mem.Allocator) ![]const std.json.Value {
        var list: std.ArrayList(std.json.Value) = .empty;
        var lines = std.mem.splitScalar(u8, c.out.written(), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try list.append(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}));
        }
        return list.items;
    }

    /// Fails if `text` is anywhere in the output.
    fn expectAbsent(c: *Capture, texts: []const []const u8) !void {
        for (texts) |text| {
            if (std.mem.find(u8, c.out.written(), text) != null) {
                std.debug.print("the log holds \"{s}\":\n{s}\n", .{ text, c.out.written() });
                return error.TestUnexpectedText;
            }
        }
    }
};

fn member(value: ?std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value orelse return null) {
        .object => |object| object.get(name),
        else => null,
    };
}

/// A field of the record's `rpc` object.
fn call(record: std.json.Value, name: []const u8) ?std.json.Value {
    return member(member(record, "rpc"), name);
}

fn expectString(expected: []const u8, value: ?std.json.Value) !void {
    switch (value orelse return error.TestExpectedField) {
        .string => |s| try testing.expectEqualStrings(expected, s),
        else => return error.TestExpectedString,
    }
}

fn stringOf(value: ?std.json.Value) ![]const u8 {
    return switch (value orelse return error.TestExpectedField) {
        .string => |s| s,
        else => error.TestExpectedString,
    };
}

/// The duration of a call: a number of milliseconds, never negative.
fn expectDuration(record: std.json.Value) !void {
    const ms: f64 = switch (call(record, "duration_ms") orelse return error.TestExpectedField) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.TestExpectedNumber,
    };
    try testing.expect(ms >= 0 and ms < 60_000);
}

fn hexOf(id: [16]u8) [32]u8 {
    return std.fmt.bytesToHex(id, .lower);
}

const caller_traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";

test "A10: the server writes one record per call: route, ids, outcome, time, transport, peer" {
    const io = testing.io;
    var capture: Capture = undefined;
    try capture.open(.info);
    defer capture.close();
    var access_log: rpc_log.AccessLog = .init(capture.logger.scoped("rpc"), .{
        .metadata_keys = &.{"x-tenant"},
        .log_subject = true,
    });
    var users: UserHandler = .{};
    var auth: rpc.testing.StaticAuthenticator = .{ .identity = .{ .subject = "user-42", .roles = &.{"auditor"}, .permissions = &.{"users.read"} } };
    var t = try rpc.testing.Server.init(testing.allocator, io, .{
        .handlers = .{&users},
        .authenticator = &auth,
        .middleware = .{&access_log},
    });
    defer t.deinit();
    var client = try t.client(.{ .credentials = .{ .bearer = "s3cret-token" } });
    defer client.deinit();

    const caller = core.Context.root.withTrace(try core.w3c.parseTraceparent(caller_traceparent));
    var r = try client.call(io, caller, api.UserApi.getUser, .{ .id = 1, .note = "body-sentinel" }, .{
        .metadata = &.{
            .{ .key = "x-tenant", .value = "acme" },
            .{ .key = "x-private", .value = "hidden-value" },
            .{ .key = "x-tenant", .value = "acme-eu" },
        },
    });
    defer r.deinit();
    try testing.expectEqualStrings("Ada Lovelace", r.outcome.ok.name);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try capture.records(arena.allocator());
    try testing.expectEqual(@as(usize, 1), records.len);
    const record = records[0];
    try expectString("info", member(record, "level"));
    try expectString("RPC call served", member(record, "message"));
    try expectString("rpc", member(record, "scope"));
    // The caller's trace, in the server's own span of it.
    try expectString("0af7651916cd43dd8448eb211c80319c", member(record, "trace_id"));
    const span = try stringOf(member(record, "span_id"));
    try testing.expectEqual(@as(usize, 16), span.len);
    try testing.expect(!std.mem.eql(u8, span, "b7ad6b7169203331"));

    try expectString("users", call(record, "service"));
    try testing.expectEqual(@as(i64, 1), (call(record, "version") orelse return error.TestExpectedField).integer);
    try expectString("getUser", call(record, "method"));
    try expectString(&hexOf(r.request_id), call(record, "request_id"));
    try expectString("ok", call(record, "code"));
    try testing.expect(call(record, "app_code") == null);
    try expectDuration(record);
    try expectString("memory", call(record, "transport"));
    try expectString("memory", call(record, "peer"));
    try expectString("user-42", call(record, "subject"));
    // Only the listed key, every value of it, in the order they came.
    const metadata = (call(record, "metadata") orelse return error.TestExpectedField).array.items;
    try testing.expectEqual(@as(usize, 2), metadata.len);
    try expectString("x-tenant", member(metadata[0], "key"));
    try expectString("acme", member(metadata[0], "value"));
    try expectString("acme-eu", member(metadata[1], "value"));

    try capture.expectAbsent(&.{ "body-sentinel", "Ada Lovelace", "s3cret-token", "Bearer", "x-private", "hidden-value", "auditor", "users.read" });
}

test "A10: a failure carries its code and app code; the level follows the outcome and the options" {
    const io = testing.io;
    var capture: Capture = undefined;
    try capture.open(.trace);
    defer capture.close();
    var users: UserHandler = .{};
    {
        var access_log: rpc_log.AccessLog = .init(capture.logger.scoped("rpc"), .{});
        var t = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&users}, .middleware = .{&access_log} });
        defer t.deinit();
        var client = try t.client(.{});
        defer client.deinit();
        var missing = try client.call(io, .root, api.UserApi.getUser, .{ .id = 2 }, .{});
        defer missing.deinit();
        try testing.expectEqualStrings("users.not_found", missing.outcome.failure.app_code);
        var crashed = try client.call(io, .root, api.UserApi.crash, .{ .id = 1 }, .{});
        defer crashed.deinit();
        try testing.expectEqual(core.ErrorCode.internal, crashed.outcome.failure.code);
    }
    {
        var access_log: rpc_log.AccessLog = .init(capture.logger.scoped("rpc"), .{
            .levels = .{ .ok = .debug, .not_found = .err },
        });
        var t = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&users}, .middleware = .{&access_log} });
        defer t.deinit();
        var client = try t.client(.{});
        defer client.deinit();
        var found = try client.call(io, .root, api.UserApi.getUser, .{ .id = 1 }, .{});
        defer found.deinit();
        var missing = try client.call(io, .root, api.UserApi.getUser, .{ .id = 2 }, .{});
        defer missing.deinit();
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try capture.records(arena.allocator());
    try testing.expectEqual(@as(usize, 4), records.len);
    // An error of the application: info by default.
    try expectString("info", member(records[0], "level"));
    try expectString("not_found", call(records[0], "code"));
    try expectString("users.not_found", call(records[0], "app_code"));
    // A failure of the service itself: warn.
    try expectString("warn", member(records[1], "level"));
    try expectString("internal", call(records[1], "code"));
    try expectString("rpc.internal", call(records[1], "app_code"));
    // Without the options, no subject and no metadata; no trace without one.
    try testing.expect(call(records[1], "subject") == null and call(records[1], "metadata") == null);
    try testing.expect(member(records[1], "trace_id") == null);
    // The levels the application set.
    try expectString("debug", member(records[2], "level"));
    try expectString("ok", call(records[2], "code"));
    try expectString("error", member(records[3], "level"));
    try expectString("not_found", call(records[3], "code"));
    try capture.expectAbsent(&.{"DiskOnFire"});
}

test "A10: at the deadline the record names the failure the client got, also for a handler that returns later" {
    const io = testing.io;
    var capture: Capture = undefined;
    try capture.open(.info);
    defer capture.close();
    var access_log: rpc_log.AccessLog = .init(capture.logger.scoped("rpc"), .{});
    var users: UserHandler = .{};
    {
        var t = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&users}, .middleware = .{&access_log} });
        defer t.deinit();
        var client = try t.client(.{});
        defer client.deinit();
        const timeout: std.Io.Duration = .fromMilliseconds(100);
        // The deadline cancels the handler.
        if (client.call(io, .root, api.UserApi.wait, .{ .ms = 10_000 }, .{ .timeout = timeout })) |result| {
            var r = result;
            defer r.deinit();
            try testing.expectEqual(core.ErrorCode.deadline_exceeded, r.outcome.failure.code);
        } else |err| try testing.expectEqual(error.DeadlineExceeded, err);
        // The handler ignores the cancelation and succeeds after the
        // deadline: the client got deadline_exceeded all the same.
        if (client.call(io, .root, api.UserApi.overstay, .{ .ms = 300 }, .{ .timeout = timeout })) |result| {
            var r = result;
            defer r.deinit();
            try testing.expectEqual(core.ErrorCode.deadline_exceeded, r.outcome.failure.code);
        } else |err| try testing.expectEqual(error.DeadlineExceeded, err);
        // The records come once the handlers have ended: the server's
        // deinit waits for them.
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try capture.records(arena.allocator());
    try testing.expectEqual(@as(usize, 2), records.len);
    for (records, [_][]const u8{ "wait", "overstay" }) |record, method| {
        try expectString(method, call(record, "method"));
        try expectString("deadline_exceeded", call(record, "code"));
        try expectString("rpc.deadline_exceeded", call(record, "app_code"));
        try expectString("info", member(record, "level"));
    }
}

test "A10: the client writes one record per call: a success, a failure of the server, an error of the transport" {
    const io = testing.io;
    var capture: Capture = undefined;
    try capture.open(.info);
    defer capture.close();
    var client_log: rpc_log.ClientAccessLog = .init(capture.logger.scoped("rpc.client"), .{});
    var users: UserHandler = .{};
    // A server takes credentials only with an authenticator.
    var auth: rpc.testing.StaticAuthenticator = .{ .identity = .{ .subject = "user-42" } };
    var t = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&users}, .authenticator = &auth });
    defer t.deinit();
    var client = try t.client(.{ .credentials = .{ .bearer = "s3cret-token" }, .middleware = .{&client_log} });
    defer client.deinit();

    const caller = core.Context.root.withTrace(try core.w3c.parseTraceparent(caller_traceparent));
    var found = try client.call(io, caller, api.UserApi.getUser, .{ .id = 1, .note = "body-sentinel" }, .{
        .metadata = &.{.{ .key = "x-private", .value = "hidden-value" }},
    });
    defer found.deinit();
    var missing = try client.call(io, caller, api.UserApi.getUser, .{ .id = 2 }, .{});
    defer missing.deinit();
    t.memory.failNext(error.Unavailable);
    try testing.expectError(error.Unavailable, client.call(io, caller, api.UserApi.getUser, .{ .id = 1 }, .{}));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try capture.records(arena.allocator());
    try testing.expectEqual(@as(usize, 3), records.len);

    const ok = records[0];
    try expectString("info", member(ok, "level"));
    try expectString("RPC call made", member(ok, "message"));
    try expectString("rpc.client", member(ok, "scope"));
    // The caller's trace, in the client's span of the call.
    try expectString("0af7651916cd43dd8448eb211c80319c", member(ok, "trace_id"));
    const span = try stringOf(member(ok, "span_id"));
    try testing.expect(span.len == 16 and !std.mem.eql(u8, span, "b7ad6b7169203331"));
    try expectString("users", call(ok, "service"));
    try testing.expectEqual(@as(i64, 1), (call(ok, "version") orelse return error.TestExpectedField).integer);
    try expectString("getUser", call(ok, "method"));
    try expectString(&hexOf(found.request_id), call(ok, "request_id"));
    try expectString("ok", call(ok, "code"));
    try testing.expect(call(ok, "app_code") == null and call(ok, "error") == null);
    try expectDuration(ok);
    try expectString("memory", call(ok, "transport"));

    const failed = records[1];
    try expectString("info", member(failed, "level"));
    try expectString(&hexOf(missing.request_id), call(failed, "request_id"));
    try expectString("not_found", call(failed, "code"));
    try expectString("users.not_found", call(failed, "app_code"));

    // No response: the code of the error, and its name.
    const lost = records[2];
    try expectString("warn", member(lost, "level"));
    try expectString("unavailable", call(lost, "code"));
    try expectString("Unavailable", call(lost, "error"));
    try testing.expect(call(lost, "app_code") == null);

    try capture.expectAbsent(&.{ "body-sentinel", "Ada Lovelace", "s3cret-token", "Bearer", "x-private", "hidden-value" });
}

test "A10: the client's log sees the response before rpc.Client decodes it, and never a request the client did not send" {
    const io = testing.io;
    var capture: Capture = undefined;
    try capture.open(.info);
    defer capture.close();
    var client_log: rpc_log.ClientAccessLog = .init(capture.logger.scoped("rpc.client"), .{});
    var users: UserHandler = .{};
    var t = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&users} });
    defer t.deinit();
    var client = try t.client(.{ .middleware = .{&client_log} });
    defer client.deinit();

    // Invalid metadata: the client does not send the call, and it never
    // passes through the chain.
    var unsent = try client.call(io, .root, api.UserApi.getUser, .{ .id = 1 }, .{
        .metadata = &.{.{ .key = "authorization", .value = "Bearer x" }},
    });
    defer unsent.deinit();
    try testing.expect(!unsent.sent);
    // The server's success does not decode as the stricter contract: the
    // log has the success the chain saw.
    try testing.expectError(error.InvalidResponse, client.call(io, .root, stricter.UserApi.getUser, .{ .id = 1 }, .{}));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try capture.records(arena.allocator());
    try testing.expectEqual(@as(usize, 1), records.len);
    try expectString("ok", call(records[0], "code"));
}

test "A10: in the text format the fields of the call are dotted keys" {
    const io = testing.io;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const logger: log.Logger = try .init(testing.allocator, io, .{ .format = .text, .output = .{ .writer = &out.writer } });
    defer logger.deinit();
    var access_log: rpc_log.AccessLog = .init(logger.scoped("rpc"), .{ .log_subject = true });
    var users: UserHandler = .{};
    var t = try rpc.testing.Server.init(testing.allocator, io, .{ .handlers = .{&users}, .middleware = .{&access_log} });
    defer t.deinit();
    var client = try t.client(.{});
    defer client.deinit();
    var missing = try client.call(io, .root, api.UserApi.getUser, .{ .id = 2 }, .{});
    defer missing.deinit();

    // An anonymous caller has a null subject.
    const line = out.written();
    try testing.expect(std.mem.find(u8, line, " INFO  [rpc] RPC call served rpc.service=users rpc.version=1 rpc.method=getUser rpc.request_id=") != null);
    try testing.expect(std.mem.find(u8, line, " rpc.code=not_found rpc.app_code=users.not_found rpc.duration_ms=") != null);
    try testing.expect(std.mem.find(u8, line, " rpc.transport=memory rpc.peer=memory rpc.subject=null\n") != null);
}
