//! The checks of layer S of `mongo.testing.conformance`, each against a
//! scripted server: S1–S21 of the design of zefir-mongo.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("../../bson.zig");
const wire = @import("../../wire.zig");
const errors = @import("../../contract/errors.zig");
const requests = @import("../../contract/requests.zig");
const results = @import("../../contract/results.zig");
const capabilities = @import("../../contract/capabilities.zig");
const Client = @import("../../contract/Client.zig");
const Cursor = @import("../../contract/Cursor.zig");
const Script = @import("../Script.zig");
const Job = @import("Job.zig");

/// The database of the commands of layer S.
const database = "conformance";

const OperationContext = requests.OperationContext;
const eql = std.mem.eql;

const s1_body = bson.literal(.{
    .count = "users",
    .query = .{ .age = .{ .@"$gte" = 30 }, .name = "Ann" },
    .limit = @as(i64, 5),
    .hint = .{ ._id = 1 },
    .comment = "S1",
});

const s1_reply = bson.literal(.{
    .n = 3,
    .names = .{ "Ann", "Bob", "Cid" },
    .stats = .{ .scanned = @as(i64, 1200), .ratio = 0.25, .complete = true },
    .ok = 1.0,
});

pub fn s1(job: *Job) Job.Error!void {
    const io = job.io;
    var queue: Script.Queue = .{ .answers = &.{.{ .reply = s1_reply }} };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, queue.handler(), .{});
    defer job.end();
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    var fence: Job.Fence = .{ .parent = arena.allocator() };
    const reply = try job.need(client.runCommand(io, .of(.root), .{ .database = database, .body = s1_body }, .{ .allocator = fence.allocator() }), "runCommand");
    fence.close();
    const held = fence.held();
    const same = eql(u8, reply.bytes, s1_reply.bytes);
    const shown = if (same) "" else try std.fmt.allocPrint(job.arena, "{f}", .{reply.raw()});
    reply.deinit();
    try job.expectSent((try job.received(&stage.script, "count", 0)).body, s1_body, database, &.{}, "the command");
    try job.expect(same, "the reply came back changed: {s}", .{shown});
    try job.expect(held > 0, "the reply was not allocated from options.allocator", .{});
    try job.expect(fence.held() == 0, "{d} allocation(s) of options.allocator were left after the reply's deinit: the reply is to be one allocation of options.allocator, and nothing else", .{fence.held()});
}

/// The fields that no driver of revision 1 writes.
const session_fields = [_][]const u8{ "$readPreference", "lsid", "txnNumber", "$clusterTime", "autocommit", "startTransaction" };

/// A cursor, a write and anything else answered with `{ok: 1.0}`.
const Mixed = struct {
    cursor: Script.Cursor,
    write: Script.Write = .{},

    pub fn handler(m: *Mixed) Script.Handler {
        return .init(m);
    }

    pub fn answer(m: *Mixed, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        const name = request.name;
        if (eql(u8, name, "find") or eql(u8, name, "getMore") or eql(u8, name, "killCursors")) return m.cursor.answer(io, arena, request);
        if (eql(u8, name, "insert") or eql(u8, name, "update") or eql(u8, name, "delete")) return m.write.answer(io, arena, request);
        return .{ .reply = Script.ok };
    }
};

const docs = [_]bson.RawDocument{
    bson.literal(.{ ._id = 0, .n = "zero" }),
    bson.literal(.{ ._id = 1, .n = "one" }),
    bson.literal(.{ ._id = 2, .n = "two" }),
    bson.literal(.{ ._id = 3, .n = "three" }),
    bson.literal(.{ ._id = 4, .n = "four" }),
    bson.literal(.{ ._id = 5, .n = "five" }),
    bson.literal(.{ ._id = 6, .n = "six" }),
};

/// The longest `maxTimeMS` for the time left at `began` of a deadline:
/// the time left, rounded up to whole milliseconds.
fn budgetMs(began: Io.Timestamp, deadline: core.Deadline) i64 {
    const left = deadline.remaining(began).nanoseconds;
    return @intCast(@divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms));
}

/// Fails unless `entry` holds `maxTimeMS`, an integer of 1 to `limit`.
fn expectMaxTime(job: *Job, entry: Script.Entry, limit: i64) Job.Error!void {
    const value = (entry.body.get("maxTimeMS") catch null) orelse return job.fail("{s} under a deadline came without maxTimeMS", .{entry.name});
    const ms = value.asI64() catch return job.fail("maxTimeMS of {s} is not an integer", .{entry.name});
    try job.expect(ms >= 1 and ms <= limit, "maxTimeMS of {s} is {d}; the deadline left at most {d} ms", .{ entry.name, ms, limit });
}

pub fn s2(job: *Job) Job.Error!void {
    const io = job.io;
    var mixed: Mixed = .{ .cursor = .{ .ns = database ++ ".s2", .batches = &.{ docs[0..1], docs[1..2], docs[2..3] } } };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, mixed.handler(), .{});
    defer job.end();
    const script = &stage.script;

    const began = Job.now(io);
    const deadline: core.Deadline = .after(began, job.ms(30_000));
    const op: OperationContext = .of(core.Context.root.withDeadline(deadline));
    const limit = budgetMs(began, deadline);
    const count_s2 = bson.literal(.{ .count = "s2" });
    const reply = try job.need(client.runCommand(io, op, .{ .database = database, .body = count_s2 }, .{ .allocator = job.gpa }), "runCommand");
    reply.deinit();
    const counted = try job.received(script, "count", 0);
    try expectMaxTime(job, counted, limit);
    try job.expectSent(counted.body, count_s2, database, &.{"maxTimeMS"}, "the command under a deadline");

    // A cursor read to its end: find, then two getMore.
    {
        var cursor = try job.need(client.openCursor(io, op, .{ .database = database, .body = bson.literal(.{ .find = "s2" }) }, .{}), "openCursor");
        defer cursor.deinit(io);
        while (try job.need(cursor.next(io, op), "next")) |_| {}
    }
    // A cursor closed in its middle: killCursors.
    {
        var cursor = try job.need(client.openCursor(io, op, .{ .database = database, .body = bson.literal(.{ .find = "s2" }) }, .{}), "openCursor");
        defer cursor.deinit(io);
        _ = try job.need(cursor.next(io, op), "next");
        cursor.close(io);
    }
    var result = try job.need(client.write(io, op, .{ .database = database, .kind = .insert, .body = bson.literal(.{ .insert = "s2" }), .items = docs[0..1] }, .{ .allocator = job.gpa }), "write");
    result.deinit(job.gpa);

    try expectMaxTime(job, try job.received(script, "find", 0), limit);
    try expectMaxTime(job, try job.received(script, "insert", 0), limit);
    try job.expect(script.count(io, "getMore") >= 2, "the cursor read to its end sent {d} getMore, not 2", .{script.count(io, "getMore")});
    try job.expect(script.count(io, "killCursors") == 1, "the cursor closed in its middle sent {d} killCursors, not 1", .{script.count(io, "killCursors")});
    for (0..script.received(io)) |i| {
        const entry = script.entry(io, i);
        if (eql(u8, entry.name, "getMore") or eql(u8, entry.name, "killCursors")) {
            try job.expect((entry.body.get("maxTimeMS") catch null) == null, "{s} came with maxTimeMS; it goes in no getMore and no killCursors", .{entry.name});
        }
        var it = entry.body.iterator();
        while (it.next() catch null) |element| {
            try job.expect(!Job.isIn(&session_fields, element.key), "{s} came with {s}, which no driver of revision 1 writes", .{ entry.name, element.key });
        }
    }
}

const s3_overloaded = bson.literal(.{
    .ok = 0.0,
    .errmsg = "The server is in quiesce mode and will shut down",
    .code = 91,
    .codeName = "ShutdownInProgress",
    .errorLabels = .{ "SystemOverloadedError", "RetryableError" },
});
const s3_expired = bson.literal(.{ .ok = 0.0, .errmsg = "operation exceeded time limit", .code = 50, .codeName = "MaxTimeMSExpired" });
const s3_missing = bson.literal(.{ .ok = 0.0, .errmsg = "ns does not exist: conformance.s3", .code = 26, .codeName = "NamespaceNotFound" });
const s3_unauthorized = bson.literal(.{ .ok = 0.0, .errmsg = "not authorized on conformance to execute command { insert: \"s3\" }", .code = 13, .codeName = "Unauthorized" });

/// Fails unless `slot` holds `reply` byte for byte; frees it.
fn expectFailureReply(job: *Job, slot: *?bson.OwnedDocument, reply: bson.RawDocument, comptime what: []const u8) Job.Error!void {
    const got = slot.* orelse return job.fail(what ++ ": failure_reply is null; it holds the whole reply after CommandFailed and Timeout by code 50", .{});
    slot.* = null;
    defer got.deinit();
    try job.expect(eql(u8, got.bytes, reply.bytes), what ++ ": failure_reply is not the reply of the server, byte for byte", .{});
}

pub fn s3(job: *Job) Job.Error!void {
    const io = job.io;
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = s3_overloaded }, .{ .reply = s3_expired }, .{ .reply = s3_missing }, .{ .reply = s3_unauthorized } } };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, queue.handler(), .{});
    defer job.end();
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    var fence: Job.Fence = .{ .parent = arena.allocator() };
    var d: errors.Diagnostics = .{};
    var failure: ?bson.OwnedDocument = null;
    defer if (failure) |f| f.deinit();
    const body = bson.literal(.{ .count = "s3" });

    try job.expectError(client.runCommand(io, .of(.root), .{ .database = database, .body = body }, .{ .allocator = fence.allocator(), .diagnostics = &d, .failure_reply = &failure }), error.CommandFailed, "a command answered with ok: 0");
    const server = d.server orelse return job.fail("Diagnostics.server is null after CommandFailed", .{});
    try job.expect(server.code == 91, "Diagnostics.server.code is {d}, not 91", .{server.code});
    try job.expect(eql(u8, server.code_name.slice(), "ShutdownInProgress"), "Diagnostics.server.code_name is \"{s}\", not \"ShutdownInProgress\"", .{server.code_name.slice()});
    try job.expect(server.labels.contains(.system_overloaded_error) and server.labels.contains(.retryable_error), "Diagnostics.server.labels lack SystemOverloadedError or RetryableError", .{});
    try job.expect(eql(u8, d.message(), "The server is in quiesce mode and will shut down"), "Diagnostics.message() is \"{s}\", not the errmsg of the server", .{d.message()});
    try job.expect(fence.held() > 0, "failure_reply of runCommand was not allocated from options.allocator", .{});
    try expectFailureReply(job, &failure, s3_overloaded, "runCommand");
    try job.expect(fence.held() == 0, "{d} allocation(s) of options.allocator were left after failure_reply's deinit", .{fence.held()});

    try job.expectError(client.runCommand(io, .of(.root), .{ .database = database, .body = body }, .{ .allocator = job.gpa, .diagnostics = &d, .failure_reply = &failure }), error.Timeout, "a command answered with code 50");
    try job.expect(d.server != null and d.server.?.code == 50, "Diagnostics.server.code is not 50 after Timeout by code 50", .{});
    try expectFailureReply(job, &failure, s3_expired, "runCommand of code 50");

    try job.expectError(client.openCursor(io, .of(.root), .{ .database = database, .body = bson.literal(.{ .find = "s3" }) }, .{ .diagnostics = &d, .failure_reply = &failure }), error.CommandFailed, "openCursor answered with ok: 0");
    try job.expect(d.server != null and d.server.?.code == 26, "Diagnostics.server.code of openCursor is not 26", .{});
    try expectFailureReply(job, &failure, s3_missing, "openCursor");

    try job.expectError(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = bson.literal(.{ .insert = "s3" }), .items = docs[0..1] }, .{ .allocator = job.gpa, .diagnostics = &d, .failure_reply = &failure }), error.CommandFailed, "a write answered with ok: 0");
    try job.expect(d.server != null and d.server.?.code == 13, "Diagnostics.server.code of the write is not 13", .{});
    try expectFailureReply(job, &failure, s3_unauthorized, "write");
}

pub fn s4(job: *Job) Job.Error!void {
    const io = job.io;
    var cursor_handler: Script.Cursor = .{ .ns = database ++ ".s4", .batches = &.{ docs[0..1], docs[1..2] } };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, cursor_handler.handler(), .{});
    defer job.end();
    const script = &stage.script;

    var cursor = try job.need(client.openCursor(io, .of(.root), .{ .database = database, .body = bson.literal(.{ .find = "s4" }) }, .{}), "openCursor");
    defer cursor.deinit(io);
    _ = try job.need(cursor.next(io, .of(.root)), "next");

    var token: core.CancellationToken = .init;
    token.cancel();
    const canceled: OperationContext = .of(core.Context.root.withCancellation(&token));
    // A deadline that has passed, and one less than 1 ms away.
    const late = [_]OperationContext{
        .of(core.Context.root.withDeadline(.after(Job.now(io), .zero))),
        .of(core.Context.root.withDeadline(.after(Job.now(io), .fromMicroseconds(500)))),
    };
    for (late) |op| {
        try job.expectError(cursor.next(io, op), error.DeadlineExceeded, "next of a cursor past the deadline");
        try job.expectError(client.runCommand(io, op, .{ .database = database, .body = bson.literal(.{ .count = "s4" }) }, .{ .allocator = job.gpa }), error.DeadlineExceeded, "runCommand past the deadline");
        try job.expectError(client.openCursor(io, op, .{ .database = database, .body = bson.literal(.{ .find = "s4" }) }, .{}), error.DeadlineExceeded, "openCursor past the deadline");
        try job.expectError(client.write(io, op, .{ .database = database, .kind = .insert, .body = bson.literal(.{ .insert = "s4" }), .items = docs[0..1] }, .{ .allocator = job.gpa }), error.DeadlineExceeded, "write past the deadline");
    }
    try job.expectError(cursor.next(io, canceled), error.Cancelled, "next of a cursor with a canceled token");
    try job.expectError(client.runCommand(io, canceled, .{ .database = database, .body = bson.literal(.{ .count = "s4" }) }, .{ .allocator = job.gpa }), error.Cancelled, "runCommand with a canceled token");
    try job.expectError(client.openCursor(io, canceled, .{ .database = database, .body = bson.literal(.{ .find = "s4" }) }, .{}), error.Cancelled, "openCursor with a canceled token");
    try job.expectError(client.write(io, canceled, .{ .database = database, .kind = .insert, .body = bson.literal(.{ .insert = "s4" }), .items = docs[0..1] }, .{ .allocator = job.gpa }), error.Cancelled, "write with a canceled token");

    const bad_commands = [_]struct { []const u8, bson.RawDocument, OperationContext }{
        .{ "", bson.literal(.{ .count = "s4" }), .of(.root) },
        .{ "con.formance", bson.literal(.{ .count = "s4" }), .of(.root) },
        .{ "conformance$", bson.literal(.{ .count = "s4" }), .of(.root) },
        .{ database, bson.RawDocument.empty, .of(.root) },
        .{ database, bson.literal(.{ .@"$where" = "s4" }), .of(.root) },
        .{ database, bson.literal(.{ .count = "s4", .@"$db" = "other" }), .of(.root) },
        .{ database, bson.literal(.{ .count = "s4", .lsid = .{ .id = 1 } }), .of(.root) },
        .{ database, bson.literal(.{ .count = "s4", .@"$readPreference" = .{ .mode = "primary" } }), .of(.root) },
        .{ database, bson.literal(.{ .count = "s4", .maxTimeMS = 100 }), job.within(10_000) },
    };
    for (bad_commands) |bad| {
        const db, const body, const op = bad;
        try job.expectError(client.runCommand(io, op, .{ .database = db, .body = body }, .{ .allocator = job.gpa }), error.InvalidArgument, "runCommand of a bad request");
    }
    const bad_writes = [_]struct { bson.RawDocument, []const bson.RawDocument }{
        .{ bson.literal(.{ .update = "s4" }), docs[0..1] },
        .{ bson.literal(.{ .insert = "s4", .documents = .{.{ ._id = 1 }} }), docs[0..1] },
        .{ bson.literal(.{ .insert = "s4", .ordered = false }), docs[0..1] },
        .{ bson.literal(.{ .insert = "s4" }), docs[0..0] },
    };
    for (bad_writes) |bad| {
        const body, const items = bad;
        try job.expectError(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = body, .items = items }, .{ .allocator = job.gpa }), error.InvalidArgument, "write of a bad request");
    }
    for ([_][]const u8{ "count", "insert", "getMore", "$where" }) |name| {
        try job.expect(script.count(io, name) == 0, "the server got {s}, which was not to be sent", .{name});
    }
    try job.expect(script.count(io, "find") == 1, "the server got {d} find, and only the first was to be sent", .{script.count(io, "find")});
    // The cursor goes on.
    const next = try job.need(cursor.next(io, .of(.root)), "next after the calls that were not sent");
    try job.expect(next != null and eql(u8, next.?.bytes, docs[1].bytes), "the cursor did not go on to its next document", .{});
}

pub fn s5(job: *Job) Job.Error!void {
    const io = job.io;
    const late = bson.literal(.{ .n = 1, .late = true, .ok = 1.0 });
    const fresh = bson.literal(.{ .n = 2, .fresh = true, .ok = 1.0 });
    const hold = job.ms(600);
    var queue: Script.Queue = .{ .answers = &.{ .{ .delayed = .{ .after = hold, .reply = late } }, .{ .reply = fresh } } };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, queue.handler(), .{});
    defer job.end();
    const body = bson.literal(.{ .count = "s5" });

    const began = Job.now(io);
    const deadline: core.Deadline = .after(began, job.ms(200));
    const result = client.runCommand(io, .of(core.Context.root.withDeadline(deadline)), .{ .database = database, .body = body }, .{ .allocator = job.gpa });
    const ended = Job.now(io);
    try job.expectError(result, error.Timeout, "a command whose reply the server held past the deadline");
    const early = ended.durationTo(deadline.expires);
    try job.expect(early.nanoseconds <= std.time.ns_per_ms, "Timeout came {d} ms before the deadline", .{early.toMilliseconds()});
    const overdue = deadline.expires.durationTo(ended);
    try job.expect(overdue.nanoseconds <= job.ms(500).nanoseconds, "Timeout came {d} ms after the deadline", .{overdue.toMilliseconds()});

    // By now the server has written the late reply on its connection.
    const late_at = began.addDuration(hold).addDuration(job.ms(100));
    const wait = Job.now(io).durationTo(late_at);
    if (wait.nanoseconds > 0) job.pause(wait);
    const next = try job.need(client.runCommand(io, job.within(10_000), .{ .database = database, .body = body }, .{ .allocator = job.gpa }), "the command after the Timeout");
    defer next.deinit();
    try job.expect(eql(u8, next.bytes, fresh.bytes), "the command after the Timeout got {f}, not its own reply: the late reply of the command before was seen", .{next.raw()});
}

/// Holds `count`, cancels its token at `distinct`, answers the rest.
const S6 = struct {
    hold: Io.Duration,
    token: core.CancellationToken = .init,

    pub fn handler(h: *S6) Script.Handler {
        return .init(h);
    }

    pub fn answer(h: *S6, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        _ = arena;
        if (eql(u8, request.name, "count")) return .{ .delayed = .{ .after = h.hold, .reply = Script.ok } };
        if (eql(u8, request.name, "distinct")) h.token.cancel();
        return .{ .reply = Script.ok };
    }
};

pub fn s6(job: *Job) Job.Error!void {
    const io = job.io;
    var held_handler: S6 = .{ .hold = job.ms(10_000) };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, held_handler.handler(), .{});
    defer job.end();

    var held: Job.Caller = .init(job, client, .{ .database = database, .body = bson.literal(.{ .count = "s6" }) });
    defer held.deinit();
    try held.begin();
    try job.awaitReceived(&stage.script, "count", 1);
    const canceled_at = Job.now(io);
    held.cancel();
    const took = canceled_at.durationTo(Job.now(io));
    try job.expectCallError(&held, error.Interrupted, "a command whose task was canceled while the server held its reply");
    try job.expect(held.kept_cancel, "after Interrupted, io.checkCancel() in the task saw no cancelation: the driver swallowed it; it calls io.recancel() before it returns", .{});
    try job.expect(took.nanoseconds <= job.ms(2000).nanoseconds, "Interrupted came {d} ms after the task was canceled", .{took.toMilliseconds()});

    const op: OperationContext = .of(core.Context.root.withCancellation(&held_handler.token));
    try job.expectError(client.runCommand(io, op, .{ .database = database, .body = bson.literal(.{ .distinct = "s6", .key = "n" }) }, .{ .allocator = job.gpa }), error.Interrupted, "a command whose token was canceled while it was out");

    const next = try job.need(client.runCommand(io, job.within(10_000), .{ .database = database, .body = bson.literal(.{ .find = "s6" }) }, .{ .allocator = job.gpa }), "the command after Interrupted");
    next.deinit();
}

/// Echoes `echo` after a random delay of up to 20 ms; serves a cursor.
const S7 = struct {
    cursor: Script.Cursor,
    scale: i64,

    pub fn handler(h: *S7) Script.Handler {
        return .init(h);
    }

    pub fn answer(h: *S7, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        if (!eql(u8, request.name, "echo")) return h.cursor.answer(io, arena, request);
        var delay: [1]u8 = undefined;
        io.random(&delay);
        const value = (request.body.get("echo") catch null) orelse @as(bson.Value, .null);
        var b: bson.Builder = .init(arena);
        b.putValue("echo", value) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidBson => .{ .reply = Script.ok },
        };
        b.putDouble("ok", 1) catch return error.OutOfMemory;
        const reply = b.finish() catch return error.OutOfMemory;
        return .{ .delayed = .{ .after = .fromMilliseconds((delay[0] % 21) * h.scale), .reply = reply.raw() } };
    }
};

/// A cursor that one task opens and another reads on.
const Handed = struct {
    io: Io,
    gpa: Allocator,
    client: Client,
    cursor: ?Cursor = null,
    read: [docs.len]?bson.OwnedDocument = @splat(null),
    count: usize = 0,
    err: ?errors.Error = null,

    fn open(h: *Handed) void {
        h.cursor = h.client.openCursor(h.io, .of(.root), .{ .database = database, .body = bson.literal(.{ .find = "s7" }) }, .{}) catch |err| {
            h.err = err;
            return;
        };
        h.take(1);
    }

    fn take(h: *Handed, n: usize) void {
        const cursor = h.cursor orelse return;
        while (h.count < n) {
            const next = cursor.nextOwned(h.io, .of(.root), h.gpa) catch |err| {
                h.err = err;
                return;
            };
            h.read[h.count] = next orelse return;
            h.count += 1;
        }
    }

    fn rest(h: *Handed) void {
        h.take(h.read.len);
    }

    fn deinit(h: *Handed) void {
        for (h.read[0..h.count]) |doc| doc.?.deinit();
        if (h.cursor) |cursor| cursor.deinit(h.io);
    }
};

pub fn s7(job: *Job) Job.Error!void {
    const io = job.io;
    var echo: S7 = .{ .cursor = .{ .ns = database ++ ".s7", .batches = &.{ docs[0..2], docs[2..4], docs[4..6] } }, .scale = job.scale() };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, echo.handler(), .{});
    defer job.end();

    const n = 64;
    var bodies: [n]?bson.OwnedDocument = @splat(null);
    defer for (bodies) |body| if (body) |b| b.deinit();
    var callers: [n]Job.Caller = undefined;
    var begun: usize = 0;
    defer for (callers[0..begun]) |*caller| caller.deinit();
    for (&bodies, &callers, 0..) |*body, *caller, i| {
        body.* = try job.encode(.{ .echo = @as(i32, @intCast(i)) });
        caller.* = .init(job, client, .{ .database = database, .body = body.*.?.raw() });
        caller.op = job.within(30_000);
        try caller.begin();
        begun += 1;
    }
    for (&callers, 0..) |*caller, i| {
        caller.join();
        if (caller.err) |err| return job.fail("call {d} of 64 at once returned error.{t}", .{ i, err });
        const echoed = (caller.reply.?.raw().get("echo") catch null) orelse return job.fail("call {d} of 64 got a reply without echo", .{i});
        const got = echoed.asI64() catch -1;
        try job.expect(got == @as(i64, @intCast(i)), "call {d} of 64 got the reply of call {d}", .{ i, got });
    }

    // A cursor opened in one task goes on in another, after the first has
    // returned.
    var handed: Handed = .{ .io = io, .gpa = job.gpa, .client = client };
    defer handed.deinit();
    try job.inTask(Handed.open, .{&handed});
    try job.inTask(Handed.rest, .{&handed});
    if (handed.err) |err| return job.fail("a cursor handed from one task to another returned error.{t}", .{err});
    try job.expect(handed.count == 6, "a cursor handed from one task to another gave {d} documents, not 6", .{handed.count});
    for (handed.read[0..6], docs[0..6], 0..) |got, expected, i| {
        try job.expect(eql(u8, got.?.bytes, expected.bytes), "document {d} of a cursor handed between tasks came changed", .{i});
    }
}

/// The capabilities that revision 1 requires, and those it reserves.
const required = [_][]const u8{ "commands", "cursors", "aggregation", "batched_writes" };
const reserved = [_][]const u8{ "sessions", "transactions", "change_streams", "retryable_reads", "retryable_writes", "read_preference", "tailable_cursors", "bulk_write_command", "compression" };

pub fn s19(job: *Job) Job.Error!void {
    const io = job.io;
    var answering: Job.Answering = .{ .with = .{ .reply = Script.ok } };
    var stage: Job.Stage = undefined;
    const hello: wire.Hello = .{ .max_wire_version = 25, .max_bson_object_size = 4 * 1024 * 1024, .max_message_size_bytes = 8_000_000, .max_write_batch_size = 7 };
    const client = try job.scripted(&stage, answering.handler(), hello);
    defer job.end();

    const caps = client.capabilities();
    try job.expect(caps.revision >= 1 and caps.revision <= capabilities.contract_revision, "capabilities().revision is {d}; a driver of this zefir-mongo is of revision 1 to {d}", .{ caps.revision, capabilities.contract_revision });
    try job.expect(caps.name.len > 0, "capabilities().name is empty; name the driver, for logs and reports", .{});
    inline for (required) |name| {
        try job.expect(@field(caps, name), "capabilities()." ++ name ++ " is false; revision 1 requires it", .{});
    }
    inline for (reserved) |name| {
        try job.expect(!@field(caps, name), "capabilities()." ++ name ++ " is true; revision 1 reserves it, so a driver of revision 1 leaves it false", .{});
    }

    // After a command the driver has talked to the server for sure.
    const reply = try job.need(client.runCommand(io, job.within(10_000), .{ .database = database, .body = bson.literal(.{ .count = "s19" }) }, .{ .allocator = job.gpa }), "runCommand");
    reply.deinit();
    const again = client.capabilities();
    try job.expect(again.revision == caps.revision and std.mem.eql(u8, again.name, caps.name), "capabilities() changed from one call to the next: revision {d} \"{s}\", then {d} \"{s}\"", .{ caps.revision, caps.name, again.revision, again.name });
    inline for (required ++ reserved) |name| {
        try job.expect(@field(again, name) == @field(caps, name), "capabilities()." ++ name ++ " changed from one call to the next", .{});
    }
    if (again.server) |server| {
        try job.expect(server.kind == .standalone, "capabilities().server.kind is not standalone, and the server is a standalone mongod", .{});
        try job.expect(server.max_wire_version == hello.max_wire_version, "capabilities().server.max_wire_version is {d}; the server said {d} in hello", .{ server.max_wire_version, hello.max_wire_version });
        try job.expect(server.max_bson_object_size == hello.max_bson_object_size and server.max_message_size_bytes == hello.max_message_size_bytes and
            server.max_write_batch_size == hello.max_write_batch_size, "capabilities().server holds the limits {d}, {d} and {d}; the server said {d}, {d} and {d} in hello", .{
            server.max_bson_object_size, server.max_message_size_bytes, server.max_write_batch_size,
            hello.max_bson_object_size,  hello.max_message_size_bytes,  hello.max_write_batch_size,
        });
    }
}
