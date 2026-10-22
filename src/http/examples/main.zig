//! The todo service of the guide, on the network: its settings come from
//! the environment through confy, it logs with zefir-log, runs on zio and
//! serves on `http.native`. Ctrl+C or SIGTERM stops it gracefully.
//!
//! Settings, from the environment or a file `.env`:
//!
//!   APP_AUTH_ANN_TOKEN   the token of Ann, who may read and delete todos
//!   APP_AUTH_BOB_TOKEN   the token of Bob, who may not delete them
//!   APP_PORT             8080 by default; 0 takes a free port
//!   APP_PUBLIC_DIR       the static files, `public` by default
//!   APP_CORS_ORIGIN      the origin of a page on another site that may
//!                        call the API; http://localhost:5173 by default
//!
//! In tests/http, `zig build examples` runs it and sends it the requests
//! of the guide.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");
const log = @import("log");
const zio = @import("zio");
const auth = @import("auth.zig");
const Cors = @import("cors.zig").Cors;
const errors = @import("errors.zig");
const mw = @import("middleware.zig");
const Billing = @import("Billing.zig");
const HealthController = @import("HealthController.zig");
const SessionController = @import("SessionController.zig");
const TodoRepository = @import("TodoRepository.zig");
const TodosV1Controller = @import("TodosV1Controller.zig");

/// zefir-http logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    auth: struct {
        ann_token: confy.Secret,
        bob_token: confy.Secret,
    },
    port: u16 = 8080,
    public_dir: []const u8 = "public",
    cors_origin: []const u8 = "http://localhost:5173",
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{ .env(".env"), .osEnv() },
    });
    // The logger outlives the runtime, so it takes `init.io`, through which
    // the tasks of the runtime may log too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    // One runtime for the service, an executor per CPU core: every request
    // runs in a task of its own on it.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();
    const gpa = init.gpa;

    // What the handlers use. It outlives the server: its deinit comes after
    // the server's, which runs first, in the reverse order of the defers.
    var repo: TodoRepository = .init(gpa);
    defer repo.deinit();
    var billing: Billing = .{};
    var live: http.sse.Manager = .init(gpa, .{});
    defer live.deinit(io);

    // The objects of the middleware; the server borrows them.
    const users = [_]auth.TokenAuth.User{
        .{ .token = config.auth.ann_token, .id = "ann", .permissions = &.{ "todos", "todos:delete" } },
        .{ .token = config.auth.bob_token, .id = "bob", .permissions = &.{"todos"} },
    };
    var token_auth: auth.TokenAuth = .{ .users = &users };
    const origins = [_][]const u8{config.cors_origin};
    var cors: Cors = .{ .origins = &origins };
    var access_log: mw.AccessLog = .{ .logger = logger.scoped("access") };
    var plans: mw.PlanLookup = .{ .billing = &billing, .repo = &repo };
    var app_errors: errors.AppErrors = .{};

    var todos_v1: TodosV1Controller = .{ .repo = &repo, .live = &live, .plans = &plans };
    var sessions: SessionController = .{ .token_auth = &token_auth, .live = &live };
    var health: HealthController = .{};

    // The network: connections, the strict HTTP/1.1 parser, keep-alive.
    var native: http.native.Backend = try .init(gpa, .{ .port = config.port });
    defer native.deinit();
    var server = try http.Server.init(gpa, .{
        .controllers = .{ &todos_v1, &sessions, &health },
        // Every request runs these, in this order, before its route is chosen.
        .middleware = .{ mw.requestId, &access_log, http.onResponse(mw.securityHeaders), &cors, &token_auth },
        .error_handler = &app_errors,
    }, .{
        .listen = .{ .backend = native.backend() },
        // Before the routes of the controllers: /api/v1/todos, /api/health.
        .prefix = "/api",
        // The page and its files; a path without a file gets index.html, so
        // that the page's own router reads the path.
        .static = &.{http.static("/", .{ .root = config.public_dir, .spa_fallback = "index.html" })},
    });
    defer server.deinit(io);

    try server.start(io);
    app.info("Serving", .{ .port = native.port() });

    // Ctrl+C or SIGTERM begins a graceful stop; `wait` returns once it is over.
    var on_interrupt = try io.concurrent(stopOnSignal, .{ io, &server, app, .interrupt });
    defer on_interrupt.cancel(io) catch {};
    var on_terminate = try io.concurrent(stopOnSignal, .{ io, &server, app, .terminate });
    defer on_terminate.cancel(io) catch {};
    try server.wait(io);
    app.info("Stopped", .{});
}

/// Waits for the signal `kind`, then asks the server to stop. A handler of
/// the system's signals may not call `std.Io`, so a task waits for it.
fn stopOnSignal(io: std.Io, server: *http.Server, app: log.Logger, kind: zio.SignalKind) !void {
    var signal = try zio.Signal.init(kind);
    defer signal.deinit();
    try signal.wait();
    app.info("Stopping", .{ .signal = @tagName(kind) });
    server.requestStop(io);
}
