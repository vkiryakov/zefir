//! The target of zefir-http in the HTTP Garden (garden/README.md): an
//! origin server on `http.native` that answers every request it parses
//! with the request as it understood it, in the JSON of the Garden's
//! echo servers: `{"method","uri","version","headers","body"}`, every
//! string in base64 and `headers` a list of `[name, value]` in the order
//! they came. The Garden sends the same bytes to several servers and
//! compares what each understood: where zefir-http accepts what the
//! others refuse, or reads a request otherwise, a request could be
//! smuggled past a proxy.
//!
//! It serves `http.native`'s backend directly, without an `http.Server`:
//! the Garden compares the parsing of requests, and the routes, the rules
//! of paths and the answers of a server would only stand in front of it.
//! A body that does not arrive whole gets 400 or 408, as from a server;
//! one over 1 MiB gets 413.
//!
//!   zefir-garden-echo [port]   listens on 0.0.0.0, port 80 unless given
//!
//! A panic prints its message and exits with code 3 instead of aborting.

const std = @import("std");
const http = @import("http");
const zio = @import("zio");

const Io = std.Io;
const Exchange = http.Backend.Exchange;

pub const panic = std.debug.FullPanic(exitOnPanic);

/// Warnings and errors only: no debug lines of zio.
pub const std_options: std.Options = .{ .log_level = .warn };

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

const gpa = std.heap.smp_allocator;
const max_body = 1 << 20;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const port: u16 = if (args.len > 1) try std.fmt.parseInt(u16, args[1], 10) else 80;
    const runtime = try zio.Runtime.init(gpa, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var native = try http.native.Backend.init(gpa, .{ .address = "0.0.0.0", .port = port });
    defer native.deinit();
    // The echo keeps no state: the handler's pointer goes unused.
    var unused: u8 = 0;
    try native.backend().start(io, .{ .ptr = &unused, .serve = serve });
    std.debug.print("zefir-http echo on port {d}\n", .{native.port()});
    // Until the container stops.
    while (true) try io.sleep(.fromSeconds(3600), .awake);
}

fn serve(_: *anyopaque, io: Io, exchange: *Exchange) void {
    respond(io, exchange) catch exchange.abort(io);
}

fn respond(io: Io, e: *Exchange) !void {
    const a = e.arena;
    var body: std.ArrayList(u8) = .empty;
    var chunk: [16 << 10]u8 = undefined;
    while (true) {
        const n = e.readBody(io, &chunk) catch |err| switch (err) {
            error.ReadFailed => {
                // As a server answers a body that does not arrive whole; a
                // broken connection gets nothing.
                const failure = e.bodyFailure() orelse return error.ReadFailed;
                return text(io, e, switch (failure) {
                    .timeout => 408,
                    .malformed => 400,
                });
            },
            else => |other| return other,
        };
        if (n == 0) break;
        if (body.items.len + n > max_body) return text(io, e, 413);
        try body.appendSlice(a, chunk[0..n]);
    }

    var json: Io.Writer.Allocating = .init(a);
    const w = &json.writer;
    try w.writeAll("{\"method\":");
    try writeBase64(w, @tagName(e.method));
    try w.writeAll(",\"uri\":");
    try writeBase64(w, e.target);
    try w.writeAll(",\"version\":");
    try writeBase64(w, switch (e.version) {
        .http10 => "1.0",
        .http11 => "1.1",
    });
    try w.writeAll(",\"headers\":[");
    for (e.fields, 0..) |field, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('[');
        try writeBase64(w, field.name);
        try w.writeByte(',');
        try writeBase64(w, field.value);
        try w.writeByte(']');
    }
    try w.writeAll("],\"body\":");
    try writeBase64(w, body.items);
    try w.writeByte('}');

    const out = json.written();
    try e.writeHead(io, 200, &.{.{ .name = "Content-Type", .value = "application/json" }}, .{ .length = out.len });
    if (e.method != .HEAD) try e.writeBody(io, out);
    try e.finish(io);
}

/// A short answer of the server with no echo: 400, 408 or 413.
fn text(io: Io, e: *Exchange, status: u16) !void {
    const reason = switch (status) {
        400 => "Bad Request",
        408 => "Request Timeout",
        else => "Content Too Large",
    };
    try e.writeHead(io, status, &.{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }}, .{ .length = reason.len });
    if (e.method != .HEAD) try e.writeBody(io, reason);
    try e.finish(io);
}

/// `bytes` in base64, as a JSON string.
fn writeBase64(w: *Io.Writer, bytes: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    try w.writeByte('"');
    var rest = bytes;
    var encoded: [4 * 256]u8 = undefined;
    while (rest.len > 0) {
        // Whole groups of three bytes, so that only the last piece pads.
        const n = if (rest.len > 3 * 256) 3 * 256 else rest.len;
        try w.writeAll(encoder.encode(&encoded, rest[0..n]));
        rest = rest[n..];
    }
    try w.writeByte('"');
}
