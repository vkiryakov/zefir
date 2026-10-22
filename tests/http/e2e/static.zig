//! Static files on `http.native` over loopback TCP, on zio: files over the
//! network, a large one a buffer at a time, its range and its 304, and
//! every way out of the root refused with 404: dot segments, encoded or
//! not, an encoded slash or backslash, symbolic links inside the root, the
//! names of Windows devices. The module's own tests open their files
//! through std's test `Io`; here the server opens them through zio, on
//! Linux, macOS and Windows. Each scenario runs on one executor, then on
//! four.

const std = @import("std");
const builtin = @import("builtin");
const http = @import("http");
const runtime = @import("runtime");
const raw = @import("client.zig");
const e2e = @import("native.zig");

const Io = std.Io;
const testing = std.testing;
const gpa = testing.allocator;

/// A route next to the files.
const App = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .ping = http.get("/api/ping", .{}) } });

    pub fn ping(_: *App, ctx: *http.Context) !void {
        try ctx.response.text("pong");
    }
};

/// The names a Windows device has: refused everywhere. Elsewhere than on
/// Windows they are files of the root, so that the rule refuses them, not
/// their absence.
const device_names = [_][]const u8{ "con", "nul.txt", "COM1.log", "lpt9", "conin$", "a.txt.", "a.txt ", "a:b", "GIT~1" };

/// The files of a scenario, in a directory of its own: the root `public`,
/// and `secret.txt` beside it, outside the root.
const Site = struct {
    tmp: testing.TmpDir,
    /// The root, relative to the working directory.
    root: []const u8,
    /// `public/large.bin`.
    large: []u8,

    fn create(a: std.mem.Allocator, with_links: bool) !Site {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const io = testing.io;
        try tmp.dir.createDirPath(io, "public/sub");
        const large = try a.alloc(u8, 512 << 10);
        for (large, 0..) |*b, i| b.* = @truncate(i *% 13 +% i / 509);
        for ([_][2][]const u8{
            .{ "secret.txt", "secret" },
            .{ "public/index.html", "<h1>home</h1>" },
            .{ "public/a.txt", "alpha" },
            .{ "public/sub/b.txt", "beta" },
            .{ "public/.env", "KEY=1" },
            .{ "public/large.bin", large },
        }) |file| try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
        if (builtin.os.tag != .windows) {
            for (device_names) |name| try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "public/{s}", .{name}), .data = "device" });
        }
        if (with_links) {
            const sep = std.fs.path.sep_str;
            try tmp.dir.symLink(io, "a.txt", "public" ++ sep ++ "link.txt", .{});
            try tmp.dir.symLink(io, ".." ++ sep ++ "secret.txt", "public" ++ sep ++ "out.txt", .{});
            try tmp.dir.symLink(io, "sub", "public" ++ sep ++ "linkdir", .{ .is_directory = true });
            try tmp.dir.symLink(io, "..", "public" ++ sep ++ "outdir", .{ .is_directory = true });
        }
        return .{ .tmp = tmp, .root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/public", .{tmp.sub_path}), .large = large };
    }
};

/// A server of `App` and the mount `/` on `http.native`, on a free port of
/// loopback. It stays where `start` put it.
const Fixture = struct {
    app: App,
    native: http.native.Backend,
    server: http.Server,

    fn start(f: *Fixture, io: Io, root: []const u8) !void {
        f.app = .{};
        f.native = try .init(gpa, .{ .address = "127.0.0.1", .port = 0 });
        errdefer f.native.deinit();
        f.server = try http.Server.init(gpa, .{ .controllers = .{&f.app} }, .{ .listen = .{ .backend = f.native.backend() }, .static = &.{http.static("/", .{ .root = root })} });
        errdefer f.server.deinit(io);
        try f.server.start(io);
    }

    fn deinit(f: *Fixture, io: Io) void {
        f.server.deinit(io);
        f.native.deinit();
    }

    fn connect(f: *Fixture, io: Io) !raw.Client {
        return raw.Client.connect(io, gpa, f.native.port());
    }
};

/// GET `target` on the connection, kept alive: its response.
fn fetch(c: *raw.Client, io: Io, a: std.mem.Allocator, target: []const u8, headers: []const u8) !raw.Response {
    try c.send(io, try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: test\r\n{s}\r\n", .{ target, headers }));
    return c.readResponse(io, a, .{});
}

/// Every target is 404, on one connection.
fn expectNotFound(c: *raw.Client, io: Io, a: std.mem.Allocator, targets: []const []const u8) !void {
    for (targets) |target| {
        const res = try fetch(c, io, a, target, "");
        testing.expectEqual(404, res.status) catch |err| {
            std.debug.print("{s}: {d} {s} (zio x{d})\n", .{ target, res.status, res.body, runtime.executors });
            return err;
        };
    }
}

test "static over the network: .., %2e%2e, %2F and %5C are 404" {
    try runtime.forEachRuntime(gpa, escapes);
}

fn escapes(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "static: escapes");
    defer dog.stop(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var site = try Site.create(a, false);
    defer site.tmp.cleanup();
    var f: Fixture = undefined;
    try f.start(io, site.root);
    defer f.deinit(io);

    var c = try f.connect(io);
    defer c.close(io);
    // A file, and the route beside the mount.
    const file = try fetch(&c, io, a, "/a.txt", "");
    try testing.expectEqual(200, file.status);
    try testing.expectEqualStrings("alpha", file.body);
    try testing.expectEqualStrings("text/plain; charset=utf-8", file.header("content-type").?);
    try testing.expectEqualStrings("nosniff", file.header("x-content-type-options").?);
    try testing.expectEqualStrings("pong", (try fetch(&c, io, a, "/api/ping", "")).body);
    try testing.expectEqualStrings("<h1>home</h1>", (try fetch(&c, io, a, "/", "")).body);
    try expectNotFound(&c, io, a, &.{
        "/../secret.txt",
        "/sub/../../secret.txt",
        "/%2e%2e/secret.txt",
        "/sub/%2E%2E/%2e%2e/secret.txt",
        "/..%2Fsecret.txt",
        "/sub%2F..%2F..%2Fsecret.txt",
        "/..%5Csecret.txt",
        "/sub%5C..%5C..%5Csecret.txt",
        "/sub%5Cb.txt",
        "/a.txt%00",
        "//secret.txt",
        "/C:%5Csecret.txt",
        "/.env",
        "/%2eenv",
    });
    try e2e.waitIdle(io, &f.server);
}

test "static over the network: a symlink inside the root, to a file or a directory, is 404" {
    // Windows creates a symbolic link only with a privilege.
    var probe = testing.tmpDir(.{});
    defer probe.cleanup();
    probe.dir.symLink(testing.io, "nothing", "link", .{}) catch |err| {
        std.debug.print("skipped: the system does not create a symbolic link here: {t}\n", .{err});
        return error.SkipZigTest;
    };
    try runtime.forEachRuntime(gpa, symlinks);
}

fn symlinks(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "static: links");
    defer dog.stop(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var site = try Site.create(a, true);
    defer site.tmp.cleanup();
    var f: Fixture = undefined;
    try f.start(io, site.root);
    defer f.deinit(io);

    var c = try f.connect(io);
    defer c.close(io);
    try testing.expectEqualStrings("beta", (try fetch(&c, io, a, "/sub/b.txt", "")).body);
    try expectNotFound(&c, io, a, &.{
        "/link.txt",
        "/out.txt",
        "/linkdir",
        "/linkdir/b.txt",
        "/outdir",
        "/outdir/secret.txt",
        "/outdir/public/a.txt",
    });
    try e2e.waitIdle(io, &f.server);
}

test "static over the network: a Windows device name is 404" {
    try runtime.forEachRuntime(gpa, devices);
}

fn devices(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "static: devices");
    defer dog.stop(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var site = try Site.create(a, false);
    defer site.tmp.cleanup();
    var f: Fixture = undefined;
    try f.start(io, site.root);
    defer f.deinit(io);

    var c = try f.connect(io);
    defer c.close(io);
    try expectNotFound(&c, io, a, &.{
        "/con",
        "/CON",
        "/nul.txt",
        "/COM1.log",
        "/lpt9",
        "/conin$",
        "/sub/aux",
        "/a.txt.",
        "/a.txt%20",
        "/a:b",
        "/a.txt::$DATA",
        "/GIT~1",
    });
    try e2e.waitIdle(io, &f.server);
}

test "a large file streams over the network" {
    try runtime.forEachRuntime(gpa, largeFile);
}

fn largeFile(io: Io) !void {
    var dog = try e2e.Watchdog.start(io, "static: a large file");
    defer dog.stop(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var site = try Site.create(a, false);
    defer site.tmp.cleanup();
    var f: Fixture = undefined;
    try f.start(io, site.root);
    defer f.deinit(io);

    var c = try f.connect(io);
    defer c.close(io);
    // 512 KiB: past the buffer of the response and those of the sockets.
    const whole = try fetch(&c, io, a, "/large.bin", "");
    try testing.expectEqual(200, whole.status);
    try testing.expectEqualStrings("524288", whole.header("content-length").?);
    try testing.expectEqual(null, whole.header("transfer-encoding"));
    try testing.expectEqualStrings("bytes", whole.header("accept-ranges").?);
    try testing.expectEqualSlices(u8, site.large, whole.body);
    const tag = whole.header("etag").?;
    // On the same connection: a range of it, its 304, and its HEAD.
    const part = try fetch(&c, io, a, "/large.bin", "Range: bytes=100000-299999\r\n");
    try testing.expectEqual(206, part.status);
    try testing.expectEqualStrings("bytes 100000-299999/524288", part.header("content-range").?);
    try testing.expectEqualSlices(u8, site.large[100_000..300_000], part.body);
    const cached = try fetch(&c, io, a, "/large.bin", try std.fmt.allocPrint(a, "If-None-Match: {s}\r\n", .{tag}));
    try testing.expectEqual(304, cached.status);
    try testing.expectEqualStrings("", cached.body);
    try c.send(io, "HEAD /large.bin HTTP/1.1\r\nHost: test\r\n\r\n");
    const head = try c.readResponse(io, a, .{ .head_request = true });
    try testing.expectEqual(200, head.status);
    try testing.expectEqualStrings("524288", head.header("content-length").?);
    try testing.expect(!try c.waitData(io, .fromMilliseconds(50)));
    try e2e.waitIdle(io, &f.server);
}
