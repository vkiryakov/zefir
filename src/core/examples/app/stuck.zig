//! A server that cannot stop: its handler is deaf to its cancelation and
//! holds a request forever. A task plays the client and, once the request
//! is in the handler, Ctrl+C. When the stop runs out of time, `run` writes
//! which bean did not stop and ends the process with code 1. The server
//! runs on the backend of zefir-http in memory, so the program needs no
//! network.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;

/// App writes each step to std.log, at info; this program has no logger of
/// its own, so std.log writes to stderr.
pub const std_options: std.Options = .{ .log_level = .info };

/// What the program sees of the request: a root value.
const Probe = struct { entered: std.Io.Event = .unset };

/// `GET /report`, which never ends.
const ReportController = struct {
    probe: *Probe,

    pub const http_routes = http.routes(.{ .methods = .{ .report = http.get("/report", .{}) } });

    pub fn report(self: *ReportController, ctx: *http.Context) !void {
        self.probe.entered.set(ctx.io());
        // Deaf to its cancelation: nothing ends this wait.
        var never: std.Io.Event = .unset;
        never.waitUncancelable(ctx.io());
    }
};

pub const AppModule = struct {
    pub const module: zefir.app.Module = .{
        .providers = &.{http.testing.Backend},
        .controllers = &.{ReportController},
        .factories = &.{Servers},
        .values = &.{*Probe},
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, backend: *http.testing.Backend, controllers: zefir.app.Controllers(AppModule)) !http.Server {
            return .init(gpa, .{ .controllers = controllers }, .{ .listen = .{ .backend = backend.backend() } });
        }
    };
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var probe: Probe = .{};
    // A stop of 200 ms: less than the 250 ms a server keeps for its own
    // end, so the server gives up at once instead of near the deadline.
    var app = try zefir.App(AppModule).init(init.gpa, io, .{&probe}, .{ .shutdown_timeout = .fromMilliseconds(200) });
    defer app.deinit();

    var client = try io.concurrent(requestReport, .{ &app, io });
    defer client.cancel(io) catch {};
    var ctrl_c = try io.concurrent(pressCtrlC, .{ &app, &probe, io });
    defer ctrl_c.cancel(io) catch {};

    // Never returns: the stop runs out of time, and run ends the process.
    try app.run();
}

/// The client: once App runs, a request of the report.
fn requestReport(app: *zefir.App(AppModule), io: std.Io) !void {
    while (!app.isReady()) try io.sleep(.fromMilliseconds(1), .awake);
    const backend: *http.testing.Backend = app.get(http.testing.Backend);
    var res = try backend.request(io, .{ .method = .GET, .target = "/report" });
    res.deinit();
}

/// What Ctrl+C does in a service, once the request is in the handler.
fn pressCtrlC(app: *zefir.App(AppModule), probe: *Probe, io: std.Io) !void {
    try probe.entered.wait(io);
    app.requestStop();
}
