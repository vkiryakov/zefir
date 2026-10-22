//! The NATS transport on zefir-nats against the conformance suite of rpc,
//! with a live broker: every check on a fresh connection to the restart
//! server, and T17, which stops and starts that server.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const rpc = @import("rpc");
const rpc_nats = @import("rpc-nats");
const nats = @import("nats");
const root = @import("root.zig");
const services = @import("services.zig");

const conformance = rpc.testing.conformance;
const servers = root.servers;

/// A fresh connection and transport for every check; both sides share the
/// connection, as one application does.
const Harness = struct {
    nc: nats.Client = undefined,
    bus: rpc_nats.Transport = undefined,

    pub fn setUp(h: *Harness, io: Io, gpa: std.mem.Allocator) !conformance.Pair {
        h.nc = try .init(gpa, io, .{ .servers = &.{servers.restart}, .reconnect = services.fast_reconnect });
        errdefer h.nc.deinit();
        try h.nc.connect();
        h.bus = try .init(gpa, &h.nc, .{});
        return .{ .client = h.bus.clientTransport(), .server = h.bus.serverTransport() };
    }

    pub fn tearDown(h: *Harness, io: Io, pair: conformance.Pair) void {
        _ = pair;
        h.bus.deinit(io);
        h.nc.deinit();
    }

    /// Stops and starts the broker; returns once the client is connected
    /// again and has subscribed anew.
    pub fn restartPeer(h: *Harness, io: Io, pair: conformance.Pair) !void {
        _ = pair;
        try root.stop(io, servers.restart_container);
        try root.start(io, servers.restart_container);
        try root.eventually(io, &h.nc, struct {
            fn connected(nc: *nats.Client) bool {
                return nc.isConnected();
            }
        }.connected);
    }
};

fn suite(io: Io) !void {
    var harness: Harness = .{};
    var report = try conformance.run(io, testing.allocator, &harness, .{ .live_broker = true, .time_scale = 2 });
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("nats", report.transport_name);
    // T12: NATS sees a broken link only at the deadline. T16: at most
    // once. T17 runs.
    for (std.enums.values(conformance.Check)) |check| {
        const skipped = report.outcome(check) == .skipped;
        if (skipped != (check == .t12 or check == .t16)) {
            std.debug.print("{f}", .{&report});
            return error.TestUnexpectedResult;
        }
    }
}

test "the NATS transport on zefir-nats passes the conformance suite of rpc against a live broker that restarts" {
    try root.onZio(suite);
}
