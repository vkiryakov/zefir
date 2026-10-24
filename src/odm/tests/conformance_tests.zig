//! Tests of `odm.testing.conformance`: `FakeDriver` passes group C, and a
//! driver that breaks a rule fails the check of that rule.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const conformance = odm.testing.conformance;
const FakeDriver = odm.testing.FakeDriver;
const Client = odm.Client;

const working = "fake://conformance";
const away = "fake://away";
const nobody = "fake://nobody";

/// `FakeDriver` with every hook: a server that is not there, a login that
/// it refuses, and a gate that holds the calls of `working` once `stall`
/// plans it.
const FakeHarness = struct {
    fake: FakeDriver = undefined,
    gate: FakeDriver.Gate = .{},

    pub fn setUp(h: *FakeHarness, io: Io, gpa: Allocator) !conformance.Setup {
        _ = io;
        h.fake = .init(gpa);
        h.gate = .{};
        errdefer h.fake.deinit();
        try h.fake.plan(away, .{ .connects = &.{error.Unavailable} });
        try h.fake.plan(nobody, .{ .connects = &.{error.AuthenticationFailed} });
        return .{ .driver = h.fake.driver(), .config = .{ .uri = working }, .database = "conformance" };
    }

    pub fn tearDown(h: *FakeHarness, io: Io, setup: conformance.Setup) void {
        _ = setup;
        h.gate.open(io);
        h.fake.deinit();
    }

    pub fn badCredentials(h: *FakeHarness) odm.ConnectionConfig {
        _ = h;
        return .{ .uri = nobody, .password = conformance.secret };
    }

    pub fn unreachableServer(h: *FakeHarness) odm.ConnectionConfig {
        _ = h;
        return .{ .uri = away };
    }

    pub fn stall(h: *FakeHarness, io: Io, setup: conformance.Setup) !void {
        _ = io;
        try h.fake.plan(setup.config.uri, .{ .gate = &h.gate });
    }
};

fn expectNoFailures(report: *const conformance.Report) !void {
    if (report.failedCount() == 0) return;
    std.debug.print("{f}", .{report});
    return error.TestUnexpectedResult;
}

test "FakeDriver passes group C" {
    var harness: FakeHarness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{ .data = false });
    defer report.deinit();
    try expectNoFailures(&report);
    try testing.expectEqual(@as(usize, 10), report.passedCount());
    try testing.expectEqual(@as(usize, 10), report.skippedCount());
    try testing.expectEqualStrings("fake", report.driver_name);
    for (std.enums.values(conformance.Check)) |check| {
        if (!check.needsData()) continue;
        try testing.expectEqualStrings("options.data is false: the checks of group D need a server that runs the queries", report.outcome(check).skipped);
    }
    const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{&report});
    defer testing.allocator.free(text);
    try testing.expectStringStartsWith(text, "odm conformance of \"fake\": 10 passed, 0 failed, 10 skipped\n  passed   C1   open does no I/O;");
}

/// A broken rule of a driver, for the tests of the suite itself.
const Flaw = enum {
    /// Sends a call with less than 1 ms left, as if it had no deadline.
    ignores_deadline,
    /// Keeps 16 bytes of the allocator of `setUp` at every call.
    leaks,
};

/// `FakeDriver` behind a driver with one flaw, with the hooks of
/// `FakeHarness`.
const FlawedHarness = struct {
    flaw: Flaw,
    inner: FakeHarness = .{},
    driver: Flawed = undefined,
    /// What `leaks` kept, which the test frees: they come from the
    /// allocator under the suite's.
    kept: std.ArrayList([]u8) = .empty,

    pub fn setUp(h: *FlawedHarness, io: Io, gpa: Allocator) !conformance.Setup {
        var setup = try h.inner.setUp(io, gpa);
        h.driver = .{ .inner = setup.driver, .flaw = h.flaw, .gpa = gpa, .kept = &h.kept };
        setup.driver = .init(&h.driver);
        return setup;
    }

    pub fn tearDown(h: *FlawedHarness, io: Io, setup: conformance.Setup) void {
        h.inner.tearDown(io, setup);
    }

    pub fn badCredentials(h: *FlawedHarness) odm.ConnectionConfig {
        return h.inner.badCredentials();
    }

    pub fn unreachableServer(h: *FlawedHarness) odm.ConnectionConfig {
        return h.inner.unreachableServer();
    }

    pub fn stall(h: *FlawedHarness, io: Io, setup: conformance.Setup) !void {
        return h.inner.stall(io, setup);
    }

    fn deinit(h: *FlawedHarness) void {
        for (h.kept.items) |block| testing.allocator.free(block);
        h.kept.deinit(testing.allocator);
    }
};

const Flawed = struct {
    inner: odm.Driver,
    flaw: Flaw,
    gpa: Allocator,
    kept: *std.ArrayList([]u8),

    pub const name = "flawed";

    pub fn open(f: *Flawed, io: Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!Client {
        const inner = try f.inner.open(io, config);
        errdefer {
            inner.close(io);
            inner.deinit();
        }
        const c = try f.gpa.create(FlawedClient);
        c.* = .{ .driver = f, .inner = inner };
        return .init(c);
    }
};

/// A client of `FakeDriver` with the flaw of its driver.
const FlawedClient = struct {
    driver: *Flawed,
    inner: Client,

    pub const capabilities: odm.Capabilities = .{ .aggregate = true, .count = true, .indexes = true, .command = true };

    /// The context the call goes out with, after the flaw.
    fn context(c: *FlawedClient, io: Io, ctx: core.Context) core.Context {
        c.keep();
        if (c.driver.flaw != .ignores_deadline) return ctx;
        const left = ctx.remaining(Io.Clock.awake.now(io)) orelse return ctx;
        return if (left.nanoseconds < std.time.ns_per_ms) .root else ctx;
    }

    fn keep(c: *FlawedClient) void {
        if (c.driver.flaw != .leaks) return;
        const block = c.driver.gpa.alloc(u8, 16) catch return;
        c.driver.kept.append(testing.allocator, block) catch c.driver.gpa.free(block);
    }

    pub fn connect(c: *FlawedClient, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void {
        return c.inner.connect(io, c.context(io, ctx), d);
    }

    pub fn ping(c: *FlawedClient, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void {
        return c.inner.ping(io, c.context(io, ctx), d);
    }

    pub fn close(c: *FlawedClient, io: Io) void {
        c.inner.close(io);
    }

    pub fn deinit(c: *FlawedClient) void {
        c.inner.deinit();
        c.driver.gpa.destroy(c);
    }

    pub fn stats(c: *FlawedClient) ?Client.PoolStats {
        return c.inner.stats();
    }

    pub fn insert(c: *FlawedClient, io: Io, ctx: core.Context, request: *const Client.InsertRequest, options: Client.CallOptions) odm.DriverError!Client.InsertResult {
        return c.inner.insert(io, c.context(io, ctx), request, options);
    }

    pub fn update(c: *FlawedClient, io: Io, ctx: core.Context, request: *const Client.UpdateRequest, options: Client.CallOptions) odm.DriverError!Client.UpdateResult {
        return c.inner.update(io, c.context(io, ctx), request, options);
    }

    pub fn delete(c: *FlawedClient, io: Io, ctx: core.Context, request: *const Client.DeleteRequest, options: Client.CallOptions) odm.DriverError!Client.DeleteResult {
        return c.inner.delete(io, c.context(io, ctx), request, options);
    }

    pub fn find(c: *FlawedClient, io: Io, ctx: core.Context, request: *const Client.FindRequest, options: Client.CallOptions) odm.DriverError!odm.RawCursor {
        return c.inner.find(io, c.context(io, ctx), request, options);
    }

    pub fn aggregate(c: *FlawedClient, io: Io, ctx: core.Context, request: *const Client.AggregateRequest, options: Client.CallOptions) odm.DriverError!odm.RawCursor {
        return c.inner.aggregate(io, c.context(io, ctx), request, options);
    }

    pub fn count(c: *FlawedClient, io: Io, ctx: core.Context, request: *const Client.CountRequest, options: Client.CallOptions) odm.DriverError!u64 {
        return c.inner.count(io, c.context(io, ctx), request, options);
    }

    pub fn createIndexes(c: *FlawedClient, io: Io, ctx: core.Context, request: *const Client.IndexRequest, options: Client.CallOptions) odm.DriverError!void {
        return c.inner.createIndexes(io, c.context(io, ctx), request, options);
    }

    pub fn command(c: *FlawedClient, io: Io, ctx: core.Context, request: *const Client.CommandRequest, options: Client.CallOptions) odm.DriverError!bson.RawDocument {
        return c.inner.command(io, c.context(io, ctx), request, options);
    }
};

test "a driver that breaks a rule fails its check" {
    var late: FlawedHarness = .{ .flaw = .ignores_deadline };
    defer late.deinit();
    var report = try conformance.run(testing.io, testing.allocator, &late, .{ .data = false });
    defer report.deinit();
    try testing.expectEqualStrings("flawed", report.driver_name);
    for (std.enums.values(conformance.Check)) |check| {
        switch (report.outcome(check)) {
            .failed => |why| {
                try testing.expectEqual(conformance.Check.c4, check);
                try testing.expectEqualStrings("the first connect with less than 1 ms left succeeded, not error.DeadlineExceeded", why);
            },
            .passed => try testing.expect(!check.needsData() and check != .c4),
            .skipped => try testing.expect(check.needsData()),
        }
    }

    var leaky: FlawedHarness = .{ .flaw = .leaks };
    defer leaky.deinit();
    var leaks = try conformance.run(testing.io, testing.allocator, &leaky, .{ .data = false, .only = &.{.c8} });
    defer leaks.deinit();
    try testing.expect(leaky.kept.items.len > 0);
    const why = leaks.outcome(.c8).failed;
    try testing.expect(std.mem.endsWith(u8, why, "allocation(s) were still held after harness.tearDown"));
    try testing.expectEqualStrings("not in options.only", leaks.outcome(.c1).skipped);
}
