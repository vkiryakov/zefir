//! The test runner of the end-to-end tests. It prints one line per test,
//! and the error return trace of a test that fails; a panic prints its
//! message and exits with code 3 instead of aborting, so a broken run ends
//! at once and says why.
//!
//! The tests make zefir-http warn on purpose, thousands of times: clients
//! that leave, handlers that fail, streams that fall behind. So its
//! warnings are counted, and the line of each test gives their number
//! instead of each warning; so are the connections that zio reports reset
//! by their peer, on Windows. Every other record of the log is printed.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const panic = std.debug.FullPanic(exitOnPanic);

pub const std_options: std.Options = .{ .log_level = .warn, .logFn = log };

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

/// The warnings of zefir-http since the last test ended. The servers of a
/// test log on the threads of its runtime, so the counts are atomic.
var http_warnings: std.atomic.Value(usize) = .init(0);
/// The connections reset or aborted by their peer that zio logged as
/// errors since the last test ended.
var zio_resets: std.atomic.Value(usize) = .init(0);

fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .http and level == .warn) {
        _ = http_warnings.fetchAdd(1, .monotonic);
        return;
    }
    if (scope == .zio and level == .err and isReset(format, args)) {
        _ = zio_resets.fetchAdd(1, .monotonic);
        return;
    }
    std.log.defaultLog(level, scope, format, args);
}

/// Whether the record names a connection reset or aborted by its peer,
/// such as `WSARecv failed: .ECONNRESET`.
fn isReset(comptime format: []const u8, args: anytype) bool {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch return false;
    return std.mem.find(u8, message, "ECONNRESET") != null or std.mem.find(u8, message, "ECONNABORTED") != null;
}

/// What a test logged that its line counts, taken when it ends.
const Logged = struct {
    warnings: usize,
    resets: usize,

    fn take() Logged {
        return .{ .warnings = http_warnings.swap(0, .monotonic), .resets = zio_resets.swap(0, .monotonic) };
    }

    /// "; 2000 warnings of http; 12 resets in zio", the parts that are not 0.
    pub fn format(l: Logged, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (l.warnings > 0) try w.print("; {d} warnings of http", .{l.warnings});
        if (l.resets > 0) try w.print("; {d} resets in zio", .{l.resets});
    }
};

pub fn main() void {
    var failed: usize = 0;
    for (builtin.test_functions) |t| {
        testing.allocator_instance = .init(std.heap.page_allocator, .{});
        testing.io_instance = .init(testing.allocator, .{});
        const start = std.Io.Clock.awake.now(testing.io);
        const result = t.func();
        const took = start.durationTo(std.Io.Clock.awake.now(testing.io));
        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() != 0;
        const logged = Logged.take();
        if (result) |_| {
            if (leaked) {
                failed += 1;
                std.debug.print("LEAK {s} ({f}{f})\n", .{ t.name, took, logged });
            } else {
                std.debug.print("ok   {s} ({f}{f})\n", .{ t.name, took, logged });
            }
        } else |err| switch (err) {
            error.SkipZigTest => std.debug.print("skip {s}\n", .{t.name}),
            else => {
                failed += 1;
                std.debug.print("FAIL {s}: {t} ({f}{f})\n", .{ t.name, err, took, logged });
                // Where it failed; error return traces are on in Debug.
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }
    std.debug.print("{d} tests, {d} failed\n", .{ builtin.test_functions.len, failed });
    std.process.exit(if (failed == 0) 0 else 1);
}
