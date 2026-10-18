//! Debug build: `Client.deinit` with a cursor not deinitialized panics,
//! since the cursor holds its batches in the client's memory. build.zig
//! runs this program and checks the panic message on stderr and the exit
//! code 3 of the panic handler below.
const std = @import("std");
const Io = std.Io;
const mongo = @import("mongo");
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const docs = [_]bson.RawDocument{bson.literal(.{ ._id = 1 })};
    var users: Script.Cursor = .{ .ns = "app.users", .batches = &.{&docs} };
    var script: Script = .init(init.gpa, users.handler());
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};

    var uri: [64]u8 = undefined;
    var driver: mongo.Client = try .init(init.gpa, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    try driver.connect(io, .root, null);
    const cursor = try driver.openCursor(io, .of(.root), .{ .database = "app", .body = bson.literal(.{ .find = "users" }) }, .{});
    _ = cursor;
    // The mistake: the client goes before its cursor.
    driver.deinit();
}
