//! Tests of the client side of the NATS transport on `FakeConn`: against a
//! NATS service that is not zefir, whose requests and replies the test
//! reads and writes itself, and end to end with `rpc.RawServer` and
//! `rpc.RawClient`.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");
const Transport = @import("Transport.zig");
const FakeConn = @import("testing/FakeConn.zig");
const wire = @import("wire.zig");
const subject = @import("subject.zig");

const testing = std.testing;
const Entry = rpc.Metadata.Entry;
const CallError = rpc.ClientTransport.CallError;

const get_user: rpc.Route = .{ .service = "users", .version = 1, .method = "getUser" };

fn waitFor(duration: std.Io.Duration) std.Io.Timeout {
    return .{ .duration = .{ .raw = duration, .clock = .awake } };
}

fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(testing.io);
}

/// A NATS service that is not zefir: the test takes its requests and writes
/// its replies.
const Service = struct {
    fake: *FakeConn,
    sub: Conn.Sub,

    fn init(fake: *FakeConn, name: []const u8) !Service {
        return .{ .fake = fake, .sub = try fake.subscribe(testing.io, name, "q", .none) };
    }

    fn deinit(s: *Service) void {
        s.fake.unsubscribe(testing.io, s.sub);
    }

    /// The next request; a drop of the link on the way is skipped.
    fn request(s: *Service) !Conn.InMsg {
        while (true) {
            const next = s.fake.next(testing.io, s.sub, waitFor(.fromSeconds(10))) catch |err| switch (err) {
                error.Disconnected => continue,
                else => return err,
            };
            return next orelse error.TestUnexpectedResult;
        }
    }

    fn reply(s: *Service, to: Conn.InMsg, headers: []const Conn.Header, payload: []const u8) !void {
        try s.fake.publish(testing.io, .{ .subject = to.reply_to.?, .headers = headers, .payload = payload }, .none);
    }
};

/// One call through the client side.
const Call = struct {
    route: rpc.Route = get_user,
    body: []const u8 = "{}",
    metadata: []const Entry = &.{},
    timeout: std.Io.Duration = .fromSeconds(10),
    codec: []const u8 = "json",
};

/// A call in a task of its own, which the test may cancel.
const Caller = struct {
    bus: *Transport,
    call: Call,
    arena: std.heap.ArenaAllocator,
    diagnostics: rpc.transport.Diagnostics = .{},
    result: CallError!rpc.Response = error.Unexpected,
    began: std.Io.Timestamp = .zero,
    ended: std.Io.Timestamp = .zero,
    future: ?std.Io.Future(void) = null,

    fn init(bus: *Transport, call: Call) Caller {
        return .{ .bus = bus, .call = call, .arena = .init(testing.allocator) };
    }

    fn run(c: *Caller) void {
        c.began = now();
        const request: rpc.transport.Request = .{
            .route = c.call.route,
            .request_id = @splat(9),
            .codec = c.call.codec,
            .ctx = core.Context.root.withDeadline(.after(c.began, c.call.timeout)),
            .metadata = c.call.metadata,
            .body = c.call.body,
        };
        c.result = c.bus.clientTransport().call(testing.io, &request, .{
            .allocator = c.arena.allocator(),
            .max_response_bytes = 1 << 20,
            .diagnostics = &c.diagnostics,
        });
        c.ended = now();
    }

    fn begin(c: *Caller) !void {
        c.future = try testing.io.concurrent(run, .{c});
    }

    fn join(c: *Caller) void {
        if (c.future) |*f| f.await(testing.io);
        c.future = null;
    }

    fn cancel(c: *Caller) void {
        if (c.future) |*f| f.cancel(testing.io);
        c.future = null;
    }

    fn deinit(c: *Caller) void {
        c.cancel();
        c.arena.deinit();
    }
};

/// A call in the test's own task.
fn callNow(bus: *Transport, call: Call) CallError!void {
    var caller: Caller = .init(bus, call);
    defer caller.deinit();
    caller.run();
    _ = try caller.result;
}

test "a call: the request as it goes on the wire, and its response back" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();
    // The inbox starts with the first call, not before.
    try testing.expectEqual(@as(usize, 1), fake.subscriptionCount(io));

    const metadata = [_]Entry{ .{ .key = "traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" }, .{ .key = "x-a", .value = "" } };
    var caller: Caller = .init(&bus, .{ .body = "{\"id\":\"1\"}", .metadata = &metadata, .timeout = .fromSeconds(2) });
    defer caller.deinit();
    try caller.begin();
    const msg = try service.request();
    defer msg.release();
    try testing.expectEqualStrings("users.v1.getUser", msg.subject);
    try testing.expectEqualStrings("{\"id\":\"1\"}", msg.payload);
    // `_INBOX.<22 base62>.<call number>`.
    var tokens = std.mem.splitScalar(u8, msg.reply_to.?, '.');
    try testing.expectEqualStrings("_INBOX", tokens.next().?);
    const token = tokens.next().?;
    try testing.expectEqual(subject.token_len, token.len);
    try testing.expect(subject.replyId(msg.reply_to.?) != null);
    try testing.expect(tokens.next() != null and tokens.next() == null);
    var inbox_pattern: [64]u8 = undefined;
    try testing.expect(fake.hasSubscription(io, try std.fmt.bufPrint(&inbox_pattern, "_INBOX.{s}.*", .{token}), null));

    var fields = (wire.Block{ .bytes = msg.header_block }).fields();
    const expected = [_][2][]const u8{
        .{ "Zefir-Rpc-Version", "1" },
        .{ "Zefir-Rpc-Request-Id", "09090909090909090909090909090909" },
        .{ "Content-Type", "application/json" },
        .{ "traceparent", metadata[0].value },
        .{ "x-a", "" },
    };
    for (expected) |want| {
        const got = fields.next().?;
        try testing.expectEqualStrings(want[0], got.name);
        try testing.expectEqualStrings(want[1], got.value);
    }
    const budget = fields.next().?;
    try testing.expectEqualStrings("Zefir-Rpc-Timeout-Ms", budget.name);
    const ms = try std.fmt.parseUnsigned(u64, budget.value, 10);
    try testing.expect(ms > 0 and ms <= 2000);
    try testing.expect(fields.next() == null);

    try service.reply(msg, &.{.{ .name = "X-R", .value = "1" }}, "{\"name\":\"Ann\"}");
    caller.join();
    const response = try caller.result;
    try testing.expect(response.status == .ok);
    try testing.expectEqualStrings("{\"name\":\"Ann\"}", response.body);
    try testing.expectEqual(@as(usize, 1), response.metadata.len);
    try testing.expectEqualStrings("x-r", response.metadata[0].key);

    // Every call shares the inbox.
    var second: Caller = .init(&bus, .{});
    defer second.deinit();
    try second.begin();
    const again = try service.request();
    defer again.release();
    try testing.expect(std.mem.startsWith(u8, again.reply_to.?, msg.reply_to.?[0 .. "_INBOX.".len + subject.token_len]));
    try testing.expect(!std.mem.eql(u8, again.reply_to.?, msg.reply_to.?));
    try service.reply(again, &.{}, "");
    second.join();
    _ = try second.result;
    try testing.expectEqual(@as(usize, 2), fake.subscriptionCount(io));
}

test "replies a client cannot take: no responders, statuses, a foreign ADR-32 failure" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);

    var nobody: Caller = .init(&bus, .{ .route = .{ .service = "missing", .version = 1, .method = "x" } });
    defer nobody.deinit();
    nobody.run();
    try testing.expectError(error.Unavailable, nobody.result);
    try testing.expectEqual(rpc.transport.Diagnostics.Phase.receive, nobody.diagnostics.phase.?);

    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();
    for ([_][]const u8{ "NATS/1.0 503\r\n\r\n", "NATS/1.0 408 Request Timeout\r\n\r\n" }, [_][]const u8{ "body", "" }) |block, payload| {
        var caller: Caller = .init(&bus, .{});
        defer caller.deinit();
        try caller.begin();
        const msg = try service.request();
        defer msg.release();
        try fake.publishRaw(io, msg.reply_to.?, null, block, payload);
        caller.join();
        try testing.expectError(error.ProtocolViolation, caller.result);
    }

    var caller: Caller = .init(&bus, .{});
    defer caller.deinit();
    try caller.begin();
    const msg = try service.request();
    defer msg.release();
    try service.reply(msg, &.{ .{ .name = "Nats-Service-Error", .value = "100% done" }, .{ .name = "Nats-Service-Error-Code", .value = "409" } }, "");
    caller.join();
    const failure = (try caller.result).status.failure;
    try testing.expectEqual(core.ErrorCode.aborted, failure.code);
    try testing.expectEqualStrings("100% done", failure.message);
    try testing.expectEqualStrings("", failure.app_code);
}

test "errors before sending: no link, a deadline too close, a denied subject, a large request, the pending limit" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{ .max_payload = 1024, .deny_publish = &.{"secret.>"} });
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{ .max_pending = 1 });
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    fake.disconnect(io);
    try testing.expectError(error.Unavailable, callNow(&bus, .{}));
    fake.reconnect(io);
    const published = fake.stats(io).published;
    try testing.expectError(error.Timeout, callNow(&bus, .{ .timeout = .fromMicroseconds(500) }));
    try testing.expectError(error.Timeout, callNow(&bus, .{ .timeout = .fromMilliseconds(-5) }));
    try testing.expectEqual(published, fake.stats(io).published);
    try testing.expectError(error.AccessDenied, callNow(&bus, .{ .route = .{ .service = "secret", .version = 1, .method = "x" } }));
    try testing.expectError(error.RequestTooLarge, callNow(&bus, .{ .body = &@as([2000]u8, @splat('x')) }));
    try testing.expectError(error.UnsupportedProtocol, callNow(&bus, .{ .codec = "not/a codec" }));
    try testing.expectError(error.Unexpected, callNow(&bus, .{ .route = .{ .service = "a.b", .version = 1, .method = "x" } }));

    // One call waits; with max_pending = 1 another is not sent.
    var waiting: Caller = .init(&bus, .{});
    defer waiting.deinit();
    try waiting.begin();
    const msg = try service.request();
    defer msg.release();
    try testing.expectError(error.TooManyPendingRequests, callNow(&bus, .{}));
    try service.reply(msg, &.{}, "");
    waiting.join();
    _ = try waiting.result;
}

test "the inbox: denied, or its flush unanswered, leaves nothing; the next call tries again" {
    const io = testing.io;
    {
        var fake: FakeConn = .init(testing.allocator, .{ .deny_subscribe = &.{"_INBOX.>"} });
        defer fake.deinit(io);
        var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
        defer bus.deinit(io);
        try testing.expectError(error.AccessDenied, callNow(&bus, .{}));
        try testing.expectEqual(@as(usize, 0), fake.subscriptionCount(io));
        // Another inbox prefix, which the permissions allow.
        var orders: Transport = try .init(testing.allocator, fake.conn(), .{ .inbox_prefix = "_INBOX_orders" });
        defer orders.deinit(io);
        try testing.expectError(error.Unavailable, callNow(&orders, .{}));
        try testing.expectEqual(@as(usize, 1), fake.subscriptionCount(io));
    }
    {
        var fake: FakeConn = .init(testing.allocator, .{});
        defer fake.deinit(io);
        var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
        defer bus.deinit(io);
        var service: Service = try .init(&fake, "users.v1.getUser");
        defer service.deinit();
        fake.hangFlush(io, true);
        try testing.expectError(error.Timeout, callNow(&bus, .{ .timeout = .fromMilliseconds(50) }));
        try testing.expectEqual(@as(usize, 1), fake.subscriptionCount(io));
        fake.hangFlush(io, false);
        var caller: Caller = .init(&bus, .{});
        defer caller.deinit();
        try caller.begin();
        const msg = try service.request();
        defer msg.release();
        try service.reply(msg, &.{}, "ok");
        caller.join();
        try testing.expectEqualStrings("ok", (try caller.result).body);
    }
}

test "the deadline: Timeout on time; a late response is dropped and counted" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    var caller: Caller = .init(&bus, .{ .timeout = .fromMilliseconds(150) });
    defer caller.deinit();
    try caller.begin();
    const late = try service.request();
    defer late.release();
    caller.join();
    try testing.expectError(error.Timeout, caller.result);
    const took = caller.began.durationTo(caller.ended);
    try testing.expect(took.nanoseconds >= 150 * std.time.ns_per_ms - std.time.ns_per_ms);
    try testing.expect(took.nanoseconds < 650 * std.time.ns_per_ms);

    try service.reply(late, &.{}, "late");
    var next: Caller = .init(&bus, .{});
    defer next.deinit();
    try next.begin();
    const msg = try service.request();
    defer msg.release();
    try service.reply(msg, &.{}, "fresh");
    next.join();
    try testing.expectEqualStrings("fresh", (try next.result).body);
    try testing.expectEqual(@as(u64, 1), bus.counters().late_responses);
}

test "cancel: Canceled once, the slot is free again, the late response is dropped" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{ .max_pending = 1 });
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    var caller: Caller = .init(&bus, .{});
    defer caller.deinit();
    try caller.begin();
    const canceled = try service.request();
    defer canceled.release();
    caller.cancel();
    try testing.expectError(error.Canceled, caller.result);
    try service.reply(canceled, &.{}, "late");

    var next: Caller = .init(&bus, .{});
    defer next.deinit();
    try next.begin();
    const msg = try service.request();
    defer msg.release();
    try service.reply(msg, &.{}, "fresh");
    next.join();
    try testing.expectEqualStrings("fresh", (try next.result).body);
    try testing.expectEqual(@as(u64, 1), bus.counters().late_responses);
}

test "a reconnect: a waiting call lives on and gets its response; new calls are Unavailable meanwhile" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    var caller: Caller = .init(&bus, .{ .timeout = .fromSeconds(10) });
    defer caller.deinit();
    try caller.begin();
    const msg = try service.request();
    defer msg.release();
    fake.disconnect(io);
    try testing.expectError(error.Unavailable, callNow(&bus, .{}));
    try io.sleep(.fromMilliseconds(30), .awake);
    fake.reconnect(io);
    try service.reply(msg, &.{}, "after the reconnect");
    caller.join();
    try testing.expectEqualStrings("after the reconnect", (try caller.result).body);
}

test "the connection closes for good: a waiting call gets ConnectionLost, a new one Unavailable" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    var caller: Caller = .init(&bus, .{ .timeout = .fromSeconds(10) });
    defer caller.deinit();
    try caller.begin();
    const msg = try service.request();
    msg.release();
    const closed_at = now();
    fake.close(io);
    caller.join();
    try testing.expectError(error.ConnectionLost, caller.result);
    try testing.expect(closed_at.durationTo(caller.ended).nanoseconds < 2 * std.time.ns_per_s);
    try testing.expectError(error.Unavailable, callNow(&bus, .{}));
}

const Methods = struct {
    fn echo(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
        _ = ptr;
        try ctx.setResponseMetadata("x-echo", "yes");
        return ctx.allocator().dupe(u8, request);
    }

    fn missing(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
        _ = ptr;
        _ = request;
        return ctx.fail(.{ .code = .not_found, .app_code = "users.not_found", .message = "No user 100%", .field = "id" });
    }
};

test "end to end: rpc.RawClient and rpc.RawServer on one connection, an inbox of the client's own" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{ .subject_prefix = "shop", .inbox_prefix = "_INBOX_orders" });
    defer bus.deinit(io);
    var state: u8 = 0;
    const methods = [_]rpc.Method{
        .{ .route = get_user, .handler = .{ .ptr = &state, .handle = Methods.echo } },
        .{ .route = .{ .service = "users", .version = 1, .method = "find" }, .handler = .{ .ptr = &state, .handle = Methods.missing } },
    };
    var server: rpc.RawServer = try .init(testing.allocator, .{ .transport = bus.serverTransport(), .methods = &methods });
    defer server.deinit(io);
    try server.start(io);
    var client: rpc.RawClient = try .init(testing.allocator, .{ .transport = bus.clientTransport() });
    defer client.deinit();

    var echoed = try client.call(io, .root, get_user, "{\"id\":\"1\"}", .{ .metadata = &.{.{ .key = "x-tenant", .value = "acme" }} });
    defer echoed.deinit();
    try testing.expect(echoed.response.status == .ok);
    try testing.expectEqualStrings("{\"id\":\"1\"}", echoed.response.body);
    try testing.expectEqualStrings("yes", (rpc.Metadata.View{ .entries = echoed.response.metadata }).get("x-echo").?);

    var found = try client.call(io, .root, .{ .service = "users", .version = 1, .method = "find" }, "{}", .{});
    defer found.deinit();
    const failure = found.response.status.failure;
    try testing.expectEqual(core.ErrorCode.not_found, failure.code);
    try testing.expectEqualStrings("users.not_found", failure.app_code);
    try testing.expectEqualStrings("No user 100%", failure.message);
    try testing.expectEqualStrings("id", failure.field.?);
    try testing.expect(!found.response.refused);

    // An unknown method of a served service: no one subscribes to it.
    try testing.expectError(error.Unavailable, client.call(io, .root, .{ .service = "users", .version = 1, .method = "nope" }, "{}", .{}));
    try server.shutdown(io);
    // A stopped server: no responders.
    try testing.expectError(error.Unavailable, client.call(io, .root, get_user, "{}", .{}));
}

test "calls that come while another starts the inbox wait for it no longer than their own deadlines" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    fake.hangFlush(io, true);
    var starter: Caller = .init(&bus, .{ .timeout = .fromMilliseconds(600) });
    defer starter.deinit();
    try starter.begin();
    // The starter is in the flush of the inbox now.
    try io.sleep(.fromMilliseconds(50), .awake);
    var quick: Caller = .init(&bus, .{ .timeout = .fromMilliseconds(100) });
    defer quick.deinit();
    quick.run();
    try testing.expectError(error.Timeout, quick.result);
    try testing.expect(quick.began.durationTo(quick.ended).nanoseconds < 400 * std.time.ns_per_ms);
    starter.join();
    try testing.expectError(error.Timeout, starter.result);
    try testing.expectEqual(@as(usize, 1), fake.subscriptionCount(io));

    fake.hangFlush(io, false);
    var caller: Caller = .init(&bus, .{});
    defer caller.deinit();
    try caller.begin();
    const msg = try service.request();
    defer msg.release();
    try service.reply(msg, &.{}, "ok");
    caller.join();
    try testing.expectEqualStrings("ok", (try caller.result).body);
}

test "an inbox that broke: the waiting call gets ConnectionLost, the next call starts it again" {
    const io = testing.io;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    var waiting: Caller = .init(&bus, .{});
    defer waiting.deinit();
    try waiting.begin();
    const msg = try service.request();
    defer msg.release();
    // `_INBOX.<token>.<id>` → `_INBOX.<token>.*`.
    const reply_to = msg.reply_to.?;
    var pattern: [64]u8 = undefined;
    const inbox = try std.fmt.bufPrint(&pattern, "{s}.*", .{reply_to[0..std.mem.findScalarLast(u8, reply_to, '.').?]});
    try testing.expect(fake.failNext(io, inbox, error.PermissionDenied));
    waiting.join();
    try testing.expectError(error.ConnectionLost, waiting.result);

    var again: Caller = .init(&bus, .{});
    defer again.deinit();
    try again.begin();
    const second = try service.request();
    defer second.release();
    // The inbox keeps its name.
    try testing.expect(std.mem.startsWith(u8, second.reply_to.?, inbox[0 .. inbox.len - 1]));
    try service.reply(second, &.{}, "again");
    again.join();
    try testing.expectEqualStrings("again", (try again.result).body);
    try testing.expectEqual(@as(usize, 2), fake.subscriptionCount(io));
}

test "a request lost when the link drops ends at its deadline with Timeout" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();
    // The inbox runs before the request goes out.
    {
        var first: Caller = .init(&bus, .{});
        defer first.deinit();
        try first.begin();
        const msg = try service.request();
        defer msg.release();
        try service.reply(msg, &.{}, "");
        first.join();
        _ = try first.result;
    }
    fake.setDelay(io, .fromMilliseconds(200));
    var caller: Caller = .init(&bus, .{ .timeout = .fromMilliseconds(400) });
    defer caller.deinit();
    try caller.begin();
    try io.sleep(.fromMilliseconds(50), .awake);
    // The request is on its way: the drop loses it.
    fake.disconnect(io);
    fake.reconnect(io);
    fake.setDelay(io, .zero);
    caller.join();
    try testing.expectError(error.Timeout, caller.result);
    try testing.expect(caller.began.durationTo(caller.ended).nanoseconds >= 399 * std.time.ns_per_ms);
}
