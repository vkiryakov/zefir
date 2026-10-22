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

const Io = std.Io;
const testing = std.testing;

test "SIGTERM stops an App: exit 0, and the log shows both phases of the stop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();

    var program: Program = try .start(io, programs.signals);
    defer program.deinit(io);
    try client.waitListening(io, program.port, .fromSeconds(10));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const res = try client.fetch(io, testing.allocator, arena_state.allocator(), program.port, "/hello", null);
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("hello", res.body);

    const term = try program.stop(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("the program {f}; its log:\n{s}\n", .{ term, program.log.items });
        return error.TestUnexpectedExit;
    }
    // The first phase asks the server to stop, the second shuts it down,
    // and the stop ends.
    try program.expectInOrder(&.{
        "info(zefir_app): stopping\n",
        "info(zefir_app): Root.Servers.httpServer stopped\n",
        "info(zefir_app): stopped\n",
    });
}

test "a server that does not stop in time: exit 1, and stderr names it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();

    var program: Program = try .start(io, programs.deaf);
    defer program.deinit(io);
    try client.waitListening(io, program.port, .fromSeconds(10));
    // A request that never ends: its connection stays open until the
    // process exits.
    var conn: client.Client = try .connect(io, testing.allocator, program.port);
    defer conn.close(io);
    try conn.send(io, "GET /hang HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try program.waitFor(io, "info(deaf): a request that never ends\n");

    const term = try program.stop(io);
    if (term != .exited or term.exited != 1) {
        std.debug.print("the program {f}; its log:\n{s}\n", .{ term, program.log.items });
        return error.TestUnexpectedExit;
    }
    try program.expectInOrder(&.{
        "info(zefir_app): stopping\n",
        "Root.Servers.httpServer did not stop in time; the process exits with code 1\n",
    });
}

/// A program of programs/, a child process on a free port, and its log on
/// stderr as it has come so far.
const Program = struct {
    child: std.process.Child,
    environ: std.process.Environ.Map,
    port: u16,
    buffer: [4096]u8 = undefined,
    reader: ?Io.File.Reader = null,
    log: std.ArrayList(u8) = .empty,

    fn start(io: Io, path: []const u8) !Program {
        const port = try client.freePort(io);
        var environ: std.process.Environ.Map = .init(testing.allocator);
        errdefer environ.deinit();
        var digits: [5]u8 = undefined;
        try environ.put("APP_PORT", try std.fmt.bufPrint(&digits, "{d}", .{port}));
        const child = try std.process.spawn(io, .{
            .argv = &.{path},
            .environ_map = &environ,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        return .{ .child = child, .environ = environ, .port = port };
    }

    fn deinit(p: *Program, io: Io) void {
        // The program has ended when the test got to its end.
        if (p.child.id != null) p.child.kill(io);
        p.log.deinit(testing.allocator);
        p.environ.deinit();
    }

    /// The next line of the log, kept; null at its end.
    fn line(p: *Program, io: Io) !?[]const u8 {
        const reader = if (p.reader) |*r| r else reader: {
            p.reader = p.child.stderr.?.readerStreaming(io, &p.buffer);
            break :reader &p.reader.?;
        };
        const next = (try reader.interface.takeDelimiter('\n')) orelse return null;
        const at = p.log.items.len;
        try p.log.appendSlice(testing.allocator, next);
        try p.log.append(testing.allocator, '\n');
        return p.log.items[at..];
    }

    /// Reads the log until the line `wanted` comes.
    fn waitFor(p: *Program, io: Io, wanted: []const u8) !void {
        while (try p.line(io)) |l| {
            if (std.mem.eql(u8, l, wanted)) return;
        }
        std.debug.print("the log of the program ended before the line {s}", .{wanted});
        std.debug.print("{s}\n", .{p.log.items});
        return error.TestProgramEnded;
    }

    /// SIGTERM, then the rest of the log until the program ends; how it
    /// ended.
    fn stop(p: *Program, io: Io) !std.process.Child.Term {
        try std.posix.kill(p.child.id.?, .TERM);
        while (try p.line(io)) |_| {}
        return p.child.wait(io);
    }

    /// Fails unless the log has each of `lines` as a whole line, after the
    /// one before it.
    fn expectInOrder(p: *const Program, lines: []const []const u8) !void {
        const log = p.log.items;
        var from: usize = 0;
        for (lines) |wanted| {
            from = while (std.mem.findPos(u8, log, from, wanted)) |at| {
                if (at == 0 or log[at - 1] == '\n') break at + wanted.len;
                from = at + 1;
            } else {
                std.debug.print("the log has no line {s}after the lines before it; the log:\n{s}\n", .{ wanted, log });
                return error.TestLineNotInLog;
            };
        }
    }
};
