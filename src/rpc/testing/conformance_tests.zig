//! Tests of `rpc.testing.conformance`: the memory transport passes every
//! check it can take, and a transport that breaks a rule fails the check
//! of that rule.

const std = @import("std");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const conformance = @import("conformance.zig");
const MemoryTransport = @import("MemoryTransport.zig");
const ClientTransport = @import("../ClientTransport.zig");
const ServerTransport = @import("../ServerTransport.zig");

const testing = std.testing;
const Check = conformance.Check;

/// The memory transport with every hook of a harness.
const MemoryHarness = struct {
    memory: MemoryTransport = undefined,

    pub fn setUp(h: *MemoryHarness, io: std.Io, gpa: std.mem.Allocator) !conformance.Pair {
        _ = io;
        h.memory = try .init(gpa, .{ .max_body_bytes = 64 * 1024 });
        return .{ .client = h.memory.clientTransport(), .server = h.memory.serverTransport() };
    }

    pub fn tearDown(h: *MemoryHarness, io: std.Io, pair: conformance.Pair) void {
        _ = pair;
        h.memory.deinit(io);
    }

    pub fn breakLink(h: *MemoryHarness, io: std.Io, pair: conformance.Pair) void {
        _ = pair;
        h.memory.breakLink(io);
    }

    /// One memory transport is one address: a second start fails while it
    /// runs.
    pub fn sameAddress(h: *MemoryHarness, io: std.Io, pair: conformance.Pair) !ServerTransport {
        _ = h;
        _ = io;
        return pair.server;
    }
};

fn expectNoFailures(report: *const conformance.Report) !void {
    if (report.failedCount() == 0) return;
    std.debug.print("{f}", .{report});
    return error.TestUnexpectedResult;
}

test "the memory transport passes every check it can take" {
    var harness: MemoryHarness = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{});
    defer report.deinit();
    try expectNoFailures(&report);
    try testing.expectEqual(@as(usize, 20), report.passedCount());
    try testing.expectEqualStrings("info().delivery is not at_least_once", report.outcome(.t16).skipped);
    try testing.expectEqualStrings("it needs a live broker: options.live_broker is false", report.outcome(.t17).skipped);
    try testing.expectEqual(@as(usize, 0), report.notes.len);
    try testing.expectEqual(@as(usize, 0), report.defaults.len);
    try testing.expectEqualStrings("memory", report.transport_name);
}

/// A broken rule of a transport, for the tests of the suite itself.
const Flaw = enum {
    /// The client side drops `refused` from every response.
    loses_refused,
    /// The client side sends the request metadata in reverse order.
    reorders_metadata,
    /// The client side sends a budget 5 s longer than the caller has.
    stretches_budget,
    /// The client side returns `Timeout` for a canceled call.
    swallows_cancel,
    /// The client side re-arms the cancelation it reports.
    reports_cancel_twice,
    /// The server side keeps taking calls after `drain`.
    ignores_drain,
    /// `setUp` takes memory that `tearDown` does not give back.
    leaks,
};

/// The memory transport with one flaw: the harness, the client side and
/// the server side in one object.
const Flawed = struct {
    flaw: Flaw,
    memory: MemoryTransport = undefined,
    /// What `leaks` took, one block a `setUp`: the test frees it, from the
    /// allocator under the suite's.
    leaked: [4][]u8 = undefined,
    leaks: usize = 0,

    pub fn setUp(f: *Flawed, io: std.Io, gpa: std.mem.Allocator) !conformance.Pair {
        _ = io;
        f.memory = try .init(gpa, .{ .max_body_bytes = 64 * 1024 });
        if (f.flaw == .leaks and f.leaks < f.leaked.len) {
            f.leaked[f.leaks] = try gpa.alloc(u8, 16);
            f.leaks += 1;
        }
        return .{ .client = .init(f), .server = .init(f) };
    }

    pub fn tearDown(f: *Flawed, io: std.Io, pair: conformance.Pair) void {
        _ = pair;
        f.memory.deinit(io);
    }

    pub fn call(f: *Flawed, io: std.Io, request: *const transport.Request, options: ClientTransport.CallOptions) ClientTransport.CallError!model.Response {
        var changed = request.*;
        var reversed: [16]model.Metadata.Entry = undefined;
        switch (f.flaw) {
            .reorders_metadata => {
                const n = @min(request.metadata.len, reversed.len);
                for (request.metadata[0..n], 0..) |entry, i| reversed[n - 1 - i] = entry;
                changed.metadata = reversed[0..n];
            },
            .stretches_budget => if (request.ctx.deadline) |deadline| {
                changed.ctx.deadline = .at(deadline.expires.addDuration(.fromSeconds(5)));
            },
            else => {},
        }
        var response = f.memory.call(io, &changed, options) catch |err| switch (err) {
            error.Canceled => switch (f.flaw) {
                .swallows_cancel => return error.Timeout,
                .reports_cancel_twice => {
                    io.recancel();
                    return error.Canceled;
                },
                else => return err,
            },
            else => return err,
        };
        if (f.flaw == .loses_refused) response.refused = false;
        return response;
    }

    pub fn info(f: *Flawed) transport.Info {
        return f.memory.info();
    }

    pub fn start(f: *Flawed, io: std.Io, dispatcher: transport.Dispatcher) ServerTransport.StartError!void {
        return f.memory.start(io, dispatcher);
    }

    pub fn drain(f: *Flawed, io: std.Io) void {
        if (f.flaw != .ignores_drain) f.memory.drain(io);
    }

    pub fn close(f: *Flawed, io: std.Io) void {
        f.memory.close(io);
    }

    pub fn isReady(f: *Flawed) bool {
        return f.memory.isReady();
    }
};

test "a transport that breaks a rule fails the check of that rule" {
    const cases = [_]struct { Flaw, Check, []const u8 }{
        .{ .loses_refused, .t21, "came without refused = true" },
        .{ .reorders_metadata, .t2, "the request metadata on the server: entry 0 is x-a" },
        .{ .stretches_budget, .t5, "more than the 1000 ms the client had" },
        .{ .swallows_cancel, .t7, "returned error.Timeout, not error.Canceled" },
        .{ .reports_cancel_twice, .t7, "the transport re-armed the one it reported" },
        .{ .ignores_drain, .t11, "a call after drain got a success" },
        .{ .leaks, .t1, "16 bytes in 1 allocation(s) were still held after harness.tearDown" },
    };
    for (cases) |case| {
        const flaw, const check, const message = case;
        var flawed: Flawed = .{ .flaw = flaw };
        defer for (flawed.leaked[0..flawed.leaks]) |block| testing.allocator.free(block);
        var report = try conformance.run(testing.io, testing.allocator, &flawed, .{ .only = &.{check} });
        defer report.deinit();
        const why = switch (report.outcome(check)) {
            .failed => |why| why,
            else => {
                std.debug.print("{t}: {f}", .{ flaw, &report });
                return error.TestUnexpectedResult;
            },
        };
        if (std.mem.indexOf(u8, why, message) == null) {
            std.debug.print("{t}: \"{s}\" does not say \"{s}\"\n", .{ flaw, why, message });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(usize, 1), report.failedCount());
        try testing.expectEqual(@as(usize, 21), report.skippedCount());
    }
}

/// The memory transport whose server side keeps the default `isReady`,
/// with no hooks: the harness and the server side in one object.
const Bare = struct {
    memory: MemoryTransport = undefined,

    pub fn setUp(b: *Bare, io: std.Io, gpa: std.mem.Allocator) !conformance.Pair {
        _ = io;
        b.memory = try .init(gpa, .{});
        return .{ .client = b.memory.clientTransport(), .server = .init(b) };
    }

    pub fn tearDown(b: *Bare, io: std.Io, pair: conformance.Pair) void {
        _ = pair;
        b.memory.deinit(io);
    }

    pub fn start(b: *Bare, io: std.Io, dispatcher: transport.Dispatcher) ServerTransport.StartError!void {
        return b.memory.start(io, dispatcher);
    }

    pub fn drain(b: *Bare, io: std.Io) void {
        b.memory.drain(io);
    }

    pub fn close(b: *Bare, io: std.Io) void {
        b.memory.close(io);
    }

    pub fn info(b: *Bare) transport.Info {
        return b.memory.info();
    }
};

test "without hooks, checks are skipped or noted, and the report shows defaults the transport left" {
    var bare: Bare = .{};
    var report = try conformance.run(testing.io, testing.allocator, &bare, .{ .only = &.{ .t9, .t12, .t14, .t18 } });
    defer report.deinit();
    try expectNoFailures(&report);
    try testing.expectEqual(@as(usize, 3), report.passedCount());
    try testing.expectEqualStrings("the harness has no breakLink", report.outcome(.t12).skipped);
    try testing.expectEqualStrings("not in options.only", report.outcome(.t1).skipped);
    try testing.expectEqual(@as(usize, 3), report.notes.len);
    try testing.expectEqual(Check.t9, report.notes[0].check);
    try testing.expectEqualStrings("the body limit was not checked: info().max_body_bytes is null", report.notes[0].text);
    try testing.expectEqual(Check.t14, report.notes[1].check);
    try testing.expectEqual(Check.t18, report.notes[2].check);
    try testing.expectEqual(@as(usize, 1), report.defaults.len);
    try testing.expectEqualStrings("rpc.ServerTransport.isReady", report.defaults[0]);

    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{&report});
    const text = w.buffered();
    const lines = [_][]const u8{
        "rpc conformance of \"memory\": 3 passed, 0 failed, 19 skipped\n",
        "  passed   T9   sizes: a body at the limit and one byte over; response limits\n",
        "  skipped  T12  broken link: ConnectionLost, Unavailable, calls canceled: the harness has no breakLink\n",
        "  note     T14  a busy address was not checked: the harness has no sameAddress\n",
        "  defaults left by the transport: rpc.ServerTransport.isReady\n",
    };
    for (lines) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}", .{ line, text });
            return error.TestUnexpectedResult;
        }
    }
}

const Unreachable = struct {
    pub fn setUp(u: *Unreachable, io: std.Io, gpa: std.mem.Allocator) !conformance.Pair {
        _ = u;
        _ = io;
        _ = gpa;
        return error.ConnectionRefused;
    }

    pub fn tearDown(u: *Unreachable, io: std.Io, pair: conformance.Pair) void {
        _ = u;
        _ = io;
        _ = pair;
    }
};

test "a harness whose setUp fails fails every check with its error" {
    var harness: Unreachable = .{};
    var report = try conformance.run(testing.io, testing.allocator, &harness, .{});
    defer report.deinit();
    try testing.expectEqual(@as(usize, 22), report.failedCount());
    try testing.expectEqualStrings("harness.setUp returned error.ConnectionRefused", report.outcome(.t1).failed);
}

test "checks have labels T1 to T22 and titles" {
    try testing.expectEqualStrings("T1", Check.t1.label());
    try testing.expectEqualStrings("T22", Check.t22.label());
    for (std.enums.values(Check)) |check| try testing.expect(check.title().len > 0);
}

fn runAll(io: std.Io, harness: *MemoryHarness) conformance.RunError!void {
    var report = try conformance.run(io, testing.allocator, harness, .{});
    report.deinit();
}

test "canceling the task of run ends it with Canceled between checks" {
    const io = testing.io;
    var harness: MemoryHarness = .{};
    var task = try io.concurrent(runAll, .{ io, &harness });
    try testing.expectError(error.Canceled, task.cancel(io));
}

test "time_scale stretches the times of the checks" {
    var harness: MemoryHarness = .{};
    const io = testing.io;
    const begun = std.Io.Clock.awake.now(io);
    var report = try conformance.run(io, testing.allocator, &harness, .{ .only = &.{.t6}, .time_scale = 2 });
    defer report.deinit();
    try expectNoFailures(&report);
    // T6 waits for a deadline of 200 ms, 400 ms at scale 2.
    const took = begun.durationTo(std.Io.Clock.awake.now(io));
    try testing.expect(took.nanoseconds >= std.Io.Duration.fromMilliseconds(400).nanoseconds);
}
