//! The shop: settings from the environment through confy, a logger, a zio
//! runtime, and App, which builds the rest out of the modules. Ctrl+C or
//! SIGTERM stops it gracefully.
//!
//! It keeps everything in memory and runs alone: it needs no database and
//! no NATS.
//!
//! Settings, from the environment:
//!
//!   SHOP_PORT   the port of the HTTP server; 8080 by default

const std = @import("std");
const zio = @import("zio");
const zefir = @import("zefir");
const Config = @import("Config.zig");
const AppModule = @import("app_module.zig").AppModule;

/// zefir and App write to std.log; this sends their records to the logger.
pub const std_options: std.Options = .{ .logFn = zefir.log.stdLogFn };

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    zefir.confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "SHOP_",
        .sources = &.{.osEnv()},
    });

    // The logger outlives the runtime, so it is made before it, on
    // `init.io`, through which the tasks of the runtime may log too.
    const logger: zefir.log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();

    // One runtime for the shop, an executor per CPU core.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // The ready objects, a tuple of pointers: App matches them against
    // AppModule.module.values by type, in any order. It builds the rest.
    var app = try zefir.App(AppModule).init(init.gpa, io, .{ &config, &logger }, .{});
    defer app.deinit();

    // SIGTERM and Ctrl+C begin a graceful stop. Signals are zio's: std.Io
    // has none.
    var on_terminate = try io.concurrent(stopOnSignal, .{ &app, .terminate });
    defer on_terminate.cancel(io) catch {};
    var on_interrupt = try io.concurrent(stopOnSignal, .{ &app, .interrupt });
    defer on_interrupt.cancel(io) catch {};

    // Starts every bean, waits until the stop is over, and returns.
    try app.run();
}

/// Waits for the signal `kind`, then asks App to stop. The type of App is
/// named as it is: zefir.App(AppModule).
fn stopOnSignal(app: *zefir.App(AppModule), kind: zio.SignalKind) !void {
    var signal = try zio.Signal.init(kind);
    // After it, a second Ctrl+C ends the process at once.
    defer signal.deinit();
    try signal.wait();
    // From any task; it never waits, and a second call does nothing.
    app.requestStop();
}
