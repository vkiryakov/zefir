//! An App whose HTTP server cannot stop: a handler deaf to its cancelation
//! holds a request forever, and the stop has 200 ms. SIGTERM begins the
//! stop; when it runs out of time, `run` writes which bean did not stop and
//! ends the process with code 1. The end-to-end tests start it, send it the
//! request that never ends, SIGTERM, and read stderr.
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

/// `GET /hang`: a request that never ends, whatever the server asks.
const Deaf = struct {
    pub const http_routes = http.routes(.{ .methods = .{ .hang = http.get("/hang", .{}) } });

    pub fn hang(_: *Deaf, ctx: *http.Context) !void {
        // The tests wait for this line before they send SIGTERM.
        std.log.scoped(.deaf).info("a request that never ends", .{});
        var never: std.Io.Event = .unset;
        never.waitUncancelable(ctx.io());
    }
};

const Root = struct {
    pub const module: zefir.app.Module = .{
        .controllers = &.{Deaf},
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

    var app = try zefir.App(Root).init(init.gpa, io, .{&config}, .{ .shutdown_timeout = .fromMilliseconds(200) });
    defer app.deinit();

    var on_terminate = try io.concurrent(stopOnSignal, .{ &app, .terminate });
    defer on_terminate.cancel(io) catch {};
    var on_interrupt = try io.concurrent(stopOnSignal, .{ &app, .interrupt });
    defer on_interrupt.cancel(io) catch {};

    // Never returns here: the stop runs out of time, and run ends the
    // process with code 1.
    try app.run();
}

fn stopOnSignal(app: *zefir.App(Root), kind: zio.SignalKind) !void {
    var signal = try zio.Signal.init(kind);
    defer signal.deinit();
    try signal.wait();
    app.requestStop();
}
