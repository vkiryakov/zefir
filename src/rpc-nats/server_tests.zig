//! Tests of the server side of the NATS transport, on `FakeConn`: under the
//! recording dispatcher of rpc, which shows what reaches the engine, and
//! under `rpc.RawServer` where the engine's own refusals matter. Requests
//! come from a NATS client that is not zefir: it writes its headers itself.

const std = @import("std");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");
const Transport = @import("Transport.zig");
const FakeConn = @import("testing/FakeConn.zig");
const wire = @import("wire.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const RecordingDispatcher = rpc.testing.RecordingDispatcher;
const Entry = rpc.Metadata.Entry;

const get_user: rpc.Route = .{ .service = "users", .version = 1, .method = "getUser" };
const list_users: rpc.Route = .{ .service = "users", .version = 1, .method = "listUsers" };
const routes = [_]rpc.Route{ get_user, list_users };

const busy: rpc.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Server overloaded" };
const no_task: rpc.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "No task for the call" };

const limits: wire.ResponseLimits = .{ .max_body_bytes = 1 << 20, .max_metadata_entries = 64, .max_metadata_bytes = 16 * 1024 };

fn waitFor(duration: std.Io.Duration) std.Io.Timeout {
    return .{ .duration = .{ .raw = duration, .clock = .awake } };
}

/// A NATS client that is not zefir: it writes the headers of its requests
/// itself and reads the replies on `_INBOX.test.*`.
const Raw = struct {
    fake: *FakeConn,
    inbox: Conn.Sub,

    fn init(fake: *FakeConn) !Raw {
        return .{ .fake = fake, .inbox = try fake.subscribe(testing.io, "_INBOX.test.*", null, .none) };
    }

    fn deinit(r: *Raw) void {
        r.fake.unsubscribe(testing.io, r.inbox);
    }

    fn request(r: *Raw, subject: []const u8, reply_to: ?[]const u8, headers: []const Conn.Header, payload: []const u8) !void {
        try r.fake.publish(testing.io, .{ .subject = subject, .reply_to = reply_to, .headers = headers, .payload = payload }, .none);
    }

    /// A request with the headers a zefir client writes.
    fn call(r: *Raw, subject: []const u8, id: u64, metadata: []const Entry, payload: []const u8) !void {
        var headers: [16]Conn.Header = undefined;
        var text: wire.RequestText = .{};
        var reply_to: [64]u8 = undefined;
        try r.request(subject, try std.fmt.bufPrint(&reply_to, "_INBOX.test.{d}", .{id}), wire.requestHeaders(&headers, &text, @splat(@truncate(id)), "json", 5000, metadata).?, payload);
    }

    /// The next reply, read as a zefir client reads it. A drop of the link
    /// that `next` reports on the way is skipped.
    fn reply(r: *Raw, arena: Allocator) !rpc.Response {
        const msg = while (true) {
            const next = r.fake.next(testing.io, r.inbox, waitFor(.fromSeconds(10))) catch |err| switch (err) {
                error.Disconnected => continue,
                else => return err,
            };
            break next orelse return error.TestUnexpectedResult;
        };
        defer msg.release();
        return wire.parseResponse(arena, msg.header_block, msg.payload, limits, null);
    }

    fn expectNoReply(r: *Raw) !void {
        try testing.expectError(error.Timeout, r.fake.next(testing.io, r.inbox, waitFor(.fromMilliseconds(50))));
    }
};

fn expectRefusal(response: rpc.Response, expected: rpc.Failure) !void {
    const f = switch (response.status) {
        .ok => return error.TestExpectedRefusal,
        .failure => |f| f,
    };
    try testing.expectEqual(expected.code, f.code);
    try testing.expectEqualStrings(expected.app_code, f.app_code);
    try testing.expectEqualStrings(expected.message, f.message);
    try testing.expect(response.refused);
}

/// Waits until `condition` holds, for at most 5 s.
fn eventually(condition: anytype) !void {
    const io = testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (!condition.holds()) {
        if (std.Io.Clock.awake.now(io).nanoseconds > deadline.nanoseconds) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

const CounterIs = struct {
    bus: *const Transport,
    counter: Transport.Counter,
    n: u64,

    fn holds(c: CounterIs) bool {
        const all = c.bus.counters();
        const value = switch (c.counter) {
            inline else => |tag| @field(all, @tagName(tag)),
        };
        return value == c.n;
    }
};

test "a request of a zefir client reaches the engine; the response goes to its reply subject" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    try testing.expect(fake.hasSubscription(io, "users.v1.getUser", "q"));
    try testing.expect(fake.hasSubscription(io, "users.v1.listUsers", "q"));
    try testing.expect(bus.isReady());

    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    const metadata = [_]Entry{ .{ .key = "authorization", .value = "Bearer t" }, .{ .key = "x-a", .value = "" }, .{ .key = "x-a", .value = "2" } };
    const sent_at = std.Io.Clock.awake.now(io);
    try raw.call("users.v1.getUser", 1, &metadata, "{\"id\":\"1\"}");
    try recorder.waitStarted(io, 1);
    const view = try recorder.call(io, 0);
    try testing.expectEqualStrings("users", view.head.route.service);
    try testing.expectEqual(@as(u16, 1), view.head.route.version);
    try testing.expectEqualStrings("getUser", view.head.route.method);
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(1)), &view.head.request_id);
    try testing.expectEqualStrings("json", view.head.codec);
    try testing.expectEqual(@as(i96, 5000 * std.time.ns_per_ms), view.head.timeout.?.nanoseconds);
    try testing.expect(view.head.received_at.nanoseconds >= sent_at.nanoseconds);
    try testing.expect(view.head.peer == .none);
    try testing.expectEqual(metadata.len, view.head.metadata.len);
    for (metadata, view.head.metadata) |want, got| {
        try testing.expectEqualStrings(want.key, got.key);
        try testing.expectEqualStrings(want.value, got.value);
    }
    try testing.expectEqualStrings("{\"id\":\"1\"}", view.body.?);

    try recorder.respond(io, 0, &.{ .status = .ok, .metadata = &.{.{ .key = "x-r", .value = "1" }}, .body = "{\"name\":\"Ann\"}" });
    try recorder.releaseCall(io, 0, .completed);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const response = try raw.reply(arena.allocator());
    try testing.expect(response.status == .ok);
    try testing.expectEqualStrings("{\"name\":\"Ann\"}", response.body);
    try testing.expectEqual(@as(usize, 1), response.metadata.len);
    try testing.expectEqualStrings("x-r", response.metadata[0].key);
    recorder.close(io);
    try testing.expectEqual(@as(usize, 0), recorder.violations().len);
}

test "a request of nats req: no zefir headers, names in any case" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    var raw: Raw = try .init(&fake);
    defer raw.deinit();

    try raw.request("users.v1.getUser", "_INBOX.test.1", &.{}, "{\"id\":\"1\"}");
    try raw.request("users.v1.getUser", "_INBOX.test.2", &.{ .{ .name = "Traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" }, .{ .name = "X-Tenant", .value = "acme" } }, "{}");
    try recorder.waitStarted(io, 2);
    const bare = try recorder.call(io, 0);
    try testing.expectEqual(@as(?std.Io.Duration, null), bare.head.timeout);
    try testing.expectEqualStrings("json", bare.head.codec);
    try testing.expectEqual(@as(usize, 0), bare.head.metadata.len);
    const go = try recorder.call(io, 1);
    // The server made up the request ids: two calls, two ids.
    try testing.expect(!std.mem.eql(u8, &bare.head.request_id, &go.head.request_id));
    try testing.expectEqual(@as(usize, 2), go.head.metadata.len);
    try testing.expectEqualStrings("traceparent", go.head.metadata[0].key);
    try testing.expectEqualStrings("x-tenant", go.head.metadata[1].key);
    for (0..2) |i| {
        try recorder.respond(io, i, &.{ .status = .ok, .body = "{}" });
        try recorder.releaseCall(io, i, .completed);
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (0..2) |_| try testing.expect((try raw.reply(arena.allocator())).status == .ok);
}

test "a request without a reply subject, or with one outside reply_prefixes, is dropped and counted" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    const evil = try fake.subscribe(io, "evil.>", null, .none);
    defer fake.unsubscribe(io, evil);

    try raw.request("users.v1.getUser", null, &.{}, "{}");
    try raw.request("users.v1.getUser", "evil.subject", &.{}, "{}");
    try fake.publishRaw(io, "users.v1.getUser", "_INBOX.*", "", "{}");
    try eventually(CounterIs{ .bus = &bus, .counter = .requests_without_reply_to, .n = 1 });
    try eventually(CounterIs{ .bus = &bus, .counter = .requests_with_foreign_reply_to, .n = 2 });
    try testing.expectError(error.Timeout, fake.next(io, evil, waitFor(.fromMilliseconds(20))));
    try testing.expectError(error.NoSuchCall, recorder.call(io, 0));

    // Another prefix, by the options.
    var other_fake: FakeConn = .init(testing.allocator, .{});
    defer other_fake.deinit(io);
    var other: Transport = try .init(testing.allocator, other_fake.conn(), .{ .reply_prefixes = &.{ "_INBOX", "replies" } });
    defer other.deinit(io);
    var other_recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer other_recorder.deinit(io);
    try other_recorder.start(io, other.serverTransport());
    try other_fake.publish(io, .{ .subject = "users.v1.getUser", .reply_to = "replies.7", .payload = "{}" }, .none);
    try other_recorder.waitStarted(io, 1);
}

test "refusals of the engine and of the transport arrive with Zefir-Rpc-Refused" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    recorder.setAdmit(io, .{ .reject = busy });
    try raw.call("users.v1.getUser", 1, &.{}, "{}");
    try expectRefusal(try raw.reply(arena.allocator()), busy);

    recorder.setAdmit(io, .accept);
    recorder.setStart(io, .{ .fail = no_task });
    try raw.call("users.v1.getUser", 2, &.{}, "{}");
    try expectRefusal(try raw.reply(arena.allocator()), no_task);

    // Refused by the transport: the engine never sees them.
    recorder.setStart(io, .run);
    const broken = [_]struct { Conn.Header, rpc.Failure }{
        .{ .{ .name = "Zefir-Rpc-Version", .value = "2" }, wire.refusals.unsupported_version },
        .{ .{ .name = "Zefir-Rpc-Timeout-Ms", .value = "soon" }, wire.refusals.invalid_timeout },
        .{ .{ .name = "Zefir-Rpc-Request-Id", .value = "abc" }, wire.refusals.invalid_request_id },
    };
    for (broken) |case| {
        const header, const failure = case;
        try raw.request("users.v1.getUser", "_INBOX.test.3", &.{header}, "{}");
        try expectRefusal(try raw.reply(arena.allocator()), failure);
    }
    try raw.request("users.v1.getUser", "_INBOX.test.4", &.{ .{ .name = "Zefir-Rpc-Timeout-Ms", .value = "100" }, .{ .name = "Zefir-Rpc-Timeout-Ms", .value = "100" } }, "{}");
    try expectRefusal(try raw.reply(arena.allocator()), wire.refusals.repeated_timeout);
    recorder.close(io);
    // Two calls reached admit: the one refused there and the one refused at
    // start.
    try testing.expectEqual(@as(usize, 0), recorder.violations().len);
    try testing.expectError(error.NoSuchCall, recorder.call(io, 2));
}

test "start fails cleanly: denied subjects, no link, no answer to the flush" {
    const io = testing.io;
    {
        var fake: FakeConn = .init(testing.allocator, .{ .deny_subscribe = &.{"users.v1.listUsers"} });
        defer fake.deinit(io);
        var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
        defer bus.deinit(io);
        var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
        defer recorder.deinit(io);
        const log_level = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = log_level;
        try testing.expectError(error.AccessDenied, recorder.start(io, bus.serverTransport()));
        try testing.expectEqual(@as(usize, 0), fake.subscriptionCount(io));
    }
    {
        var fake: FakeConn = .init(testing.allocator, .{});
        defer fake.deinit(io);
        var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
        defer bus.deinit(io);
        var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
        defer recorder.deinit(io);
        fake.disconnect(io);
        try testing.expect(!bus.isReady());
        try testing.expectError(error.Unavailable, recorder.start(io, bus.serverTransport()));
        fake.reconnect(io);
        fake.hangFlush(io, true);
        var quick: Transport = try .init(testing.allocator, fake.conn(), .{ .flush_timeout = .fromMilliseconds(50) });
        defer quick.deinit(io);
        const began = std.Io.Clock.awake.now(io);
        try testing.expectError(error.Unavailable, recorder.start(io, quick.serverTransport()));
        const took = began.durationTo(std.Io.Clock.awake.now(io));
        try testing.expect(took.nanoseconds >= 50 * std.time.ns_per_ms and took.nanoseconds < 5 * std.time.ns_per_s);
        try testing.expectEqual(@as(usize, 0), fake.subscriptionCount(io));
        // Once the broker answers, the same transport starts.
        fake.hangFlush(io, false);
        try recorder.start(io, quick.serverTransport());
        try testing.expectEqual(@as(usize, 2), fake.subscriptionCount(io));
        recorder.close(io);
    }
}

/// `testing.io` whose `Group.concurrent` fails from call number `fail_at`
/// on, after a pause in which the tasks started so far could take
/// requests.
const FailingSpawn = struct {
    var vtable: std.Io.VTable = undefined;
    var spawned: u32 = 0;
    var fail_at: u32 = std.math.maxInt(u32);

    fn io(fail_at_call: u32) std.Io {
        vtable = testing.io.vtable.*;
        vtable.groupConcurrent = groupConcurrent;
        spawned = 0;
        fail_at = fail_at_call;
        return .{ .userdata = testing.io.userdata, .vtable = &vtable };
    }

    fn groupConcurrent(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) void) std.Io.ConcurrentError!void {
        spawned += 1;
        if (spawned >= fail_at) {
            testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
            return error.ConcurrencyUnavailable;
        }
        return testing.io.vtable.groupConcurrent(userdata, group, context, context_alignment, start);
    }
};

/// An adapter on `FakeConn` whose `flush`, when armed, also brings a request
/// to `users.v1.getUser`: one that comes while the server starts.
const RequestOnFlush = struct {
    fake: *FakeConn,
    armed: bool = false,

    pub fn publish(a: *RequestOnFlush, io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
        return a.fake.publish(io, msg, timeout);
    }
    pub fn subscribe(a: *RequestOnFlush, io: std.Io, name: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
        return a.fake.subscribe(io, name, queue, timeout);
    }
    pub fn next(a: *RequestOnFlush, io: std.Io, sub: Conn.Sub, timeout: std.Io.Timeout) Conn.Error!?Conn.InMsg {
        return a.fake.next(io, sub, timeout);
    }
    pub fn drain(a: *RequestOnFlush, io: std.Io, sub: Conn.Sub) Conn.Error!void {
        return a.fake.drain(io, sub);
    }
    pub fn unsubscribe(a: *RequestOnFlush, io: std.Io, sub: Conn.Sub) void {
        a.fake.unsubscribe(io, sub);
    }
    pub fn flush(a: *RequestOnFlush, io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
        try a.fake.flush(io, timeout);
        if (!a.armed) return;
        a.armed = false;
        try a.fake.publish(io, .{ .subject = "users.v1.getUser", .reply_to = "_INBOX.test.1", .payload = "{}" }, .none);
    }
};

test "a start that cannot start every receiving task takes no request with those it started" {
    const io = FailingSpawn.io(3);
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var adapter: RequestOnFlush = .{ .fake = &fake, .armed = true };
    var bus: Transport = try .init(testing.allocator, .init(&adapter), .{});
    defer bus.deinit(io);
    const three = [_]rpc.Route{ get_user, list_users, .{ .service = "users", .version = 1, .method = "deleteUser" } };
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &three });
    defer recorder.deinit(io);
    try testing.expectError(error.ConcurrencyUnavailable, recorder.start(io, bus.serverTransport()));
    // The task of getUser had its request for 50 ms and left it.
    try testing.expectError(error.NoSuchCall, recorder.call(io, 0));
    try testing.expectEqual(@as(usize, 0), fake.subscriptionCount(io));

    // The next start works.
    FailingSpawn.fail_at = std.math.maxInt(u32);
    adapter.armed = true;
    try recorder.start(io, bus.serverTransport());
    try recorder.waitStarted(io, 1);
    try recorder.respond(io, 0, &.{ .status = .ok });
    try recorder.releaseCall(io, 0, .completed);
    recorder.close(io);
    try testing.expectEqual(@as(usize, 0), recorder.violations().len);
}

test "a route without a NATS subject is a configuration error" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &.{ get_user, .{ .service = "_INBOX", .version = 1, .method = "x" } } });
    defer recorder.deinit(io);
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    try testing.expectError(error.InvalidConfiguration, recorder.start(io, bus.serverTransport()));
    try testing.expectEqual(@as(usize, 0), fake.subscriptionCount(io));
}

test "lifecycle: a second start is AddressInUse; drain and close twice; start again after close" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{ .subject_prefix = "shop" });
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    try testing.expect(fake.hasSubscription(io, "shop.users.v1.getUser", "q"));
    var second: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer second.deinit(io);
    try testing.expectError(error.AddressInUse, second.start(io, bus.serverTransport()));

    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const server = bus.serverTransport();
    server.drain(io);
    server.drain(io);
    // Drained: no one takes a new request, and the broker says so.
    try raw.call("shop.users.v1.getUser", 1, &.{}, "{}");
    const no_responders = (try fake.next(io, raw.inbox, waitFor(.fromSeconds(5)))).?;
    try testing.expectEqualStrings("NATS/1.0 503\r\n\r\n", no_responders.header_block);
    no_responders.release();
    server.close(io);
    server.close(io);
    // Only the raw client's inbox is left.
    try testing.expectEqual(@as(usize, 1), fake.subscriptionCount(io));

    var again: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer again.deinit(io);
    try again.start(io, bus.serverTransport());
    try raw.call("shop.users.v1.getUser", 2, &.{}, "{}");
    try again.waitStarted(io, 1);
    try again.respond(io, 0, &.{ .status = .ok, .body = "again" });
    try again.releaseCall(io, 0, .completed);
    try testing.expectEqualStrings("again", (try raw.reply(arena.allocator())).body);
}

test "receiving: a slow consumer is counted, a dropped link waited out, a closed connection stops the server" {
    const io = testing.io;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expect(fake.failNext(io, "users.v1.getUser", error.SlowConsumer));
    try eventually(CounterIs{ .bus = &bus, .counter = .slow_consumer_errors, .n = 1 });
    try raw.call("users.v1.getUser", 1, &.{}, "{}");
    try recorder.waitStarted(io, 1);
    try recorder.respond(io, 0, &.{ .status = .ok, .body = "after slow" });
    try recorder.releaseCall(io, 0, .completed);
    try testing.expectEqualStrings("after slow", (try raw.reply(arena.allocator())).body);

    fake.disconnect(io);
    try testing.expect(!bus.isReady());
    try io.sleep(.fromMilliseconds(30), .awake);
    fake.reconnect(io);
    try testing.expect(bus.isReady());
    try raw.call("users.v1.getUser", 2, &.{}, "{}");
    try recorder.waitStarted(io, 2);
    try recorder.respond(io, 1, &.{ .status = .ok, .body = "after the drop" });
    try recorder.releaseCall(io, 1, .completed);
    try testing.expectEqualStrings("after the drop", (try raw.reply(arena.allocator())).body);
    try testing.expectEqual(@as(?RecordingDispatcher.Fatal, null), recorder.fatal(io));

    fake.close(io);
    try eventually(struct {
        recorder: *RecordingDispatcher,
        fn holds(c: @This()) bool {
            return c.recorder.fatal(testing.io) != null;
        }
    }{ .recorder = &recorder });
    const fatal = recorder.fatal(io).?;
    try testing.expectEqual(error.Unavailable, fatal.err);
    try testing.expectEqual(error.ConnectionClosed, fatal.diagnostics.?.cause.?);
}

test "receiving: a revoked permission stops the server with AccessDenied" {
    const io = testing.io;
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    try testing.expect(fake.failNext(io, "users.v1.listUsers", error.PermissionDenied));
    try eventually(struct {
        recorder: *RecordingDispatcher,
        fn holds(c: @This()) bool {
            return c.recorder.fatal(testing.io) != null;
        }
    }{ .recorder = &recorder });
    try testing.expectEqual(error.AccessDenied, recorder.fatal(io).?.err);
}

const Failed = struct {
    recorder: *RecordingDispatcher,

    fn holds(c: Failed) bool {
        return c.recorder.fatal(testing.io) != null;
    }
};

test "receiving: a subscription that ends while the server runs stops it with Unavailable" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    // Ended by someone else, not by `drain` of the transport: `next` hands
    // out null.
    try fake.drain(io, bus.server.routes[1].sub);
    try eventually(Failed{ .recorder = &recorder });
    const fatal = recorder.fatal(io).?;
    try testing.expectEqual(error.Unavailable, fatal.err);
    try testing.expectEqual(@as(?anyerror, null), fatal.diagnostics.?.cause);
    try testing.expectEqualStrings("the subscription to users.v1.listUsers ended while the server runs", fatal.diagnostics.?.message());
}

test "Reply.send without a link to the broker: Closed" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    try raw.call("users.v1.getUser", 1, &.{}, "{}");
    try recorder.waitStarted(io, 1);
    fake.disconnect(io);
    try testing.expectError(error.Closed, recorder.respond(io, 0, &.{ .status = .ok }));
    fake.reconnect(io);
    try recorder.releaseCall(io, 0, .completed);
    recorder.close(io);
    try testing.expectEqual(@as(usize, 0), recorder.violations().len);
}

test "Reply.send: over max_payload is ResponseTooLarge, a small failure goes after it; after close, Closed" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{ .max_payload = 512 });
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try raw.call("users.v1.getUser", 1, &.{}, "{}");
    try recorder.waitStarted(io, 1);
    const big: [600]u8 = @splat('b');
    try testing.expectError(error.ResponseTooLarge, recorder.respond(io, 0, &.{ .status = .ok, .body = &big }));
    const too_large: rpc.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Response too large" };
    try recorder.respond(io, 0, &.{ .status = .{ .failure = too_large } });
    try recorder.releaseCall(io, 0, .completed);
    const response = try raw.reply(arena.allocator());
    try testing.expectEqualStrings("Response too large", response.status.failure.message);
    try testing.expect(!response.refused);

    try raw.call("users.v1.getUser", 2, &.{}, "{}");
    try recorder.waitStarted(io, 2);
    recorder.close(io);
    try testing.expectError(error.Closed, recorder.respond(io, 1, &.{ .status = .ok }));
    try recorder.releaseCall(io, 1, .canceled);
    try testing.expectEqual(@as(usize, 0), recorder.violations().len);
}

const many_routes = many: {
    var list: [24]rpc.Route = undefined;
    for (&list, 0..) |*route, i| route.* = .{ .service = "users", .version = 1, .method = std.fmt.comptimePrint("m{d}", .{i}) };
    break :many list;
};

test "close straight from running: the subscriptions it drains do not stop the server as broken" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    for (0..20) |_| {
        var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &many_routes });
        defer recorder.deinit(io);
        try recorder.start(io, bus.serverTransport());
        // The receiving tasks reach `next`.
        try io.sleep(.fromMilliseconds(2), .awake);
        recorder.close(io);
        try testing.expectEqual(@as(?RecordingDispatcher.Fatal, null), recorder.fatal(io));
        try testing.expectEqual(@as(usize, 0), fake.subscriptionCount(io));
    }
}

test "close while a request is in admission: the call is abandoned and refused" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var bus: Transport = try .init(testing.allocator, fake.conn(), .{});
    defer bus.deinit(io);
    var recorder: RecordingDispatcher = try .init(testing.allocator, .{ .routes = &routes, .admit = .{ .hold = .fromMilliseconds(200) } });
    defer recorder.deinit(io);
    try recorder.start(io, bus.serverTransport());
    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try raw.call("users.v1.getUser", 1, &.{}, "{}");
    try recorder.waitAdmitted(io, 1);
    recorder.close(io);
    try testing.expectEqual(RecordingDispatcher.State.abandoned, (try recorder.call(io, 0)).state);
    try expectRefusal(try raw.reply(arena.allocator()), .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Server is stopping" });
    try testing.expectEqual(@as(usize, 0), recorder.violations().len);
}

/// Counts what is allocated through it, from any task.
const Counting = struct {
    parent: Allocator,
    allocations: std.atomic.Value(usize) = .init(0),

    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        _ = c.allocations.fetchAdd(1, .monotonic);
        return c.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        c.parent.rawFree(memory, alignment, ret_addr);
    }
};

const Echo = struct {
    fn handle(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
        _ = ptr;
        return ctx.allocator().dupe(u8, request);
    }
};

test "hostile headers: 10 000 of them in 64 KiB, or one of 60 KiB, are refused before anything is allocated" {
    const io = testing.io;
    var fake: FakeConn = .init(testing.allocator, .{});
    defer fake.deinit(io);
    var counting: Counting = .{ .parent = testing.allocator };
    var bus: Transport = try .init(counting.allocator(), fake.conn(), .{});
    defer bus.deinit(io);
    var state: u8 = 0;
    const methods = [_]rpc.Method{.{ .route = get_user, .handler = .{ .ptr = &state, .handle = Echo.handle } }};
    var server: rpc.RawServer = try .init(testing.allocator, .{ .transport = bus.serverTransport(), .methods = &methods });
    defer server.deinit(io);
    try server.start(io);
    var raw: Raw = try .init(&fake);
    defer raw.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var many: std.Io.Writer.Allocating = .init(testing.allocator);
    defer many.deinit();
    try many.writer.writeAll("NATS/1.0\r\n");
    for (0..10_000) |i| try many.writer.print("X-Header-{d}: v\r\n", .{i});
    try many.writer.writeAll("\r\n");
    try testing.expect(many.written().len > 64 * 1024);
    var one: std.Io.Writer.Allocating = .init(testing.allocator);
    defer one.deinit();
    try one.writer.writeAll("NATS/1.0\r\nx-big: ");
    for (0..60 * 1024) |_| try one.writer.writeByte('v');
    try one.writer.writeAll("\r\n\r\n");

    const metadata_too_large: rpc.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Metadata too large" };
    const before = counting.allocations.load(.monotonic);
    for ([_][]const u8{ many.written(), one.written() }) |block| {
        try fake.publishRaw(io, "users.v1.getUser", "_INBOX.test.1", block, "{}");
        try expectRefusal(try raw.reply(arena.allocator()), metadata_too_large);
    }
    try testing.expectEqual(before, counting.allocations.load(.monotonic));

    // A request of the same size limits passes.
    try raw.call("users.v1.getUser", 2, &.{}, "echo");
    try testing.expectEqualStrings("echo", (try raw.reply(arena.allocator())).body);
    try server.shutdown(io);
}
