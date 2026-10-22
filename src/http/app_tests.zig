//! `http.Server` under `core.App`: a factory builds the server from the
//! controllers App gives it, on a backend App builds too; App starts the
//! server, watches its `wait` and stops it within its deadline.
const std = @import("std");
const core = @import("core");
const http = @import("root.zig");

const testing = std.testing;

/// `GET /livez`: a controller without fields, as many health checks are.
const Health = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .livez = http.get("/livez", .{}) } });

    pub fn livez(_: *Health, _: *http.Context) !http.Json(struct { ok: bool }) {
        return .{ .value = .{ .ok = true } };
    }
};

/// Middleware App builds: it stamps each response with the state of App,
/// which App gives it as a field.
const Stamp = struct {
    status: *const core.app.Status,

    pub fn onResponse(self: *Stamp, ctx: *http.Context) !void {
        try ctx.response.setHeader("x-app-state", @tagName(self.status.state()));
    }
};

const Root = struct {
    pub const module: core.app.Module = .{
        .providers = &.{ http.testing.Backend, Stamp },
        .controllers = &.{Health},
        .factories = &.{Servers},
    };

    pub const Servers = struct {
        pub fn httpServer(
            gpa: std.mem.Allocator,
            backend: *http.testing.Backend,
            stamp: *Stamp,
            controllers: core.app.Controllers(Root),
        ) !http.Server {
            return .init(gpa, .{ .controllers = controllers, .middleware = .{stamp} }, .{
                .listen = .{ .backend = backend.backend() },
            });
        }
    };
};

/// Silences the warnings of a test that makes App or the server warn.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

test "http.Server under core.App: a request, then a stop" {
    const io = testing.io;
    var app = try core.App(Root).init(testing.allocator, io, .{}, .{});
    defer app.deinit();
    try app.start();

    const backend: *http.testing.Backend = app.get(http.testing.Backend);
    var res = try backend.request(io, .{ .method = .GET, .target = "/livez" });
    defer res.deinit();
    try testing.expectEqual(200, res.status);
    try testing.expectEqualStrings("{\"ok\":true}", res.body);
    try testing.expectEqualStrings("running", res.header("x-app-state").?);

    app.requestStop();
    try app.wait();
    try testing.expectEqual(core.app.State.stopped, app.state());
    try testing.expectEqual(null, app.failure());
}

test "a backend that fails stops the App" {
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var app = try core.App(Root).init(testing.allocator, io, .{}, .{});
    defer app.deinit();
    try app.start();

    app.get(http.testing.Backend).fail(io, error.Unavailable);
    try testing.expectError(error.Unavailable, app.wait());
    const failure = app.failure().?;
    try testing.expectEqualStrings("Root.Servers.httpServer", failure.bean);
    try testing.expectEqual(core.app.Failure.Step.wait, failure.step);
    try testing.expectEqual(error.Unavailable, failure.err);
}

/// What the test sees of the request of `Late`.
const Probe = struct { entered: std.Io.Event = .unset };

/// `GET /late`: holds its request until the stop cancels it, then works on
/// for 1100 ms with cancelation blocked, as a handler that finishes a write
/// it began.
const Late = struct {
    probe: *Probe,

    pub const http_routes = http.routes(.{ .methods = .{ .late = http.get("/late", .{}) } });

    pub fn late(self: *Late, ctx: *http.Context) !void {
        const io = ctx.io();
        self.probe.entered.set(io);
        var never: std.Io.Event = .unset;
        never.wait(io) catch |err| {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            io.sleep(.fromMilliseconds(1100), .awake) catch {};
            return err;
        };
    }
};

const LateRoot = struct {
    pub const module: core.app.Module = .{
        .providers = &.{http.testing.Backend},
        .controllers = &.{Late},
        .factories = &.{Servers},
        .values = &.{*Probe},
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, backend: *http.testing.Backend, controllers: core.app.Controllers(LateRoot)) !http.Server {
            return .init(gpa, .{ .controllers = controllers }, .{
                .listen = .{ .backend = backend.backend() },
                .shutdown_grace = .fromSeconds(10),
                .finish_timeout = .fromSeconds(1),
            });
        }
    };
};

fn requestLate(backend: *http.testing.Backend, io: std.Io) http.testing.RequestError!http.testing.Response {
    return backend.request(io, .{ .method = .GET, .target = "/late" });
}

test "a request that ends only after its cancelation, late in its budget: the App's wait returns {}" {
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var probe: Probe = .{};
    var app = try core.App(LateRoot).init(testing.allocator, io, .{&probe}, .{ .shutdown_timeout = .fromSeconds(3) });
    defer app.deinit();
    try app.start();

    var pending = try io.concurrent(requestLate, .{ app.get(http.testing.Backend), io });
    defer if (pending.await(io)) |res| {
        var r = res;
        r.deinit();
    } else |_| {};
    try probe.entered.wait(io);

    // The grace ends 1 s, .finish_timeout (1 s) and 250 ms before App's
    // deadline, 3 s away, so 750 ms after the stop began. The canceled
    // request ends 1100 ms later, past the second the server keeps for
    // canceled requests, and the server's shutdown returns before the last
    // 250 ms. The 900 ms left over hold under ThreadSanitizer on a busy
    // machine, where a wake-up comes hundreds of milliseconds late.
    const asked = std.Io.Clock.awake.now(io);
    app.requestStop();
    try app.wait();
    const took = asked.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(took >= 1700 and took < 3000);
    try testing.expectEqual(core.app.State.stopped, app.state());
    try testing.expectEqual(null, app.failure());
}
