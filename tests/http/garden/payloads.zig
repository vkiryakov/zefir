//! Prints the corpus of zefir-http's parser, every input of
//! src/http/h1/testdata/ (`inputs` of src/http/h1/fuzz.zig), as lines of
//! the HTTP Garden's REPL: `payload '<bytes>' | fanout | grid`, one per
//! input. `zig build garden-payloads` runs it; CI's http-garden.yml pipes
//! its lines into `./garden.sh repl`, which sends each input to every
//! server it runs and prints how each understood it.
//!
//! A panic prints its message and exits with code 3 instead of aborting.

const std = @import("std");
const corpus = @import("corpus");

pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    var buffer: [64 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    for (corpus.inputs) |input| {
        try out.writeAll("payload '");
        try writeEscaped(out, input);
        try out.writeAll("' | fanout | grid\n");
    }
    try out.flush();
}

/// `bytes` as the REPL reads them back: it keeps what is between single
/// quotes as it is, then decodes Python's `unicode-escape`. Printable ASCII
/// goes as it is, but for the quote and the backslash; the rest as `\r`,
/// `\n`, `\t` or `\xNN`.
fn writeEscaped(out: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |b| switch (b) {
        '\\' => try out.writeAll("\\\\"),
        '\r' => try out.writeAll("\\r"),
        '\n' => try out.writeAll("\\n"),
        '\t' => try out.writeAll("\\t"),
        ' '...'&', '('...'[', ']'...'~' => try out.writeByte(b),
        else => try out.print("\\x{x:0>2}", .{b}),
    };
}
