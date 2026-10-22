//! Group C of `odm.testing.conformance` on `mongo.OdmDriver`, against
//! `mongo.testing.FakeServer`: a script that answers every command with an
//! empty cursor or `{ok: 1}`. Group D needs mongod: tests/odm runs it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("odm");
const mongo = @import("../root.zig");
const FakeServer = mongo.testing.FakeServer;
const Script = mongo.testing.Script;
const conformance = odm.testing.conformance;

/// Answers find and aggregate with an empty cursor, and any other command
/// with `{ok: 1}`; once `stalled`, its next answer comes 10 s late.
const Empty = struct {
    stalled: std.atomic.Value(bool) = .init(false),

    pub fn answer(e: *Empty, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        const cursor = std.mem.eql(u8, request.name, "find") or std.mem.eql(u8, request.name, "aggregate");
        const reply = if (cursor) try emptyCursor(arena, request) else Script.ok;
        if (e.stalled.swap(false, .acq_rel)) return .{ .delayed = .{ .after = .fromSeconds(10), .reply = reply } };
        return .{ .reply = reply };
    }
};

/// The reply of a cursor without documents, in the namespace of `request`.
fn emptyCursor(arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!bson.RawDocument {
    const first = (request.body.first() catch null) orelse return Script.ok;
    const collection = switch (first.value) {
        .string => |name| name,
        else => "",
    };
    const ns = try std.fmt.allocPrint(arena, "{s}.{s}", .{ request.database, collection });
    return Script.cursorReply(arena, ns, 0, .first, &.{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Not for these keys; the client would take `{ok: 1}` as a
        // broken cursor, and the check would say so.
        error.InvalidBson => Script.ok,
    };
}

/// A FakeServer for each check, and the driver: its memory and the
/// script's are the suite's.
const Harness = struct {
    answers: Empty = .{},
    script: Script = undefined,
    listener: net.Server = undefined,
    server: Io.Future(FakeServer.ServeError!void) = undefined,
    driver: mongo.OdmDriver = undefined,
    buffer: [64]u8 = undefined,
    nobody_buffer: [96]u8 = undefined,
    /// A user that FakeServer lacks: saslStart answers code 18.
    nobody: []const u8 = "",

    pub fn setUp(h: *Harness, io: Io, gpa: std.mem.Allocator) !conformance.Setup {
        h.answers = .{};
        h.script = .init(gpa, .init(&h.answers));
        errdefer h.script.deinit();
        h.listener = try FakeServer.listen(io);
        errdefer h.listener.deinit(io);
        const uri = try FakeServer.uri(&h.listener, &h.buffer);
        h.nobody = try std.fmt.bufPrint(&h.nobody_buffer, "mongodb://odm_nobody@127.0.0.1:{d}/admin", .{FakeServer.port(&h.listener)});
        h.server = try io.concurrent(FakeServer.serve, .{ io, &h.listener, &h.script });
        h.driver = .init(gpa);
        return .{ .driver = h.driver.driver(), .config = .{ .uri = uri }, .database = "conformance" };
    }

    pub fn tearDown(h: *Harness, io: Io, setup: conformance.Setup) void {
        _ = setup;
        h.server.cancel(io) catch {};
        h.listener.deinit(io);
        h.script.deinit();
    }

    pub fn badCredentials(h: *Harness) odm.ConnectionConfig {
        return .{ .uri = h.nobody, .password = conformance.secret };
    }

    pub fn stall(h: *Harness, io: Io, setup: conformance.Setup) !void {
        _ = io;
        _ = setup;
        h.answers.stalled.store(true, .release);
    }
};

test "mongo.OdmDriver passes group C against FakeServer" {
    var harness: Harness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .data = false });
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 10), report.passedCount());
    try testing.expectEqualStrings("zefir-mongo", report.driver_name);
}
