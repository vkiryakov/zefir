//! The service of the guide of zefir-http, src/http/examples/main.zig, on
//! the network: this test starts it as a reader of the guide does, sends
//! it the guide's curl commands one after another, stops it with Ctrl+C,
//! and checks that the guide shows every command with the response it
//! got, and the log of the service from its start to its stop. Each
//! command is the very line the guide shows: the test reads its method,
//! URL, headers and body from it as curl would, and sends what curl sends.
//!
//! The build gives the paths of the service's program and of the app's
//! static files (`guide_options`), and embeds the guide (`guide`). Ctrl+C
//! is SIGINT, which Windows cannot send to one process: there the test is
//! skipped, and `zig build check` still builds the service.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const check = @import("guide-check");
const options = @import("guide_options");
const raw = @import("e2e/client.zig");
const Client = raw.Client;

const Io = std.Io;
const testing = std.testing;

/// How the guide runs the service, after `$ `.
const run_command = "APP_AUTH_ANN_TOKEN=ann-secret APP_AUTH_BOB_TOKEN=bob-secret zig build run";

/// A step of the session, in the order of the guide.
const Step = union(enum) {
    /// A curl command and its whole response.
    curl: []const u8,
    /// A curl command of a stream (`curl -N`): its head comes, and it
    /// stays open.
    open: []const u8,
    /// The next event of the open stream.
    event,
    /// Ctrl+C where the stream runs: its client leaves.
    leave,
};

const ann = "-H \"Authorization: Bearer ann-secret\"";

/// The curl commands of the guide, chapter by chapter.
const session = [_]Step{
    // Getting started
    .{ .curl = "curl -i localhost:8080/api/health" },
    .{ .curl = "curl -i localhost:8080/api/v1/todos " ++ ann ++ " --json '{\"title\":\"Buy milk\"}'" },
    .{ .curl = "curl -i localhost:8080/api/v1/todos " ++ ann },
    // Controllers and routes
    .{ .curl = "curl -i localhost:8080/api/v1/todos/1 " ++ ann },
    .{ .curl = "curl -i -X PUT localhost:8080/api/v1/todos/1 " ++ ann },
    .{ .curl = "curl -i localhost:8080/api/v2/todos " ++ ann },
    .{ .curl = "curl -I localhost:8080/api/health" },
    // Input
    .{ .curl = "curl -i localhost:8080/api/v1/todos " ++ ann ++ " --json '{\"title\":\"  Call Bob  \",\"priority\":\"high\",\"dueDate\":\"2026-10-20\",\"tags\":[\"Phone\",\" home \"]}'" },
    .{ .curl = "curl -i localhost:8080/api/v1/todos " ++ ann ++ " --json '{\"titel\":\"Buy bread\",\"priority\":\"urgent\"}'" },
    .{ .curl = "curl -i 'localhost:8080/api/v1/todos?q=BOB&tags=phone,home' " ++ ann },
    .{ .curl = "curl -i 'localhost:8080/api/v1/todos?perPage=500' " ++ ann },
    .{ .curl = "curl -i -X PATCH localhost:8080/api/v1/todos/1 " ++ ann ++ " --json '{\"done\":true}'" },
    // The same command twice: a retry with the same key.
    .{ .curl = "curl -i localhost:8080/api/v1/todos " ++ ann ++ " -H \"Idempotency-Key: plants-1\" --json '{\"title\":\"Water the plants\"}'" },
    .{ .curl = "curl -i localhost:8080/api/v1/todos " ++ ann ++ " -H \"Idempotency-Key: plants-1\" --json '{\"title\":\"Water the plants\"}'" },
    // Responses
    .{ .curl = "curl -i localhost:8080/api/v1/todos/export.csv " ++ ann },
    // Errors
    .{ .curl = "curl -i localhost:8080/api/v1/todos/42 " ++ ann },
    .{ .curl = "curl -i localhost:8080/api/v1/todos " ++ ann ++ " --json '{\"title\":\"Plan the trip\"}'" },
    .{ .curl = "curl -i localhost:8080/api/v1/todos " ++ ann ++ " -d 'title=Plan the trip'" },
    // Middleware
    .{ .curl = "curl -i localhost:8080/api/health -H \"X-Request-Id: checkout-42\"" },
    // Authentication and CORS
    .{ .curl = "curl -i localhost:8080/api/v1/todos" },
    .{ .curl = "curl -i -X DELETE localhost:8080/api/v1/todos/1 -H \"Authorization: Bearer bob-secret\"" },
    .{ .curl = "curl -i -X DELETE localhost:8080/api/v1/todos/1 " ++ ann },
    .{ .curl = "curl -i localhost:8080/api/session -d 'token=ann-secret'" },
    .{ .curl = "curl -i localhost:8080/api/v1/todos -b 'session=ann-secret'" },
    .{ .curl = "curl -i -X DELETE localhost:8080/api/session -b 'session=ann-secret'" },
    // The form of a page of another site, as a browser says.
    .{ .curl = "curl -i localhost:8080/api/session -d 'token=ann-secret' -H \"Sec-Fetch-Site: cross-site\"" },
    .{ .curl = "curl -i -X OPTIONS localhost:8080/api/v1/todos/2 -H \"Origin: http://localhost:5173\" -H \"Access-Control-Request-Method: DELETE\"" },
    // Server-sent events: the stream in one terminal, a change in another.
    .{ .open = "curl -i -N localhost:8080/api/v1/todos/events -b 'session=ann-secret'" },
    .{ .curl = "curl -i -X PATCH localhost:8080/api/v1/todos/2 " ++ ann ++ " --json '{\"done\":true}'" },
    .event,
    .leave,
    // Static files
    .{ .curl = "curl -I localhost:8080/" },
    .{ .curl = "curl -I localhost:8080/todos/today" },
    .{ .curl = "curl -i localhost:8080/.env" },
    // The OpenAPI document
    .{ .curl = "curl -I localhost:8080/api/openapi.json" },
};

test "the guide shows every curl command of the service with its response, and the service's log" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var dog = try io.concurrent(watch, .{io});
    defer dog.cancel(io);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var service: Service = try .start(gpa, io);
    defer service.deinit(io);
    const port = try service.port(io);

    var exchanges: std.ArrayList(Exchange) = .empty;
    var stream: ?Stream = null;
    defer if (stream) |*s| s.conn.close(io);
    for (session) |step| switch (step) {
        .curl => |command| {
            var conn = try Client.connect(io, gpa, port);
            defer conn.close(io);
            const request = try parse(arena, command);
            try conn.send(io, try request.bytes(arena));
            const res = try conn.readResponse(io, arena, .{ .head_request = request.method == .HEAD });
            try exchanges.append(arena, .{ .command = command, .output = try render(arena, res, request.method == .HEAD) });
            // The record of the access log comes after the response: the
            // next request waits for it, so the log keeps their order.
            try service.waitFor(io, res.header("x-request-id") orelse return error.TestNoRequestId);
        },
        .open => |command| stream = try .open(arena, io, gpa, port, command),
        .event => try stream.?.nextEvent(arena, io),
        .leave => {
            var s = stream.?;
            stream = null;
            s.conn.close(io);
            try s.output.appendSlice(arena, "^C\n");
            try exchanges.append(arena, .{ .command = s.command, .output = s.output.items });
            try service.waitFor(io, s.request_id);
        },
    };

    const log = try service.stop(io);
    const guide = @embedFile("guide");
    const name = "src/http/examples/README.md";
    var failed = false;
    for (exchanges.items) |e| check.expectExchange(name, guide, e.command, e.output) catch {
        failed = true;
    };
    check.expectSession(name, guide, run_command, log) catch {
        failed = true;
    };
    if (failed) {
        // What the session printed, as the guide would show it.
        std.debug.print("\nThe session printed:\n\n```text\n$ {s}\n{s}```\n", .{ run_command, log });
        for (exchanges.items) |e| std.debug.print("\n```text\n$ {s}\n{s}```\n", .{ e.command, e.output });
        return error.TestGuideOutOfDate;
    }
}

/// The run has a minute: past it, it is stuck.
fn watch(io: Io) void {
    io.sleep(.fromSeconds(60), .awake) catch return;
    std.debug.print("the session of the guide still runs after 60 s: a hang\n", .{});
    std.process.exit(4);
}

/// A command of the guide and what it printed.
const Exchange = struct { command: []const u8, output: []const u8 };

/// A request as curl sends it for a command line.
const Request = struct {
    method: std.http.Method,
    /// The path and the query of the URL.
    target: []const u8,
    headers: []const [2][]const u8,
    body: ?[]const u8,

    /// The request on the wire: curl's own fields first, then those of
    /// `-H`, then the body's.
    fn bytes(r: Request, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("{t} {s} HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\n", .{ r.method, r.target });
        for (r.headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
        if (r.body) |body| try w.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body }) else try w.writeAll("\r\n");
        return out.written();
    }
};

/// The request of a curl command line of the guide: `-i`, `-I` (HEAD),
/// `-N`, `-X <method>`, `-H <field>`, `--json <body>`, `-d <form>`, `-b
/// <cookie>` and the URL, each argument bare or in single or double
/// quotes.
fn parse(arena: std.mem.Allocator, command: []const u8) !Request {
    const args = try split(arena, command);
    if (args.len == 0 or !std.mem.eql(u8, args[0], "curl")) return error.TestNotCurl;
    var method: ?std.http.Method = null;
    var url: ?[]const u8 = null;
    var accept: []const u8 = "*/*";
    var body: ?[]const u8 = null;
    var content_type: ?[]const u8 = null;
    var fields: std.ArrayList([2][]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "-N")) continue;
        if (std.mem.eql(u8, arg, "-I")) {
            method = .HEAD;
            continue;
        }
        if (arg[0] != '-') {
            url = arg;
            continue;
        }
        i += 1;
        if (i == args.len) return error.TestNoValue;
        const value = args[i];
        if (std.mem.eql(u8, arg, "-X")) {
            method = std.meta.stringToEnum(std.http.Method, value) orelse return error.TestBadMethod;
        } else if (std.mem.eql(u8, arg, "-H")) {
            const colon = std.mem.findScalar(u8, value, ':') orelse return error.TestBadHeader;
            try fields.append(arena, .{ value[0..colon], std.mem.trim(u8, value[colon + 1 ..], " ") });
        } else if (std.mem.eql(u8, arg, "--json")) {
            body = value;
            content_type = "application/json";
            accept = "application/json";
        } else if (std.mem.eql(u8, arg, "-d")) {
            body = value;
            content_type = "application/x-www-form-urlencoded";
        } else if (std.mem.eql(u8, arg, "-b")) {
            try fields.append(arena, .{ "Cookie", value });
        } else return error.TestUnknownOption;
    }
    const given = url orelse return error.TestNoUrl;
    const slash = std.mem.findScalar(u8, given, '/') orelse return error.TestBadUrl;
    var headers: std.ArrayList([2][]const u8) = .empty;
    try headers.append(arena, .{ "Accept", accept });
    try headers.appendSlice(arena, fields.items);
    if (content_type) |t| try headers.append(arena, .{ "Content-Type", t });
    return .{
        .method = method orelse if (body != null) .POST else .GET,
        .target = given[slash..],
        .headers = headers.items,
        .body = body,
    };
}

/// The arguments of a command line, as a shell splits them: at spaces,
/// but within single or double quotes.
fn split(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var arg: std.ArrayList(u8) = .empty;
    var in_arg = false;
    var quote: ?u8 = null;
    for (line) |c| {
        if (quote) |q| {
            if (c == q) quote = null else try arg.append(arena, c);
        } else if (c == '\'' or c == '"') {
            quote = c;
            in_arg = true;
        } else if (c == ' ') {
            if (in_arg) try args.append(arena, try arg.toOwnedSlice(arena));
            in_arg = false;
        } else {
            try arg.append(arena, c);
            in_arg = true;
        }
    }
    if (quote != null) return error.TestUnclosedQuote;
    if (in_arg) try args.append(arena, try arg.toOwnedSlice(arena));
    return args.items;
}

/// A response as `curl -i` prints it: the status line, the fields as they
/// came, an empty line and the body; for HEAD (`curl -I`), the head alone.
fn render(arena: std.mem.Allocator, res: raw.Response, head_only: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try writeHead(w, res.status, res.reason, res.headers);
    if (!head_only and res.body.len > 0) {
        try w.print("\n{s}", .{res.body});
        if (!std.mem.endsWith(u8, res.body, "\n")) try w.writeAll("\n");
    }
    return out.written();
}

fn writeHead(w: *std.Io.Writer, status: u16, reason: []const u8, headers: []const raw.Header) !void {
    try w.print("HTTP/1.1 {d} {s}\n", .{ status, reason });
    for (headers) |h| try w.print("{s}: {s}\n", .{ h.name, h.value });
}

/// A stream of `curl -N`: what it has printed so far.
const Stream = struct {
    command: []const u8,
    conn: Client,
    output: std.ArrayList(u8) = .empty,
    request_id: []const u8,

    /// Sends the request of `command` and reads the head of its response.
    fn open(arena: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, port: u16, command: []const u8) !Stream {
        var conn = try Client.connect(io, gpa, port);
        errdefer conn.close(io);
        const request = try parse(arena, command);
        try conn.send(io, try request.bytes(arena));
        if (!try conn.readUntil(io, "\r\n\r\n", .fromSeconds(5))) return error.TestNoHead;
        const kept = conn.kept();
        const head_len = std.mem.find(u8, kept, "\r\n\r\n").? + 4;
        var s: Stream = .{ .command = command, .conn = conn, .request_id = "" };
        var lines = std.mem.splitSequence(u8, kept[0 .. head_len - 4], "\r\n");
        try s.output.appendSlice(arena, lines.first());
        try s.output.append(arena, '\n');
        while (lines.next()) |line| {
            try s.output.appendSlice(arena, line);
            try s.output.append(arena, '\n');
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "x-request-id")) s.request_id = try arena.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " "));
        }
        try s.output.append(arena, '\n');
        s.conn.consume(head_len);
        return s;
    }

    /// Reads the chunks of the body until an event has ended, an empty
    /// line, and prints them as curl does, without the framing.
    fn nextEvent(s: *Stream, arena: std.mem.Allocator, io: Io) !void {
        // An event ends with an empty line, and its last chunk with CRLF.
        if (!try s.conn.readUntil(io, "\n\n\r\n", .fromSeconds(5))) return error.TestNoEvent;
        while (true) {
            const kept = s.conn.kept();
            const line_end = std.mem.find(u8, kept, "\r\n") orelse return error.TestBadChunk;
            const size = try std.fmt.parseInt(usize, kept[0..line_end], 16);
            if (size == 0 or kept.len < line_end + 2 + size + 2) return error.TestBadChunk;
            try s.output.appendSlice(arena, kept[line_end + 2 ..][0..size]);
            s.conn.consume(line_end + 2 + size + 2);
            if (std.mem.endsWith(u8, s.output.items, "\n\n")) return;
        }
    }
};

/// The service, a child process, and its log as it has come so far.
const Service = struct {
    child: std.process.Child,
    gpa: std.mem.Allocator,
    environ: std.process.Environ.Map,
    buffer: [4096]u8 = undefined,
    reader: ?Io.File.Reader = null,
    log: std.ArrayList(u8) = .empty,

    fn start(gpa: std.mem.Allocator, io: Io) !Service {
        var environ: std.process.Environ.Map = .init(gpa);
        errdefer environ.deinit();
        try environ.put("APP_AUTH_ANN_TOKEN", "ann-secret");
        try environ.put("APP_AUTH_BOB_TOKEN", "bob-secret");
        // A free port, which the log names, and the files of the app.
        try environ.put("APP_PORT", "0");
        try environ.put("APP_PUBLIC_DIR", options.public_dir);
        const child = try std.process.spawn(io, .{
            .argv = &.{options.service},
            .environ_map = &environ,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        return .{ .child = child, .gpa = gpa, .environ = environ };
    }

    fn deinit(s: *Service, io: Io) void {
        // The service has ended when the test got to its end.
        if (s.child.id != null) s.child.kill(io);
        s.log.deinit(s.gpa);
        s.environ.deinit();
    }

    /// The next line of the log, kept; null at its end.
    fn line(s: *Service, io: Io) !?[]const u8 {
        const reader = if (s.reader) |*r| r else reader: {
            s.reader = s.child.stdout.?.readerStreaming(io, &s.buffer);
            break :reader &s.reader.?;
        };
        const next = (try reader.interface.takeDelimiter('\n')) orelse return null;
        const at = s.log.items.len;
        try s.log.appendSlice(s.gpa, next);
        try s.log.append(s.gpa, '\n');
        return s.log.items[at..];
    }

    /// The port of `Serving port=…`, the first line of the log.
    fn port(s: *Service, io: Io) !u16 {
        const first = (try s.line(io)) orelse return error.TestServiceEnded;
        const key = "port=";
        const at = (std.mem.find(u8, first, key) orelse return error.TestNoPort) + key.len;
        var end = at;
        while (end < first.len and std.ascii.isDigit(first[end])) end += 1;
        return std.fmt.parseInt(u16, first[at..end], 10);
    }

    /// Reads the log until a line holds `needle`, such as the id of a
    /// request in its record of the access log.
    fn waitFor(s: *Service, io: Io, needle: []const u8) !void {
        while (try s.line(io)) |l| {
            if (std.mem.find(u8, l, needle) != null) return;
        }
        std.debug.print("the log of the service ended before a line with {s}:\n{s}\n", .{ needle, s.log.items });
        return error.TestServiceEnded;
    }

    /// Ctrl+C: SIGINT, then the rest of the log until the service ends,
    /// which it must with code 0. The log, whole.
    fn stop(s: *Service, io: Io) ![]const u8 {
        try std.posix.kill(s.child.id.?, .INT);
        while (try s.line(io)) |_| {}
        const term = try s.child.wait(io);
        if (!term.success()) {
            std.debug.print("the service {f}; its log:\n{s}\n", .{ term, s.log.items });
            return error.TestServiceFailed;
        }
        return s.log.items;
    }
};
