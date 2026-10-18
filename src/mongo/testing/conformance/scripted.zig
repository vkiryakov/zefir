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

/// A cursor, a write, `distinct` answered with `distinct`, and anything
/// else answered with `{ok: 1.0}`.
const Mixed = struct {
    cursor: Script.Cursor,
    write: Script.Write = .{},
    distinct: bson.RawDocument = Script.ok,

    pub fn handler(m: *Mixed) Script.Handler {
        return .init(m);
    }

    pub fn answer(m: *Mixed, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        const name = request.name;
        if (eql(u8, name, "find") or eql(u8, name, "getMore") or eql(u8, name, "killCursors")) return m.cursor.answer(io, arena, request);
        if (eql(u8, name, "insert") or eql(u8, name, "update") or eql(u8, name, "delete")) return m.write.answer(io, arena, request);
        if (eql(u8, name, "distinct")) return .{ .reply = m.distinct };
        return .{ .reply = Script.ok };
    }
};

/// A failure for the paths of errors.
const bad_value = bson.literal(.{ .ok = 0.0, .errmsg = "key must be a string", .code = 2, .codeName = "BadValue" });

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

/// Opens a cursor of `command` in `database` with no deadline.
fn open(job: *Job, client: Client, command: bson.RawDocument, options: requests.CursorOptions) Job.Error!Cursor {
    return job.need(client.openCursor(job.io, .of(.root), .{ .database = database, .body = command }, options), "openCursor");
}

/// Fails unless the journal holds `n` killCursors in all.
fn expectKills(job: *Job, script: *Script, n: usize, comptime what: []const u8) Job.Error!void {
    const got = script.count(job.io, "killCursors");
    try job.expect(got == n, what ++ ": the server has got {d} killCursors in all, not {d}", .{ got, n });
}

const s8_comment = bson.literal(.{ .tag = "S8", .n = 8 });

/// Fails unless `entry` is the getMore of cursor `id`, in `collection` of
/// `db`, with `batchSize` and `comment` of the options, and nothing else.
fn expectGetMore(job: *Job, entry: Script.Entry, id: i64, collection: []const u8, db: []const u8, batch_size: i64, comment: bson.RawDocument) Job.Error!void {
    var seen: [4]bool = @splat(false);
    var it = entry.body.iterator();
    while (it.next() catch return job.fail("getMore came as invalid BSON", .{})) |element| {
        const key = element.key;
        const value = element.value;
        if (eql(u8, key, "getMore")) {
            try job.expect(value == .int64 and value.int64 == id, "getMore came with another cursor id than the int64 {d} of the cursor", .{id});
            seen[0] = true;
        } else if (eql(u8, key, "collection")) {
            const got = if (value == .string) value.string else "";
            try job.expect(eql(u8, got, collection), "getMore came with the collection \"{s}\", not \"{s}\": it is the namespace of the cursor after its first dot", .{ got, collection });
            seen[1] = true;
        } else if (eql(u8, key, "batchSize")) {
            const n = value.asI64() catch -1;
            try job.expect(n == batch_size, "getMore came with batchSize {d}, not the {d} of the options", .{ n, batch_size });
            seen[2] = true;
        } else if (eql(u8, key, "comment")) {
            try job.expect(value == .document and eql(u8, value.document.bytes, comment.bytes), "getMore came with another comment than that of the options", .{});
            seen[3] = true;
        } else if (eql(u8, key, "$db")) {
            const got = if (value == .string) value.string else "";
            try job.expect(eql(u8, got, db), "getMore came with $db \"{s}\", not \"{s}\": it is the namespace of the cursor before its first dot", .{ got, db });
        } else return job.fail("getMore came with '{s}'; it carries getMore, collection, batchSize, comment and $db", .{key});
    }
    for (seen, [_][]const u8{ "getMore", "collection", "batchSize", "comment" }) |found, key| {
        try job.expect(found, "getMore came without {s}", .{key});
    }
}

pub fn s8(job: *Job) Job.Error!void {
    const io = job.io;
    // The namespace of the cursor names another database than the command,
    // and a collection with a dot in it: getMore follows the namespace.
    var chunks: Script.Cursor = .{ .ns = "conformance_ns.fs.chunks", .id = 8, .batches = &.{ docs[0..2], docs[2..4], docs[4..6], docs[6..7] } };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, chunks.handler(), .{});
    defer job.end();
    const script = &stage.script;
    var cursor = try open(job, client, bson.literal(.{ .find = "fs.chunks" }), .{ .batch_size = 2, .comment = .{ .document = s8_comment } });
    defer cursor.deinit(io);
    for (docs, 0..) |expected, i| {
        const doc = (try job.need(cursor.next(io, .of(.root)), "next")) orelse return job.fail("the cursor ended after {d} documents, not 7", .{i});
        try job.expect(eql(u8, doc.bytes, expected.bytes), "document {d} of the cursor came changed or out of its order", .{i});
    }
    for (0..2) |_| {
        const after = try job.need(cursor.next(io, .of(.root)), "next after the end");
        try job.expect(after == null, "next after the last document gave a document, not null", .{});
    }
    try job.expect(script.count(io, "getMore") == 3, "the cursor sent {d} getMore for the three batches after the first", .{script.count(io, "getMore")});
    try expectKills(job, script, 0, "a cursor read to its end");
    for (0..3) |i| try expectGetMore(job, try job.received(script, "getMore", i), 8, "fs.chunks", "conformance_ns", 2, s8_comment);
}

pub fn s9(job: *Job) Job.Error!void {
    const io = job.io;
    var cursor_handler: Script.Cursor = .{ .ns = database ++ ".s9", .id = 9, .batches = &.{ docs[0..1], docs[1..2], docs[2..3] } };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, cursor_handler.handler(), .{});
    defer job.end();
    const script = &stage.script;
    const find = bson.literal(.{ .find = "s9" });
    {
        var cursor = try open(job, client, find, .{});
        defer cursor.deinit(io);
        _ = try job.need(cursor.next(io, .of(.root)), "next");
        cursor.close(io);
        try expectKills(job, script, 1, "close in the middle of a cursor");
        cursor.close(io);
        try expectKills(job, script, 1, "a second close");
        try job.expectError(cursor.next(io, .of(.root)), error.Closed, "next after close");
    }
    try expectKills(job, script, 1, "deinit after close");
    {
        var cursor = try open(job, client, find, .{});
        _ = try job.need(cursor.next(io, .of(.root)), "next");
        cursor.deinit(io);
    }
    try expectKills(job, script, 2, "deinit in the middle of a cursor");
    {
        var cursor = try open(job, client, find, .{});
        defer cursor.deinit(io);
        while (try job.need(cursor.next(io, .of(.root)), "next")) |_| {}
        cursor.close(io);
    }
    try expectKills(job, script, 2, "close and deinit of a cursor read to its end");
    {
        const op = job.within(300);
        var cursor = try job.need(client.openCursor(io, op, .{ .database = database, .body = find }, .{}), "openCursor");
        defer cursor.deinit(io);
        _ = try job.need(cursor.next(io, op), "next");
        job.pause(job.ms(350));
        cursor.close(io);
        try expectKills(job, script, 3, "close of a cursor whose deadline has passed: its killCursors has a budget of its own");
    }
    for (0..3) |i| {
        const kill = try job.received(script, "killCursors", i);
        try job.expectSent(kill.body, bson.literal(.{ .killCursors = "s9", .cursors = .{@as(i64, 9)} }), database, &.{}, "killCursors");
    }
}

const cursor_not_found = bson.literal(.{ .ok = 0.0, .errmsg = "cursor id 10 not found", .code = 43, .codeName = "CursorNotFound" });

/// A cursor whose getMore the check breaks; aggregate gets a reply without
/// a cursor.
const S10 = struct {
    cursor: Script.Cursor,
    get_more: std.atomic.Value(GetMore) = .init(.serve),

    const GetMore = enum(u8) { serve, lose, not_found };

    pub fn handler(h: *S10) Script.Handler {
        return .init(h);
    }

    pub fn answer(h: *S10, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        if (eql(u8, request.name, "aggregate")) return .{ .reply = bson.literal(.{ .n = 1, .ok = 1.0 }) };
        if (eql(u8, request.name, "getMore")) switch (h.get_more.load(.acquire)) {
            .serve => {},
            .lose => return .close_connection,
            .not_found => return .{ .reply = cursor_not_found },
        };
        return h.cursor.answer(io, arena, request);
    }
};

pub fn s10(job: *Job) Job.Error!void {
    const io = job.io;
    var faulty: S10 = .{ .cursor = .{ .ns = database ++ ".s10", .id = 10, .batches = &.{ docs[0..1], docs[1..2], docs[2..3], docs[3..4] } } };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, faulty.handler(), .{});
    defer job.end();
    const script = &stage.script;
    const find = bson.literal(.{ .find = "s10" });
    {
        var cursor = try open(job, client, find, .{});
        defer cursor.deinit(io);
        _ = try job.need(cursor.next(io, .of(.root)), "next");
        const past: OperationContext = .of(core.Context.root.withDeadline(.after(Job.now(io), .zero)));
        try job.expectError(cursor.next(io, past), error.DeadlineExceeded, "next past the deadline before getMore");
        try job.expect(script.count(io, "getMore") == 0, "next past the deadline sent getMore", .{});
        const second = try job.need(cursor.next(io, .of(.root)), "next after DeadlineExceeded");
        try job.expect(second != null and eql(u8, second.?.bytes, docs[1].bytes), "after DeadlineExceeded before getMore, the cursor did not go on to its next document", .{});
        faulty.get_more.store(.lose, .release);
        try job.expectError(cursor.next(io, .of(.root)), error.ConnectionLost, "next whose getMore lost its connection");
        try job.expectError(cursor.next(io, .of(.root)), error.Closed, "next after a lost getMore");
        try job.expectError(cursor.next(io, .of(.root)), error.Closed, "next again after a lost getMore");
    }
    faulty.get_more.store(.serve, .release);
    try job.expectError(client.openCursor(io, .of(.root), .{ .database = database, .body = bson.literal(.{ .aggregate = "s10", .pipeline = [0]i32{}, .cursor = .{} }) }, .{}), error.ProtocolViolation, "openCursor answered without cursor");
    {
        var d: errors.Diagnostics = .{};
        var cursor = try open(job, client, find, .{ .diagnostics = &d });
        defer cursor.deinit(io);
        _ = try job.need(cursor.next(io, .of(.root)), "next");
        faulty.get_more.store(.not_found, .release);
        try job.expectError(cursor.next(io, .of(.root)), error.CommandFailed, "next whose getMore got CursorNotFound");
        try job.expect(d.server != null and d.server.?.code == 43, "Diagnostics.server.code after CursorNotFound is not 43", .{});
        try job.expectError(cursor.next(io, .of(.root)), error.Closed, "next after CursorNotFound");
    }
}

/// Serves a cursor and holds `count`.
const Held = struct {
    cursor: Script.Cursor,
    hold: Io.Duration,

    pub fn handler(h: *Held) Script.Handler {
        return .init(h);
    }

    pub fn answer(h: *Held, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        if (eql(u8, request.name, "count")) return .{ .delayed = .{ .after = h.hold, .reply = Script.ok } };
        return h.cursor.answer(io, arena, request);
    }
};

pub fn s17(job: *Job) Job.Error!void {
    const io = job.io;
    const hold = job.ms(2000);
    var held_handler: Held = .{ .cursor = .{ .ns = database ++ ".s17", .id = 17, .batches = &.{ docs[0..1], docs[1..2] } }, .hold = hold };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, held_handler.handler(), .{});
    defer job.end();
    const script = &stage.script;
    const count_s17 = bson.literal(.{ .count = "s17" });
    const find = bson.literal(.{ .find = "s17" });
    var cursor = try open(job, client, find, .{});
    defer cursor.deinit(io);
    _ = try job.need(cursor.next(io, .of(.root)), "next");

    var callers: [4]Job.Caller = undefined;
    var begun: usize = 0;
    defer for (callers[0..begun]) |*caller| caller.deinit();
    for (&callers) |*caller| {
        caller.* = .init(job, client, .{ .database = database, .body = count_s17 });
        try caller.begin();
        begun += 1;
    }
    try job.awaitReceived(script, "count", 1);

    const began = Job.now(io);
    job.close();
    const closed_in = began.durationTo(Job.now(io));
    const bound = hold.nanoseconds + job.ms(3000).nanoseconds;
    for (&callers, 0..) |*caller, i| {
        caller.join();
        if (caller.err) |err| switch (err) {
            error.ConnectionLost, error.Closed => {},
            else => return job.fail("call {d}, out at close, returned error.{t}; close cuts a call with ConnectionLost, and one waiting for a connection gets Closed", .{ i, err }),
        };
        const took = began.durationTo(caller.ended);
        try job.expect(took.nanoseconds <= bound, "call {d}, out at close, returned {d} ms after close began", .{ i, took.toMilliseconds() });
    }
    try job.expect(closed_in.nanoseconds <= bound, "close took {d} ms with calls out", .{closed_in.toMilliseconds()});
    try expectKills(job, script, 1, "close of the client with a cursor open");
    try job.expectSent((try job.received(script, "killCursors", 0)).body, bson.literal(.{ .killCursors = "s17", .cursors = .{@as(i64, 17)} }), database, &.{}, "killCursors of close");

    try job.expectError(client.runCommand(io, .of(.root), .{ .database = database, .body = count_s17 }, .{ .allocator = job.gpa }), error.Closed, "runCommand after close");
    try job.expectError(client.openCursor(io, .of(.root), .{ .database = database, .body = find }, .{}), error.Closed, "openCursor after close");
    try job.expectError(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = bson.literal(.{ .insert = "s17" }), .items = docs[0..1] }, .{ .allocator = job.gpa }), error.Closed, "write after close");
    try job.expectError(cursor.next(io, .of(.root)), error.Closed, "next of a cursor after close of the client");

    const received = script.received(io);
    const again = Job.now(io);
    job.close();
    const twice = again.durationTo(Job.now(io));
    try job.expect(twice.nanoseconds <= job.ms(1000).nanoseconds, "a second close took {d} ms", .{twice.toMilliseconds()});
    cursor.close(io);
    try job.expect(script.received(io) == received, "a second close, or close of a cursor after close of the client, sent {d} command(s)", .{script.received(io) - received});
}

const s18_comment = "the comment of S18";

pub fn s18(job: *Job) Job.Error!void {
    const io = job.io;
    var mixed: Mixed = .{
        .cursor = .{ .ns = database ++ ".s18", .id = 18, .batches = &.{ docs[0..1], docs[1..2], docs[2..3] } },
        .write = .{ .refuse = &.{.{ .index = 1 }} },
        .distinct = bad_value,
    };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, mixed.handler(), .{});
    defer job.end();
    const script = &stage.script;
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var fences: [3]Job.Fence = @splat(.{ .parent = a });

    // A reply: one allocation of the call's allocator.
    const reply = try job.need(client.runCommand(io, .of(.root), .{ .database = database, .body = bson.literal(.{ .count = "s18" }) }, .{ .allocator = fences[0].allocator() }), "runCommand");
    fences[0].close();
    try job.expect(fences[0].held() == 1, "the reply is {d} allocation(s) of options.allocator, not one", .{fences[0].held()});
    reply.deinit();
    try job.expect(fences[0].held() == 0, "the reply's deinit left an allocation of options.allocator", .{});

    // The result of a write, refused items among it: all of it from the
    // call's allocator.
    var items: [3]bson.RawDocument = undefined;
    for (&items, docs[0..3]) |*item, doc| item.* = .{ .bytes = try a.dupe(u8, doc.bytes) };
    var result = try job.need(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = bson.literal(.{ .insert = "s18" }), .items = &items, .ordered = false }, .{ .allocator = fences[1].allocator() }), "write");
    fences[1].close();
    for (items) |item| @memset(@constCast(item.bytes), 0xAA);
    try job.expect(result.write_errors.len == 1, "the write came back with {d} refused items, not 1", .{result.write_errors.len});
    result.deinit(fences[1].allocator());
    try job.expect(fences[1].held() == 0, "{d} allocation(s) of options.allocator were left after the result's deinit: a WriteResult is all from options.allocator", .{fences[1].held()});

    // A cursor: its command, database and comment are the caller's, and may
    // change once openCursor has returned.
    const db = try a.dupe(u8, database);
    const find = try a.dupe(u8, bson.literal(.{ .find = "s18" }).bytes);
    const comment = try a.dupe(u8, s18_comment);
    var cursor = try job.need(client.openCursor(io, .of(.root), .{ .database = db, .body = .{ .bytes = find } }, .{ .comment = .{ .string = comment }, .batch_size = 1 }), "openCursor");
    defer cursor.deinit(io);
    @memset(db, 'x');
    @memset(find, 0xAA);
    @memset(comment, '?');
    var n: usize = 0;
    while (try job.need(cursor.next(io, .of(.root)), "next")) |doc| : (n += 1) {
        try job.expect(n < 3 and eql(u8, doc.bytes, docs[n].bytes), "document {d} of the cursor came changed", .{n});
    }
    try job.expect(n == 3, "the cursor gave {d} documents, not 3", .{n});
    for (0..2) |i| {
        const more = try job.received(script, "getMore", i);
        const got = if (more.body.get("comment") catch null) |value| switch (value) {
            .string => |text| text,
            else => "",
        } else "";
        try job.expect(eql(u8, got, s18_comment), "getMore came with the comment \"{s}\": the driver kept the caller's comment instead of a copy", .{got});
        try job.expect(eql(u8, more.database, database), "getMore came with $db \"{s}\": the driver kept the caller's database instead of the namespace of the cursor", .{more.database});
    }

    // failure_reply: from the call's allocator too.
    var failure: ?bson.OwnedDocument = null;
    try job.expectError(client.runCommand(io, .of(.root), .{ .database = database, .body = bson.literal(.{ .distinct = "s18", .key = "n" }) }, .{ .allocator = fences[2].allocator(), .failure_reply = &failure }), error.CommandFailed, "a command answered with ok: 0");
    fences[2].close();
    if (failure) |f| f.deinit() else return job.fail("failure_reply is null after CommandFailed", .{});
    try job.expect(fences[2].held() == 0, "failure_reply is not one allocation of options.allocator", .{});

    for (&fences, [_][]const u8{ "runCommand", "write", "runCommand of a failure" }) |*fence, what| {
        try job.expect(fence.late() == 0, "{s} took memory of its options.allocator {d} time(s) after it returned", .{ what, fence.late() });
    }
}

/// Closes and frees cursors, fails a command and closes the client, all in
/// a task with a cancelation pending, and tells after each step whether
/// the cancelation is still there.
const Keeper = struct {
    job: *Job,
    client: Client,
    closing: Cursor,
    freeing: Cursor,
    canceled: bool = false,
    freed: bool = false,
    kept: [4]?bool = @splat(null),

    const steps = [_][]const u8{ "close of a cursor", "deinit of a cursor", "a command that failed", "close of the client" };

    fn task(k: *Keeper) void {
        const io = k.job.io;
        // Waits until the check cancels the task.
        if (io.sleep(.fromSeconds(3600), .awake)) |_| return else |_| {}
        k.canceled = true;
        for (0..steps.len) |i| {
            io.recancel();
            switch (i) {
                0 => k.closing.close(io),
                1 => {
                    k.freeing.deinit(io);
                    k.freed = true;
                },
                2 => if (k.client.runCommand(io, .of(.root), .{ .database = database, .body = bson.literal(.{ .distinct = "s20", .key = "n" }) }, .{ .allocator = k.job.gpa })) |reply| reply.deinit() else |_| {},
                else => k.job.close(),
            }
            k.kept[i] = if (io.checkCancel()) |_| false else |_| true;
            if (!k.kept[i].?) return;
        }
    }
};

pub fn s20(job: *Job) Job.Error!void {
    const io = job.io;
    var mixed: Mixed = .{ .cursor = .{ .ns = database ++ ".s20", .id = 20, .batches = &.{ docs[0..1], docs[1..2] } }, .distinct = bad_value };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, mixed.handler(), .{});
    defer job.end();
    const find = bson.literal(.{ .find = "s20" });
    const closing = try open(job, client, find, .{});
    defer closing.deinit(io);
    var keeper: Keeper = .{ .job = job, .client = client, .closing = closing, .freeing = try open(job, client, find, .{}) };
    defer if (!keeper.freed) keeper.freeing.deinit(io);
    _ = try job.need(closing.next(io, .of(.root)), "next");
    _ = try job.need(keeper.freeing.next(io, .of(.root)), "next");
    var task = io.concurrent(Keeper.task, .{&keeper}) catch |err| return job.fail("no task for the check: io.concurrent returned error.{t}", .{err});
    task.cancel(io);
    try job.expect(keeper.canceled, "the task of the check was not canceled", .{});
    for (keeper.kept, Keeper.steps) |kept, step| {
        const still = kept orelse break;
        try job.expect(still, "{s} swallowed a cancelation of its task: io.checkCancel() after it saw none", .{step});
    }
}

/// Ten inserts, `{_id: 0}` to `{_id: 9}`.
const ten = ten: {
    var items: [10]bson.RawDocument = undefined;
    for (&items, 0..) |*item, i| item.* = bson.literal(.{ ._id = @as(i32, i) });
    break :ten items;
};

/// Ten updates of `{_id: 0}` to `{_id: 9}`.
const ten_updates = updates: {
    var items: [10]bson.RawDocument = undefined;
    for (&items, 0..) |*item, i| item.* = bson.literal(.{ .q = .{ ._id = @as(i32, i) }, .u = .{ .@"$set" = .{ .seen = true } } });
    break :updates items;
};

/// Four deletes of `{_id: 0}` to `{_id: 3}`.
const four_deletes = deletes: {
    var items: [4]bson.RawDocument = undefined;
    for (&items, 0..) |*item, i| item.* = bson.literal(.{ .q = .{ ._id = @as(i32, i) }, .limit = 1 });
    break :deletes items;
};

/// The length of the OP_MSG that carried `entry`, without a checksum.
fn messageLength(entry: Script.Entry) usize {
    var n: usize = 16 + 4 + 1 + entry.body.bytes.len;
    if (entry.sequence) |sequence| n += 1 + 4 + sequence.identifier.len + 1 + sequence.bytes.len;
    return n;
}

/// Fails unless the journal's commands named `name`, from number `first`
/// on, carry `items` in their order, in batches of `sizes`, each in a
/// section of kind 1 named `identifier`, with `body` as the caller wrote it
/// plus `ordered` and `$db`.
fn expectBatches(job: *Job, script: *Script, name: []const u8, first: usize, identifier: []const u8, items: []const bson.RawDocument, sizes: []const usize, body: bson.RawDocument, ordered: bool) Job.Error!void {
    const io = job.io;
    try job.expect(script.count(io, name) == first + sizes.len, "{d} items went out in {d} {s} command(s), not {d}", .{ items.len, script.count(io, name) - first, name, sizes.len });
    var at: usize = 0;
    for (sizes, first..) |size, i| {
        const entry = try job.received(script, name, i);
        const sequence = entry.sequence orelse return job.fail("batch {d} of {s} came without a section of kind 1; its items go in one", .{ i - first, name });
        try job.expect(eql(u8, sequence.identifier, identifier), "batch {d} of {s} came in a section of kind 1 named \"{s}\", not \"{s}\"", .{ i - first, name, sequence.identifier, identifier });
        var sent = sequence.documents();
        var n: usize = 0;
        while (sent.next()) |doc| : (n += 1) {
            try job.expect(at + n < items.len and eql(u8, doc.bytes, items[at + n].bytes), "item {d} of {s} came changed or out of its order", .{ at + n, name });
        }
        try job.expect(n == size, "batch {d} of {s} carried {d} items, not {d}", .{ i - first, name, n, size });
        at += n;
        try job.expectSent(entry.body, body, database, &.{"ordered"}, "a batch of a write");
        const flag = (entry.body.get("ordered") catch null) orelse return job.fail("batch {d} of {s} came without ordered", .{ i - first, name });
        try job.expect(flag == .boolean and flag.boolean == ordered, "batch {d} of {s} came with another ordered than the request's {}", .{ i - first, name, ordered });
    }
}

pub fn s11(job: *Job) Job.Error!void {
    const io = job.io;
    var writes: Script.Write = .{};
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, writes.handler(), .{ .max_write_batch_size = 3 });
    defer job.end();
    const script = &stage.script;
    const kinds = [_]struct { requests.WriteKind, bson.RawDocument, []const bson.RawDocument, []const usize }{
        .{ .insert, bson.literal(.{ .insert = "s11" }), &ten, &.{ 3, 3, 3, 1 } },
        .{ .update, bson.literal(.{ .update = "s11" }), ten_updates[0..4], &.{ 3, 1 } },
        .{ .delete, bson.literal(.{ .delete = "s11" }), &four_deletes, &.{ 3, 1 } },
    };
    for (kinds) |write| {
        const kind, const body, const items, const sizes = write;
        var result = try job.need(client.write(io, .of(.root), .{ .database = database, .kind = kind, .body = body, .items = items }, .{ .allocator = job.gpa }), "write");
        defer result.deinit(job.gpa);
        try job.expect(result.n == items.len, "a write of {d} items that the server took in batches came back with n is {d}: the n of the batches add up", .{ items.len, result.n });
        try job.expect(result.answered == items.len, "a write of {d} items came back with answered {d}", .{ items.len, result.answered });
        if (kind == .update) try job.expect(result.modified == items.len, "an update of {d} items came back with modified {d}: the nModified of the batches add up", .{ items.len, result.modified });
        try expectBatches(job, script, kind.command(), 0, kind.items(), items, sizes, body, true);
    }
}

pub fn s12(job: *Job) Job.Error!void {
    const io = job.io;
    var writes: Script.Write = .{};
    var stage: Job.Stage = undefined;
    const hello: wire.Hello = .{ .max_message_size_bytes = 2048, .max_bson_object_size = 512 };
    const client = try job.scripted(&stage, writes.handler(), hello);
    defer job.end();
    const script = &stage.script;
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pad = try a.alloc(u8, 2100);
    @memset(pad, 'p');
    const body = bson.literal(.{ .insert = "s12" });

    // Twelve items of 304 bytes: a message holds six.
    var items: [12]bson.RawDocument = undefined;
    for (&items, 0..) |*item, i| item.* = (try job.encodeIn(a, .{ ._id = @as(i32, @intCast(i)), .pad = pad[0..280] })).raw();
    var result = try job.need(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = body, .items = &items }, .{ .allocator = job.gpa }), "a write of twelve items");
    result.deinit(job.gpa);
    const batches = script.count(io, "insert");
    try job.expect(batches >= 2, "twelve items of 304 bytes went out in one message, which the server takes at 2048 bytes at most", .{});
    var at: usize = 0;
    for (0..batches) |i| {
        const entry = try job.received(script, "insert", i);
        try job.expect(messageLength(entry) <= hello.max_message_size_bytes, "batch {d} went out in a message of {d} bytes; the server takes {d} at most", .{ i, messageLength(entry), hello.max_message_size_bytes });
        var sent = (entry.sequence orelse return job.fail("batch {d} came without a section of kind 1", .{i})).documents();
        while (sent.next()) |doc| : (at += 1) {
            try job.expect(at < items.len and eql(u8, doc.bytes, items[at].bytes), "item {d} came changed or out of its order", .{at});
        }
    }
    try job.expect(at == items.len, "{d} of twelve items went out", .{at});

    // An item that no message holds alone: not sent.
    const huge = (try job.encodeIn(a, .{ ._id = 100, .pad = pad })).raw();
    try job.expectError(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = body, .items = &.{ items[0], huge } }, .{ .allocator = job.gpa }), error.InvalidArgument, "a write of an item that no message holds");
    try job.expect(script.count(io, "insert") == batches, "a write of an item that no message holds sent a batch", .{});

    // An item larger than maxBsonObjectSize, within a message: it goes out,
    // and the server refuses it, not the driver.
    const large = (try job.encodeIn(a, .{ ._id = 200, .pad = pad[0..700] })).raw();
    var sent = try job.need(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = body, .items = &.{large} }, .{ .allocator = job.gpa }), "a write of an item larger than maxBsonObjectSize");
    sent.deinit(job.gpa);
    const last = try job.received(script, "insert", batches);
    var carried = (last.sequence orelse return job.fail("the large item came without a section of kind 1", .{})).documents();
    const item = carried.next() orelse return job.fail("the large item came without items", .{});
    try job.expect(eql(u8, item.bytes, large.bytes), "the item larger than maxBsonObjectSize came changed", .{});
}

/// The `q._id` of the first item of a write's batch.
fn firstItemId(request: *const Script.Request) ?i64 {
    const sequence = request.sequence orelse return null;
    var items = sequence.documents();
    const first = items.next() orelse return null;
    const id = (first.getPath("q._id") catch null) orelse return null;
    return id.asI64() catch null;
}

const replication_timeout = .{ .code = 64, .codeName = "WriteConcernTimeout", .errmsg = "waiting for replication timed out" };

/// Answers each batch of ten updates, by its first item, with upserts,
/// refused items and failed write concerns, indexed in the batch.
const S13 = struct {
    pub fn handler(h: *S13) Script.Handler {
        return .init(h);
    }

    pub fn answer(h: *S13, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = h;
        _ = io;
        _ = arena;
        return .{ .reply = switch (firstItemId(request) orelse -1) {
            0 => bson.literal(.{ .n = 3, .nModified = 2, .upserted = .{.{ .index = 1, ._id = "up-1" }}, .ok = 1.0 }),
            3 => bson.literal(.{ .n = 2, .nModified = 1, .writeErrors = .{.{ .index = 2, .code = 11000, .errmsg = "E11000 duplicate key error" }}, .ok = 1.0 }),
            6 => bson.literal(.{ .n = 3, .nModified = 3, .writeConcernError = replication_timeout, .ok = 1.0 }),
            9 => bson.literal(.{ .n = 1, .nModified = 0, .upserted = .{.{ .index = 0, ._id = "up-9" }}, .writeConcernError = replication_timeout, .ok = 1.0 }),
            else => bad_value,
        } };
    }
};

fn expectUpserted(job: *Job, got: results.Upserted, index: usize, id: []const u8) Job.Error!void {
    try job.expect(got.index == index, "an upsert came with the index {d}, not {d}: indexes count in the whole request", .{ got.index, index });
    try job.expect(got.id == .string and eql(u8, got.id.string, id), "the upsert of item {d} came with another _id than \"{s}\"", .{ index, id });
}

pub fn s13(job: *Job) Job.Error!void {
    const io = job.io;
    var merging: S13 = .{};
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, merging.handler(), .{ .max_write_batch_size = 3 });
    defer job.end();
    const script = &stage.script;
    const body = bson.literal(.{ .update = "s13" });

    var result = try job.need(client.write(io, .of(.root), .{ .database = database, .kind = .update, .body = body, .items = &ten_updates, .ordered = false }, .{ .allocator = job.gpa }), "an unordered write with refused items");
    defer result.deinit(job.gpa);
    try job.expect(script.count(io, "update") == 4, "an unordered write sent {d} batches of 4", .{script.count(io, "update")});
    try job.expect(result.n == 9 and result.modified == 6, "the merge came with n {d} and modified {d}, not the sums 9 and 6", .{ result.n, result.modified });
    try job.expect(result.upserted.len == 2, "the merge came with {d} upserts, not 2", .{result.upserted.len});
    try expectUpserted(job, result.upserted[0], 1, "up-1");
    try expectUpserted(job, result.upserted[1], 9, "up-9");
    try job.expect(result.write_errors.len == 1, "the merge came with {d} refused items, not 1", .{result.write_errors.len});
    const refused = result.write_errors[0];
    try job.expect(refused.index == 5 and refused.code == 11000 and eql(u8, refused.message, "E11000 duplicate key error"), "the refused item came as index {d}, code {d}, \"{s}\"; the server refused index 5, code 11000", .{ refused.index, refused.code, refused.message });
    try job.expect(result.write_concern_errors.len == 2, "the merge came with {d} failed write concerns, not those of the 2 batches", .{result.write_concern_errors.len});
    for (result.write_concern_errors) |concern| try job.expect(concern.code == 64, "a failed write concern came with the code {d}, not 64", .{concern.code});
    try job.expect(result.answered == 10, "the merge came with answered {d}, not 10", .{result.answered});
    try expectBatches(job, script, "update", 0, "updates", &ten_updates, &.{ 3, 3, 3, 1 }, body, false);

    var ordered = try job.need(client.write(io, .of(.root), .{ .database = database, .kind = .update, .body = body, .items = &ten_updates }, .{ .allocator = job.gpa }), "an ordered write with a refused item");
    defer ordered.deinit(job.gpa);
    try job.expect(script.count(io, "update") == 6, "an ordered write sent {d} batches; it sends none after the batch with a refused item, the second", .{script.count(io, "update") - 4});
    try job.expect(ordered.n == 5 and ordered.modified == 3 and ordered.answered == 6, "the ordered merge came with n {d}, modified {d}, answered {d}, not 5, 3 and 6", .{ ordered.n, ordered.modified, ordered.answered });
    try job.expect(ordered.upserted.len == 1 and ordered.write_errors.len == 1 and ordered.write_errors[0].index == 5, "the ordered merge came with other upserts or refused items than those of its two batches", .{});
}

const three = bson.literal(.{ .n = 3, .ok = 1.0 });

pub fn s14(job: *Job) Job.Error!void {
    const io = job.io;
    var queue: Script.Queue = .{ .answers = &.{ .{ .reply = three }, .{ .reply = three }, .close_connection } };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, queue.handler(), .{ .max_write_batch_size = 3 });
    defer job.end();
    const script = &stage.script;
    var arena: std.heap.ArenaAllocator = .init(job.gpa);
    defer arena.deinit();
    var fence: Job.Fence = .{ .parent = arena.allocator() };
    var partial: results.WriteResult = .{};
    var d: errors.Diagnostics = .{};
    const body = bson.literal(.{ .insert = "s14" });
    try job.expectError(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = body, .items = &ten }, .{ .allocator = fence.allocator(), .diagnostics = &d, .partial = &partial }), error.IncompleteWrite, "a write whose third batch lost its connection");
    try job.expect(d.reason == @as(?errors.Error, error.ConnectionLost), "Diagnostics.reason of the IncompleteWrite is {?t}, not ConnectionLost", .{d.reason});
    try job.expect(d.batch_offset == 6, "Diagnostics.batch_offset of the IncompleteWrite is {?d}, not 6", .{d.batch_offset});
    try job.expect(partial.n == 6 and partial.answered == 6, "partial came with n {d} and answered {d}, not the 6 of the two batches answered", .{ partial.n, partial.answered });
    try job.expect(script.count(io, "insert") == 3, "the write sent {d} batches, not 3", .{script.count(io, "insert")});
    partial.deinit(fence.allocator());
    try job.expect(fence.held() == 0, "partial is not all from options.allocator", .{});

    try job.expectError(client.write(io, .of(.root), .{ .database = database, .kind = .insert, .body = body, .items = &.{} }, .{ .allocator = job.gpa }), error.InvalidArgument, "a write without items");
    try job.expect(script.count(io, "insert") == 3, "a write without items reached the server", .{});
}

/// Closes the connection of the first command, refuses connections at the
/// second, and answers the rest.
const S15 = struct {
    seen: std.atomic.Value(u32) = .init(0),

    pub fn handler(h: *S15) Script.Handler {
        return .init(h);
    }

    pub fn answer(h: *S15, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        _ = arena;
        _ = request;
        return switch (h.seen.fetchAdd(1, .monotonic)) {
            0 => .close_connection,
            1 => .refuse_connections,
            else => .{ .reply = Script.ok },
        };
    }
};

pub fn s15(job: *Job) Job.Error!void {
    const io = job.io;
    var lossy: S15 = .{};
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, lossy.handler(), .{});
    defer job.end();
    const script = &stage.script;
    const command: requests.Command = .{ .database = database, .body = bson.literal(.{ .count = "s15" }) };
    try job.expectError(client.runCommand(io, job.within(10_000), command, .{ .allocator = job.gpa }), error.ConnectionLost, "a command whose connection the server closed after reading it");
    try job.expectError(client.runCommand(io, job.within(10_000), command, .{ .allocator = job.gpa }), error.ConnectionLost, "a command whose connection the server closed, refusing new ones");
    try job.expectError(client.runCommand(io, job.within(10_000), command, .{ .allocator = job.gpa }), error.Unavailable, "a command while the server refuses connections");
    try job.expect(script.received(io) == 2, "a command while the server refuses connections reached it", .{});
    script.acceptConnections();
    // Calls may be Unavailable while the driver reconnects; then they go
    // through.
    const deadline: core.Deadline = .after(Job.now(io), job.ms(10_000));
    while (true) {
        if (client.runCommand(io, job.within(5_000), command, .{ .allocator = job.gpa })) |reply| {
            reply.deinit();
            break;
        } else |err| {
            if (err != error.Unavailable) return job.fail("a command after the server came back returned error.{t}", .{err});
            if (deadline.isExpired(Job.now(io))) return job.fail("commands did not go through within {d} s after the server came back", .{10 * job.scale()});
            job.pause(job.ms(50));
        }
    }
}

pub fn s16(job: *Job) Job.Error!void {
    const io = job.io;
    const kinds = [_]Script.Malformed{ .wrong_response_to, .unknown_required_flag, .sequence_in_reply, .truncated };
    var answers: [2 * kinds.len]Script.Answer = undefined;
    for (kinds, 0..) |kind, i| {
        answers[2 * i] = .{ .malformed = kind };
        answers[2 * i + 1] = .{ .reply = Script.ok };
    }
    var queue: Script.Queue = .{ .answers = &answers };
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, queue.handler(), .{});
    defer job.end();
    const script = &stage.script;
    const command: requests.Command = .{ .database = database, .body = bson.literal(.{ .count = "s16" }) };
    for (kinds, 0..) |kind, i| {
        if (client.runCommand(io, job.within(10_000), command, .{ .allocator = job.gpa })) |reply| {
            reply.deinit();
            return job.fail("a reply that breaks OP_MSG ({t}) was taken", .{kind});
        } else |err| {
            try job.expect(err == error.ProtocolViolation, "a reply that breaks OP_MSG ({t}) gave error.{t}, not ProtocolViolation", .{ kind, err });
        }
        const next = try job.need(client.runCommand(io, job.within(10_000), command, .{ .allocator = job.gpa }), "the command after a ProtocolViolation");
        next.deinit();
        const broken = try job.received(script, "count", 2 * i);
        const after = try job.received(script, "count", 2 * i + 1);
        try job.expect(after.connection != broken.connection, "after a ProtocolViolation ({t}), the next command came on the same connection; a connection is not used after a violation", .{kind});
    }
}

/// Cancels its token at the second batch of a write.
const S21 = struct {
    write: Script.Write = .{},
    token: core.CancellationToken = .init,
    batches: std.atomic.Value(u32) = .init(0),

    pub fn handler(h: *S21) Script.Handler {
        return .init(h);
    }

    pub fn answer(h: *S21, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        if (h.batches.fetchAdd(1, .monotonic) == 1) h.token.cancel();
        return h.write.answer(io, arena, request);
    }
};

pub fn s21(job: *Job) Job.Error!void {
    const io = job.io;
    var canceler: S21 = .{};
    var stage: Job.Stage = undefined;
    const client = try job.scripted(&stage, canceler.handler(), .{ .max_write_batch_size = 3 });
    defer job.end();
    const script = &stage.script;
    const body = bson.literal(.{ .insert = "s21" });
    var partial: results.WriteResult = .{};
    defer partial.deinit(job.gpa);
    var d: errors.Diagnostics = .{};
    const op: OperationContext = .of(core.Context.root.withCancellation(&canceler.token));
    try job.expectError(client.write(io, op, .{ .database = database, .kind = .insert, .body = body, .items = &ten }, .{ .allocator = job.gpa, .diagnostics = &d, .partial = &partial }), error.IncompleteWrite, "a write whose token was canceled while its second batch was out");
    try job.expect(d.reason == @as(?errors.Error, error.Cancelled), "Diagnostics.reason of the IncompleteWrite is {?t}, not Cancelled", .{d.reason});
    try job.expect(errors.outcome(error.IncompleteWrite) == .may_have_executed, "IncompleteWrite is not may_have_executed", .{});
    try job.expect(d.batch_offset == 6, "Diagnostics.batch_offset of the IncompleteWrite is {?d}, not 6", .{d.batch_offset});
    try job.expect(partial.n == 6 and partial.answered == 6, "partial came with n {d} and answered {d}, not the 6 of the two batches", .{ partial.n, partial.answered });
    try job.expect(script.count(io, "insert") == 2, "the write sent {d} batches; the token is checked before each", .{script.count(io, "insert")});

    var token: core.CancellationToken = .init;
    token.cancel();
    try job.expectError(client.write(io, .of(core.Context.root.withCancellation(&token)), .{ .database = database, .kind = .insert, .body = body, .items = ten[0..2] }, .{ .allocator = job.gpa }), error.Cancelled, "a write of one batch whose token was canceled before it");
    try job.expect(errors.outcome(error.Cancelled) == .not_sent, "Cancelled is not not_sent", .{});
    try job.expect(script.count(io, "insert") == 2, "a write whose token was canceled before it reached the server", .{});
}
