//! A program of the tests in a process of its own, with settings in its
//! environment, and its log, read line by line as it comes: the tests send
//! it requests and a signal, and check how it ended and what it logged.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub const Program = struct {
    child: std.process.Child,
    environ: std.process.Environ.Map,
    /// Where the program logs.
    stream: Stream,
    buffer: [4096]u8 = undefined,
    reader: ?Io.File.Reader = null,
    log: std.ArrayList(u8) = .empty,
    /// Kills the program after the limit of `limit`.
    guard: ?Io.Future(void) = null,
    /// Guards `waited` against the guard.
    mutex: Io.Mutex = .init,
    /// The test waits for the end of the program: its id may soon be
    /// another process's, so the guard leaves it alone.
    waited: bool = false,

    pub const Stream = enum { stdout, stderr };

    /// Starts the program at `path` with only the settings `env` in its
    /// environment; the other stream is inherited.
    pub fn start(io: Io, path: []const u8, env: []const [2][]const u8, stream: Stream) !Program {
        var environ: std.process.Environ.Map = .init(testing.allocator);
        errdefer environ.deinit();
        for (env) |pair| try environ.put(pair[0], pair[1]);
        const child = try std.process.spawn(io, .{
            .argv = &.{path},
            .environ_map = &environ,
            .stdout = if (stream == .stdout) .pipe else .inherit,
            .stderr = if (stream == .stderr) .pipe else .inherit,
        });
        return .{ .child = child, .environ = environ, .stream = stream };
    }

    pub fn deinit(p: *Program, io: Io) void {
        if (p.guard) |*guard| guard.cancel(io);
        // The program has ended when the test got to its end.
        if (p.child.id != null) p.child.kill(io);
        p.log.deinit(testing.allocator);
        p.environ.deinit();
    }

    /// Kills the program once `seconds` have passed, unless the test
    /// already waits for its end: a program that hangs then ends the
    /// reading of its log, and the test fails and prints that log instead
    /// of hanging `zig build e2e`.
    pub fn limit(p: *Program, io: Io, seconds: i64) !void {
        p.guard = try io.concurrent(killAfter, .{ p, io, seconds });
    }

    fn killAfter(p: *Program, io: Io, seconds: i64) void {
        io.sleep(.fromSeconds(seconds), .awake) catch return;
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        if (p.waited) return;
        std.debug.print("the program still runs after {d} s: killed\n", .{seconds});
        std.posix.kill(p.child.id.?, .KILL) catch {};
    }

    /// The next line of the log, kept; null at its end.
    pub fn line(p: *Program, io: Io) !?[]const u8 {
        const reader = if (p.reader) |*r| r else reader: {
            const file = switch (p.stream) {
                .stdout => p.child.stdout.?,
                .stderr => p.child.stderr.?,
            };
            p.reader = file.readerStreaming(io, &p.buffer);
            break :reader &p.reader.?;
        };
        const next = (try reader.interface.takeDelimiter('\n')) orelse return null;
        const at = p.log.items.len;
        try p.log.appendSlice(testing.allocator, next);
        try p.log.append(testing.allocator, '\n');
        return p.log.items[at .. p.log.items.len - 1];
    }

    /// Reads the log until a line ends with `wanted`.
    pub fn waitFor(p: *Program, io: Io, wanted: []const u8) !void {
        while (try p.line(io)) |l| {
            if (std.mem.endsWith(u8, l, wanted)) return;
        }
        std.debug.print("the log of the program ended before a line with {s}:\n{s}\n", .{ wanted, p.log.items });
        return error.TestProgramEnded;
    }

    /// Sends `signal`, then reads the rest of the log until the program
    /// ends; how it ended.
    pub fn stop(p: *Program, io: Io, signal: std.posix.SIG) !std.process.Child.Term {
        try std.posix.kill(p.child.id.?, signal);
        while (try p.line(io)) |_| {}
        {
            p.mutex.lockUncancelable(io);
            defer p.mutex.unlock(io);
            p.waited = true;
        }
        return p.child.wait(io);
    }

    /// Fails unless lines of the log end with each of `lines`, one after
    /// another: the record of a logger begins with its time.
    pub fn expectInOrder(p: *const Program, lines: []const []const u8) !void {
        var it = std.mem.splitScalar(u8, p.log.items, '\n');
        for (lines) |wanted| {
            while (it.next()) |l| {
                if (std.mem.endsWith(u8, l, wanted)) break;
            } else {
                std.debug.print("the log has no line that ends with \"{s}\" after the lines before it; the log:\n{s}\n", .{ wanted, p.log.items });
                return error.TestLineNotInLog;
            }
        }
    }
};
