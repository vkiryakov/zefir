//! Debug build: a cursor that two tasks use at once panics; one task at a
//! time calls its methods. build.zig runs this program and checks the
//! panic message on stderr and the exit code 3 of the panic handler below.
const std = @import("std");
const Io = std.Io;
const mongo = @import("mongo");
const native = @import("mongo-async-driver");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const FakeServer = mongo.testing.FakeServer;

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

/// Opens a cursor with an empty first batch, and holds its getMore.
const Held = struct {
    pub fn answer(h: *Held, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ h, io };
        const empty: []const bson.RawDocument = &.{};
        if (std.mem.eql(u8, request.name, "find")) return .{ .reply = Script.cursorReply(arena, "app.users", 7, .first, empty) catch return error.OutOfMemory };
        if (std.mem.eql(u8, request.name, "getMore")) return .{ .delayed = .{ .after = .fromSeconds(10), .reply = Script.cursorReply(arena, "app.users", 0, .next, empty) catch return error.OutOfMemory } };
        return .{ .reply = Script.ok };
    }
};

fn next(io: Io, cursor: mongo.Cursor) void {
    _ = cursor.next(io, .of(.root)) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var held: Held = .{};
    var script: Script = .init(init.gpa, .init(&held));
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};

    var uri: [64]u8 = undefined;
    var driver: native.Client = try .init(init.gpa, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer driver.deinit();
    try driver.connect(io, .root, null);
    const cursor = try driver.client().openCursor(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .find = "users" }) }, .{});
    defer cursor.deinit(io);

    // One task waits in a getMore that the server holds...
    var waiting = try io.concurrent(next, .{ io, cursor });
    defer waiting.cancel(io);
    while (script.count(io, "getMore") == 0) try io.sleep(.fromMilliseconds(1), .awake);
    // ...and the mistake: another task calls the cursor meanwhile.
    _ = cursor.next(io, .of(.root)) catch {};
}
