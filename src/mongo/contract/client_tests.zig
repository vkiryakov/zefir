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
