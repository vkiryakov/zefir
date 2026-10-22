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
const far = @import("shared.zig").far;
const wire = @import("wire.zig");
const subject = @import("subject.zig");
const client_side = @import("client.zig");

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

/// Waits until `condition(context)` holds, for at most 5 s.
fn eventually(context: anytype, comptime condition: fn (@TypeOf(context)) bool) !void {
    const deadline = now().addDuration(.fromSeconds(5));
    while (!condition(context)) {
        if (now().nanoseconds > deadline.nanoseconds) return error.TestTimedOut;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
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
    /// A context without a deadline; `timeout` is not used.
    no_deadline: bool = false,
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
            .ctx = if (c.call.no_deadline) core.Context.root else core.Context.root.withDeadline(.after(c.began, c.call.timeout)),
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
    try testing.expect(took.nanoseconds < 2 * std.time.ns_per_s);

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
    try server.shutdown(io, far(io));
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
    var starter: Caller = .init(&bus, .{ .timeout = .fromSeconds(2) });
    defer starter.deinit();
    try starter.begin();
    // The starter is in the flush of the inbox now.
    try io.sleep(.fromMilliseconds(50), .awake);
    var quick: Caller = .init(&bus, .{ .timeout = .fromMilliseconds(100) });
    defer quick.deinit();
    quick.run();
    try testing.expectError(error.Timeout, quick.result);
    try testing.expect(quick.began.durationTo(quick.ended).nanoseconds < std.time.ns_per_s);
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

test "a call canceled while it starts the inbox leaves it idle; the next call starts it" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    fake.hangFlush(io, true);
    var starter: Caller = .init(&bus, .{});
    defer starter.deinit();
    try starter.begin();
    try eventually(&bus, struct {
        fn starting(b: *Transport) bool {
            return b.client.phase.load(.acquire) == .starting;
        }
    }.starting);
    // The starter is in the flush of the inbox now.
    try io.sleep(.fromMilliseconds(20), .awake);
    starter.cancel();
    try testing.expectError(error.Canceled, starter.result);
    try testing.expectEqual(client_side.Phase.idle, bus.client.phase.load(.acquire));
    // Only the service's subscription is left.
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

test "a request without a deadline goes out with the largest budget and waits for its response" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var service: Service = try .init(&fake, "users.v1.getUser");
    defer service.deinit();

    var caller: Caller = .init(&bus, .{ .no_deadline = true });
    defer caller.deinit();
    try caller.begin();
    const msg = try service.request();
    defer msg.release();
    var fields = (wire.Block{ .bytes = msg.header_block }).fields();
    const budget = while (fields.next()) |field| {
        if (std.mem.eql(u8, field.name, "Zefir-Rpc-Timeout-Ms")) break field.value;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(std.math.maxInt(u64), try std.fmt.parseUnsigned(u64, budget, 10));
    try io.sleep(.fromMilliseconds(20), .awake);
    try service.reply(msg, &.{}, "whenever");
    caller.join();
    try testing.expectEqualStrings("whenever", (try caller.result).body);
}

test "the inbox as a slow consumer: counted, and the calls go on" {
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

    var caller: Caller = .init(&bus, .{});
    defer caller.deinit();
    try caller.begin();
    const msg = try service.request();
    defer msg.release();
    const reply_to = msg.reply_to.?;
    var pattern: [64]u8 = undefined;
    const inbox = try std.fmt.bufPrint(&pattern, "{s}.*", .{reply_to[0..std.mem.findScalarLast(u8, reply_to, '.').?]});
    try testing.expect(fake.failNext(io, inbox, error.SlowConsumer));
    try eventually(&bus, struct {
        fn counted(b: *Transport) bool {
            return b.counters().slow_consumer_errors != 0;
        }
    }.counted);
    try service.reply(msg, &.{}, "after slow");
    caller.join();
    try testing.expectEqualStrings("after slow", (try caller.result).body);
    try testing.expectEqual(@as(u64, 1), bus.counters().slow_consumer_errors);
}

/// An adapter on `FakeConn` whose inbox ends as soon as it starts: `next`
/// returns `ending`, or null when it is null (a subscription that ended).
/// Its `flush` waits until the test opens `gate`, so that another call
/// comes while the first one starts the inbox.
const EndingInbox = struct {
    fake: *FakeConn,
    ending: ?Conn.Error,
    gate: std.Io.Event = .unset,
    flushes: std.atomic.Value(u32) = .init(0),

    pub fn publish(a: *EndingInbox, io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
        return a.fake.publish(io, msg, timeout);
    }
    pub fn subscribe(a: *EndingInbox, io: std.Io, name: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
        return a.fake.subscribe(io, name, queue, timeout);
    }
    pub fn next(a: *EndingInbox, io: std.Io, sub: Conn.Sub, timeout: std.Io.Timeout) Conn.Error!?Conn.InMsg {
        _ = io;
        _ = sub;
        _ = timeout;
        const err = a.ending orelse return null;
        return err;
    }
    pub fn drain(a: *EndingInbox, io: std.Io, sub: Conn.Sub) Conn.Error!void {
        return a.fake.drain(io, sub);
    }
    pub fn unsubscribe(a: *EndingInbox, io: std.Io, sub: Conn.Sub) void {
        a.fake.unsubscribe(io, sub);
    }
    pub fn flush(a: *EndingInbox, io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
        _ = a.flushes.fetchAdd(1, .monotonic);
        try a.gate.wait(io);
        return a.fake.flush(io, timeout);
    }
    pub fn isConnected(a: *EndingInbox) bool {
        return a.fake.isConnected();
    }
};

test "an inbox that ends as it starts, while another call waits for the start: both calls end, nothing is left" {
    const io = testing.io;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    for ([_]?Conn.Error{ error.ConnectionClosed, error.PermissionDenied, null }) |ending| {
        for (0..20) |_| {
            var fake: FakeConn = .init(testing.allocator, .{});
            defer fake.deinit(io);
            var adapter: EndingInbox = .{ .fake = &fake, .ending = ending };
            {
                var bus: Transport = try .init(testing.allocator, .init(&adapter), .{});
                defer bus.deinit(io);
                var first: Caller = .init(&bus, .{ .timeout = .fromSeconds(5) });
                defer first.deinit();
                try first.begin();
                // The first call is in the flush of the inbox.
                try eventually(&adapter, struct {
                    fn flushing(a: *EndingInbox) bool {
                        return a.flushes.load(.monotonic) != 0;
                    }
                }.flushing);
                var second: Caller = .init(&bus, .{ .timeout = .fromSeconds(5) });
                defer second.deinit();
                try second.begin();
                // The second waits for the start.
                try io.sleep(.fromMilliseconds(2), .awake);
                adapter.gate.set(io);
                first.join();
                second.join();
                for ([_]*const Caller{ &first, &second }) |c| {
                    // Ended by the inbox, not by the deadline.
                    if (c.result) |_| return error.TestUnexpectedResult else |err| switch (err) {
                        error.Unavailable, error.ConnectionLost => {},
                        else => return err,
                    }
                    try testing.expect(c.began.durationTo(c.ended).nanoseconds < 4 * std.time.ns_per_s);
                }
            }
            // Every subscription of an inbox was ended, each once.
            try testing.expectEqual(@as(usize, 0), fake.subscriptionCount(io));
        }
    }
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

/// An adapter on `FakeConn` that makes the first flush after `arm` overlap
/// another: it waits, `hold` at most, until a second flush begins, and goes
/// first; the second waits until the first is done. By then the side of the
/// second flush has made its subscriptions, unless the transport keeps it
/// out while the first side confirms its own.
const Overlap = struct {
    fake: *FakeConn,
    armed: std.atomic.Value(bool) = .init(false),
    /// Flushes since `arm`.
    flushes: std.atomic.Value(u32) = .init(0),
    second: std.Io.Event = .unset,
    first_done: std.Io.Event = .unset,

    const hold: std.Io.Duration = .fromMilliseconds(200);

    fn arm(a: *Overlap) void {
        a.flushes.store(0, .monotonic);
        a.armed.store(true, .release);
    }

    fn flushing(a: *Overlap) bool {
        return a.flushes.load(.monotonic) != 0;
    }

    pub fn publish(a: *Overlap, io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
        return a.fake.publish(io, msg, timeout);
    }
    pub fn subscribe(a: *Overlap, io: std.Io, name: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
        return a.fake.subscribe(io, name, queue, timeout);
    }
    pub fn next(a: *Overlap, io: std.Io, sub: Conn.Sub, timeout: std.Io.Timeout) Conn.Error!?Conn.InMsg {
        return a.fake.next(io, sub, timeout);
    }
    pub fn drain(a: *Overlap, io: std.Io, sub: Conn.Sub) Conn.Error!void {
        return a.fake.drain(io, sub);
    }
    pub fn unsubscribe(a: *Overlap, io: std.Io, sub: Conn.Sub) void {
        a.fake.unsubscribe(io, sub);
    }
    pub fn flush(a: *Overlap, io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
        if (a.armed.load(.acquire)) switch (a.flushes.fetchAdd(1, .acq_rel)) {
            0 => {
                defer a.first_done.set(io);
                const until = std.Io.Clock.awake.now(io).addDuration(hold);
                while (!a.second.isSet() and std.Io.Clock.awake.now(io).nanoseconds < until.nanoseconds) {
                    a.second.waitTimeout(io, .{ .deadline = until.withClock(.awake) }) catch |err| switch (err) {
                        error.Timeout => {},
                        error.Canceled => return error.Canceled,
                    };
                }
                return a.fake.flush(io, timeout);
            },
            1 => {
                a.second.set(io);
                try a.first_done.wait(io);
            },
            else => {},
        };
        return a.fake.flush(io, timeout);
    }
    pub fn isConnected(a: *Overlap) bool {
        return a.fake.isConnected();
    }
};

/// A transport on `Overlap`, with a server of `get_user` that has not
/// started.
const OverlapStage = struct {
    fake: FakeConn,
    adapter: Overlap,
    bus: Transport,
    server: rpc.RawServer,
    state: u8 = 0,

    fn init(s: *OverlapStage, deny_subscribe: []const []const u8) !void {
        const io = testing.io;
        s.fake = .init(testing.allocator, .{ .deny_subscribe = deny_subscribe });
        errdefer s.fake.deinit(io);
        s.adapter = .{ .fake = &s.fake };
        s.bus = try .init(testing.allocator, .init(&s.adapter), .{});
        errdefer s.bus.deinit(io);
        s.state = 0;
        const methods = [_]rpc.Method{.{ .route = get_user, .handler = .{ .ptr = &s.state, .handle = Methods.echo } }};
        s.server = try .init(testing.allocator, .{ .transport = s.bus.serverTransport(), .methods = &methods });
    }

    fn deinit(s: *OverlapStage) void {
        const io = testing.io;
        s.server.deinit(io);
        s.bus.deinit(io);
        s.fake.deinit(io);
    }
};

test "a denied inbox fails the first call, not the start of a server that overlaps it" {
    const io = testing.io;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var stage: OverlapStage = undefined;
    try stage.init(&.{"_INBOX.>"});
    defer stage.deinit();
    var caller: Caller = .init(&stage.bus, .{ .timeout = .fromSeconds(5) });
    defer caller.deinit();

    stage.adapter.arm();
    // The server subscribes and waits in its flush; the first call starts
    // the inbox meanwhile.
    var starting = try io.concurrent(rpc.RawServer.start, .{ &stage.server, io });
    const overlapped = eventually(&stage.adapter, Overlap.flushing);
    if (overlapped) |_| caller.run() else |_| {}
    const started = starting.await(io);
    try overlapped;
    try started;
    try testing.expectError(error.AccessDenied, caller.result);
    try stage.server.shutdown(io, far(io));
}

test "a denied route fails the start of the server, not a first call that overlaps it" {
    const io = testing.io;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var stage: OverlapStage = undefined;
    try stage.init(&.{"users.v1.getUser"});
    defer stage.deinit();
    var caller: Caller = .init(&stage.bus, .{ .timeout = .fromSeconds(5) });
    defer caller.deinit();

    stage.adapter.arm();
    // The first call subscribes its inbox and waits in its flush; the server
    // starts meanwhile.
    try caller.begin();
    const overlapped = eventually(&stage.adapter, Overlap.flushing);
    const started = if (overlapped) |_| stage.server.start(io) else |_| {};
    caller.join();
    try overlapped;
    try testing.expectError(error.AccessDenied, started);
    // The request went out once the inbox ran: no one serves the route.
    try testing.expectError(error.Unavailable, caller.result);
}

test "a denied inbox fails the first call, not the close of a server that overlaps it" {
    const io = testing.io;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var stage: OverlapStage = undefined;
    try stage.init(&.{"_INBOX.>"});
    defer stage.deinit();
    var caller: Caller = .init(&stage.bus, .{ .timeout = .fromSeconds(5) });
    defer caller.deinit();
    try stage.server.start(io);

    stage.adapter.arm();
    // The server stops: its close flushes the responses sent so far, and the
    // first call starts the inbox meanwhile.
    stage.server.requestStop(io);
    const overlapped = eventually(&stage.adapter, Overlap.flushing);
    if (overlapped) |_| caller.run() else |_| {}
    const stopped = stage.server.shutdown(io, far(io));
    try overlapped;
    try stopped;
    try testing.expectError(error.AccessDenied, caller.result);
}
