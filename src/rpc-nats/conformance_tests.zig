//! The NATS transport against the conformance suite of rpc, on `FakeConn`,
//! and against foreign and broken neighbours on NATS through the real
//! engine: `nats req` without the headers of zefir, `Traceparent` written
//! by a Go client, repeated headers.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const Conn = @import("Conn.zig");
const Transport = @import("Transport.zig");
const FakeConn = @import("testing/FakeConn.zig");
const wire = @import("wire.zig");

const testing = std.testing;
const conformance = rpc.testing.conformance;

/// A fresh connection and transport for every check; both sides share the
/// connection, as one application does.
const Harness = struct {
    fake: FakeConn = undefined,
    bus: Transport = undefined,

    pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator) !conformance.Pair {
        _ = io;
        h.fake = .init(gpa, .{});
        h.bus = try .initConn(gpa, h.fake.conn(), .{});
        return .{ .client = h.bus.clientTransport(), .server = h.bus.serverTransport() };
    }

    pub fn tearDown(h: *Harness, io: std.Io, pair: conformance.Pair) void {
        _ = pair;
        h.bus.deinit(io);
        h.fake.deinit(io);
    }
};

test "the NATS transport on FakeConn passes the conformance suite of rpc" {
    // The suite's own engine warns about the failures it provokes.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;
    var harness: Harness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("nats", report.transport_name);
    // T12: NATS sees a broken link only at the deadline. T16: at most once.
    // T17: it needs a live broker.
    for (std.enums.values(conformance.Check)) |check| {
        const skipped = report.outcome(check) == .skipped;
        const expected = check == .t12 or check == .t16 or check == .t17;
        if (skipped != expected) {
            std.debug.print("{f}", .{&report});
            return error.TestUnexpectedResult;
        }
    }
    // The transport has its own isReady.
    try testing.expectEqual(@as(usize, 0), report.defaults.len);
}

const echo_route: rpc.Route = .{ .service = "users", .version = 1, .method = "getUser" };

/// A method on bytes that answers with what it saw: the body, the trace
/// and the metadata of the call.
const Seen = struct {
    fn handle(ptr: *anyopaque, ctx: *rpc.Context, request: []const u8) anyerror![]const u8 {
        _ = ptr;
        const trace = ctx.operation().trace;
        var out: std.Io.Writer.Allocating = .init(ctx.allocator());
        try out.writer.print("body={s};trace=", .{request});
        if (trace) |t| try out.writer.writeAll(&std.fmt.bytesToHex(t.trace_id.bytes, .lower)) else try out.writer.writeAll("none");
        try out.writer.writeAll(";metadata=");
        var it = ctx.metadata().iterator();
        while (it.next()) |entry| try out.writer.print("{s}:{s},", .{ entry.key, entry.value });
        return out.written();
    }
};

/// A server of `Seen` on a fake connection, and a NATS client that is not
/// zefir on the same connection.
const Stage = struct {
    fake: FakeConn,
    bus: Transport,
    server: rpc.RawServer,
    inbox: Conn.Sub,
    state: u8 = 0,
    arena: std.heap.ArenaAllocator,

    fn init(s: *Stage) !void {
        const io = testing.io;
        s.fake = .init(testing.allocator, .{});
        errdefer s.fake.deinit(io);
        s.bus = try .initConn(testing.allocator, s.fake.conn(), .{});
        errdefer s.bus.deinit(io);
        const methods = [_]rpc.Method{.{ .route = echo_route, .handler = .{ .ptr = &s.state, .handle = Seen.handle } }};
        s.server = try .init(testing.allocator, .{ .transport = s.bus.serverTransport(), .methods = &methods });
        errdefer s.server.deinit(io);
        try s.server.start(io);
        s.inbox = try s.fake.subscribe(io, "_INBOX.foreign.*", null, .none);
        s.arena = .init(testing.allocator);
    }

    fn deinit(s: *Stage) void {
        const io = testing.io;
        s.arena.deinit();
        s.fake.unsubscribe(io, s.inbox);
        s.server.deinit(io);
        s.bus.deinit(io);
        s.fake.deinit(io);
    }

    /// A request as a foreign client writes it, and the reply as a zefir
    /// client reads it.
    fn ask(s: *Stage, headers: []const Conn.Header, payload: []const u8) !rpc.Response {
        const io = testing.io;
        try s.fake.publish(io, .{ .subject = "users.v1.getUser", .reply_to = "_INBOX.foreign.1", .headers = headers, .payload = payload }, .none);
        const msg = (try s.fake.next(io, s.inbox, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } })).?;
        defer msg.release();
        return wire.parseResponse(s.arena.allocator(), msg.header_block, msg.payload, .{ .max_body_bytes = 1 << 20, .max_metadata_entries = 64, .max_metadata_bytes = 16 * 1024 }, null);
    }
};

test "neighbours: nats req without the headers of zefir is served with the server's own budget and id" {
    var stage: Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const response = try stage.ask(&.{}, "{\"id\":\"1\"}");
    try testing.expect(response.status == .ok);
    try testing.expectEqualStrings("body={\"id\":\"1\"};trace=none;metadata=", response.body);
}

test "neighbours: Traceparent written by a Go client becomes the trace of the call" {
    var stage: Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const response = try stage.ask(&.{
        .{ .name = "Traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
        .{ .name = "X-Tenant", .value = "acme" },
    }, "x");
    try testing.expectEqualStrings("body=x;trace=4bf92f3577b34da6a3ce929d0e0e4736;metadata=x-tenant:acme,", response.body);
}

test "neighbours: a repeated header is refused, by the transport or by the engine" {
    var stage: Stage = undefined;
    try stage.init();
    defer stage.deinit();
    // A transport header twice: the transport refuses it.
    const timeout = try stage.ask(&.{ .{ .name = "Zefir-Rpc-Timeout-Ms", .value = "100" }, .{ .name = "Zefir-Rpc-Timeout-Ms", .value = "200" } }, "x");
    try testing.expectEqualStrings(wire.refusals.repeated_timeout.message, timeout.status.failure.message);
    try testing.expect(timeout.refused);
    // A reserved key twice, in two cases: the engine refuses it.
    const trace = try stage.ask(&.{
        .{ .name = "traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
        .{ .name = "Traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
    }, "x");
    const f = trace.status.failure;
    try testing.expectEqual(core.ErrorCode.invalid_argument, f.code);
    try testing.expectEqualStrings("rpc.invalid_metadata", f.app_code);
    try testing.expect(trace.refused);
    // A later major version: unimplemented.
    const later = try stage.ask(&.{.{ .name = "Zefir-Rpc-Version", .value = "2" }}, "x");
    try testing.expectEqual(core.ErrorCode.unimplemented, later.status.failure.code);
    try testing.expect(later.refused);
}

test "neighbours: a budget in a header the engine cannot use is refused, garbage by the transport" {
    var stage: Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const garbage = try stage.ask(&.{.{ .name = "Zefir-Rpc-Timeout-Ms", .value = "soon" }}, "x");
    try testing.expectEqualStrings(wire.refusals.invalid_timeout.message, garbage.status.failure.message);
    const spent = try stage.ask(&.{.{ .name = "Zefir-Rpc-Timeout-Ms", .value = "0" }}, "x");
    try testing.expectEqual(core.ErrorCode.deadline_exceeded, spent.status.failure.code);
    try testing.expect(spent.refused);
    // A content type the engine has no codec for.
    const text = try stage.ask(&.{.{ .name = "Content-Type", .value = "text/plain" }}, "x");
    try testing.expectEqual(core.ErrorCode.unimplemented, text.status.failure.code);
    try testing.expectEqualStrings("rpc.unsupported_codec", text.status.failure.app_code);
}
