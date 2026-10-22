//! Signals and a stop that runs out of time, in processes of their own:
//! programs/signals.zig and programs/deaf.zig, each an App with an HTTP
//! server on zio. The test starts a program on a free port, sends it a
//! request, then SIGTERM, and checks its exit code and its log on stderr.
//! The build gives the paths of the programs (`programs`). Windows cannot
//! send SIGTERM to one process: there the tests are skipped, and `zig
//! build check` still builds the programs.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const programs = @import("programs");
const client = @import("client.zig");
const Program = @import("child.zig").Program;

const testing = std.testing;

test "SIGTERM stops an App: exit 0, and the log shows the stop of its server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();

    const port = try client.freePort(io);
    var digits: [5]u8 = undefined;
    var program: Program = try .start(io, programs.signals, &.{.{ "APP_PORT", try std.fmt.bufPrint(&digits, "{d}", .{port}) }}, .stderr);
    defer program.deinit(io);
    try program.limit(io, 30);
    try client.waitListening(io, port, .fromSeconds(10));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const res = try client.fetch(io, testing.allocator, arena_state.allocator(), port, "/hello", null);
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("hello", res.body);

    const term = try program.stop(io, .TERM);
    if (term != .exited or term.exited != 0) {
        std.debug.print("the program {f}; its log:\n{s}\n", .{ term, program.log.items });
        return error.TestUnexpectedExit;
    }
    // The stop begins, the server is shut down, and the stop ends.
    try program.expectInOrder(&.{
        "info(zefir_app): stopping",
        "info(zefir_app): Root.Servers.httpServer stopped",
        "info(zefir_app): stopped",
    });
}

test "a server that does not stop in time: exit 1, and stderr names it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();

    const port = try client.freePort(io);
    var digits: [5]u8 = undefined;
    var program: Program = try .start(io, programs.deaf, &.{.{ "APP_PORT", try std.fmt.bufPrint(&digits, "{d}", .{port}) }}, .stderr);
    defer program.deinit(io);
    try program.limit(io, 30);
    try client.waitListening(io, port, .fromSeconds(10));
    // A request that never ends: its connection stays open until the
    // process exits.
    var conn: client.Client = try .connect(io, testing.allocator, port);
    defer conn.close(io);
    try conn.send(io, "GET /hang HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try program.waitFor(io, "info(deaf): a request that never ends");

    const term = try program.stop(io, .TERM);
    if (term != .exited or term.exited != 1) {
        std.debug.print("the program {f}; its log:\n{s}\n", .{ term, program.log.items });
        return error.TestUnexpectedExit;
    }
    try program.expectInOrder(&.{
        "info(zefir_app): stopping",
        "Root.Servers.httpServer did not stop in time; the process exits with code 1",
    });
}
