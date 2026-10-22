//! The checks of group C of `odm.testing.conformance`, C1–C10: the
//! discipline of the driver contract, without data. A server that answers
//! every command with an empty cursor or `{ok: 1}` passes them; with
//! `Options.data`, C4 and C5 also see that nothing was written.

const std = @import("std");
const Io = std.Io;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("../../root.zig");
const conformance = @import("../conformance.zig");
const Job = @import("Job.zig");
const Error = Job.Error;
const secret = conformance.secret;

/// The collection that the checks of group C write to.
const collection = "conformance";
const doc = bson.literal(.{ ._id = 1, .n = 1 });
const by_id = bson.literal(.{ ._id = 1 });
const change = bson.literal(.{ .@"$set" = .{ .n = 2 } });
const match = bson.literal(.{ .@"$match" = .{ .n = 1 } });
const ping = bson.literal(.{ .ping = 1 });
const index: odm.Client.IndexSpec = .{ .name = "n_1", .keys = bson.literal(.{ .n = 1 }) };

/// A closed port on loopback, without and with the password in the
/// connection string, for a harness without `unreachableServer`.
const unreachable_user = "mongodb://odm_conformance@127.0.0.1:1/";
const unreachable_inline = "mongodb://odm_conformance:" ++ secret ++ "@127.0.0.1:1/";

fn unreachableServer(job: *Job) odm.ConnectionConfig {
    const hook = job.harness.unreachable_server orelse return .{ .uri = unreachable_user, .password = secret };
    return hook(job.harness.ptr);
}

pub fn c1(job: *Job) Error!void {
    const began = job.now();
    const client = try job.open(unreachableServer(job), "the settings of a server that is not there");
    defer job.release(client);
    const opening = job.elapsed(began);
    try job.expect(opening < job.ms(1000).toMilliseconds(), "open of a server that is not there took {d} ms: open does no I/O", .{opening});
    const limit = job.ms(2000);
    const start = job.now();
    if (client.connect(job.io, core.Context.root.withDeadline(.after(start, limit)), &job.diag)) |_| {
        return job.fail("connect to a server that is not there succeeded", .{});
    } else |err| switch (err) {
        error.Unavailable, error.DeadlineExceeded => {},
        else => return job.fail("connect to a server that is not there returned error.{t}, not Unavailable or DeadlineExceeded: {s}", .{ err, job.diag.message() }),
    }
    const waited = job.elapsed(start);
    try job.expect(waited <= limit.toMilliseconds() + job.ms(1000).toMilliseconds(), "connect to a server that is not there took {d} ms, past its deadline of {d} ms", .{ waited, limit.toMilliseconds() });
}

pub fn c2(job: *Job) Error!void {
    const client = try job.open(job.setup.config, "the settings of setUp");
    defer job.release(client);
    try job.need(client.connect(job.io, job.ctx(), &job.diag), "connect");
    try job.need(client.connect(job.io, job.ctx(), &job.diag), "connect of a connected client");
    try job.need(client.ping(job.io, job.ctx(), &job.diag), "ping");
    client.close(job.io);
    try job.expectError(client.connect(job.io, job.ctx(), &job.diag), error.Closed, "connect after close");
    try job.expectError(client.ping(job.io, job.ctx(), &job.diag), error.Closed, "ping after close");
}

pub fn c3(job: *Job) Error!void {
    const hook = job.harness.bad_credentials.?;
    const client = try job.open(hook(job.harness.ptr), "the bad credentials of the harness");
    defer job.release(client);
    try job.expectError(client.connect(job.io, job.ctx(), &job.diag), error.AuthenticationFailed, "connect with the bad credentials of the harness");
}

pub fn c4(job: *Job) Error!void {
    const client = try job.open(job.setup.config, "the settings of setUp");
    defer job.release(client);
    try job.expectError(client.connect(job.io, job.nearlyExpired(), &job.diag), error.DeadlineExceeded, "the first connect with less than 1 ms left");
    try job.need(client.connect(job.io, job.ctx(), &job.diag), "connect");
    try everyOperation(job, client, Job.nearlyExpired, error.DeadlineExceeded, "with less than 1 ms left");
    if (job.options.data) try nothingWritten(job, client);
}

pub fn c5(job: *Job) Error!void {
    const client = try job.open(job.setup.config, "the settings of setUp");
    defer job.release(client);
    try job.expectError(client.connect(job.io, job.canceled(), &job.diag), error.Cancelled, "the first connect with a canceled token");
    try job.need(client.connect(job.io, job.ctx(), &job.diag), "connect");
    try everyOperation(job, client, Job.canceled, error.Cancelled, "with a canceled token");
    if (job.options.data) try nothingWritten(job, client);
}

/// Every operation that `client` has, each in a context of `contextOf`,
/// must fail with `expected`.
fn everyOperation(job: *Job, client: odm.Client, comptime contextOf: fn (*const Job) core.Context, expected: odm.DriverError, comptime when: []const u8) Error!void {
    const io = job.io;
    const at = job.ns(collection);
    const caps = client.capabilities();
    try job.expectError(client.ping(io, contextOf(job), &job.diag), expected, "ping " ++ when);
    try job.expectError(client.insert(io, contextOf(job), &.{ .ns = at, .documents = &.{doc} }, job.call()), expected, "insert " ++ when);
    try job.expectError(client.update(io, contextOf(job), &.{ .ns = at, .filter = by_id, .update = change, .mode = .one }, job.call()), expected, "update " ++ when);
    try job.expectError(client.delete(io, contextOf(job), &.{ .ns = at, .filter = by_id, .many = false }, job.call()), expected, "delete " ++ when);
    try job.expectError(client.find(io, contextOf(job), &.{ .ns = at, .filter = by_id }, job.call()), expected, "find " ++ when);
    try job.expectError(client.find(io, contextOf(job), &.{ .ns = at, .filter = by_id, .limit = 1 }, job.call()), expected, "find with limit 1 " ++ when);
    if (caps.aggregate) try job.expectError(client.aggregate(io, contextOf(job), &.{ .ns = at, .pipeline = &.{match} }, job.call()), expected, "aggregate " ++ when);
    if (caps.count) try job.expectError(client.count(io, contextOf(job), &.{ .ns = at, .filter = by_id }, job.call()), expected, "count " ++ when);
    if (caps.indexes) try job.expectError(client.createIndexes(io, contextOf(job), &.{ .ns = at, .indexes = &.{index} }, job.call()), expected, "createIndexes " ++ when);
    if (caps.command) try job.expectError(client.command(io, contextOf(job), &.{ .database = job.setup.database, .body = ping }, job.call()), expected, "command " ++ when);
}

/// The insert that failed before it went out left nothing.
fn nothingWritten(job: *Job, client: odm.Client) Error!void {
    const docs = try job.findAll(client, .{ .ns = job.ns(collection), .filter = .empty }, "find after the operations that were not sent");
    try job.expect(docs.len == 0, "the insert that was not sent left {d} document(s)", .{docs.len});
}

/// A call that the harness made hang: its error, and when it returned.
const Stalled = struct {
    job: *Job,
    client: odm.Client,
    result: odm.DriverError!void = {},
    ended: Io.Timestamp = .zero,
    diag: odm.Diagnostics = .{},

    fn run(s: *Stalled) void {
        const io = s.job.io;
        var memory: std.heap.ArenaAllocator = .init(s.job.gpa);
        defer memory.deinit();
        const request: odm.Client.FindRequest = .{ .ns = s.job.ns(collection), .filter = .empty };
        defer s.ended = s.job.now();
        const cursor = s.client.find(io, s.job.within(30_000), &request, .{ .allocator = memory.allocator(), .diagnostics = &s.diag }) catch |err| {
            s.result = err;
            return;
        };
        cursor.deinit(io);
    }
};

fn closeClient(client: odm.Client, io: Io) void {
    client.close(io);
}

pub fn c6(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    const stall = job.harness.stall.?;
    stall(job.harness.ptr, io, job.setup) catch |err| return job.fail("harness.stall returned error.{t}", .{err});
    var call: Stalled = .{ .job = job, .client = client };
    var task = io.concurrent(Stalled.run, .{&call}) catch return job.fail("no task for the call that stalls: io.concurrent failed", .{});
    defer task.cancel(io);
    // Time for the call to reach the server and hang there.
    job.pause(job.ms(300));
    const closing = job.now();
    var first = io.concurrent(closeClient, .{ client, io }) catch return job.fail("no task for a close: io.concurrent failed", .{});
    defer first.cancel(io);
    var second = io.concurrent(closeClient, .{ client, io }) catch return job.fail("no task for a close: io.concurrent failed", .{});
    defer second.cancel(io);
    first.await(io);
    second.await(io);
    client.close(io);
    task.await(io);
    if (call.result) |_| {
        return job.fail("the find in flight succeeded after close", .{});
    } else |err| switch (err) {
        error.ConnectionLost, error.Interrupted, error.Closed => {},
        else => return job.fail("the find in flight returned error.{t} after close, not ConnectionLost, Interrupted or Closed: {s}", .{ err, call.diag.message() }),
    }
    const cut = closing.durationTo(call.ended).toMilliseconds();
    try job.expect(cut <= job.ms(2000).toMilliseconds(), "the find in flight returned {d} ms after close began, not within 2 s", .{cut});
    const at = job.ns(collection);
    try job.expectError(client.ping(io, job.ctx(), &job.diag), error.Closed, "ping after close");
    try job.expectError(client.find(io, job.ctx(), &.{ .ns = at, .filter = .empty }, job.call()), error.Closed, "find after close");
    try job.expectError(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &.{doc} }, job.call()), error.Closed, "insert after close");
}

pub fn c7(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    const at = job.ns(collection);
    if (job.options.data) {
        // Documents in the first batch: close ends them too.
        const three = [_]bson.RawDocument{ bson.literal(.{ ._id = 1 }), bson.literal(.{ ._id = 2 }), bson.literal(.{ ._id = 3 }) };
        _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &three }, job.call()), "insert");
    }
    const all = try job.need(client.find(io, job.ctx(), &.{ .ns = at, .filter = .empty, .batch_size = 2 }, job.call()), "find");
    defer all.deinit(io);
    const one = try job.need(client.find(io, job.ctx(), &.{ .ns = at, .filter = .empty, .limit = 1 }, job.call()), "find with limit 1");
    defer one.deinit(io);
    const aggregated: ?odm.RawCursor = if (client.capabilities().aggregate)
        try job.need(client.aggregate(io, job.ctx(), &.{ .ns = at, .pipeline = &.{} }, job.call()), "aggregate")
    else
        null;
    defer if (aggregated) |cursor| cursor.deinit(io);
    client.close(io);
    for (0..2) |_| {
        try job.expectError(all.next(io, job.ctx(), &job.diag), error.Closed, "next of a cursor of find after close of its client");
        try job.expectError(one.next(io, job.ctx(), &job.diag), error.Closed, "next of a cursor of find with limit 1 after close of its client");
        if (aggregated) |cursor| try job.expectError(cursor.next(io, job.ctx(), &job.diag), error.Closed, "next of a cursor of aggregate after close of its client");
    }
}

pub fn c8(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    const at = job.ns(collection);
    const caps = client.capabilities();
    var fences: [9]Job.Fence = undefined;
    var made: usize = 0;
    defer for (fences[0..made]) |*f| f.deinit();
    const names = [_][]const u8{ "insert", "update", "delete", "find", "find with limit 1", "aggregate", "count", "createIndexes", "command" };
    for (&fences) |*f| {
        f.* = .init(job.gpa);
        made += 1;
    }
    const upsert_filter = bson.literal(.{ ._id = "c8-upsert" });

    _ = try job.need(client.insert(io, job.ctx(), &.{ .ns = at, .documents = &.{doc} }, of(&fences[0])), "insert");
    fences[0].close();
    const updated = try job.need(client.update(io, job.ctx(), &.{ .ns = at, .filter = upsert_filter, .update = change, .mode = .one, .upsert = true }, of(&fences[1])), "update with upsert");
    fences[1].close();
    if (updated.upserted_id) |id| try job.expect(ownsValue(&fences[1], id), "the upserted_id of update is not in options.allocator", .{});
    _ = try job.need(client.delete(io, job.ctx(), &.{ .ns = at, .filter = by_id, .many = false }, of(&fences[2])), "delete");
    fences[2].close();
    const found = try job.need(client.find(io, job.ctx(), &.{ .ns = at, .filter = .empty, .batch_size = 1 }, of(&fences[3])), "find");
    fences[3].close();
    _ = try job.drain(found, "find");
    const first = try job.need(client.find(io, job.ctx(), &.{ .ns = at, .filter = .empty, .limit = 1 }, of(&fences[4])), "find with limit 1");
    fences[4].close();
    _ = try job.drain(first, "find with limit 1");
    if (caps.aggregate) {
        const aggregated = try job.need(client.aggregate(io, job.ctx(), &.{ .ns = at, .pipeline = &.{match} }, of(&fences[5])), "aggregate");
        fences[5].close();
        _ = try job.drain(aggregated, "aggregate");
    }
    if (caps.count) {
        _ = try job.need(client.count(io, job.ctx(), &.{ .ns = at, .filter = .empty }, of(&fences[6])), "count");
        fences[6].close();
    }
    if (caps.indexes) {
        try job.need(client.createIndexes(io, job.ctx(), &.{ .ns = at, .indexes = &.{index} }, of(&fences[7])), "createIndexes");
        fences[7].close();
    }
    if (caps.command) {
        const reply = try job.need(client.command(io, job.ctx(), &.{ .database = job.setup.database, .body = ping }, of(&fences[8])), "command");
        fences[8].close();
        try job.expect(fences[8].owns(reply.bytes), "the reply of command is not in options.allocator", .{});
    }
    // The cursors, and the closing of the client, came after their calls.
    client.close(io);
    for (&fences, names) |*f, name| {
        f.close();
        const late = f.lateUses();
        try job.expect(late == 0, "the driver used the options.allocator of {s} {d} time(s) after the call returned", .{ name, late });
    }
}

fn of(fence: *Job.Fence) odm.Client.CallOptions {
    return .{ .allocator = fence.allocator() };
}

/// Whether the bytes of `value`, if it has any, are in `fence`.
fn ownsValue(fence: *const Job.Fence, value: bson.Value) bool {
    return switch (value) {
        .string, .javascript, .symbol => |text| text.len == 0 or fence.owns(text),
        .document, .array => |d| fence.owns(d.bytes),
        .binary => |b| b.bytes.len == 0 or fence.owns(b.bytes),
        else => true,
    };
}

/// A task of C9: 20 rounds of ping and find.
const Worker = struct {
    job: *Job,
    client: odm.Client,
    err: ?odm.DriverError = null,
    what: []const u8 = "",
    round: usize = 0,
    diag: odm.Diagnostics = .{},

    fn run(w: *Worker) void {
        const io = w.job.io;
        var memory: std.heap.ArenaAllocator = .init(w.job.gpa);
        defer memory.deinit();
        const request: odm.Client.FindRequest = .{ .ns = w.job.ns(collection), .filter = .empty };
        for (0..20) |round| {
            w.round = round;
            _ = memory.reset(.retain_capacity);
            w.client.ping(io, w.job.ctx(), &w.diag) catch |err| return w.failed(err, "ping");
            const cursor = w.client.find(io, w.job.ctx(), &request, .{ .allocator = memory.allocator(), .diagnostics = &w.diag }) catch |err| return w.failed(err, "find");
            defer cursor.deinit(io);
            while (cursor.next(io, w.job.ctx(), &w.diag) catch |err| return w.failed(err, "next")) |_| {}
        }
    }

    fn failed(w: *Worker, err: odm.DriverError, what: []const u8) void {
        w.err = err;
        w.what = what;
    }
};

pub fn c9(job: *Job) Error!void {
    const io = job.io;
    const client = try job.connected();
    defer job.release(client);
    var workers: [16]Worker = undefined;
    var group: Io.Group = .init;
    for (&workers) |*w| {
        w.* = .{ .job = job, .client = client };
        group.concurrent(io, Worker.run, .{w}) catch {
            group.cancel(io);
            return job.fail("no task for each of 16 workers: io.concurrent failed", .{});
        };
    }
    group.await(io) catch {};
    for (&workers, 0..) |*w, i| {
        if (w.err) |err| return job.fail("task {d}, round {d}: {s} returned error.{t}: {s}", .{ i, w.round, w.what, err, w.diag.message() });
    }
}

pub fn c10(job: *Job) Error!void {
    try secretless(job, .{ .uri = "", .password = secret }, "an empty connection string");
    try secretless(job, .{ .uri = "mongodb://odm_conformance:" ++ secret ++ "@/" }, "a connection string with the password and no host");
    try secretless(job, .{ .uri = "mongodb://odm_conformance:" ++ secret ++ "@127.0.0.1:1/?maxPoolSize=0" }, "a connection string with the password and a bad option");
    if (job.harness.bad_credentials) |hook| try secretless(job, hook(job.harness.ptr), "the bad credentials of the harness");
    try secretless(job, unreachableServer(job), "the settings of a server that is not there");
    if (job.harness.unreachable_server == null) try secretless(job, .{ .uri = unreachable_inline }, "a server that is not there, with the password in the connection string");
}

/// Opens `config`, connects and pings, and fails if the password shows in
/// a text of the diagnostics of any of them.
fn secretless(job: *Job, config: odm.ConnectionConfig, comptime what: []const u8) Error!void {
    var d: odm.Diagnostics = .{};
    var settings = config;
    settings.diagnostics = &d;
    const client = job.setup.driver.open(job.io, &settings) catch |err| return noSecret(job, &d, "open of " ++ what, err);
    defer job.release(client);
    try noSecret(job, &d, "open of " ++ what, null);
    client.connect(job.io, job.within(2000), &d) catch |err| try noSecret(job, &d, "connect of " ++ what, err);
    client.ping(job.io, job.within(2000), &d) catch |err| try noSecret(job, &d, "ping of " ++ what, err);
}

fn noSecret(job: *Job, d: *const odm.Diagnostics, comptime what: []const u8, err: ?anyerror) Error!void {
    for ([_][]const u8{ d.message(), d.path() }) |text| {
        if (std.mem.find(u8, text, secret) != null)
            return job.fail(what ++ " wrote the password into its diagnostics, with error.{s}: \"{s}\"", .{ if (err) |e| @errorName(e) else "none", text });
    }
}
