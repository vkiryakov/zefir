//! Tests of `rpc.Client`: what it sends and how it reads what comes back,
//! through a client transport that answers as each test tells it; and calls
//! end to end through the memory transport and `rpc.Server`.

const std = @import("std");
const core = @import("core");
const v = @import("validator");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const contract = @import("contract.zig");
const Client = @import("Client.zig");
const Server = @import("Server.zig");
const ClientTransport = @import("../ClientTransport.zig");
const MemoryTransport = @import("../testing/MemoryTransport.zig");
const Context = @import("../engine/Context.zig").Context;
const ClientContext = @import("../engine/RawClient.zig").ClientContext;
const ClientNext = @import("../middleware.zig").ClientNext;
const Credentials = @import("../credentials.zig").Credentials;
const auth = @import("../auth.zig");

const testing = std.testing;
const far = @import("../wait.zig").far;

const GetUserRequest = struct { id: u64 };
const User = struct {
    id: u64,
    name: []const u8,
    email: ?[]const u8 = null,

    pub const field_rules = .{ .name = v.notEmpty };
};
const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .name = .{ v.notEmpty, v.maxLength(128) },
        .email = v.email,
        .tags = v.each(v.notEmpty),
    };
};
const DeleteUserRequest = struct { id: u64 };
const Point = struct { x: f64 };
const Note = struct { text: []const u8 };

const UserApi = contract.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{
        .getUser = contract.method(GetUserRequest, User),
        .createUser = contract.method(CreateUserRequest, User),
        .deleteUser = contract.method(DeleteUserRequest, void),
        .plot = contract.method(Point, Point),
        .note = contract.method(Note, void),
        .history = contract.method(GetUserRequest, []const ?[1000]u64),
    },
});

/// A client transport that answers as the test tells it and records what
/// the client sent.
const Scripted = struct {
    answer: Answer = .{ .ok = "{}" },
    calls: u32 = 0,
    /// The last request: its body copied, its route and id.
    body: std.ArrayList(u8) = .empty,
    route: ?model.Route = null,
    request_id: [16]u8 = undefined,
    authorization: ?[]const u8 = null,
    /// Set when a call reaches the transport.
    entered: std.atomic.Value(u32) = .init(0),

    const Answer = union(enum) {
        ok: []const u8,
        ok_with_metadata: struct { body: []const u8, metadata: []const model.Metadata.Entry },
        failure: struct { failure: model.Failure, body: []const u8 = "", refused: bool = false },
        err: ClientTransport.CallError,
        /// Sleeps until the caller's task is canceled.
        hang,
    };

    fn deinit(s: *Scripted) void {
        s.body.deinit(testing.allocator);
        if (s.authorization) |value| testing.allocator.free(value);
    }

    pub fn call(s: *Scripted, io: std.Io, request: *const transport.Request, options: ClientTransport.CallOptions) ClientTransport.CallError!model.Response {
        s.calls += 1;
        s.route = request.route;
        s.request_id = request.request_id;
        {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            s.body.clearRetainingCapacity();
            try s.body.appendSlice(testing.allocator, request.body);
            if (s.authorization) |value| testing.allocator.free(value);
            s.authorization = null;
            const view: model.Metadata.View = .{ .entries = request.metadata };
            if (view.get("authorization")) |value| s.authorization = try testing.allocator.dupe(u8, value);
        }
        _ = s.entered.fetchAdd(1, .acq_rel);
        if (s.answer == .hang) {
            try io.sleep(.fromSeconds(60), .awake);
            return error.Unexpected;
        }
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        const a = options.allocator;
        return switch (s.answer) {
            .ok => |body| .{ .status = .ok, .body = try copyBody(a, body, options) },
            .ok_with_metadata => |answer| .{
                .status = .ok,
                .body = try copyBody(a, answer.body, options),
                .metadata = try copyMetadata(a, answer.metadata),
            },
            .failure => |answer| .{
                .status = .{ .failure = answer.failure },
                .body = try copyBody(a, answer.body, options),
                .refused = answer.refused,
            },
            .err => |err| err,
            .hang => unreachable,
        };
    }

    pub fn info(s: *Scripted) transport.Info {
        _ = s;
        return .{ .name = "scripted" };
    }

    fn copyBody(a: std.mem.Allocator, body: []const u8, options: ClientTransport.CallOptions) ClientTransport.CallError![]const u8 {
        if (body.len > options.max_response_bytes) return error.ResponseTooLarge;
        return a.dupe(u8, body);
    }

    fn copyMetadata(a: std.mem.Allocator, entries: []const model.Metadata.Entry) error{OutOfMemory}![]const model.Metadata.Entry {
        const copies = try a.alloc(model.Metadata.Entry, entries.len);
        for (entries, copies) |entry, *copy| copy.* = .{ .key = try a.dupe(u8, entry.key), .value = try a.dupe(u8, entry.value) };
        return copies;
    }
};

fn scriptedClient(script: *Scripted) !Client {
    return Client.init(testing.allocator, .{}, .{ .transport = ClientTransport.init(script) });
}

fn expectFailure(failure: model.Failure, code: core.ErrorCode, app_code: []const u8, message: []const u8) !void {
    try testing.expectEqual(code, failure.code);
    try testing.expectEqualStrings(app_code, failure.app_code);
    try testing.expectEqualStrings(message, failure.message);
}

test "a call sends the request as JSON on the method's route and decodes the response" {
    var script: Scripted = .{ .answer = .{ .ok = "{\"id\":\"9007199254740993\",\"name\":\"Ann\",\"email\":null}" } };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();

    var r = try client.call(testing.io, .root, UserApi.getUser, .{ .id = 42 }, .{});
    defer r.deinit();
    try testing.expectEqualStrings("{\"id\":\"42\"}", script.body.items);
    try testing.expectEqualStrings("users", script.route.?.service);
    try testing.expectEqual(@as(u16, 1), script.route.?.version);
    try testing.expectEqualStrings("getUser", script.route.?.method);
    const user: User = r.outcome.ok;
    try testing.expectEqual(@as(u64, 9007199254740993), user.id);
    try testing.expectEqualStrings("Ann", user.name);
    try testing.expectEqual(@as(?[]const u8, null), user.email);
    try testing.expect(r.sent);
    try testing.expect(!r.refused);
    try testing.expectEqualSlices(u8, &script.request_id, &r.request_id);
    try testing.expectEqual(@as(usize, 0), r.metadata().entries.len);
}

test "a request against its rules is not sent, and the failure lists all its violations" {
    var script: Scripted = .{};
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();

    var r = try client.call(testing.io, .root, UserApi.createUser, .{ .name = "", .email = "not an email", .tags = &.{ "a", "", "" } }, .{});
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), script.calls);
    try testing.expect(!r.sent);
    try testing.expect(!r.refused);
    const failure = r.outcome.failure;
    try expectFailure(failure, .invalid_argument, "rpc.invalid_request", "Invalid request");
    try testing.expectEqualStrings("name", failure.field.?);
    try testing.expectEqual(@as(usize, 4), failure.violations.len);
    try testing.expectEqualStrings("name", failure.violations[0].field.?);
    try testing.expectEqualStrings("validation.not_empty", failure.violations[0].code);
    try testing.expectEqualStrings("email", failure.violations[1].field.?);
    try testing.expectEqualStrings("tags[1]", failure.violations[2].field.?);
    try testing.expectEqualStrings("tags[2]", failure.violations[3].field.?);
    try testing.expect(!failure.violations_truncated);
}

test "a request with more than 100 violations keeps the first 100 and says it dropped some" {
    var script: Scripted = .{};
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();

    const tags: [150][]const u8 = @splat("");
    var r = try client.call(testing.io, .root, UserApi.createUser, .{ .name = "Ann", .email = "ann@example.com", .tags = &tags }, .{});
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), script.calls);
    const failure = r.outcome.failure;
    try testing.expectEqual(@as(usize, 100), failure.violations.len);
    try testing.expect(failure.violations_truncated);
    try testing.expectEqualStrings("tags[0]", failure.field.?);
    try testing.expectEqualStrings("tags[99]", failure.violations[99].field.?);
}

test "a request JSON cannot carry is not sent" {
    var script: Scripted = .{};
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();

    var nan = try client.call(testing.io, .root, UserApi.plot, .{ .x = std.math.nan(f64) }, .{});
    defer nan.deinit();
    try testing.expect(!nan.sent);
    try expectFailure(nan.outcome.failure, .invalid_argument, "rpc.invalid_request", "A float of the request is NaN or infinite");
    try testing.expectEqual(@as(?[]const u8, null), nan.outcome.failure.field);

    var bytes = try client.call(testing.io, .root, UserApi.note, .{ .text = "caf\xe9" }, .{});
    defer bytes.deinit();
    try testing.expect(!bytes.sent);
    try expectFailure(bytes.outcome.failure, .invalid_argument, "rpc.invalid_request", "A string of the request is not UTF-8");
    try testing.expectEqual(@as(u32, 0), script.calls);

    script.answer = .{ .ok = "{\"x\":1}" };
    var fine = try client.call(testing.io, .root, UserApi.plot, .{ .x = 0.5 }, .{});
    defer fine.deinit();
    try testing.expectEqualStrings("{\"x\":0.5}", script.body.items);
    try testing.expectEqual(@as(f64, 1), fine.outcome.ok.x);
}

test "a response that does not decode is InvalidResponse, and diagnostics say where" {
    var script: Scripted = .{};
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();
    var d: transport.Diagnostics = .{};

    for ([_]struct { []const u8, []const u8 }{
        .{ "{\"id\":\"1\"}", "users.v1.getUser: the response does not decode: missing required field at name" },
        .{ "{\"id\":1,\"name\":\"Ann\"}", "users.v1.getUser: the response does not decode: wrong type at id" },
        .{ "not json", "users.v1.getUser: the response does not decode: invalid JSON" },
        .{ "{\"id\":\"1\",\"name\":\"Ann\"} {}", "users.v1.getUser: the response does not decode: invalid JSON" },
    }) |case| {
        script.answer = .{ .ok = case[0] };
        d = .{};
        try testing.expectError(error.InvalidResponse, client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{ .diagnostics = &d }));
        try testing.expectEqual(transport.Diagnostics.Phase.receive, d.phase.?);
        try testing.expectEqualStrings(case[1], d.message());
    }
    // Without diagnostics, the same error.
    script.answer = .{ .ok = "[]" };
    try testing.expectError(error.InvalidResponse, client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{}));
}

test "a response against its rules is InvalidResponse, with the path and the rule in diagnostics" {
    var script: Scripted = .{ .answer = .{ .ok = "{\"id\":\"1\",\"name\":\"\"}" } };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();
    var d: transport.Diagnostics = .{};
    try testing.expectError(error.InvalidResponse, client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{ .diagnostics = &d }));
    try testing.expectEqualStrings("users.v1.getUser: the response breaks its rules at name: must not be empty (validation.not_empty)", d.message());
}

test "a void response is {} or nothing" {
    var script: Scripted = .{ .answer = .{ .ok = "{}" } };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();
    var braces = try client.call(testing.io, .root, UserApi.deleteUser, .{ .id = 1 }, .{});
    defer braces.deinit();
    try testing.expect(braces.outcome == .ok);
    script.answer = .{ .ok = "" };
    var empty = try client.call(testing.io, .root, UserApi.deleteUser, .{ .id = 1 }, .{});
    defer empty.deinit();
    try testing.expect(empty.outcome == .ok);
    script.answer = .{ .ok = "null" };
    try testing.expectError(error.InvalidResponse, client.call(testing.io, .root, UserApi.deleteUser, .{ .id = 1 }, .{}));
}

test "a failure of the server comes as it is, with the violations of its body" {
    var script: Scripted = .{ .answer = .{ .failure = .{
        .failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "Invalid request", .field = "name" },
        .body = "{\"violations\":[" ++
            "{\"field\":\"name\",\"code\":\"validation.not_empty\",\"message\":\"must not be empty\"}," ++
            "{\"field\":null,\"code\":\"orders.end_before_start\",\"message\":\"end must not be before start\"}," ++
            "{\"code\":\"c\",\"message\":\"no field at all\",\"hint\":\"unknown keys are skipped\"}," ++
            "{\"field\":\"a\\nb\",\"code\":\"x\",\"message\":\"a path with a line break is left out\"}" ++
            "],\"truncated\":true}",
    } } };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();

    var r = try client.call(testing.io, .root, UserApi.createUser, .{ .name = "Ann", .email = "ann@example.com" }, .{});
    defer r.deinit();
    try testing.expect(r.sent);
    try testing.expect(!r.refused);
    const failure = r.outcome.failure;
    try expectFailure(failure, .invalid_argument, "rpc.invalid_request", "Invalid request");
    try testing.expectEqualStrings("name", failure.field.?);
    try testing.expectEqual(@as(usize, 4), failure.violations.len);
    try testing.expectEqualStrings("name", failure.violations[0].field.?);
    try testing.expectEqualStrings("must not be empty", failure.violations[0].message);
    try testing.expectEqual(@as(?[]const u8, null), failure.violations[1].field);
    try testing.expectEqualStrings("orders.end_before_start", failure.violations[1].code);
    try testing.expectEqual(@as(?[]const u8, null), failure.violations[2].field);
    try testing.expectEqual(@as(?[]const u8, null), failure.violations[3].field);
    try testing.expect(failure.violations_truncated);
}

test "a body of more than 100 violations gives the first 100, truncated" {
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"violations\":[");
    for (0..150) |i| {
        if (i > 0) try body.writer.writeByte(',');
        try body.writer.print("{{\"field\":\"tags[{d}]\",\"code\":\"validation.not_empty\",\"message\":\"must not be empty\"}}", .{i});
    }
    try body.writer.writeAll("]}");
    var script: Scripted = .{ .answer = .{ .failure = .{
        .failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "Invalid request" },
        .body = body.written(),
    } } };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();

    var r = try client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{});
    defer r.deinit();
    const failure = r.outcome.failure;
    try testing.expectEqual(@as(usize, 100), failure.violations.len);
    try testing.expectEqualStrings("tags[99]", failure.violations[99].field.?);
    try testing.expect(failure.violations_truncated);
}

test "a failure body as large as max_response_bytes leaves only the kept violations behind" {
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"violations\":[");
    // The first has escapes: its strings are decoded, not borrowed from the
    // body.
    try body.writer.writeAll("{\"field\":\"n\\u0061me\",\"code\":\"c\\u0021\",\"message\":\"m\\u0021\"}");
    for (1..41_000) |_| try body.writer.writeAll(",{\"code\":\"\",\"message\":\"\"}");
    try body.writer.writeAll("]}");
    try testing.expect(body.written().len <= 1 << 20);
    var script: Scripted = .{ .answer = .{ .failure = .{
        .failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "Invalid request" },
        .body = body.written(),
    } } };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();

    var r = try client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{});
    defer r.deinit();
    const failure = r.outcome.failure;
    try testing.expectEqual(@as(usize, 100), failure.violations.len);
    try testing.expect(failure.violations_truncated);
    try testing.expectEqualStrings("name", failure.violations[0].field.?);
    try testing.expectEqualStrings("c!", failure.violations[0].code);
    try testing.expectEqualStrings("m!", failure.violations[0].message);
    try testing.expectEqual(@as(?[]const u8, null), failure.violations[99].field);
    // The result keeps the body and a hundred violations, not the whole
    // list of 41 000 that the decoding took.
    try testing.expect(r.arena.queryCapacity() < 3 * body.written().len);
}

test "a failure body that is not a list of violations is left aside" {
    var script: Scripted = .{};
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();
    const unavailable: model.Failure = .{ .code = .unavailable, .app_code = "", .message = "503 Service Unavailable" };

    for ([_][]const u8{ "Service Unavailable", "{\"error\":\"down\"}", "{\"violations\":[{\"field\":1}]}", "{\"violations\":[]} trailing" }) |body| {
        script.answer = .{ .failure = .{ .failure = unavailable, .body = body } };
        var r = try client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{});
        defer r.deinit();
        const failure = r.outcome.failure;
        try expectFailure(failure, .unavailable, "", "503 Service Unavailable");
        try testing.expectEqual(@as(usize, 0), failure.violations.len);
        try testing.expect(!failure.violations_truncated);
    }
}

test "a refusal at admission says so" {
    var script: Scripted = .{ .answer = .{ .failure = .{
        .failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Server overloaded" },
        .refused = true,
    } } };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();
    var r = try client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{});
    defer r.deinit();
    try testing.expect(r.refused);
    try testing.expect(r.sent);
    try expectFailure(r.outcome.failure, .resource_exhausted, "rpc.resource_exhausted", "Server overloaded");
}

test "the metadata of the response" {
    var script: Scripted = .{ .answer = .{ .ok_with_metadata = .{
        .body = "{\"id\":\"1\",\"name\":\"Ann\"}",
        .metadata = &.{ .{ .key = "x-served-by", .value = "users-2" }, .{ .key = "x-tag", .value = "a" }, .{ .key = "x-tag", .value = "b" } },
    } } };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();
    var r = try client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{});
    defer r.deinit();
    try testing.expectEqualStrings("users-2", r.metadata().get("x-served-by").?);
    var tags = r.metadata().getAll("x-tag");
    try testing.expectEqualStrings("a", tags.next().?);
    try testing.expectEqualStrings("b", tags.next().?);
    try testing.expectEqual(@as(?[]const u8, null), tags.next());
    var it = r.metadata().iterator();
    try testing.expectEqualStrings("x-served-by", it.next().?.key);
}

test "a response that takes more memory than the client allows is ResponseTooLarge" {
    var script: Scripted = .{};
    defer script.deinit();
    var client: Client = try .init(testing.allocator, .{}, .{ .transport = ClientTransport.init(&script), .max_response_bytes = 64 * 1024 });
    defer client.deinit();

    // 10 000 nulls in 50 KB of JSON ask for 80 MB: refused before any of it
    // is taken.
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try body.writer.writeByte('[');
    for (0..10_000) |i| try body.writer.writeAll(if (i == 0) "null" else ",null");
    try body.writer.writeByte(']');
    script.answer = .{ .ok = body.written() };
    try testing.expectError(error.ResponseTooLarge, client.call(testing.io, .root, UserApi.history, .{ .id = 1 }, .{}));

    // A few of them fit the budget: 8 times 64 KiB.
    script.answer = .{ .ok = "[null,null,null]" };
    var r = try client.call(testing.io, .root, UserApi.history, .{ .id = 1 }, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.outcome.ok.len);
    try testing.expectEqual(@as(usize, 8 * 64 * 1024), @max(64 * 1024 * Client.decode_budget_factor, Client.min_decode_budget));

    // A body over max_response_bytes is the transport's ResponseTooLarge.
    const big: [64 * 1024 + 1]u8 = @splat(' ');
    script.answer = .{ .ok = &big };
    try testing.expectError(error.ResponseTooLarge, client.call(testing.io, .root, UserApi.history, .{ .id = 1 }, .{}));
}

test "the errors of the engine and of the transport come as they are" {
    var script: Scripted = .{};
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();
    script.answer = .{ .err = error.Unavailable };
    try testing.expectError(error.Unavailable, client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{}));
    script.answer = .{ .err = error.ConnectionLost };
    try testing.expectError(error.ConnectionLost, client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{}));
    script.answer = .{ .err = error.Closed };
    try testing.expectError(error.ClientClosed, client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{}));

    // A canceled context sends nothing.
    var token: core.CancellationToken = .init;
    token.cancel();
    const calls = script.calls;
    try testing.expectError(error.Cancelled, client.call(testing.io, core.Context.root.withCancellation(&token), UserApi.getUser, .{ .id = 1 }, .{}));
    try testing.expectEqual(calls, script.calls);

    // Metadata against the rules is the engine's failure, not sent.
    var r = try client.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{ .metadata = &.{.{ .key = "zefir-x", .value = "1" }} });
    defer r.deinit();
    try testing.expect(!r.sent);
    try expectFailure(r.outcome.failure, .invalid_argument, "rpc.invalid_metadata", "Invalid metadata");
    try testing.expectEqual(calls, script.calls);
}

const Observed = struct { result: Client.CallError!void, still_canceled: bool };

/// Calls, then looks whether a cancelation of its task is still there.
fn callAndLook(client: *Client, io: std.Io) Observed {
    var observed: Observed = .{ .result = {}, .still_canceled = false };
    if (client.call(io, .root, UserApi.getUser, .{ .id = 1 }, .{ .timeout = .fromSeconds(30) })) |result| {
        var r = result;
        r.deinit();
    } else |err| observed.result = err;
    io.checkCancel() catch {
        observed.still_canceled = true;
    };
    return observed;
}

/// Waits until `counter` reaches `n`, ten seconds at most.
fn waitFor(io: std.Io, counter: *const std.atomic.Value(u32), n: u32) !void {
    const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(10));
    while (counter.load(.acquire) < n) {
        if (deadline.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "the caller's task canceled during a call: Cancelled, and the cancelation stays for the task" {
    const io = testing.io;
    var script: Scripted = .{ .answer = .hang };
    defer script.deinit();
    var client = try scriptedClient(&script);
    defer client.deinit();

    var caller = try io.concurrent(callAndLook, .{ &client, io });
    try waitFor(io, &script.entered, 1);
    const observed = caller.cancel(io);
    try testing.expectError(error.Cancelled, observed.result);
    try testing.expect(observed.still_canceled);
}

test "every failed allocation ends a call with OutOfMemory and leaves nothing behind" {
    const answers = [_]Scripted.Answer{
        .{ .ok = "{\"id\":\"1\",\"name\":\"\\u0041nn\",\"email\":\"a\\u0040b\"}" },
        .{ .failure = .{
            .failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "Invalid request" },
            .body = "{\"violations\":[{\"field\":\"n\\u0061me\",\"code\":\"c\",\"message\":\"m\"}]}",
        } },
    };
    for (answers) |answer| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var script: Scripted = .{ .answer = answer };
            defer script.deinit();
            var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
            var client = Client.init(failing.allocator(), .{}, .{ .transport = ClientTransport.init(&script) }) catch continue;
            defer client.deinit();
            var r = client.call(testing.io, .root, UserApi.createUser, .{ .name = "Ann", .email = "ann@example.com" }, .{}) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                continue;
            };
            r.deinit();
            if (!failing.has_induced_failure) break;
        }
    }
    // The invalid request's own allocations too.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var script: Scripted = .{};
        defer script.deinit();
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        var client = Client.init(failing.allocator(), .{}, .{ .transport = ClientTransport.init(&script) }) catch continue;
        defer client.deinit();
        var r = client.call(testing.io, .root, UserApi.createUser, .{ .name = "", .email = "" }, .{}) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        try testing.expectEqual(@as(usize, 2), r.outcome.failure.violations.len);
        r.deinit();
        if (!failing.has_induced_failure) break;
    }
}

/// Counts the calls that pass it, and tags them.
const Tagger = struct {
    calls: u32 = 0,

    pub fn run(t: *Tagger, ctx: *ClientContext, next: *ClientNext) anyerror!void {
        t.calls += 1;
        try ctx.addMetadata("x-tagged", "yes");
        return next.run();
    }
};

fn refuseAll(ctx: *ClientContext, next: *ClientNext) anyerror!void {
    _ = ctx;
    _ = next;
    return error.Unavailable;
}

test "init takes credentials and middleware as literals, and the limits" {
    var script: Scripted = .{ .answer = .{ .ok = "{\"id\":\"1\",\"name\":\"Ann\"}" } };
    defer script.deinit();
    var token: []const u8 = "t-1";
    _ = &token;

    var tagger: Tagger = .{};
    var bearer: Client = try .init(testing.allocator, .{
        .middleware = .{&tagger},
    }, .{
        .transport = ClientTransport.init(&script),
        .credentials = .{ .bearer = token },
        .default_timeout = std.Io.Duration.fromSeconds(5),
        .max_pending = 7,
        .max_response_bytes = 4096,
    });
    defer bearer.deinit();
    try testing.expectEqual(@as(u32, 7), bearer.engine.max_pending);
    try testing.expectEqual(@as(usize, 4096), bearer.engine.max_response_bytes);
    try testing.expectEqual(@as(i96, std.Io.Duration.fromSeconds(5).nanoseconds), bearer.engine.default_timeout.nanoseconds);
    var r = try bearer.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{});
    r.deinit();
    try testing.expectEqualStrings("Bearer t-1", script.authorization.?);
    try testing.expectEqual(@as(u32, 1), tagger.calls);

    // The call's own credentials, and an anonymous call.
    var own = try bearer.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{ .credentials = .{ .bearer = "t-2" } });
    own.deinit();
    try testing.expectEqualStrings("Bearer t-2", script.authorization.?);
    var anonymous = try bearer.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{ .credentials = .none });
    anonymous.deinit();
    try testing.expectEqual(@as(?[]const u8, null), script.authorization);

    var basic: Client = try .init(testing.allocator, .{}, .{
        .transport = ClientTransport.init(&script),
        .credentials = .{ .basic = .{ .user = "svc", .password = token } },
    });
    defer basic.deinit();
    var b = try basic.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{});
    b.deinit();
    try testing.expectEqualStrings("Basic c3ZjOnQtMQ==", script.authorization.?);

    var none: Client = try .init(testing.allocator, .{ .middleware = .{refuseAll} }, .{ .transport = ClientTransport.init(&script), .credentials = .none });
    defer none.deinit();
    const calls = script.calls;
    try testing.expectError(error.Unavailable, none.call(testing.io, .root, UserApi.getUser, .{ .id = 1 }, .{}));
    try testing.expectEqual(calls, script.calls);
}

test "rpc.Client refuses values that would refuse every call" {
    var script: Scripted = .{ .answer = .{ .ok = "{}" } };
    defer script.deinit();
    const on = ClientTransport.init(&script);
    try testing.expectError(error.InvalidConfiguration, Client.init(testing.allocator, .{}, .{ .transport = on, .max_pending = 0 }));
    try testing.expectError(error.InvalidConfiguration, Client.init(testing.allocator, .{}, .{ .transport = on, .max_response_bytes = 0 }));
    try testing.expectError(error.InvalidConfiguration, Client.init(testing.allocator, .{}, .{ .transport = on, .default_timeout = .zero }));
    try testing.expectError(error.InvalidConfiguration, Client.init(testing.allocator, .{}, .{ .transport = on, .default_timeout = .fromMilliseconds(-5) }));
}

// End to end through the memory transport and rpc.Server.

const UserHandler = struct {
    pub const rpc_handler = contract.implement(UserApi, .{});

    pub fn getUser(self: *UserHandler, ctx: *Context, req: GetUserRequest) !User {
        _ = self;
        try ctx.setResponseMetadata("x-served-by", "memory");
        return .{ .id = req.id, .name = try std.fmt.allocPrint(ctx.allocator(), "user-{d}", .{req.id}) };
    }

    pub fn createUser(self: *UserHandler, ctx: *Context, req: CreateUserRequest) !User {
        _ = self;
        _ = ctx;
        return .{ .id = 1, .name = req.name, .email = req.email };
    }

    pub fn deleteUser(self: *UserHandler, ctx: *Context, req: DeleteUserRequest) !void {
        _ = self;
        _ = ctx;
        if (req.id == 0) return error.Internal;
    }

    pub fn plot(self: *UserHandler, ctx: *Context, req: Point) !Point {
        _ = self;
        _ = ctx;
        return .{ .x = req.x * 2 };
    }

    pub fn note(self: *UserHandler, ctx: *Context, req: Note) !void {
        _ = self;
        _ = ctx;
        _ = req;
    }

    pub fn history(self: *UserHandler, ctx: *Context, req: GetUserRequest) ![]const ?[1000]u64 {
        _ = self;
        _ = ctx;
        _ = req;
        return &.{null};
    }
};

/// Notes the bearer token of the last call, or that it came without
/// credentials; any token is an identity.
const SeesBearer = struct {
    token: [16]u8 = undefined,
    len: usize = 0,
    anonymous: bool = false,

    pub fn authenticate(self: *SeesBearer, ctx: *const auth.AuthContext) auth.AuthError!?auth.IdentityView {
        switch (ctx.credentials) {
            .none => {
                self.anonymous = true;
                return null;
            },
            .bearer => |token| {
                @memcpy(self.token[0..token.len], token);
                self.len = token.len;
                self.anonymous = false;
                return .{ .subject = "u1" };
            },
            else => return error.InvalidCredentials,
        }
    }
};

test "rpc.Client takes its credentials in typed options" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var users: UserHandler = .{};
    var sees: SeesBearer = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users}, .authenticator = &sees }, .{ .transport = memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);

    var signed: Client = try .init(testing.allocator, .{}, .{ .transport = memory.clientTransport(), .credentials = .{ .bearer = "t-1" } });
    defer signed.deinit();
    var r = try signed.call(io, .root, UserApi.getUser, .{ .id = 1 }, .{ .timeout = .fromSeconds(10) });
    r.deinit();
    try testing.expectEqualStrings("t-1", sees.token[0..sees.len]);
    try testing.expect(!sees.anonymous);

    var plain: Client = try .init(testing.allocator, .{}, .{ .transport = memory.clientTransport(), .credentials = .none });
    defer plain.deinit();
    var a = try plain.call(io, .root, UserApi.getUser, .{ .id = 1 }, .{ .timeout = .fromSeconds(10) });
    a.deinit();
    try testing.expect(sees.anonymous);
}

/// Calls `getUser` with `id` from a task of its own and checks the answer.
fn callUser(client: *Client, io: std.Io, id: u64) anyerror!void {
    var r = try client.call(io, .root, UserApi.getUser, .{ .id = id }, .{ .timeout = .fromSeconds(10) });
    defer r.deinit();
    var expected: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "user-{d}", .{id}), r.outcome.ok.name);
    try testing.expectEqualStrings("memory", r.metadata().get("x-served-by").?);
}

test "calls from many tasks at once through the memory transport and rpc.Server" {
    const io = testing.io;
    var memory: MemoryTransport = try .init(testing.allocator, .{});
    defer memory.deinit(io);
    var users: UserHandler = .{};
    var server: Server = try .init(testing.allocator, .{ .handlers = .{&users} }, .{ .transport = memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);
    var client: Client = try .init(testing.allocator, .{}, .{ .transport = memory.clientTransport() });
    defer client.deinit();

    var callers: [32]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (callers[0..started]) |*caller| caller.cancel(io) catch {};
    for (&callers, 0..) |*caller, i| {
        caller.* = try io.concurrent(callUser, .{ &client, io, @as(u64, i) });
        started += 1;
    }
    for (callers[0..started]) |*caller| try caller.await(io);

    var deleted = try client.call(io, .root, UserApi.deleteUser, .{ .id = 0 }, .{});
    defer deleted.deinit();
    try expectFailure(deleted.outcome.failure, .internal, "rpc.internal", "Internal error");
    var doubled = try client.call(io, .root, UserApi.plot, .{ .x = 1.25 }, .{});
    defer doubled.deinit();
    try testing.expectEqual(@as(f64, 2.5), doubled.outcome.ok.x);
    try server.shutdown(io, far(io));
}
