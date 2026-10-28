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
//! The objects of the service, its server and its OpenAPI document are
//! built in Service.zig, for `main` and the tests alike.

const std = @import("std");
const confy = @import("confy");
const http = @import("http");
const log = @import("log");
const zio = @import("zio");
const auth = @import("auth.zig");
const Service = @import("Service.zig");

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

    // The users and their tokens, and the origin of CORS, from the
    // settings; the service borrows them.
    const users = [_]auth.TokenAuth.User{
        .{ .token = config.auth.ann_token, .id = "ann", .permissions = &.{ "todos", "todos:delete" } },
        .{ .token = config.auth.bob_token, .id = "bob", .permissions = &.{"todos"} },
    };
    const origins = [_][]const u8{config.cors_origin};

    // The network: connections, the strict HTTP/1.1 parser, keep-alive.
    var native: http.native.Backend = try .init(gpa, .{ .port = config.port });
    defer native.deinit();
    var service: Service = .{ .users = &users, .origins = &origins, .public_dir = config.public_dir, .logger = logger };
    try service.start(gpa, io, native.backend());
    // It runs before the defers above: the server stops before its backend.
    defer service.deinit(gpa, io);
    app.info("Serving", .{ .port = native.port() });

    // Ctrl+C or SIGTERM begins a graceful stop; `wait` returns once it is over.
    var on_interrupt = try io.concurrent(stopOnSignal, .{ io, &service.server, app, .interrupt });
    defer on_interrupt.cancel(io) catch {};
    var on_terminate = try io.concurrent(stopOnSignal, .{ io, &service.server, app, .terminate });
    defer on_terminate.cancel(io) catch {};
    try service.server.wait(io);
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
