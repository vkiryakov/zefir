//! codec writes what the golden applications of zefir-openapi read and
//! write, for the check of those bodies against their documents:
//!
//!     codec <out.json>
//!
//! It serves each application of src/openapi/tests/apps on the backend of
//! zefir-http in memory, sends it its requests, each of which must get the
//! status it lists, and writes a record per request and version of the
//! document, 3.1 and 3.2:
//!
//!     {"app":"todos","version":"3.1","prefix":"/api","method":"POST","target":"/api/v1/todos","status":201,
//!      "request_type":"application/json","request_body":"{\"title\":\"Buy milk\"}",
//!      "response_type":"application/json","response_body":"{\"id\":2,...}"}
//!
//! The stream of events of `secure` is a record too: its body is what a
//! client read of it, an event of each kind. codec.mjs (`zig build codec`)
//! checks each record against the document of its application in its
//! version, src/openapi/tests/golden/<app>-<version>.json.
const std = @import("std");
const zefir = @import("zefir");
const apps = @import("apps");
const http = zefir.http;

/// A panic exits with code 3: an aborting process hangs some machines.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("codec: panic: {s}\n", .{message});
    std.process.exit(3);
}

/// The prefix of every golden application.
const prefix = "/api";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: codec <out.json>\n", .{});
        std.process.exit(2);
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var records: Records = .{ .w = &out.writer };
    try out.writer.writeAll("[\n");
    try serve("todos", apps.todos, gpa, io, &records);
    try serve("shapes", apps.shapes, gpa, io, &records);
    try serve("rules", apps.rules, gpa, io, &records);
    try serve("secure", apps.secure, gpa, io, &records);
    try out.writer.writeAll("\n]\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = out.written() });
    std.debug.print("codec: {d} records\n", .{records.count});
}

/// Starts the service of `App`, sends its requests and records each.
fn serve(comptime name: []const u8, comptime App: type, gpa: std.mem.Allocator, io: std.Io, records: *Records) !void {
    var backend: http.testing.Backend = .init(gpa);
    defer backend.deinit();
    var service: App.Service = .{};
    try service.start(gpa, io, backend.backend());
    defer service.deinit(io);
    for (App.requests) |req| {
        var res = try backend.request(io, .{ .method = req.method, .target = req.target, .headers = req.headers, .body = req.body });
        defer res.deinit();
        if (res.status != req.status) {
            std.debug.print("codec: {s}: {t} {s} answered {d}, not {d}: {s}\n", .{ name, req.method, req.target, res.status, req.status, res.body });
            return error.UnexpectedStatus;
        }
        try records.add(name, req, res.header("content-type"), res.body);
    }
    if (App == apps.secure) try streamEvents(gpa, io, &service, &backend, records);
}

/// The stream of events of `secure`, as a signed-in client reads it: an
/// event of each kind, the first with an id and a retry.
fn streamEvents(gpa: std.mem.Allocator, io: std.Io, service: *apps.secure.Service, backend: *http.testing.Backend, records: *Records) !void {
    const req: apps.Request = .{
        .method = .GET,
        .target = prefix ++ "/v1/projects/7/todos/events",
        .headers = &.{.{ "authorization", "Bearer ann-secret" }},
        .status = 200,
    };
    const stream = try backend.open(io, .{ .method = req.method, .target = req.target, .headers = req.headers });
    defer stream.deinit(io);
    if (stream.status != req.status) {
        std.debug.print("codec: secure: GET {s} answered {d}, not {d}\n", .{ req.target, stream.status, req.status });
        return error.UnexpectedStatus;
    }
    // The stream subscribed before its head came: it gets each event.
    const live = &service.live;
    try live.publish(.root, io, "ann", .{ .event = .{ .@"todo.created" = .{ .id = 2, .title = "Buy milk" } }, .id = "2", .retry = 3000 });
    try live.publish(.root, io, "ann", .{ .event = .{ .@"todo.deleted" = .{ .id = 2 } } });
    try live.publish(.root, io, "ann", .{ .event = .ping });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    while (events(body.items) < 3) {
        const piece = (try stream.next(io, .fromSeconds(5))) orelse {
            std.debug.print("codec: secure: the stream ended before its events: {s}\n", .{body.items});
            return error.StreamEnded;
        };
        try body.appendSlice(gpa, piece);
    }
    try records.add("secure", req, stream.header("content-type"), body.items);
}

/// The events of a stream's text: its blocks with data.
fn events(text: []const u8) usize {
    var count: usize = 0;
    var blocks = std.mem.splitSequence(u8, text, "\n\n");
    while (blocks.next()) |block| {
        if (blocks.peek() == null) break; // not ended yet
        if (std.mem.startsWith(u8, block, "data:") or std.mem.find(u8, block, "\ndata:") != null) count += 1;
    }
    return count;
}

/// The records, written as the items of a JSON array.
const Records = struct {
    w: *std.Io.Writer,
    count: usize = 0,

    const Record = struct {
        app: []const u8,
        version: []const u8,
        prefix: []const u8,
        method: []const u8,
        target: []const u8,
        status: u16,
        request_type: ?[]const u8,
        request_body: []const u8,
        response_type: ?[]const u8,
        response_body: []const u8,
    };

    /// A record of the exchange for each version of the document.
    fn add(r: *Records, app: []const u8, req: apps.Request, response_type: ?[]const u8, response_body: []const u8) !void {
        for ([_][]const u8{ "3.1", "3.2" }) |version| {
            if (r.count > 0) try r.w.writeAll(",\n");
            try std.json.Stringify.value(Record{
                .app = app,
                .version = version,
                .prefix = prefix,
                .method = @tagName(req.method),
                .target = req.target,
                .status = req.status,
                .request_type = contentType(req.headers),
                .request_body = req.body,
                .response_type = response_type,
                .response_body = response_body,
            }, .{}, r.w);
            r.count += 1;
        }
    }
};

fn contentType(headers: []const [2][]const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h[0], "content-type")) return h[1];
    }
    return null;
}
