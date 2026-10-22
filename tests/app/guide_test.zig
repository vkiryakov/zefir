//! The shop of the guide of zefir.App, src/core/examples/app/main.zig, on
//! the network: this test starts it as a reader of the guide does, sends it
//! the guide's curl commands one after another, stops it with Ctrl+C, and
//! checks that the guide shows every command with the response it got, and
//! the log of the shop from its start to its stop. Each command is the very
//! line the guide shows: the test reads its method, URL, headers and body
//! from it as curl would, and sends what curl sends.
//!
//! The build gives the path of the shop's program (`guide_options`) and
//! embeds the guide (`guide`). The shop listens on a free port instead of
//! the guide's 8080. Ctrl+C is SIGINT, which Windows cannot send to one
//! process: there the test is skipped, and `zig build check` still builds
//! the shop.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const check = @import("guide-check");
const options = @import("guide_options");
const client = @import("e2e/client.zig");
const Program = @import("e2e/child.zig").Program;

const Io = std.Io;
const testing = std.testing;

/// How the guide runs the shop, after `$ `.
const run_command = "zig build run";

/// The curl commands of the guide, in its order.
const session = [_][]const u8{
    "curl -i localhost:8080/api/readyz",
    "curl -i localhost:8080/api/v1/users --json '{\"name\":\"Ann\"}'",
    "curl -i localhost:8080/api/v1/users/1",
    "curl -i localhost:8080/api/v1/orders --json '{\"user_id\":1,\"item\":\"Green tea\"}'",
    "curl -i localhost:8080/api/v1/orders --json '{\"user_id\":2,\"item\":\"Coffee\"}'",
    "curl -i localhost:8080/api/v1/orders/1",
};

test "the guide shows every curl command of the shop with its response, and the shop's log" {
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

    const port = try client.freePort(io);
    var digits: [5]u8 = undefined;
    var shop: Program = try .start(io, options.service, &.{.{ "SHOP_PORT", try std.fmt.bufPrint(&digits, "{d}", .{port}) }}, .stdout);
    defer shop.deinit(io);
    // The last bean has started, and App runs right after it.
    try shop.waitFor(io, "[zefir_app] AppModule.Servers.rpcServer started");
    try waitReady(io, arena, port);

    var exchanges: std.ArrayList(Exchange) = .empty;
    for (session) |command| {
        var conn: client.Client = try .connect(io, gpa, port);
        defer conn.close(io);
        const request = try parse(arena, command);
        try conn.send(io, try request.bytes(arena));
        const res = try conn.readResponse(io, arena, .{});
        try exchanges.append(arena, .{ .command = command, .output = try render(arena, res) });
    }

    // Ctrl+C, and the rest of the log until the shop ends, with code 0.
    const term = try shop.stop(io, .INT);
    if (term != .exited or term.exited != 0) {
        std.debug.print("the shop {f}; its log:\n{s}\n", .{ term, shop.log.items });
        return error.TestShopFailed;
    }
    const log = shop.log.items;
    const guide = @embedFile("guide");
    const name = "src/core/examples/app/README.md";
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

/// Asks `GET /api/readyz` until it answers 200, 10 s at most. It writes
/// nothing to the log of the shop.
fn waitReady(io: Io, arena: std.mem.Allocator, port: u16) !void {
    const start = Io.Clock.awake.now(io);
    while (true) {
        if (client.fetch(io, testing.allocator, arena, port, "/api/readyz", null)) |res| {
            if (res.status == 200) return;
        } else |_| {}
        if (start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() > 10_000) return error.TestShopNotReady;
        try io.sleep(.fromMilliseconds(10), .awake);
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

    /// The request on the wire: curl's own fields first, then the body's.
    fn bytes(r: Request, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        try w.print("{t} {s} HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: curl/8.7.1\r\n", .{ r.method, r.target });
        for (r.headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
        if (r.body) |body| try w.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body }) else try w.writeAll("\r\n");
        return out.written();
    }
};

/// The request of a curl command line of the guide: `-i`, `--json <body>`
/// and the URL, each argument bare or in single quotes.
fn parse(arena: std.mem.Allocator, command: []const u8) !Request {
    const args = try split(arena, command);
    if (args.len == 0 or !std.mem.eql(u8, args[0], "curl")) return error.TestNotCurl;
    var url: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-i")) continue;
        if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i == args.len) return error.TestNoValue;
            body = args[i];
            continue;
        }
        if (arg[0] == '-') return error.TestUnknownOption;
        url = arg;
    }
    const given = url orelse return error.TestNoUrl;
    const slash = std.mem.findScalar(u8, given, '/') orelse return error.TestBadUrl;
    var headers: std.ArrayList([2][]const u8) = .empty;
    if (body != null) {
        try headers.append(arena, .{ "Content-Type", "application/json" });
        try headers.append(arena, .{ "Accept", "application/json" });
    } else {
        try headers.append(arena, .{ "Accept", "*/*" });
    }
    return .{
        .method = if (body != null) .POST else .GET,
        .target = given[slash..],
        .headers = headers.items,
        .body = body,
    };
}

/// The arguments of a command line, as a shell splits them: at spaces,
/// but within single quotes.
fn split(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var arg: std.ArrayList(u8) = .empty;
    var in_arg = false;
    var quoted = false;
    for (line) |c| {
        if (quoted) {
            if (c == '\'') quoted = false else try arg.append(arena, c);
        } else if (c == '\'') {
            quoted = true;
            in_arg = true;
        } else if (c == ' ') {
            if (in_arg) try args.append(arena, try arg.toOwnedSlice(arena));
            in_arg = false;
        } else {
            try arg.append(arena, c);
            in_arg = true;
        }
    }
    if (quoted) return error.TestUnclosedQuote;
    if (in_arg) try args.append(arena, try arg.toOwnedSlice(arena));
    return args.items;
}

/// A response as `curl -i` prints it: the status line, the fields as they
/// came, an empty line and the body.
fn render(arena: std.mem.Allocator, res: client.Response) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("HTTP/1.1 {d} {s}\n", .{ res.status, res.reason });
    for (res.headers) |h| try w.print("{s}: {s}\n", .{ h.name, h.value });
    if (res.body.len > 0) {
        try w.print("\n{s}", .{res.body});
        if (!std.mem.endsWith(u8, res.body, "\n")) try w.writeAll("\n");
    }
    return out.written();
}
