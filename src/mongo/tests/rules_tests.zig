//! Tests of the rules that the client checks before and after the
//! exchange of a call, against `mongo.testing.FakeServer` over loopback: a
//! request that breaks a rule, a deadline with less than 1 ms left and a
//! canceled token reach no server; a token canceled while the call is out
//! is `Interrupted`, and nothing of the call is lost; every call starts the
//! caller's `Diagnostics` afresh. Every test runs under a time limit of 5 s.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const Script = mongo.testing.Script;
const Served = @import("Served.zig");
const within5s = @import("connection_tests.zig").within5s;

/// Answers every command with `{ok: 1.0}`.
const Ok = struct {
    pub fn answer(o: *Ok, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = .{ o, io, arena, request };
        return .{ .reply = Script.ok };
    }
};

const count = bson.literal(.{ .count = "users" });
const find = bson.literal(.{ .find = "users", .filter = .{} });
const insert = bson.literal(.{ .insert = "users" });
const docs = [_]bson.RawDocument{ bson.literal(.{ .name = "Ann" }), bson.literal(.{ .name = "Bob" }) };

/// A command whose first key is "".
const nameless = bson.RawDocument{ .bytes = &.{ 0x0b, 0, 0, 0, 0x10, 0, 1, 0, 0, 0, 0 } };
/// A command whose second element is cut short.
const broken = bson.RawDocument{ .bytes = &.{ 0x0f, 0, 0, 0, 0x10, 'a', 0, 1, 0, 0, 0, 0x10, 'b', 0, 0 } };

test "a command that breaks a rule is InvalidArgument, and the server never sees it" {
    try within5s(testing.io, badCommands, .{testing.io});
}

fn badCommands(io: Io) !void {
    const cases = [_]struct { []const u8, bson.RawDocument }{
        .{ "", count },
        .{ &@as([64]u8, @splat('a')), count },
        .{ "app\x00", count },
        .{ "my/app", count },
        .{ "my\\app", count },
        .{ "my.app", count },
        .{ "my app", count },
        .{ "my\"app", count },
        .{ "my$app", count },
        .{ "app", bson.RawDocument.empty },
        .{ "app", nameless },
        .{ "app", bson.literal(.{ .@"$count" = 1 }) },
        .{ "app", broken },
        .{ "app", bson.literal(.{ .find = "users", .@"$db" = "other" }) },
        .{ "app", bson.literal(.{ .find = "users", .@"$readPreference" = .{ .mode = "primary" } }) },
        .{ "app", bson.literal(.{ .find = "users", .lsid = .{ .id = 1 } }) },
        .{ "app", bson.literal(.{ .find = "users", .txnNumber = 1 }) },
        .{ "app", bson.literal(.{ .find = "users", .@"$clusterTime" = .{} }) },
        .{ "app", bson.literal(.{ .find = "users", .autocommit = false }) },
        .{ "app", bson.literal(.{ .find = "users", .startTransaction = true }) },
    };
    var ok: Ok = .{};
    var served: Served = undefined;
    try served.start(io, .init(&ok), .{});
    defer served.stop(io);
    const c = served.client();
    for (cases) |case| {
        errdefer std.debug.print("database '{s}', command {f}\n", .{ case[0], case[1] });
        var d: mongo.Diagnostics = .{};
        const command: mongo.Command = .{ .database = case[0], .body = case[1] };
        try testing.expectError(error.InvalidArgument, c.runCommand(io, .of(.root), command, .{ .allocator = testing.allocator, .diagnostics = &d }));
        try testing.expect(d.message().len > 0);
        try testing.expectError(error.InvalidArgument, c.openCursor(io, .of(.root), command, .{}));
    }
    try testing.expectEqual(@as(usize, 0), served.script.received(io));
    // A name of 63 bytes is fine.
    const reply = try c.runCommand(io, .of(.root), .{ .database = &@as([63]u8, @splat('a')), .body = count }, .{ .allocator = testing.allocator });
    reply.deinit();
    try testing.expectEqual(@as(usize, 1), served.script.received(io));
}

test "maxTimeMS goes out as it is without a deadline, and is refused under one" {
    try within5s(testing.io, callersMaxTime, .{testing.io});
}

fn callersMaxTime(io: Io) !void {
    var ok: Ok = .{};
    var served: Served = undefined;
    try served.start(io, .init(&ok), .{});
    defer served.stop(io);
    const c = served.client();
    const command: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .find = "users", .maxTimeMS = 100 }) };
    const reply = try c.runCommand(io, .of(.root), command, .{ .allocator = testing.allocator });
    reply.deinit();
    try testing.expectEqualSlices(u8, bson.literal(.{ .find = "users", .maxTimeMS = 100, .@"$db" = "app" }).bytes, served.script.entry(io, 0).body.bytes);
    const ctx = core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), .fromSeconds(60)));
    var d: mongo.Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, c.runCommand(io, .of(ctx), command, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the command holds maxTimeMS and the call has a deadline, from which the driver writes it: drop one of the two", d.message());
    try testing.expectEqual(@as(usize, 1), served.script.received(io));
}

test "a write names its kind, keeps the driver's fields out and has items" {
    try within5s(testing.io, badWrites, .{testing.io});
}

fn badWrites(io: Io) !void {
    const cases = [_]struct { mongo.WriteKind, bson.RawDocument, []const bson.RawDocument }{
        .{ .update, insert, &docs },
        .{ .insert, bson.literal(.{ .delete = "users" }), &docs },
        .{ .insert, bson.literal(.{ .insert = "users", .documents = .{.{ .a = 1 }} }), &docs },
        .{ .update, bson.literal(.{ .update = "users", .updates = .{} }), &docs },
        .{ .delete, bson.literal(.{ .delete = "users", .deletes = .{} }), &docs },
        .{ .insert, bson.literal(.{ .insert = "users", .ordered = false }), &docs },
        .{ .insert, bson.literal(.{ .insert = "users", .@"$db" = "app" }), &docs },
        .{ .insert, insert, &.{} },
        // Items are validated in Debug only.
        .{ .insert, insert, &.{broken} },
    };
    var ok: Ok = .{};
    var served: Served = undefined;
    try served.start(io, .init(&ok), .{});
    defer served.stop(io);
    const c = served.client();
    for (cases, 0..) |case, i| {
        if (i == cases.len - 1 and @import("builtin").mode != .debug) continue;
        errdefer std.debug.print("{t} {f} with {d} items\n", .{ case[0], case[1], case[2].len });
        const request: mongo.WriteRequest = .{ .database = "app", .kind = case[0], .body = case[1], .items = case[2] };
        var d: mongo.Diagnostics = .{};
        try testing.expectError(error.InvalidArgument, c.write(io, .of(.root), request, .{ .allocator = testing.allocator, .diagnostics = &d }));
        try testing.expect(d.message().len > 0);
    }
    try testing.expectEqual(@as(usize, 0), served.script.received(io));
}

test "a deadline with less than 1 ms left and a canceled token stop the call before it goes out" {
    try within5s(testing.io, beforeTheCall, .{testing.io});
}

fn beforeTheCall(io: Io) !void {
    var ok: Ok = .{};
    var served: Served = undefined;
    try served.start(io, .init(&ok), .{});
    defer served.stop(io);
    const c = served.client();
    const now = Io.Clock.awake.now(io);
    const expired = core.Context.root.withDeadline(.after(now, .zero));
    const almost = core.Context.root.withDeadline(.after(now, .fromNanoseconds(500 * std.time.ns_per_us)));
    var token: core.CancellationToken = .init;
    token.cancel();
    const canceled = core.Context.root.withCancellation(&token);
    const command: mongo.Command = .{ .database = "app", .body = count };
    const request: mongo.WriteRequest = .{ .database = "app", .kind = .insert, .body = insert, .items = &docs };
    var d: mongo.Diagnostics = .{};

    try testing.expectError(error.DeadlineExceeded, c.runCommand(io, .of(expired), command, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("less than 1 ms was left of the deadline before the call", d.message());
    try testing.expectError(error.DeadlineExceeded, c.runCommand(io, .of(almost), command, .{ .allocator = testing.allocator }));
    try testing.expectError(error.DeadlineExceeded, c.openCursor(io, .of(expired), command, .{}));
    try testing.expectError(error.DeadlineExceeded, c.write(io, .of(expired), request, .{ .allocator = testing.allocator }));
    try testing.expectError(error.Cancelled, c.runCommand(io, .of(canceled), command, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the token was canceled before the call", d.message());
    try testing.expectError(error.Cancelled, c.openCursor(io, .of(canceled), command, .{}));
    try testing.expectError(error.Cancelled, c.write(io, .of(canceled), request, .{ .allocator = testing.allocator }));
    // The deadline comes first: a server cancels the token at the deadline.
    try testing.expectError(error.DeadlineExceeded, c.write(io, .of(expired.withCancellation(&token)), request, .{ .allocator = testing.allocator }));
    // The rules of the request come before the context.
    try testing.expectError(error.InvalidArgument, c.runCommand(io, .of(expired), .{ .database = "", .body = count }, .{ .allocator = testing.allocator }));
    try testing.expectEqual(@as(usize, 0), served.script.received(io));
}

/// Cancels `token` at every command but killCursors, as a caller that
/// cancels it while the command is out: `find` gets a cursor that the
/// server keeps open, a write a refused item.
const CancelDuring = struct {
    token: core.CancellationToken = .init,

    pub fn answer(h: *CancelDuring, io: Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        if (std.mem.eql(u8, request.name, "killCursors")) return .{ .reply = Script.ok };
        h.token.cancel();
        if (std.mem.eql(u8, request.name, "find")) {
            return .{ .reply = Script.cursorReply(arena, "app.users", 9, .first, docs[0..1]) catch return error.OutOfMemory };
        }
        if (std.mem.eql(u8, request.name, "insert")) return .{ .reply = bson.literal(.{
            .n = 1,
            .writeErrors = .{.{ .index = 1, .code = 11000, .errmsg = "E11000 duplicate key" }},
            .ok = 1.0,
        }) };
        return .{ .reply = Script.ok };
    }
};

test "a token canceled while the call is out gives Interrupted, and nothing of the call is lost" {
    try within5s(testing.io, interrupted, .{testing.io});
}

fn interrupted(io: Io) !void {
    var canceler: CancelDuring = .{};
    var served: Served = undefined;
    try served.start(io, .init(&canceler), .{});
    defer served.stop(io);
    const c = served.client();
    const op: mongo.OperationContext = .of(core.Context.root.withCancellation(&canceler.token));
    var d: mongo.Diagnostics = .{};

    // The reply is freed: testing.allocator reports it otherwise.
    try testing.expectError(error.Interrupted, c.runCommand(io, op, .{ .database = "app", .body = count }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expectEqualStrings("the token was canceled while the call was out; its outcome is dropped", d.message());
    canceler.token = .init;
    // The cursor is freed, and its deinit sends killCursors.
    try testing.expectError(error.Interrupted, c.openCursor(io, op, .{ .database = "app", .body = find }, .{}));
    try testing.expectEqual(@as(usize, 1), served.script.count(io, "killCursors"));
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "users", .cursors = .{@as(i64, 9)}, .@"$db" = "app" }).bytes, served.script.entry(io, 2).body.bytes);
    canceler.token = .init;
    // The result goes to partial.
    var partial: mongo.WriteResult = .{};
    defer partial.deinit(testing.allocator);
    const request: mongo.WriteRequest = .{ .database = "app", .kind = .insert, .body = insert, .items = &docs };
    try testing.expectError(error.Interrupted, c.write(io, op, request, .{ .allocator = testing.allocator, .partial = &partial }));
    try testing.expectEqual(@as(u64, 1), partial.n);
    try testing.expectEqual(@as(usize, 2), partial.answered);
    try testing.expectEqualStrings("E11000 duplicate key", partial.write_errors[0].message);
    canceler.token = .init;
    // Without partial the result is freed.
    try testing.expectError(error.Interrupted, c.write(io, op, request, .{ .allocator = testing.allocator }));
    try testing.expectEqual(@as(usize, 2), served.script.count(io, "insert"));
}

test "a Diagnostics used again holds nothing of the error before" {
    try within5s(testing.io, freshDiagnostics, .{testing.io});
}

fn freshDiagnostics(io: Io) !void {
    var ok: Ok = .{};
    var served: Served = undefined;
    try served.start(io, .init(&ok), .{});
    defer served.stop(io);
    const c = served.client();
    var d: mongo.Diagnostics = .{ .server = .{ .code = 11000 }, .batch_offset = 6, .reason = error.ConnectionLost, .cause = error.BrokenPipe };
    d.set(.send, error.BrokenPipe, "an old error", .{});

    const reply = try c.runCommand(io, .of(.root), .{ .database = "app", .body = count }, .{ .allocator = testing.allocator, .diagnostics = &d });
    reply.deinit();
    try testing.expect(d.server == null and d.batch_offset == null and d.reason == null and d.cause == null and d.phase == null);
    try testing.expectEqualStrings("", d.message());

    d = .{ .server = .{ .code = 11000 }, .batch_offset = 6, .reason = error.ConnectionLost };
    try testing.expectError(error.InvalidArgument, c.runCommand(io, .of(.root), .{ .database = "my.app", .body = count }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(d.server == null and d.batch_offset == null and d.reason == null);
    try testing.expect(std.mem.find(u8, d.message(), "database name") != null);
}
