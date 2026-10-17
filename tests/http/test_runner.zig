//! The test runner of the end-to-end tests. It prints one line per test,
//! and the error return trace of a test that fails; a panic prints its
//! message and exits with code 3 instead of aborting, so a broken run ends
//! at once and says why.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const panic = std.debug.FullPanic(exitOnPanic);

pub const std_options: std.Options = .{ .log_level = .warn };

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

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
        if (result) |_| {
            if (leaked) {
                failed += 1;
                std.debug.print("LEAK {s}\n", .{t.name});
            } else {
                std.debug.print("ok   {s} ({f})\n", .{ t.name, took });
            }
        } else |err| switch (err) {
            error.SkipZigTest => std.debug.print("skip {s}\n", .{t.name}),
            else => {
                failed += 1;
                std.debug.print("FAIL {s}: {t}\n", .{ t.name, err });
                // Where it failed; error return traces are on in Debug.
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }
    std.debug.print("{d} tests, {d} failed\n", .{ builtin.test_functions.len, failed });
    std.process.exit(if (failed == 0) 0 else 1);
}
