//! Schemathesis against the service of the guide of zefir-http,
//! src/http/examples/main.zig, on the network: this test starts the service
//! as a reader of the guide does, runs Schemathesis in Docker against its
//! OpenAPI document, which the service serves at /api/openapi.json, and
//! stops it with Ctrl+C. Schemathesis sends each operation of the document
//! requests that the document allows, as Ann, and checks every response
//! against the document: its status, its media type, its headers and its
//! body. The stream of events, /v1/todos/events, is left out: it does not
//! end. POST /session is reached only on its 401: the token of its form is
//! one Schemathesis makes up, never Ann's, so it warns that one operation
//! answered only 401 or 403. The 303 of a right token is checked by
//! todos_test.zig of the guide and by the guide's curl session
//! (`zig build examples`). Only data the document allows is sent: a schema
//! may be stricter than the server, where a transform such as `v.trim`
//! runs before a rule, and a request the server takes but the schema does
//! not would be no mistake. Every check runs, `positive_data_acceptance`
//! too, which wants every request of valid data taken: but the schema of a
//! 64-bit integer has no `maximum` (the tools of JavaScript show 2^64 - 1
//! inexactly), so an id above it passes the schema, and the server answers
//! it with 422. schemathesis.toml lets the three operations of
//! /v1/todos/{id}, and no other, answer valid data with that 422. The
//! service is a Debug build, so it checks each request and response
//! against what its route declares, too: a mismatch is a 500, which
//! Schemathesis reports, and a line of the log, which this test does.
//!
//! The build gives the paths of the service's program and of the app's
//! static files (`guide_options`), and of schemathesis.toml
//! (`schemathesis_options`). Docker runs Linux containers on Linux, with
//! the host's network, and on macOS, through host.docker.internal; on
//! Windows the test is skipped.

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const options = @import("guide_options");
/// The absolute path of schemathesis.toml.
const config = @import("schemathesis_options").config;

const Io = std.Io;
const testing = std.testing;

/// The image of Schemathesis, by its exact tag.
const image = "schemathesis/schemathesis:4.32.3";

test "Schemathesis finds every response of the guide's service as its OpenAPI document says" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var dog = try io.concurrent(watch, .{io});
    defer dog.cancel(io);

    // Before the service starts: it runs for two minutes at most.
    try runDocker(io, &.{ "docker", "pull", "--quiet", image });

    var service: Service = try .start(gpa, io);
    defer service.deinit(io);
    const port = try service.port(io);

    // The document, at the address of the host as a container sees it: on
    // Linux the container has the host's network, on macOS
    // host.docker.internal leads to the host.
    var url_buffer: [96]u8 = undefined;
    const on_mac = builtin.os.tag == .macos;
    const url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/api/openapi.json", .{ if (on_mac) "host.docker.internal" else "127.0.0.1", port });
    const network: []const []const u8 = if (on_mac) &.{} else &.{ "--network", "host" };
    // The configuration, which the container reads at /schemathesis.toml:
    // an option of Schemathesis itself, before its command `run`.
    const mount = try std.fmt.allocPrint(gpa, "{s}:/schemathesis.toml:ro", .{config});
    defer gpa.free(mount);
    var argv_buffer: [32][]const u8 = undefined;
    var argv: std.ArrayList([]const u8) = .initBuffer(&argv_buffer);
    argv.appendSliceAssumeCapacity(&.{ "docker", "run", "--rm", "-v", mount });
    argv.appendSliceAssumeCapacity(network);
    argv.appendSliceAssumeCapacity(&.{ image, "--config-file", "/schemathesis.toml", "run", url });
    // Only data the document allows, and every check.
    argv.appendSliceAssumeCapacity(&.{ "--mode", "positive" });
    argv.appendSliceAssumeCapacity(&.{ "--checks", "all" });
    argv.appendSliceAssumeCapacity(&.{ "--exclude-path", "/v1/todos/events" });
    argv.appendSliceAssumeCapacity(&.{ "--header", "Authorization: Bearer ann-secret", "--no-color" });

    // From here the service's log is read as it comes, until it stops.
    var drain = try io.concurrent(Service.drain, .{ &service, io });
    const result = runDocker(io, argv.items);
    const stopped = service.interrupt();
    drain.await(io);
    try stopped;
    try service.wait(io);
    try result;
    // The Debug check's lines, and any other warning of zefir-http.
    if (std.mem.find(u8, service.log.items, "zefir.http: ") != null) {
        std.debug.print("the log of the service has warnings of zefir-http:\n{s}\n", .{service.log.items});
        return error.TestServiceWarned;
    }
}

/// Runs a command of Docker, its output on ours, which must end with 0.
fn runDocker(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .inherit, .stderr = .inherit });
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("{s} {s}: {f}\n", .{ argv[0], argv[1], term });
        return error.TestDockerFailed;
    }
}

/// The run has five minutes: past them, it is stuck.
fn watch(io: Io) void {
    io.sleep(.fromSeconds(300), .awake) catch return;
    std.debug.print("Schemathesis still runs after 300 s: a hang\n", .{});
    std.process.exit(4);
}

/// The service, a child process, and its log, which `drain` reads as it
/// comes, so that the service never waits for its pipe.
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

    /// Reads the log to its end, when the service stops.
    fn drain(s: *Service, io: Io) void {
        while (s.line(io) catch null) |_| {}
    }

    /// Ctrl+C: SIGINT, which begins a graceful stop.
    fn interrupt(s: *Service) !void {
        try std.posix.kill(s.child.id.?, .INT);
    }

    /// The end of the service, once its log has ended: with code 0.
    fn wait(s: *Service, io: Io) !void {
        const term = try s.child.wait(io);
        if (!term.success()) {
            std.debug.print("the service {f}; its log:\n{s}\n", .{ term, s.log.items });
            return error.TestServiceFailed;
        }
    }
};
