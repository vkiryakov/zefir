//! The program of every variant: builds the server of the synthetic
//! application with the variant's document, as `Service.start` of design
//! 1.2 does, writes the document to the file its first argument names, and
//! prints what it measured. With a document it writes it eleven times and
//! prints the first write and the fastest of the others.
const std = @import("std");
const http = @import("http");
const app = @import("app");
const variants = @import("variants.zig");

pub fn run(init: std.process.Init, comptime Variant: type) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var backend: http.testing.Backend = .init(gpa);
    defer backend.deinit();
    var service: app.Service = .{};
    const document = try service.start(gpa, backend.backend(), Variant);
    defer service.server.deinit(io);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Known at compile time: only the branch of the variant is compiled.
    if (Variant == variants.Real) {
        var first_us: i64 = 0;
        var fastest_us: i64 = std.math.maxInt(i64);
        for (0..11) |i| {
            out.clearRetainingCapacity();
            const start = std.Io.Timestamp.now(io, .awake);
            try document.write(&out.writer);
            const took = start.untilNow(io, .awake).toMicroseconds();
            if (i == 0) first_us = took else fastest_us = @min(fastest_us, took);
        }
        std.debug.print("write_us_first={d} write_us_min={d}\n", .{ first_us, fastest_us });
    }
    const bytes = out.written();
    std.debug.print("routes={d} doc_bytes={d}\n", .{ service.server.internal.routes.len, bytes.len });
    if (args.len > 1 and bytes.len > 0) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = bytes });
}
