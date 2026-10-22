//! The shop of the design of zefir.App, against NATS and MongoDB: HTTP on
//! its port, rpc over NATS, two databases of one client of Mongo. SIGTERM
//! or Ctrl+C stops it gracefully. Settings: Config.zig.

const std = @import("std");
const zio = @import("zio");
const zefir = @import("zefir");
const Config = @import("Config.zig");
const AppModule = @import("app_module.zig").AppModule;

/// zefir and App write to std.log; this sends their records to the logger
/// of the application.
pub const std_options: std.Options = .{ .logFn = zefir.log.stdLogFn };

/// A panic prints its message and exits with code 3 instead of aborting, so
/// that a broken run of the tests ends at once and says why.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    zefir.confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "SHOP_",
        .sources = &.{.osEnv()},
    });

    // The logger outlives the runtime, so it is made before App.
    const logger: zefir.log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();

    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // The ready objects: a tuple of pointers, which App matches against
    // AppModule.module.values by type, in any order. App builds the rest.
    var app = try zefir.App(AppModule).init(init.gpa, io, .{ &config, &logger }, .{ .shutdown_timeout = .fromSeconds(25) });
    defer app.deinit();

    // SIGTERM and Ctrl+C begin a graceful stop. Signals are zio's: std.Io
    // has none.
    var on_terminate = try io.concurrent(stopOnSignal, .{ &app, .terminate });
    defer on_terminate.cancel(io) catch {};
    var on_interrupt = try io.concurrent(stopOnSignal, .{ &app, .interrupt });
    defer on_interrupt.cancel(io) catch {};

    try app.run();
}

/// The type of App is named as it is: zefir.App(AppModule).
fn stopOnSignal(app: *zefir.App(AppModule), kind: zio.SignalKind) !void {
    var signal = try zio.Signal.init(kind);
    defer signal.deinit(); // after it, a second Ctrl+C ends the process at once
    try signal.wait();
    app.requestStop(); // from any task; never waits; a second call does nothing
}
