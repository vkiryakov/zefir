//! Tests of the interfaces `mongo.Client` and `mongo.Cursor` on a small
//! driver: its calls reach its methods, and the wrapper's rules hold
//! before and after them.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;

/// A cursor over a list of documents.
const ListCursor = struct {
    docs: []const bson.RawDocument,
    pos: usize = 0,
    closed: bool = false,
    closes: u32 = 0,
    deinits: u32 = 0,

    pub fn next(self: *ListCursor, io: std.Io, op: mongo.OperationContext) mongo.Error!?bson.RawDocument {
        _ = io;
        _ = op;
        if (self.closed) return error.Closed;
        if (self.pos == self.docs.len) return null;
        defer self.pos += 1;
        return self.docs[self.pos];
    }

    pub fn close(self: *ListCursor, io: std.Io) void {
        _ = io;
        self.closed = true;
        self.closes += 1;
    }

    pub fn deinit(self: *ListCursor, io: std.Io) void {
        _ = io;
        self.closed = true;
        self.deinits += 1;
    }

    pub fn cursor(self: *ListCursor) mongo.Cursor {
        return .init(self);
    }
};

/// A driver that counts its calls and answers each with what the test set.
const Recorder = struct {
    commands: u32 = 0,
    cursors: u32 = 0,
    writes: u32 = 0,
    /// The database and the first key of the last command or write.
    database: []const u8 = "",
    name: []const u8 = "",
    list: ListCursor = .{ .docs = &.{} },
    /// The token to cancel while a call is out, as if a caller canceled
    /// it during the exchange.
    cancel_during_call: ?*core.CancellationToken = null,
    /// What a write answers.
    result: mongo.WriteResult = .{},

    pub fn runCommand(self: *Recorder, io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!bson.OwnedDocument {
        _ = io;
        _ = op;
        self.commands += 1;
        self.record(command.database, command.body);
        if (self.cancel_during_call) |token| token.cancel();
        return bson.literal(.{ .ok = 1 }).dupe(options.allocator);
    }

    pub fn openCursor(self: *Recorder, io: std.Io, op: mongo.OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor {
        _ = io;
        _ = op;
        _ = options;
        self.cursors += 1;
        self.record(command.database, command.body);
        if (self.cancel_during_call) |token| token.cancel();
        return self.list.cursor();
    }

    pub fn write(self: *Recorder, io: std.Io, op: mongo.OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
        _ = io;
        _ = op;
        self.writes += 1;
        self.record(request.database, request.body);
        if (self.cancel_during_call) |token| token.cancel();
        var result = self.result;
        result.answered = request.items.len;
        if (self.result.write_errors.len > 0) {
            const write_errors = try options.allocator.alloc(mongo.WriteError, self.result.write_errors.len);
            for (write_errors, self.result.write_errors) |*copy, original| {
                copy.* = original;
                copy.message = try options.allocator.dupe(u8, original.message);
            }
            result.write_errors = write_errors;
        }
        return result;
    }

    pub fn capabilities(self: *Recorder) mongo.Capabilities {
        _ = self;
        return .{ .revision = 1, .name = "recorder", .commands = true, .cursors = true, .aggregation = true, .batched_writes = true };
    }

    pub fn client(self: *Recorder) mongo.Client {
        return .init(self);
    }

    fn record(self: *Recorder, database: []const u8, body: bson.RawDocument) void {
        self.database = database;
        self.name = if (body.first() catch null) |first| first.key else "";
    }

    fn calls(self: *const Recorder) u32 {
        return self.commands + self.cursors + self.writes;
    }
};

const ping = bson.literal(.{ .ping = 1 });
const find = bson.literal(.{ .find = "users", .filter = .{} });
const insert = bson.literal(.{ .insert = "users" });
const docs = [_]bson.RawDocument{ bson.literal(.{ .name = "Ann" }), bson.literal(.{ .name = "Bob" }) };

test "init builds a client whose calls reach the driver's methods" {
    const io = testing.io;
    var driver: Recorder = .{ .list = .{ .docs = &docs } };
    const client = driver.client();

    const reply = try client.runCommand(io, .of(.root), .{ .database = "admin", .body = ping }, .{ .allocator = testing.allocator });
    defer reply.deinit();
    try testing.expectEqualSlices(u8, bson.literal(.{ .ok = 1 }).bytes, reply.bytes);
    try testing.expectEqualStrings("admin", driver.database);
    try testing.expectEqualStrings("ping", driver.name);

    var cursor = try client.openCursor(io, .of(.root), .{ .database = "app", .body = find }, .{});
    defer cursor.deinit(io);
    try testing.expectEqualStrings("find", driver.name);
    const first = (try cursor.next(io, .of(.root))).?;
    try testing.expectEqualSlices(u8, docs[0].bytes, first.bytes);
    const second = (try cursor.nextOwned(io, .of(.root), testing.allocator)).?;
    defer second.deinit();
    try testing.expectEqualSlices(u8, docs[1].bytes, second.bytes);
    try testing.expectEqual(@as(?bson.RawDocument, null), try cursor.next(io, .of(.root)));
    try testing.expectEqual(@as(?bson.OwnedDocument, null), try cursor.nextOwned(io, .of(.root), testing.allocator));

    var result = try client.write(io, .of(.root), .{ .database = "app", .kind = .insert, .body = insert, .items = &docs }, .{ .allocator = testing.allocator });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result.answered);
    try testing.expectEqualStrings("insert", driver.name);

    try testing.expectEqualStrings("recorder", client.capabilities().name);
    try testing.expectEqual(@as(u32, 3), driver.calls());
    // A copy is the same client: two pointers, nothing else.
    try testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @sizeOf(mongo.Client));
    try testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @sizeOf(mongo.Cursor));
}

test "a cursor's close and deinit reach the cursor" {
    const io = testing.io;
    var list: ListCursor = .{ .docs = &docs };
    const cursor = list.cursor();
    cursor.close(io);
    cursor.close(io);
    try testing.expectEqual(@as(u32, 2), list.closes);
    try testing.expectError(error.Closed, cursor.next(io, .of(.root)));
    cursor.deinit(io);
    try testing.expectEqual(@as(u32, 1), list.deinits);
}

/// A command whose first key is "".
const nameless = bson.RawDocument{ .bytes = &.{ 0x0b, 0, 0, 0, 0x10, 0, 1, 0, 0, 0, 0 } };
/// A command whose second element is cut short.
const broken = bson.RawDocument{ .bytes = &.{ 0x0f, 0, 0, 0, 0x10, 'a', 0, 1, 0, 0, 0, 0x10, 'b', 0, 0 } };

test "a command that breaks a rule is InvalidArgument, and the driver never sees it" {
    const io = testing.io;
    const cases = [_]struct { []const u8, bson.RawDocument }{
        .{ "", ping },
        .{ &@as([64]u8, @splat('a')), ping },
        .{ "app\x00", ping },
        .{ "my/app", ping },
        .{ "my\\app", ping },
        .{ "my.app", ping },
        .{ "my app", ping },
        .{ "my\"app", ping },
        .{ "my$app", ping },
        .{ "app", bson.RawDocument.empty },
        .{ "app", nameless },
        .{ "app", bson.literal(.{ .@"$ping" = 1 }) },
        .{ "app", broken },
        .{ "app", bson.literal(.{ .find = "users", .@"$db" = "other" }) },
        .{ "app", bson.literal(.{ .find = "users", .@"$readPreference" = .{ .mode = "primary" } }) },
        .{ "app", bson.literal(.{ .find = "users", .lsid = .{ .id = 1 } }) },
        .{ "app", bson.literal(.{ .find = "users", .txnNumber = 1 }) },
        .{ "app", bson.literal(.{ .find = "users", .@"$clusterTime" = .{} }) },
        .{ "app", bson.literal(.{ .find = "users", .autocommit = false }) },
        .{ "app", bson.literal(.{ .find = "users", .startTransaction = true }) },
    };
    var driver: Recorder = .{};
    const client = driver.client();
    for (cases) |case| {
        errdefer std.debug.print("database '{s}', command {f}\n", .{ case[0], case[1] });
        var d: mongo.Diagnostics = .{};
        const command: mongo.Command = .{ .database = case[0], .body = case[1] };
        try testing.expectError(error.InvalidArgument, client.runCommand(io, .of(.root), command, .{ .allocator = testing.allocator, .diagnostics = &d }));
        try testing.expect(d.message().len > 0);
        try testing.expectError(error.InvalidArgument, client.openCursor(io, .of(.root), command, .{}));
    }
    try testing.expectEqual(@as(u32, 0), driver.calls());
    // A name of 63 bytes is fine.
    const reply = try client.runCommand(io, .of(.root), .{ .database = &@as([63]u8, @splat('a')), .body = ping }, .{ .allocator = testing.allocator });
    reply.deinit();
}

test "maxTimeMS goes out as it is without a deadline, and is refused under one" {
    const io = testing.io;
    var driver: Recorder = .{};
    const client = driver.client();
    const command: mongo.Command = .{ .database = "app", .body = bson.literal(.{ .find = "users", .maxTimeMS = 100 }) };
    const reply = try client.runCommand(io, .of(.root), command, .{ .allocator = testing.allocator });
    reply.deinit();
    const ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(60)));
    try testing.expectError(error.InvalidArgument, client.runCommand(io, .of(ctx), command, .{ .allocator = testing.allocator }));
    try testing.expectEqual(@as(u32, 1), driver.commands);
}

test "a write names its kind, keeps the driver's fields out and has items" {
    const io = testing.io;
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
    var driver: Recorder = .{};
    const client = driver.client();
    for (cases, 0..) |case, i| {
        if (i == cases.len - 1 and @import("builtin").mode != .debug) continue;
        errdefer std.debug.print("{t} {f} with {d} items\n", .{ case[0], case[1], case[2].len });
        const request: mongo.WriteRequest = .{ .database = "app", .kind = case[0], .body = case[1], .items = case[2] };
        try testing.expectError(error.InvalidArgument, client.write(io, .of(.root), request, .{ .allocator = testing.allocator }));
    }
    try testing.expectEqual(@as(u32, 0), driver.calls());
}

test "a deadline with less than 1 ms left and a canceled token stop the call before the driver" {
    const io = testing.io;
    var driver: Recorder = .{};
    const client = driver.client();
    const now = std.Io.Clock.awake.now(io);
    const expired = core.Context.root.withDeadline(.after(now, .zero));
    const almost = core.Context.root.withDeadline(.after(now, .fromNanoseconds(500 * std.time.ns_per_us)));
    var token: core.CancellationToken = .init;
    token.cancel();
    const canceled = core.Context.root.withCancellation(&token);
    const command: mongo.Command = .{ .database = "app", .body = ping };
    const request: mongo.WriteRequest = .{ .database = "app", .kind = .insert, .body = insert, .items = &docs };

    try testing.expectError(error.DeadlineExceeded, client.runCommand(io, .of(expired), command, .{ .allocator = testing.allocator }));
    try testing.expectError(error.DeadlineExceeded, client.runCommand(io, .of(almost), command, .{ .allocator = testing.allocator }));
    try testing.expectError(error.Cancelled, client.runCommand(io, .of(canceled), command, .{ .allocator = testing.allocator }));
    try testing.expectError(error.Cancelled, client.openCursor(io, .of(canceled), command, .{}));
    try testing.expectError(error.Cancelled, client.write(io, .of(canceled), request, .{ .allocator = testing.allocator }));
    // The deadline comes first: a server cancels the token at the deadline.
    try testing.expectError(error.DeadlineExceeded, client.write(io, .of(expired.withCancellation(&token)), request, .{ .allocator = testing.allocator }));
    // The rules of the request come before the context.
    try testing.expectError(error.InvalidArgument, client.runCommand(io, .of(expired), .{ .database = "", .body = ping }, .{ .allocator = testing.allocator }));
    try testing.expectEqual(@as(u32, 0), driver.calls());
}

test "a token canceled while the call is out gives Interrupted, and nothing of the call is lost" {
    const io = testing.io;
    var token: core.CancellationToken = .init;
    var driver: Recorder = .{ .list = .{ .docs = &docs }, .cancel_during_call = &token };
    const client = driver.client();
    const op: mongo.OperationContext = .of(core.Context.root.withCancellation(&token));
    var d: mongo.Diagnostics = .{};

    // The reply is freed: testing.allocator reports it otherwise.
    try testing.expectError(error.Interrupted, client.runCommand(io, op, .{ .database = "admin", .body = ping }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(d.message().len > 0);
    token = .init;
    // The cursor is closed with deinit, which sends killCursors.
    try testing.expectError(error.Interrupted, client.openCursor(io, op, .{ .database = "app", .body = find }, .{}));
    try testing.expectEqual(@as(u32, 1), driver.list.deinits);
    token = .init;
    // The result goes to partial.
    driver.result = .{ .n = 1, .write_errors = &.{.{ .index = 1, .code = 11000, .message = "E11000 duplicate key" }} };
    var partial: mongo.WriteResult = .{};
    defer partial.deinit(testing.allocator);
    const request: mongo.WriteRequest = .{ .database = "app", .kind = .insert, .body = insert, .items = &docs };
    try testing.expectError(error.Interrupted, client.write(io, op, request, .{ .allocator = testing.allocator, .partial = &partial }));
    try testing.expectEqual(@as(u64, 1), partial.n);
    try testing.expectEqual(@as(usize, 2), partial.answered);
    try testing.expectEqualStrings("E11000 duplicate key", partial.write_errors[0].message);
    token = .init;
    // Without partial the result is freed.
    try testing.expectError(error.Interrupted, client.write(io, op, request, .{ .allocator = testing.allocator }));
    try testing.expectEqual(@as(u32, 4), driver.calls());
}

test "a Diagnostics used again holds nothing of the error before" {
    const io = testing.io;
    var driver: Recorder = .{};
    const client = driver.client();
    var d: mongo.Diagnostics = .{ .server = .{ .code = 11000 }, .batch_offset = 6, .reason = error.ConnectionLost, .cause = error.BrokenPipe };
    d.set(.send, error.BrokenPipe, "an old error", .{});

    const reply = try client.runCommand(io, .of(.root), .{ .database = "admin", .body = ping }, .{ .allocator = testing.allocator, .diagnostics = &d });
    reply.deinit();
    try testing.expect(d.server == null and d.batch_offset == null and d.reason == null and d.cause == null and d.phase == null);
    try testing.expectEqualStrings("", d.message());

    d = .{ .server = .{ .code = 11000 }, .batch_offset = 6, .reason = error.ConnectionLost };
    try testing.expectError(error.InvalidArgument, client.runCommand(io, .of(.root), .{ .database = "my.app", .body = ping }, .{ .allocator = testing.allocator, .diagnostics = &d }));
    try testing.expect(d.server == null and d.batch_offset == null and d.reason == null);
    try testing.expect(std.mem.find(u8, d.message(), "database name") != null);
}
