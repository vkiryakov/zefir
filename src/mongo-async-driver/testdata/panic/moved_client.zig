//! Debug build: a client copied after `connect()` panics on its first
//! method call, since its pool still points to the old place. build.zig
//! runs this program and checks the panic message on stderr and the exit
//! code 3 of the panic handler below.
const std = @import("std");
const Io = std.Io;
const mongo = @import("mongo");
const native = @import("mongo-async-driver");
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

/// Answers every command with `{ok: 1.0}`.
const Ok = struct {
    pub fn answer(o: *Ok, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ o, io, arena, request };
        return .{ .reply = Script.ok };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var ok: Ok = .{};
    var script: Script = .init(init.gpa, .init(&ok));
    defer script.deinit();
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(FakeServer.serve, .{ io, &listener, &script });
    defer server.cancel(io) catch {};

    var uri: [64]u8 = undefined;
    var driver: native.Client = try .init(init.gpa, io, .{ .uri = try FakeServer.uri(&listener, &uri) });
    defer driver.deinit();
    try driver.connect(io, .root, null);

    // The mistake: a copy of the connected client.
    var moved = driver;
    const ping: mongo.Command = .{ .database = "admin", .body = mongo.bson.literal(.{ .ping = 1 }) };
    const reply = moved.client().runCommand(io, .of(.root), ping, .{ .allocator = init.gpa }) catch return;
    reply.deinit();
}
