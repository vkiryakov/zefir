//! The conformance suite of zefir-mongo against mongo-plain: on the native
//! driver, layer S against the scripts of its checks and layer L with fail
//! points; on `FakeDriver`, layer S and L1–L6 through `Proxy`. L7–L10
//! configure fail points, which act on the connections of a driver to
//! mongod: `FakeDriver` skips them.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const mongo = @import("mongo");
const native = @import("mongo-async-driver");
const conformance = mongo.testing.conformance;
const Script = mongo.testing.Script;
const FakeDriver = mongo.testing.FakeDriver;
const e2e = @import("root.zig");
const Proxy = @import("Proxy.zig");

/// `FakeDriver` on the script of a check of layer S, and on a script that
/// forwards to the mongod of layer L.
const Harness = struct {
    fake: FakeDriver = undefined,
    proxy: Proxy = undefined,
    script: Script = undefined,
    live: bool = false,

    pub fn setUp(h: *Harness, io: Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
        switch (target) {
            .scripted => |s| {
                h.live = false;
                h.fake = .init(gpa, s.script);
            },
            .live => |l| {
                h.live = true;
                h.proxy = .init(gpa, try portOf(l.uri));
                h.script = .init(gpa, h.proxy.handler());
                h.fake = .init(gpa, &h.script);
            },
        }
        try h.fake.connect(io, .root);
        return h.fake.client();
    }

    pub fn close(h: *Harness, io: Io) void {
        h.fake.close(io);
    }

    pub fn tearDown(h: *Harness, io: Io) void {
        h.fake.deinit();
        if (h.live) {
            h.script.deinit();
            h.proxy.deinit(io);
        }
    }
};

/// The port of "mongodb://host:port".
fn portOf(uri: []const u8) !u16 {
    const colon = std.mem.findScalarLast(u8, uri, ':') orelse return error.NoPort;
    return std.fmt.parseInt(u16, uri[colon + 1 ..], 10);
}

test "FakeDriver keeps the contract: layer S, and L1 to L6 against mongo-plain through the proxy" {
    try e2e.onZio(suite);
}

fn suite(io: Io) !void {
    var harness: Harness = .{};
    var buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port});
    var report = try conformance.run(io, testing.allocator, &harness, .{ .live = .{ .uri = uri, .fail_points = true } });
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    for ([_]conformance.Check{ .l1, .l2, .l3, .l4, .l5, .l6 }) |check| {
        try testing.expectEqual(conformance.Outcome.passed, report.outcome(check));
    }
    for ([_]conformance.Check{ .l7, .l8, .l9, .l10 }) |check| {
        try testing.expectEqualStrings("fail points need a driver on the wire: no connection came to the FakeServer, and a fail point acts on the connections of a driver to mongod", report.outcome(check).skipped);
    }
    try testing.expectEqual(@as(usize, 26), report.passedCount());
    try testing.expectEqual(@as(usize, 5), report.skippedCount());
}

/// A fresh native driver on the target of each check: the FakeServer of a
/// check of layer S, mongo-plain for layer L.
const NativeHarness = struct {
    driver: native.Client = undefined,

    pub fn setUp(h: *NativeHarness, io: Io, gpa: std.mem.Allocator, target: conformance.Target) !mongo.Client {
        const uri = switch (target) {
            .scripted => |s| s.uri,
            .live => |l| l.uri,
        };
        h.driver = try .init(gpa, io, .{ .uri = uri });
        errdefer h.driver.deinit();
        try h.driver.connect(io, .root, null);
        return h.driver.client();
    }

    pub fn close(h: *NativeHarness, io: Io) void {
        h.driver.close(io);
    }

    pub fn tearDown(h: *NativeHarness, io: Io) void {
        _ = io;
        h.driver.deinit();
    }
};

test "the native driver keeps the contract: layer S, and layer L with fail points against mongo-plain" {
    try e2e.onZio(nativeSuite);
}

fn nativeSuite(io: Io) !void {
    var harness: NativeHarness = .{};
    var buffer: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{e2e.servers.plain_port});
    var report = try conformance.run(io, testing.allocator, &harness, .{ .live = .{ .uri = uri, .fail_points = true } });
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("zefir-mongo-async-driver", report.driver_name);
    try testing.expectEqual(@as(usize, 31), report.passedCount());
}
