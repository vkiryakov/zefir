//! Static files (design section 13): `http.static(mount, options)` serves
//! a directory of the disk under a path of the site.
//!
//! ```zig
//! .static = .{
//!     http.static("/assets", .{ .root = "public/assets", .cache_control = "public, max-age=31536000, immutable" }),
//!     http.static("/", .{ .root = "public", .spa_fallback = "index.html" }),
//! },
//! ```
//!
//! The routes of the controllers come first: a mount serves a GET or HEAD
//! that no route takes, from the longest mount whose path begins it. A
//! file goes out with its type, its length, `ETag` and `Last-Modified`,
//! `Accept-Ranges: bytes`, the `Cache-Control` of its mount and always
//! `X-Content-Type-Options: nosniff`, read from the disk as it goes; a
//! directory gives its index file and never a listing. `If-None-Match`, and
//! without it `If-Modified-Since`, give 304; one range of a GET gives 206,
//! several the whole file, one past the end 416, and `If-Range` sends a
//! changed file whole. OPTIONS on a file is 204 with `Allow: GET, HEAD`,
//! another method 405 with it; on a path without a file, 404.
//!
//! The root is safe to serve: hidden files, the names of Windows devices
//! and every way out of the root are refused (static/resolve.zig), and so
//! is every symbolic link inside it, wherever it points.
//!
//! A static response runs the server's middleware, as every request does,
//! within the server's `.request_timeout`, and so does the open of its
//! file. The file goes out after, without a deadline: a large file to a
//! slow client takes its time, and only the backend's write timeout cuts a
//! client that stops reading.
const std = @import("std");
const Context = @import("Context.zig");
const Server = @import("Server.zig");
const h1 = @import("h1/head.zig");
const date = @import("h1/date.zig");
const mime = @import("mime.zig");
const path = @import("path.zig");
const resolve = @import("static/resolve.zig");
const conditional = @import("static/conditional.zig");

const Io = std.Io;
const log = std.log.scoped(.http);

pub const StaticOptions = struct {
    /// The directory the files come from: relative to the working
    /// directory of the process, or absolute. `start` opens it, and does
    /// not start without it.
    root: []const u8,
    /// The file that a directory serves, `docs/index.html` for `/docs`.
    /// Null: a directory serves nothing; there are no listings.
    index: ?[]const u8 = "index.html",
    /// For a single-page application: the file, relative to the root, that
    /// a GET or HEAD of a path without a file gets, such as "index.html",
    /// so that the application's own router reads the path. Never for a
    /// path under the server's `.prefix`: the API's 404 stays a 404.
    spa_fallback: ?[]const u8 = null,
    /// The `Cache-Control` of the mount's files, such as
    /// "public, max-age=31536000, immutable" for files whose names change
    /// with their content.
    cache_control: ?[]const u8 = null,
};

/// A mount of `.static`, as `http.static` declares it.
pub const Static = struct {
    /// "/" or a path such as "/assets": segments of visible ASCII without
    /// `%`, `?`, `#`, `{` and `}`, no empty or dot segments, no trailing
    /// slash.
    mount: []const u8,
    options: StaticOptions,
};

/// Declares a mount: the files of `options.root` under the path `mount`.
/// Only a declaration: `Server.init` copies and checks it, `start` opens
/// its root, and each request opens its file.
pub fn static(mount: []const u8, options: StaticOptions) Static {
    return .{ .mount = mount, .options = options };
}

/// A mount at run time, its strings copied.
pub const Mount = struct {
    mount: []const u8,
    root: []const u8,
    index: ?[]const u8,
    /// The segments of `spa_fallback`, slices of `spa_path`.
    spa_fallback: ?[]const []const u8,
    spa_path: ?[]const u8,
    cache_control: ?[]const u8,
    /// The root, open from `start` to `deinit`.
    dir: ?Io.Dir = null,
};

const static_form = "zefir.http: Server.init .static is a tuple of http.static(...) values: .{ http.static(\"/\", .{ .root = \"public\" }) }";

/// The mounts of the option `.static`, a tuple of `Static`, copied and
/// checked without I/O: the syntax of each mount, as of a server's prefix
/// (and "/"), no two mounts on one path, an index file that is one name, a
/// SPA file whose every segment is one a request could name, a
/// `Cache-Control` value without CR, LF or NUL, a root that is not empty.
/// `InvalidConfiguration` otherwise.
pub fn copyMounts(gpa: std.mem.Allocator, option: anytype) Server.InitError![]Mount {
    const info = @typeInfo(@TypeOf(option));
    if (info != .@"struct" or !(info.@"struct".is_tuple or info.@"struct".field_names.len == 0)) @compileError(static_form);
    inline for (info.@"struct".field_types) |F| {
        if (F != Static) @compileError(static_form);
    }
    const count = info.@"struct".field_names.len;
    const mounts = try gpa.alloc(Mount, count);
    var done: usize = 0;
    errdefer {
        for (mounts[0..done]) |m| freeMount(gpa, m);
        gpa.free(mounts);
    }
    inline for (0..count) |i| {
        mounts[i] = try copyMount(gpa, option[i]);
        done += 1;
    }
    for (mounts, 0..) |a, i| {
        for (mounts[i + 1 ..]) |b| if (std.mem.eql(u8, a.mount, b.mount)) return error.InvalidConfiguration;
    }
    return mounts;
}

fn copyMount(gpa: std.mem.Allocator, s: Static) Server.InitError!Mount {
    const o = s.options;
    if (!std.mem.eql(u8, s.mount, "/") and (s.mount.len == 0 or !Server.validPrefix(s.mount))) return error.InvalidConfiguration;
    if (o.root.len == 0) return error.InvalidConfiguration;
    if (o.index) |name| if (!resolve.allowed(name)) return error.InvalidConfiguration;
    if (o.spa_fallback) |file| {
        var it = std.mem.splitScalar(u8, file, '/');
        while (it.next()) |segment| if (!resolve.allowed(segment)) return error.InvalidConfiguration;
    }
    if (o.cache_control) |value| {
        for (value) |c| if (!h1.isValueChar(c)) return error.InvalidConfiguration;
    }

    var m: Mount = .{ .mount = "", .root = "", .index = null, .spa_fallback = null, .spa_path = null, .cache_control = null };
    errdefer freeMount(gpa, m);
    m.mount = try gpa.dupe(u8, s.mount);
    m.root = try gpa.dupe(u8, o.root);
    if (o.index) |name| m.index = try gpa.dupe(u8, name);
    if (o.cache_control) |value| m.cache_control = try gpa.dupe(u8, value);
    if (o.spa_fallback) |file| {
        const copy = try gpa.dupe(u8, file);
        m.spa_path = copy;
        const segments = try gpa.alloc([]const u8, std.mem.countScalar(u8, copy, '/') + 1);
        var it = std.mem.splitScalar(u8, copy, '/');
        for (segments) |*segment| segment.* = it.next().?;
        m.spa_fallback = segments;
    }
    return m;
}

fn freeMount(gpa: std.mem.Allocator, m: Mount) void {
    gpa.free(m.mount);
    gpa.free(m.root);
    if (m.index) |name| gpa.free(name);
    if (m.cache_control) |value| gpa.free(value);
    if (m.spa_fallback) |segments| gpa.free(segments);
    if (m.spa_path) |file| gpa.free(file);
}

pub fn freeMounts(gpa: std.mem.Allocator, mounts: []Mount) void {
    for (mounts) |m| freeMount(gpa, m);
    gpa.free(mounts);
}

/// Opens the root of every mount, for `start`: one that is missing, is not
/// a directory or does not open is `InvalidStaticRoot`, logged with its
/// mount, its path and the error of the system; then no root stays open.
pub fn openRoots(mounts: []Mount, io: Io) (error{InvalidStaticRoot} || Io.Cancelable)!void {
    for (mounts, 0..) |*m, i| {
        m.dir = Io.Dir.cwd().openDir(io, m.root, .{}) catch |err| {
            closeRoots(mounts[0..i], io);
            if (err == error.Canceled) return error.Canceled;
            log.warn("static {s}: the root \"{s}\" does not open as a directory: error.{t}; the server does not start", .{ m.mount, m.root, err });
            return error.InvalidStaticRoot;
        };
    }
}

pub fn closeRoots(mounts: []Mount, io: Io) void {
    for (mounts) |*m| {
        if (m.dir) |dir| dir.close(io);
        m.dir = null;
    }
}

/// A request for the files of a mount.
pub const Target = struct {
    /// The mount, by its index in the server's mounts.
    mount: u32,
    /// The segments of the path after the mount's.
    rest: []const []const u8,
    /// The path lies under the server's `.prefix`, which is the API's: no
    /// 405 and no SPA file there.
    under_prefix: bool,
};

/// The mount of a path that no route takes: the longest whose segments
/// begin it. Null for none, and for a path with an empty segment.
pub fn find(mounts: []const Mount, prefix: []const u8, normalized: path.Normalized) ?Target {
    if (mounts.len == 0 or normalized.empty_segment) return null;
    var best: ?Target = null;
    var best_len: usize = 0;
    for (mounts, 0..) |m, i| {
        const after = segmentsAfter(if (m.mount.len == 1) "" else m.mount, normalized.segments) orelse continue;
        if (best != null and after <= best_len) continue;
        best = .{ .mount = @intCast(i), .rest = normalized.segments[after..], .under_prefix = false };
        best_len = after;
    }
    if (best) |*b| b.under_prefix = prefix.len > 0 and segmentsAfter(prefix, normalized.segments) != null;
    return best;
}

/// How many of `segments` the path `prefix` ("" or such as "/a/b") takes,
/// or null when they do not begin with it.
fn segmentsAfter(prefix: []const u8, segments: []const []const u8) ?usize {
    if (prefix.len == 0) return 0;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, prefix[1..], '/');
    while (it.next()) |p| : (i += 1) {
        if (i == segments.len or !std.mem.eql(u8, p, segments[i])) return null;
    }
    return i;
}

/// The file of a GET or HEAD, open: `open` leaves it in the request's
/// context, and `send` sends it once the request has ended.
pub const File = struct {
    mount: *const Mount,
    opened: resolve.Opened,
};

/// Opens the file of `target`, after the server's middleware, within the
/// request's deadline: the file of a GET or HEAD, or its SPA file, stays
/// open in `ctx` for `send`; OPTIONS on a file gets 204 with its methods;
/// else the error that answers the request (`RouteNotFound`,
/// `MethodNotAllowed`; `ReadFailed`, 500, for a system that failed to open
/// a file, logged).
pub fn open(server: *Server, ctx: *Context, target: Target) anyerror!void {
    const mount = &server.mounts[target.mount];
    const io = ctx.io();
    const reading = ctx.request.method == .GET or ctx.request.method == .HEAD;
    const root = mount.dir.?;
    var found = try resolve.open(io, root, target.rest, mount.index);
    if (found == .missing and reading and !target.under_prefix) {
        if (mount.spa_fallback) |file| found = try resolve.open(io, root, file, null);
    }
    switch (found) {
        .file => |opened| {
            if (reading) {
                ctx.internal.static_file = .{ .mount = mount, .opened = opened };
                return;
            }
            opened.file.close(io);
            // Another method on a file; under the prefix the path is the
            // API's.
            if (target.under_prefix) return error.RouteNotFound;
            try ctx.response.setHeader("allow", "GET, HEAD");
            // OPTIONS: the methods of the file, as of a route's path.
            if (ctx.request.method == .OPTIONS) {
                _ = ctx.response.status(204);
                return;
            }
            return error.MethodNotAllowed;
        },
        .missing, .refused => return error.RouteNotFound,
        .failed => |err| {
            log.warn("static {s}: a file did not open: error.{t}; the response is 500 (request {s})", .{ mount.mount, err, ctx.requestId() });
            return error.ReadFailed;
        },
    }
}

/// Sends the file `open` left, on the connection's task, once the request
/// has ended within its deadline: without one, as the backend's write
/// timeout holds for it. Closes the file.
pub fn send(ctx: *Context, file: File) anyerror!void {
    defer file.opened.file.close(ctx.io());
    return sendFile(ctx, file.mount, file.opened);
}

/// The response of a file: 304 when the client has it, the range a GET
/// asks for, 416 for one past the end, else the whole file.
fn sendFile(ctx: *Context, mount: *const Mount, opened: resolve.Opened) anyerror!void {
    const res = &ctx.response;
    const size = opened.stat.size;
    var tag: [conditional.etag_max]u8 = undefined;
    const validators: conditional.Validators = .{
        .etag = conditional.etag(&tag, opened.stat.mtime, size),
        .last_modified = conditional.lastModified(opened.stat.mtime, Io.Clock.real.now(ctx.io())),
    };
    var modified: [date.len]u8 = undefined;
    try res.setHeader("etag", validators.etag);
    try res.setHeader("last-modified", date.formatImfFixdate(.fromNanoseconds(@as(i96, validators.last_modified) * std.time.ns_per_s), &modified));
    if (mount.cache_control) |value| try res.setHeader("cache-control", value);
    try res.setHeader("x-content-type-options", "nosniff");
    if (conditional.notModified(try fieldValues(ctx, "if-none-match"), ctx.request.header("if-modified-since"), validators)) {
        _ = res.status(304);
        return;
    }
    try res.setHeader("accept-ranges", "bytes");
    var start: u64 = 0;
    var length = size;
    // A range only for a GET, and only when If-Range lets it.
    if (ctx.request.method == .GET) if (ctx.request.header("range")) |value| {
        const applies = if (ctx.request.header("if-range")) |condition| conditional.ifRange(condition, validators) else true;
        if (applies) switch (conditional.range(value, size)) {
            .whole => {},
            .part => |part| {
                start = part.start;
                length = part.len;
                try res.setHeaderFmt("content-range", "bytes {d}-{d}/{d}", .{ part.start, part.start + part.len - 1, size });
                _ = res.status(206);
            },
            .unsatisfiable => {
                try res.setHeaderFmt("content-range", "bytes */{d}", .{size});
                _ = res.status(416);
                return;
            },
        };
    };
    return res.internal.sendFile(opened.file, mime.of(opened.name), start, length, "static");
}

/// The values of every field `name` of the request, in order.
fn fieldValues(ctx: *const Context, name: []const u8) error{OutOfMemory}![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    for (ctx.request.internal.exchange.fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) try values.append(ctx.internal.arena, f.value);
    }
    return values.items;
}

test {
    _ = resolve;
    _ = conditional;
}

const builtin = @import("builtin");
const testing = std.testing;
const TestingBackend = @import("testing/Backend.zig");
const route_decls = @import("routes.zig");
const mw = @import("middleware.zig");

/// The files of the tests, in a directory of their own under the working
/// directory: the roots `public` and `assets`, and `secret.txt` beside
/// them, outside every root.
const Site = struct {
    tmp: testing.TmpDir,
    /// The roots, relative to the working directory.
    public: []const u8,
    assets: []const u8,
    /// `public/data.bin`, 1000 bytes, and `public/large.bin`, 40 000.
    data: [1000]u8,
    large: [40_000]u8,

    fn create(site: *Site, arena: std.mem.Allocator) !void {
        site.tmp = testing.tmpDir(.{});
        errdefer site.tmp.cleanup();
        const io = testing.io;
        const dir = site.tmp.dir;
        for ([_][]const u8{ "public/sub", "public/docs", "public/empty", "public/.git", "public/api/v1", "public/assets", "assets" }) |sub| try dir.createDirPath(io, sub);
        for (&site.data, 0..) |*b, i| b.* = @truncate(i *% 31 +% i / 256);
        for (&site.large, 0..) |*b, i| b.* = @truncate(i *% 7 +% i / 251);
        for ([_][2][]const u8{
            .{ "secret.txt", "secret" },
            .{ "public/index.html", "<h1>home</h1>" },
            .{ "public/a.txt", "alpha" },
            .{ "public/sub/b.txt", "beta" },
            .{ "public/sub/.hidden", "hidden" },
            .{ "public/docs/index.html", "<h1>docs</h1>" },
            .{ "public/.env", "KEY=1" },
            .{ "public/.git/config", "[core]" },
            .{ "public/api/data.txt", "api data" },
            .{ "public/api/v1/ping", "a file" },
            .{ "public/assets/app.js", "shadowed" },
            .{ "assets/app.js", "console.log(1)" },
            .{ "public/data.bin", &site.data },
            .{ "public/large.bin", &site.large },
        }) |file| try dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
        site.public = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/public", .{site.tmp.sub_path});
        site.assets = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/assets", .{site.tmp.sub_path});
    }
};

/// A route under the server's prefix `/api`: `/api/v1/ping`, where
/// `public/api/v1/ping` is a file too.
const PingV1Controller = struct {
    pub const http_routes = route_decls.routes(.{ .prefix = "/v1", .methods = .{ .ping = route_decls.get("/ping", .{}) } });

    pub fn ping(_: *PingV1Controller, ctx: *Context) !void {
        try ctx.response.text("pong");
    }
};

/// A server of `PingV1Controller` with the prefix `/api` and the mounts
/// `statics`, started.
const Fixture = struct {
    ping: PingV1Controller = .{},
    backend: TestingBackend = undefined,
    server: Server = undefined,

    fn start(f: *Fixture, statics: anytype) !void {
        f.backend = .init(testing.allocator);
        f.server = try .init(testing.allocator, .{ .backend = f.backend.backend(), .prefix = "/api", .controllers = .{&f.ping}, .static = statics });
        f.server.start(testing.io) catch |err| {
            f.server.deinit(testing.io);
            return err;
        };
    }

    fn stop(f: *Fixture) void {
        f.server.deinit(testing.io);
        f.backend.deinit();
    }

    fn get(f: *Fixture, target: []const u8) !TestingBackend.Response {
        return f.backend.request(testing.io, .{ .method = .GET, .target = target });
    }

    fn request(f: *Fixture, method: std.http.Method, target: []const u8, headers: []const [2][]const u8) !TestingBackend.Response {
        return f.backend.request(testing.io, .{ .method = method, .target = target, .headers = headers });
    }

    /// The status of a GET of `target`, its body dropped.
    fn statusOf(f: *Fixture, target: []const u8) !u16 {
        var res = try f.get(target);
        defer res.deinit();
        return res.status;
    }
};

test "start fails with InvalidStaticRoot for a missing root or a file root" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var site: Site = undefined;
    try site.create(arena);
    defer site.tmp.cleanup();
    const level = testing.log_level;
    testing.log_level = .err; // each refusal is logged as a warning
    defer testing.log_level = level;

    const missing = try std.fmt.allocPrint(arena, "{s}/nothing", .{site.public});
    const file = try std.fmt.allocPrint(arena, "{s}/a.txt", .{site.public});
    for ([_][]const u8{ missing, file }) |root| {
        var ping: PingV1Controller = .{};
        var backend: TestingBackend = .init(testing.allocator);
        defer backend.deinit();
        var server = try Server.init(testing.allocator, .{ .backend = backend.backend(), .controllers = .{&ping}, .static = .{
            static("/assets", .{ .root = site.assets }),
            static("/", .{ .root = root }),
        } });
        defer server.deinit(testing.io);
        // The first root opens, the second does not: none stays open, and
        // nothing is accepted.
        try testing.expectError(error.InvalidStaticRoot, server.start(testing.io));
        for (server.mounts) |m| try testing.expectEqual(null, m.dir);
        try testing.expectEqual(Server.State.stopped, server.state());
        try testing.expectError(error.NotStarted, backend.request(testing.io, .{ .method = .GET, .target = "/assets/app.js" }));
        try testing.expectError(error.InvalidState, server.start(testing.io));
    }

    // A root that opens serves.
    var f: Fixture = .{};
    try f.start(.{static("/", .{ .root = site.public })});
    defer f.stop();
    try testing.expectEqual(200, try f.statusOf("/a.txt"));
}

test "two mounts with one prefix fail init" {
    var ping: PingV1Controller = .{};
    var backend: TestingBackend = .init(testing.allocator);
    defer backend.deinit();
    const b = backend.backend();
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidConfiguration, Server.init(gpa, .{ .backend = b, .controllers = .{&ping}, .static = .{ static("/assets", .{ .root = "a" }), static("/assets", .{ .root = "b" }) } }));
    try testing.expectError(error.InvalidConfiguration, Server.init(gpa, .{ .backend = b, .controllers = .{&ping}, .static = .{ static("/", .{ .root = "a" }), static("/x", .{ .root = "b" }), static("/", .{ .root = "c" }) } }));
    // The syntax of a mount is that of a prefix, and "/".
    for ([_][]const u8{ "", "assets", "/assets/", "//assets", "/a//b", "/a/../b", "/./a", "/a b", "/a%20b", "/{x}", "/a?b" }) |mount| {
        testing.expectError(error.InvalidConfiguration, Server.init(gpa, .{ .backend = b, .controllers = .{&ping}, .static = .{static(mount, .{ .root = "public" })} })) catch |err| {
            std.debug.print("mount {s}\n", .{mount});
            return err;
        };
    }
    // An index that is not one name, a SPA file a request could not name,
    // a Cache-Control that would split the head, no root.
    for ([_]StaticOptions{
        .{ .root = "public", .index = "a/index.html" },
        .{ .root = "public", .index = ".index.html" },
        .{ .root = "public", .index = "" },
        .{ .root = "public", .spa_fallback = ".env" },
        .{ .root = "public", .spa_fallback = "../index.html" },
        .{ .root = "public", .spa_fallback = "app//index.html" },
        .{ .root = "public", .spa_fallback = "con.html" },
        .{ .root = "public", .cache_control = "no-store\r\nx-a: 1" },
        .{ .root = "" },
    }) |options| {
        try testing.expectError(error.InvalidConfiguration, Server.init(gpa, .{ .backend = b, .controllers = .{&ping}, .static = .{static("/", options)} }));
    }

    // The strings come from the config: init copies them.
    const mount = try gpa.dupe(u8, "/assets");
    const root = try gpa.dupe(u8, "public/assets");
    const spa = try gpa.dupe(u8, "app/index.html");
    var server = Server.init(gpa, .{ .backend = b, .controllers = .{&ping}, .static = .{ static(mount, .{ .root = root, .spa_fallback = spa, .cache_control = "no-cache" }), static("/", .{ .root = "public", .index = null }) } }) catch |err| {
        for ([_][]const u8{ mount, root, spa }) |s| gpa.free(s);
        return err;
    };
    defer server.deinit(testing.io);
    for ([_][]const u8{ mount, root, spa }) |s| gpa.free(s);
    try testing.expectEqual(2, server.needs.static_mounts);
    const m = server.mounts[0];
    try testing.expectEqualStrings("/assets", m.mount);
    try testing.expectEqualStrings("public/assets", m.root);
    try testing.expectEqualStrings("index.html", m.index.?);
    try testing.expectEqualStrings("app", m.spa_fallback.?[0]);
    try testing.expectEqualStrings("index.html", m.spa_fallback.?[1]);
    try testing.expectEqualStrings("no-cache", m.cache_control.?);
    try testing.expectEqual(null, server.mounts[1].index);
}

fn memoryOfMounts(gpa: std.mem.Allocator) !void {
    var ping: PingV1Controller = .{};
    var backend: TestingBackend = .init(gpa);
    defer backend.deinit();
    var server = try Server.init(gpa, .{ .backend = backend.backend(), .controllers = .{&ping}, .static = .{
        static("/assets", .{ .root = "assets", .spa_fallback = "app/index.html", .cache_control = "no-cache" }),
        static("/", .{ .root = "public" }),
    } });
    server.deinit(testing.io);
}

test "init frees the mounts it took when memory runs out" {
    try testing.checkAllAllocationFailures(testing.allocator, memoryOfMounts, .{});
}

test "controllers win; the longest mount wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var site: Site = undefined;
    try site.create(arena_state.allocator());
    defer site.tmp.cleanup();
    var f: Fixture = .{};
    try f.start(.{ static("/", .{ .root = site.public }), static("/assets", .{ .root = site.assets }) });
    defer f.stop();

    // A route of a controller, though public/api/v1/ping is a file.
    var ping = try f.get("/api/v1/ping");
    defer ping.deinit();
    try testing.expectEqualStrings("pong", ping.body);
    // Its path takes another method: the controller's 405, not the mount's.
    var post = try f.request(.POST, "/api/v1/ping", &.{});
    defer post.deinit();
    try testing.expectEqual(405, post.status);
    try testing.expectEqualStrings("GET, HEAD, OPTIONS", post.header("allow").?);

    // /assets is longer than /: assets/app.js, not public/assets/app.js.
    var app = try f.get("/assets/app.js");
    defer app.deinit();
    try testing.expectEqual(200, app.status);
    try testing.expectEqualStrings("console.log(1)", app.body);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", app.header("content-type").?);
    // A file missing from the longest mount is 404: no shorter mount
    // stands in.
    try testing.expectEqual(404, try f.statusOf("/assets/missing.js"));
    // The rest of the site comes from /.
    var a = try f.get("/a.txt");
    defer a.deinit();
    try testing.expectEqualStrings("alpha", a.body);
    // Under the server's prefix, a path no route takes: still a file.
    var data = try f.get("/api/data.txt");
    defer data.deinit();
    try testing.expectEqualStrings("api data", data.body);
}

test "POST on a mount: 405 for a file, OPTIONS 204; 404 for a missing one and under the server prefix" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var site: Site = undefined;
    try site.create(arena_state.allocator());
    defer site.tmp.cleanup();
    var f: Fixture = .{};
    try f.start(.{static("/", .{ .root = site.public, .spa_fallback = "index.html" })});
    defer f.stop();

    // A file, and the index file of /: 405, the methods of a file.
    for ([_][]const u8{ "/a.txt", "/", "/docs" }) |target| {
        var res = try f.request(.POST, target, &.{});
        defer res.deinit();
        try testing.expectEqual(405, res.status);
        try testing.expectEqualStrings("GET, HEAD", res.header("allow").?);
        try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
    }
    var delete = try f.request(.DELETE, "/sub/b.txt", &.{});
    defer delete.deinit();
    try testing.expectEqual(405, delete.status);
    // OPTIONS on a file: 204 with its methods, as on the path of a route.
    var options = try f.request(.OPTIONS, "/a.txt", &.{});
    defer options.deinit();
    try testing.expectEqual(204, options.status);
    try testing.expectEqualStrings("GET, HEAD", options.header("allow").?);
    try testing.expectEqualStrings("", options.body);
    // No file there: 404, and the SPA file is for GET and HEAD only.
    for ([_]std.http.Method{ .POST, .OPTIONS }) |method| {
        for ([_][]const u8{ "/missing.txt", "/app/settings", "/.env", "/empty" }) |target| {
            var res = try f.request(method, target, &.{});
            defer res.deinit();
            try testing.expectEqual(404, res.status);
            try testing.expectEqual(null, res.header("allow"));
        }
    }
    // Under the server's prefix the path is the API's: 404 though a file
    // lies there.
    for ([_]std.http.Method{ .POST, .OPTIONS }) |method| {
        var api = try f.request(method, "/api/data.txt", &.{});
        defer api.deinit();
        try testing.expectEqual(404, api.status);
        try testing.expectEqual(null, api.header("allow"));
    }
}

test "static: .., %2e%2e, %2F, %5C, NUL, an absolute path and hidden files are 404; invalid UTF-8 is 400" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var site: Site = undefined;
    try site.create(arena_state.allocator());
    defer site.tmp.cleanup();
    var f: Fixture = .{};
    try f.start(.{static("/", .{ .root = site.public })});
    defer f.stop();

    // What is served, for comparison.
    try testing.expectEqual(200, try f.statusOf("/a.txt"));
    try testing.expectEqual(200, try f.statusOf("/sub/b.txt"));
    try testing.expectEqual(200, try f.statusOf("/sub/../a.txt"));
    for ([_][]const u8{
        // Dot segments never climb above the root: these name
        // public/secret.txt, which does not exist.
        "/../secret.txt",
        "/sub/../../secret.txt",
        "/%2e%2e/secret.txt",
        "/sub/%2E%2E/%2e%2E/secret.txt",
        "/.%2e/secret.txt",
        // A slash or a backslash inside a segment, encoded.
        "/..%2Fsecret.txt",
        "/sub%2F..%2F..%2Fsecret.txt",
        "/sub%2Fb.txt",
        "/..%5Csecret.txt",
        "/sub%5Cb.txt",
        "/sub%5C..%5C..%5Csecret.txt",
        // NUL.
        "/a.txt%00",
        "/a%00.txt",
        "/sub/b.txt%00.html",
        // Absolute paths: an empty segment, a drive, an encoded root.
        "//etc/passwd",
        "/sub//b.txt",
        "/C:/secret.txt",
        "/C:%5Csecret.txt",
        "/%2Fetc%2Fpasswd",
        "/%5C%5Cserver%5Cshare",
        // Hidden files and directories, as they are or encoded.
        "/.env",
        "/%2eenv",
        "/.git/config",
        "/.git",
        "/sub/.hidden",
    }) |target| {
        var res = try f.get(target);
        defer res.deinit();
        testing.expectEqual(404, res.status) catch |err| {
            std.debug.print("target {s}: {s}\n", .{ target, res.body });
            return err;
        };
        try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
    }
    // A path that is not UTF-8 once decoded is the server's 400 for every
    // path (design section 5): no file is opened for it.
    try testing.expectEqual(400, try f.statusOf("/a%ff.txt"));
    try testing.expectEqual(400, try f.statusOf("/sub/%c3%28"));
}

/// Creates the symbolic link `link` to `target` in `dir`; false when the
/// system does not let the test create one (Windows without the
/// privilege).
fn symLink(dir: Io.Dir, target: []const u8, link: []const u8, is_directory: bool) !bool {
    dir.symLink(testing.io, target, link, .{ .is_directory = is_directory }) catch |err| {
        std.debug.print("skipped: the system does not create a symbolic link here: {t}\n", .{err});
        return false;
    };
    return true;
}

test "static: a symlink inside the root is not served, nor a symlinked directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var site: Site = undefined;
    try site.create(arena_state.allocator());
    defer site.tmp.cleanup();
    const sep = std.fs.path.sep_str;
    const links = [_]struct { []const u8, []const u8, bool }{
        // To a file inside the root, and to one outside it.
        .{ "a.txt", "public" ++ sep ++ "link.txt", false },
        .{ ".." ++ sep ++ "secret.txt", "public" ++ sep ++ "out.txt", false },
        .{ ".." ++ sep ++ "a.txt", "public" ++ sep ++ "sub" ++ sep ++ "up.txt", false },
        // To a directory inside the root, and to the one above it.
        .{ "sub", "public" ++ sep ++ "linkdir", true },
        .{ "..", "public" ++ sep ++ "outdir", true },
        // A link to nothing.
        .{ "nothing", "public" ++ sep ++ "dangling", false },
    };
    for (links) |l| if (!try symLink(site.tmp.dir, l[0], l[1], l[2])) return error.SkipZigTest;
    var f: Fixture = .{};
    try f.start(.{static("/", .{ .root = site.public })});
    defer f.stop();

    try testing.expectEqual(200, try f.statusOf("/a.txt"));
    try testing.expectEqual(200, try f.statusOf("/sub/b.txt"));
    for ([_][]const u8{
        "/link.txt",
        "/out.txt",
        "/sub/up.txt",
        "/linkdir",
        "/linkdir/b.txt",
        "/outdir",
        "/outdir/secret.txt",
        "/outdir/public/a.txt",
        "/dangling",
    }) |target| {
        var res = try f.get(target);
        defer res.deinit();
        testing.expectEqual(404, res.status) catch |err| {
            std.debug.print("target {s}: {s}\n", .{ target, res.body });
            return err;
        };
    }
    // Nor the SPA file, nor another method, finds them.
    var post = try f.request(.POST, "/link.txt", &.{});
    defer post.deinit();
    try testing.expectEqual(404, post.status);
}

test "static: Windows names are refused on every system" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var site: Site = undefined;
    try site.create(arena_state.allocator());
    defer site.tmp.cleanup();
    const names = [_][]const u8{ "con", "CON.txt", "nul.txt", "Aux.html", "prn", "com1", "COM9.log", "lpt1.txt", "LPT9", "conin$", "a.txt.", "a.txt ", "a:b", "GIT~1" };
    // Elsewhere than on Windows they can be files: the rule refuses them,
    // not their absence.
    if (builtin.os.tag != .windows) {
        for (names) |name| try site.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(arena_state.allocator(), "public/{s}", .{name}), .data = "device" });
    }
    var f: Fixture = .{};
    try f.start(.{static("/", .{ .root = site.public })});
    defer f.stop();

    for ([_][]const u8{
        "/con",
        "/CON.txt",
        "/nul.txt",
        "/Aux.html",
        "/prn",
        "/com1",
        "/COM9.log",
        "/lpt1.txt",
        "/LPT9",
        "/conin$",
        "/sub/con",
        "/con/b.txt",
        // A dot or a space at the end, which Windows drops: a.txt.
        "/a.txt.",
        "/a.txt%20",
        // An alternate data stream, and a short name.
        "/a:b",
        "/a.txt::$DATA",
        "/GIT~1",
    }) |target| {
        var res = try f.get(target);
        defer res.deinit();
        testing.expectEqual(404, res.status) catch |err| {
            std.debug.print("target {s}: {s}\n", .{ target, res.body });
            return err;
        };
    }
}

test "static: a file with its type, length, nosniff and Cache-Control; HEAD without a body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var site: Site = undefined;
    try site.create(arena_state.allocator());
    defer site.tmp.cleanup();
    var f: Fixture = .{};
    try f.start(.{
        static("/assets", .{ .root = site.assets, .cache_control = "public, max-age=31536000, immutable" }),
        static("/", .{ .root = site.public }),
    });
    defer f.stop();

    var app = try f.get("/assets/app.js");
    defer app.deinit();
    try testing.expectEqual(200, app.status);
    try testing.expect(!app.aborted);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", app.header("content-type").?);
    try testing.expectEqualStrings("14", app.header("content-length").?);
    try testing.expectEqualStrings("nosniff", app.header("x-content-type-options").?);
    try testing.expectEqualStrings("public, max-age=31536000, immutable", app.header("cache-control").?);
    try testing.expectEqualStrings("bytes", app.header("accept-ranges").?);
    const tag = app.header("etag").?;
    try testing.expect(tag.len > 4 and tag[0] == '"' and tag[tag.len - 1] == '"' and std.mem.endsWith(u8, tag, "-e\""));
    const modified = app.header("last-modified").?;
    try testing.expect(date.parseHttpDate(modified) != null);
    try testing.expectEqualStrings("console.log(1)", app.body);
    // A mount without Cache-Control sends none.
    var a = try f.get("/a.txt");
    defer a.deinit();
    try testing.expectEqual(null, a.header("cache-control"));
    try testing.expectEqualStrings("text/plain; charset=utf-8", a.header("content-type").?);
    try testing.expectEqualStrings("nosniff", a.header("x-content-type-options").?);

    // HEAD: the same head, its length, no body.
    var head = try f.request(.HEAD, "/assets/app.js", &.{});
    defer head.deinit();
    try testing.expectEqual(200, head.status);
    try testing.expect(!head.aborted);
    try testing.expectEqualStrings("14", head.header("content-length").?);
    try testing.expectEqualStrings(tag, head.header("etag").?);
    try testing.expectEqualStrings("nosniff", head.header("x-content-type-options").?);
    try testing.expectEqualStrings("", head.body);

    // A file larger than the buffer goes out a buffer at a time, never
    // held whole, with its length.
    var large = try f.get("/large.bin");
    defer large.deinit();
    try testing.expectEqual(200, large.status);
    try testing.expectEqualStrings("application/octet-stream", large.header("content-type").?);
    try testing.expectEqualStrings("40000", large.header("content-length").?);
    try testing.expectEqualSlices(u8, &site.large, large.body);
    try testing.expectEqual(3, large.chunks.len);
    for (large.chunks) |chunk| try testing.expect(chunk.len <= Context.Response.buffer_size);
}

test "static: index file and SPA fallback, not under the server prefix" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var site: Site = undefined;
    try site.create(arena_state.allocator());
    defer site.tmp.cleanup();

    // Without a SPA file: a directory gives its index file, or nothing.
    {
        var f: Fixture = .{};
        try f.start(.{static("/", .{ .root = site.public })});
        defer f.stop();
        for ([_][2][]const u8{ .{ "/", "<h1>home</h1>" }, .{ "/docs", "<h1>docs</h1>" }, .{ "/docs/", "<h1>docs</h1>" } }) |row| {
            var res = try f.get(row[0]);
            defer res.deinit();
            try testing.expectEqual(200, res.status);
            try testing.expectEqualStrings("text/html; charset=utf-8", res.header("content-type").?);
            try testing.expectEqualStrings(row[1], res.body);
        }
        // No index file, no listing; no file, no SPA file.
        try testing.expectEqual(404, try f.statusOf("/empty"));
        try testing.expectEqual(404, try f.statusOf("/sub"));
        try testing.expectEqual(404, try f.statusOf("/app/settings"));
    }
    // With index = null a directory serves nothing.
    {
        var f: Fixture = .{};
        try f.start(.{static("/", .{ .root = site.public, .index = null })});
        defer f.stop();
        try testing.expectEqual(404, try f.statusOf("/"));
        try testing.expectEqual(404, try f.statusOf("/docs"));
        try testing.expectEqual(200, try f.statusOf("/docs/index.html"));
    }
    // A single-page application.
    {
        var f: Fixture = .{};
        try f.start(.{
            static("/assets", .{ .root = site.assets }),
            static("/", .{ .root = site.public, .spa_fallback = "index.html" }),
        });
        defer f.stop();
        // A path without a file, a directory without an index file: the
        // SPA file, with its type.
        for ([_][]const u8{ "/app/settings", "/todos/42", "/empty" }) |target| {
            var res = try f.get(target);
            defer res.deinit();
            try testing.expectEqual(200, res.status);
            try testing.expectEqualStrings("text/html; charset=utf-8", res.header("content-type").?);
            try testing.expectEqualStrings("<h1>home</h1>", res.body);
        }
        var head = try f.request(.HEAD, "/app/settings", &.{});
        defer head.deinit();
        try testing.expectEqual(200, head.status);
        try testing.expectEqualStrings("13", head.header("content-length").?);
        try testing.expectEqualStrings("", head.body);
        // Files stay files.
        var a = try f.get("/a.txt");
        defer a.deinit();
        try testing.expectEqualStrings("alpha", a.body);
        // Under the server's prefix: the API's 404, as problem+json.
        var api = try f.get("/api/v2/nothing");
        defer api.deinit();
        try testing.expectEqual(404, api.status);
        try testing.expectEqualStrings("application/problem+json", api.header("content-type").?);
        // A refused path is no path without a file; the longest mount has
        // no SPA file of its own.
        try testing.expectEqual(404, try f.statusOf("/.env"));
        try testing.expectEqual(404, try f.statusOf("/assets/missing.js"));
    }
}

test "conditional: If-None-Match beats If-Modified-Since" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var site: Site = undefined;
    try site.create(arena);
    defer site.tmp.cleanup();
    var f: Fixture = .{};
    try f.start(.{static("/", .{ .root = site.public, .cache_control = "no-cache" })});
    defer f.stop();

    var first = try f.get("/a.txt");
    defer first.deinit();
    const tag = try arena.dupe(u8, first.header("etag").?);
    const modified = try arena.dupe(u8, first.header("last-modified").?);

    // The client has the file: 304 with its validators and Cache-Control,
    // and no body.
    for ([_][]const [2][]const u8{
        &.{.{ "if-none-match", tag }},
        &.{.{ "if-none-match", try std.fmt.allocPrint(arena, "W/{s}", .{tag}) }},
        &.{.{ "if-none-match", try std.fmt.allocPrint(arena, "\"old\", {s}", .{tag}) }},
        &.{ .{ "if-none-match", "\"old\"" }, .{ "if-none-match", tag } },
        &.{.{ "if-none-match", "*" }},
        &.{.{ "if-modified-since", modified }},
        &.{.{ "if-modified-since", "Fri, 31 Dec 9999 23:59:59 GMT" }},
        // A tag that matches wins over a date that does not.
        &.{ .{ "if-none-match", tag }, .{ "if-modified-since", "Thu, 01 Jan 1970 00:00:00 GMT" } },
    }) |headers| {
        var res = try f.request(.GET, "/a.txt", headers);
        defer res.deinit();
        try testing.expectEqual(304, res.status);
        try testing.expectEqualStrings(tag, res.header("etag").?);
        try testing.expectEqualStrings(modified, res.header("last-modified").?);
        try testing.expectEqualStrings("no-cache", res.header("cache-control").?);
        try testing.expectEqualStrings("nosniff", res.header("x-content-type-options").?);
        try testing.expectEqual(null, res.header("content-length"));
        try testing.expectEqual(null, res.header("content-type"));
        try testing.expectEqualStrings("", res.body);
    }
    // A tag that does not match: the file, whatever If-Modified-Since says.
    for ([_][]const [2][]const u8{
        &.{.{ "if-none-match", "\"old\"" }},
        &.{ .{ "if-none-match", "\"old\"" }, .{ "if-modified-since", modified } },
        &.{.{ "if-modified-since", "Thu, 01 Jan 1970 00:00:00 GMT" }},
        &.{.{ "if-modified-since", "not a date" }},
    }) |headers| {
        var res = try f.request(.GET, "/a.txt", headers);
        defer res.deinit();
        try testing.expectEqual(200, res.status);
        try testing.expectEqualStrings("alpha", res.body);
    }
    var head = try f.request(.HEAD, "/a.txt", &.{.{ "if-none-match", tag }});
    defer head.deinit();
    try testing.expectEqual(304, head.status);
}

test "ranges: 206, a suffix range, several ranges, 416 with */N, If-Range" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var site: Site = undefined;
    try site.create(arena);
    defer site.tmp.cleanup();
    var f: Fixture = .{};
    try f.start(.{static("/", .{ .root = site.public })});
    defer f.stop();
    var first = try f.get("/data.bin");
    defer first.deinit();
    const tag = try arena.dupe(u8, first.header("etag").?);
    const modified = try arena.dupe(u8, first.header("last-modified").?);

    // One range: 206, its part of the file.
    for ([_]struct { []const [2][]const u8, []const u8, usize, usize }{
        .{ &.{.{ "range", "bytes=0-99" }}, "bytes 0-99/1000", 0, 100 },
        .{ &.{.{ "range", "bytes=-100" }}, "bytes 900-999/1000", 900, 100 },
        .{ &.{.{ "range", "bytes=900-" }}, "bytes 900-999/1000", 900, 100 },
        .{ &.{.{ "range", "bytes=990-5000" }}, "bytes 990-999/1000", 990, 10 },
        .{ &.{ .{ "range", "bytes=10-19" }, .{ "if-range", tag } }, "bytes 10-19/1000", 10, 10 },
        .{ &.{ .{ "range", "bytes=10-19" }, .{ "if-range", modified } }, "bytes 10-19/1000", 10, 10 },
    }) |row| {
        var res = try f.request(.GET, "/data.bin", row[0]);
        defer res.deinit();
        try testing.expectEqual(206, res.status);
        try testing.expectEqualStrings(row[1], res.header("content-range").?);
        try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d}", .{row[3]}), res.header("content-length").?);
        try testing.expectEqualSlices(u8, site.data[row[2]..][0..row[3]], res.body);
        try testing.expectEqualStrings("bytes", res.header("accept-ranges").?);
        try testing.expectEqualStrings("application/octet-stream", res.header("content-type").?);
    }
    // The whole file: several ranges, a malformed one, another unit, a
    // file changed since If-Range; and a HEAD, which ranges do not take.
    for ([_]struct { std.http.Method, []const [2][]const u8 }{
        .{ .GET, &.{.{ "range", "bytes=0-1,5-6" }} },
        .{ .GET, &.{.{ "range", "bytes=5-1" }} },
        .{ .GET, &.{.{ "range", "bytes=x-" }} },
        .{ .GET, &.{.{ "range", "items=0-1" }} },
        .{ .GET, &.{ .{ "range", "bytes=0-9" }, .{ "if-range", "\"stale\"" } } },
        .{ .GET, &.{ .{ "range", "bytes=0-9" }, .{ "if-range", try std.fmt.allocPrint(arena, "W/{s}", .{tag}) } } },
        .{ .GET, &.{ .{ "range", "bytes=0-9" }, .{ "if-range", "Thu, 01 Jan 1970 00:00:00 GMT" } } },
        .{ .HEAD, &.{.{ "range", "bytes=0-9" }} },
    }) |row| {
        var res = try f.request(row[0], "/data.bin", row[1]);
        defer res.deinit();
        try testing.expectEqual(200, res.status);
        try testing.expectEqual(null, res.header("content-range"));
        try testing.expectEqualStrings("1000", res.header("content-length").?);
        if (row[0] == .GET) try testing.expectEqualSlices(u8, &site.data, res.body);
    }
    // Past the end: 416 with the length of the file, no body.
    for ([_][]const u8{ "bytes=1000-", "bytes=5000-6000", "bytes=-0" }) |value| {
        var res = try f.request(.GET, "/data.bin", &.{.{ "range", value }});
        defer res.deinit();
        try testing.expectEqual(416, res.status);
        try testing.expectEqualStrings("bytes */1000", res.header("content-range").?);
        try testing.expectEqualStrings("0", res.header("content-length").?);
        try testing.expectEqualStrings("", res.body);
    }
    // A range past the buffer, sent a buffer at a time.
    var part = try f.request(.GET, "/large.bin", &.{.{ "range", "bytes=1000-39999" }});
    defer part.deinit();
    try testing.expectEqual(206, part.status);
    try testing.expectEqualStrings("bytes 1000-39999/40000", part.header("content-range").?);
    try testing.expectEqualSlices(u8, site.large[1000..], part.body);
    try testing.expect(part.chunks.len >= 2);
}

/// Every request runs it: it sleeps past the server's deadline of 5 ms.
const SlowRun = struct {
    pub fn run(ctx: *Context) !mw.MiddlewareResult {
        try ctx.io().sleep(.fromMilliseconds(100), .awake);
        return .next;
    }
};

fn expectTimeout(res: *TestingBackend.Response) !void {
    try testing.expectEqualStrings("application/problem+json", res.header("content-type").?);
    try testing.expect(std.mem.find(u8, res.body, "\"code\":\"timeout\"") != null);
}

/// Every response waits 100 ms right before its head goes out, past the
/// server's deadline of 50 ms.
const SlowHead = struct {
    pub fn onResponse(ctx: *Context) !void {
        try ctx.io().sleep(.fromMilliseconds(100), .awake);
    }
};

test "static: the server's deadline holds for its middleware and the open of the file, not for the file going out" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var site: Site = undefined;
    try site.create(arena_state.allocator());
    defer site.tmp.cleanup();
    var ping: PingV1Controller = .{};
    {
        var backend: TestingBackend = .init(testing.allocator);
        defer backend.deinit();
        var server = try Server.init(testing.allocator, .{
            .backend = backend.backend(),
            .prefix = "/api",
            .controllers = .{&ping},
            .middleware = .{SlowRun},
            .request_timeout = std.Io.Duration.fromMilliseconds(5),
            .static = .{static("/", .{ .root = site.public })},
        });
        defer server.deinit(testing.io);
        try server.start(testing.io);

        // A route, a file and a path without one: the middleware runs past
        // the deadline, and each gets 504.
        for ([_][]const u8{ "/api/v1/ping", "/a.txt", "/missing.txt" }) |target| {
            var res = try backend.request(testing.io, .{ .method = .GET, .target = target });
            defer res.deinit();
            testing.expectEqual(504, res.status) catch |err| {
                std.debug.print("GET {s}\n", .{target});
                return err;
            };
            try expectTimeout(&res);
        }
    }
    {
        var backend: TestingBackend = .init(testing.allocator);
        defer backend.deinit();
        var server = try Server.init(testing.allocator, .{
            .backend = backend.backend(),
            .prefix = "/api",
            .controllers = .{&ping},
            .middleware = .{SlowHead},
            .request_timeout = std.Io.Duration.fromMilliseconds(50),
            .static = .{static("/", .{ .root = site.public })},
        });
        defer server.deinit(testing.io);
        try server.start(testing.io);

        // The file is open within the deadline; it goes out after, without
        // one, whole.
        var file = try backend.request(testing.io, .{ .method = .GET, .target = "/large.bin" });
        defer file.deinit();
        try testing.expectEqual(200, file.status);
        try testing.expect(!file.aborted);
        try testing.expectEqualSlices(u8, &site.large, file.body);
    }
}
