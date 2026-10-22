//! A graceful stop. Two calls run when the server is asked to stop: a
//! short one ends within the grace and gets its response; a long one is
//! canceled when the grace runs out, and its client gets `cancelled`. A
//! call that comes after the stop is refused at once. So is a third call
//! while the two run: the server holds two calls at most.

const std = @import("std");
const confy = @import("confy");
const log = @import("log");
const rpc = @import("rpc");

// The contract of a reports service; a real one lives in its own package,
// as users-api does.
const BuildRequest = struct { name: []const u8, ms: u32 };
const Report = struct { name: []const u8, rows: u64 };
const ReportApi = rpc.Contract(.{
    .name = "reports",
    .version = 1,
    .methods = .{ .build = rpc.method(BuildRequest, Report) },
});

const Config = struct {
    shutdown: struct {
        /// How long the calls in flight may still run after the stop begins.
        grace_ms: u32 = 1000,
    } = .{},
};

/// Builds a report in `ms` milliseconds.
const Reports = struct {
    /// Set once two calls run: then the program begins the stop.
    both_running: std.Io.Event = .unset,
    running: std.atomic.Value(u32) = .init(0),

    pub const rpc_handler = rpc.implement(ReportApi, .{
        .defaults = .{ .timeout_ms = 30_000 },
    });

    pub fn build(self: *Reports, ctx: *rpc.Context, req: BuildRequest) std.Io.Cancelable!Report {
        if (self.running.fetchAdd(1, .acq_rel) + 1 == 2) self.both_running.set(ctx.io());
        // A wait through ctx.io() is where the stop cancels the call once
        // the grace is over.
        try ctx.io().sleep(.fromMilliseconds(req.ms), .awake);
        return .{ .name = req.name, .rows = 1200 };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();
    const app = logger.scoped("app");

    var reports: Reports = .{};
    var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer memory.deinit(io);
    var server = try rpc.Server.init(gpa, .{
        .handlers = .{&reports},
    }, .{
        .transport = memory.serverTransport(),
        .shutdown_grace = .fromMilliseconds(config.shutdown.grace_ms),
        // Two calls at once; one more is refused at admission.
        .limits = .{ .max_inflight = 2 },
    });
    defer server.deinit(io);
    try server.start(io);
    app.info("Serving", .{ .state = server.state(), .ready = server.isReady() });

    var client = try rpc.Client.init(gpa, .{}, .{ .transport = memory.clientTransport() });
    defer client.deinit();

    // Two calls in tasks of their own; the stop begins while both run. On an
    // error before their awaits, the calls are canceled and their results
    // freed.
    var daily = try io.concurrent(buildReport, .{ &client, io, "daily", 500 });
    errdefer discard(daily.cancel(io));
    var yearly = try io.concurrent(buildReport, .{ &client, io, "yearly", 10_000 });
    errdefer discard(yearly.cancel(io));
    try reports.both_running.wait(io);

    // The server holds two calls already: a third is refused at once, and
    // its client knows that it did not run.
    logOutcome(app, "monthly", buildReport(&client, io, "monthly", 100));

    app.info("Stopping", .{ .grace_ms = config.shutdown.grace_ms });
    // requestStop and a wait until the server has stopped; the stop ends
    // 250 ms before this deadline at the latest.
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake });
    try server.shutdown(io, deadline);
    app.info("Stopped", .{ .state = server.state() });

    logOutcome(app, "daily", daily.await(io));
    logOutcome(app, "yearly", yearly.await(io));
    logOutcome(app, "weekly", buildReport(&client, io, "weekly", 100));
}

fn buildReport(client: *rpc.Client, io: std.Io, name: []const u8, ms: u32) rpc.Client.CallError!rpc.Client.Result(Report) {
    return client.call(io, .root, ReportApi.build, .{ .name = name, .ms = ms }, .{});
}

fn discard(built: rpc.Client.CallError!rpc.Client.Result(Report)) void {
    var result = built catch return;
    result.deinit();
}

fn logOutcome(app: log.Logger, name: []const u8, built: rpc.Client.CallError!rpc.Client.Result(Report)) void {
    var result = built catch |err| return app.warn("Report not sent", .{ .name = name, .reason = err });
    defer result.deinit();
    switch (result.outcome) {
        .ok => |report| app.info("Report built", .{ .name = report.name, .rows = report.rows }),
        .failure => |failure| app.warn("Report failed", .{ .name = name, .code = failure.code, .reason = failure.message, .refused = result.refused }),
    }
}
