//! An App with an HTTP server on zio that SIGTERM or Ctrl+C stops, as the
//! `main` of a service does: two tasks wait for the signals and ask App to
//! stop, and `run` returns once the stop is over. The end-to-end tests
//! start it, send it a request and SIGTERM, and read its log on stderr.
//!
//! Settings, from the environment:
//!
//!   APP_PORT   the port of the server, on 127.0.0.1

const std = @import("std");
const zio = @import("zio");
const zefir = @import("zefir");

const http = zefir.http;

/// A panic prints its message and exits with code 3 instead of aborting.
pub const panic = std.debug.FullPanic(exitOnPanic);

/// App writes each start and stop to std.log, at info: here on stderr.
pub const std_options: std.Options = .{ .log_level = .info };

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

const Config = struct {
    port: u16,
};

/// `GET /hello`.
const Hello = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .hello = http.get("/hello", .{}) } });

    pub fn hello(_: *Hello, ctx: *http.Context) !void {
        try ctx.response.text("hello");
    }
};

const Root = struct {
    pub const module: zefir.app.Module = .{
        .controllers = &.{Hello},
        .factories = &.{Servers},
        .values = &.{*const Config},
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, config: *const Config, controllers: zefir.app.Controllers(Root)) !http.Server {
            return .init(gpa, .{ .controllers = controllers }, .{
                .listen = .{ .native = .{ .address = "127.0.0.1", .port = config.port } },
            });
        }
    };
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    zefir.confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });

    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    var app = try zefir.App(Root).init(init.gpa, io, .{&config}, .{});
    defer app.deinit();

    // SIGTERM and Ctrl+C begin a graceful stop. Signals are zio's: std.Io
    // has none.
    var on_terminate = try io.concurrent(stopOnSignal, .{ &app, .terminate });
    defer on_terminate.cancel(io) catch {};
    var on_interrupt = try io.concurrent(stopOnSignal, .{ &app, .interrupt });
    defer on_interrupt.cancel(io) catch {};

    try app.run();
}

fn stopOnSignal(app: *zefir.App(Root), kind: zio.SignalKind) !void {
    var signal = try zio.Signal.init(kind);
    // After it, a second signal of this kind ends the process at once.
    defer signal.deinit();
    try signal.wait();
    app.requestStop();
}
