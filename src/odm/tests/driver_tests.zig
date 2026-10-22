//! Tests of the driver contract: odm.Driver, odm.Client and odm.RawCursor
//! route each call to the method of the type behind them.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const Client = odm.Client;

/// A cursor over a fixed list of documents, counting its calls.
const ListCursor = struct {
    documents: []const bson.RawDocument,
    at: usize = 0,
    next_calls: usize = 0,
    deinit_calls: usize = 0,
    last_ctx: ?core.Context = null,
    last_diagnostics: ?*odm.Diagnostics = null,

    pub fn next(self: *ListCursor, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!?bson.RawDocument {
        _ = io;
        self.next_calls += 1;
        self.last_ctx = ctx;
        self.last_diagnostics = d;
        if (self.at == self.documents.len) return null;
        defer self.at += 1;
        return self.documents[self.at];
    }

    pub fn deinit(self: *ListCursor, io: Io) void {
        _ = io;
        self.deinit_calls += 1;
    }
};

/// The method of a client that a call reached, and with what.
const Seen = struct {
    calls: usize = 0,
    io: ?Io = null,
    ctx: ?core.Context = null,
    request: ?*const anyopaque = null,
    diagnostics: ?*odm.Diagnostics = null,
};

/// A client with every method of the contract: each records its call and
/// answers with a value of its own.
const FullClient = struct {
    connect_seen: Seen = .{},
    ping_seen: Seen = .{},
    close_seen: Seen = .{},
    deinit_seen: Seen = .{},
    stats_seen: Seen = .{},
    insert_seen: Seen = .{},
    update_seen: Seen = .{},
    delete_seen: Seen = .{},
    find_seen: Seen = .{},
    aggregate_seen: Seen = .{},
    count_seen: Seen = .{},
    indexes_seen: Seen = .{},
    command_seen: Seen = .{},
    cursor: ListCursor = .{ .documents = &.{} },

    pub const capabilities: odm.Capabilities = .{ .aggregate = true, .count = true, .indexes = true, .command = true };

    fn note(seen: *Seen, io: ?Io, ctx: ?core.Context, request: ?*const anyopaque, d: ?*odm.Diagnostics) void {
        seen.calls += 1;
        seen.io = io;
        seen.ctx = ctx;
        seen.request = request;
        seen.diagnostics = d;
    }

    pub fn connect(self: *FullClient, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void {
        note(&self.connect_seen, io, ctx, null, d);
    }

    pub fn ping(self: *FullClient, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void {
        note(&self.ping_seen, io, ctx, null, d);
        return error.Unavailable;
    }

    pub fn close(self: *FullClient, io: Io) void {
        note(&self.close_seen, io, null, null, null);
    }

    pub fn deinit(self: *FullClient) void {
        note(&self.deinit_seen, null, null, null, null);
    }

    pub fn stats(self: *FullClient) ?Client.PoolStats {
        note(&self.stats_seen, null, null, null, null);
        return .{ .connections = 3, .idle = 1, .in_use = 2, .waiting = 5 };
    }

    pub fn insert(self: *FullClient, io: Io, ctx: core.Context, request: *const Client.InsertRequest, options: Client.CallOptions) odm.DriverError!Client.InsertResult {
        note(&self.insert_seen, io, ctx, request, options.diagnostics);
        return .{ .inserted = 7 };
    }

    pub fn update(self: *FullClient, io: Io, ctx: core.Context, request: *const Client.UpdateRequest, options: Client.CallOptions) odm.DriverError!Client.UpdateResult {
        note(&self.update_seen, io, ctx, request, options.diagnostics);
        return .{ .matched = 2, .modified = 1, .upserted_id = .{ .int32 = 9 } };
    }

    pub fn delete(self: *FullClient, io: Io, ctx: core.Context, request: *const Client.DeleteRequest, options: Client.CallOptions) odm.DriverError!Client.DeleteResult {
        note(&self.delete_seen, io, ctx, request, options.diagnostics);
        return .{ .deleted = 4 };
    }

    pub fn find(self: *FullClient, io: Io, ctx: core.Context, request: *const Client.FindRequest, options: Client.CallOptions) odm.DriverError!odm.RawCursor {
        note(&self.find_seen, io, ctx, request, options.diagnostics);
        return .init(&self.cursor);
    }

    pub fn aggregate(self: *FullClient, io: Io, ctx: core.Context, request: *const Client.AggregateRequest, options: Client.CallOptions) odm.DriverError!odm.RawCursor {
        note(&self.aggregate_seen, io, ctx, request, options.diagnostics);
        return .init(&self.cursor);
    }

    pub fn count(self: *FullClient, io: Io, ctx: core.Context, request: *const Client.CountRequest, options: Client.CallOptions) odm.DriverError!u64 {
        note(&self.count_seen, io, ctx, request, options.diagnostics);
        return 11;
    }

    pub fn createIndexes(self: *FullClient, io: Io, ctx: core.Context, request: *const Client.IndexRequest, options: Client.CallOptions) odm.DriverError!void {
        note(&self.indexes_seen, io, ctx, request, options.diagnostics);
        return error.CommandFailed;
    }

    pub fn command(self: *FullClient, io: Io, ctx: core.Context, request: *const Client.CommandRequest, options: Client.CallOptions) odm.DriverError!bson.RawDocument {
        note(&self.command_seen, io, ctx, request, options.diagnostics);
        return bson.literal(.{ .ok = 1.0 });
    }
};

/// Checks that a call reached its method once, with these arguments.
fn expectSeen(seen: Seen, io: ?Io, token: ?*const core.CancellationToken, request: ?*const anyopaque, d: ?*odm.Diagnostics) !void {
    try testing.expectEqual(@as(usize, 1), seen.calls);
    if (io) |expected| {
        try testing.expectEqual(expected.userdata, seen.io.?.userdata);
        try testing.expectEqual(expected.vtable, seen.io.?.vtable);
    } else try testing.expect(seen.io == null);
    if (token) |expected| {
        try testing.expectEqual(expected, seen.ctx.?.cancellation.?);
    } else try testing.expect(seen.ctx == null);
    try testing.expectEqual(request, seen.request);
    try testing.expectEqual(d, seen.diagnostics);
}

test "Client.init routes each wrapper to the method of the type" {
    const io = testing.io;
    var impl: FullClient = .{};
    const client: Client = .init(&impl);
    try testing.expectEqual(@as(*anyopaque, &impl), client.ptr);
    try testing.expectEqual(FullClient.capabilities, client.capabilities());

    var token: core.CancellationToken = .init;
    const ctx = core.Context.root.withCancellation(&token);
    var d: odm.Diagnostics = .{};
    const options: Client.CallOptions = .{ .allocator = testing.allocator, .diagnostics = &d };
    const ns: Client.Namespace = .{ .database = "app", .collection = "users" };
    const filter = bson.literal(.{ .name = "Ann" });

    try client.connect(io, ctx, &d);
    try expectSeen(impl.connect_seen, io, &token, null, &d);
    try testing.expectError(error.Unavailable, client.ping(io, ctx, &d));
    try expectSeen(impl.ping_seen, io, &token, null, &d);

    const insert: Client.InsertRequest = .{ .ns = ns, .documents = &.{filter} };
    try testing.expectEqual(@as(u64, 7), (try client.insert(io, ctx, &insert, options)).inserted);
    try expectSeen(impl.insert_seen, io, &token, &insert, &d);

    const update: Client.UpdateRequest = .{ .ns = ns, .filter = filter, .update = bson.literal(.{ .@"$set" = .{ .age = 30 } }), .mode = .one };
    const updated = try client.update(io, ctx, &update, options);
    try testing.expectEqual(@as(u64, 2), updated.matched);
    try testing.expectEqual(@as(u64, 1), updated.modified);
    try testing.expectEqual(@as(i32, 9), updated.upserted_id.?.int32);
    try expectSeen(impl.update_seen, io, &token, &update, &d);

    const delete: Client.DeleteRequest = .{ .ns = ns, .filter = filter, .many = true };
    try testing.expectEqual(@as(u64, 4), (try client.delete(io, ctx, &delete, options)).deleted);
    try expectSeen(impl.delete_seen, io, &token, &delete, &d);

    const find: Client.FindRequest = .{ .ns = ns, .filter = filter, .limit = 1 };
    const found = try client.find(io, ctx, &find, options);
    try testing.expectEqual(@as(*anyopaque, &impl.cursor), found.ptr);
    try expectSeen(impl.find_seen, io, &token, &find, &d);

    const aggregate: Client.AggregateRequest = .{ .ns = ns, .pipeline = &.{bson.literal(.{ .@"$match" = .{ .name = "Ann" } })} };
    const aggregated = try client.aggregate(io, ctx, &aggregate, options);
    try testing.expectEqual(@as(*anyopaque, &impl.cursor), aggregated.ptr);
    try expectSeen(impl.aggregate_seen, io, &token, &aggregate, &d);

    const count: Client.CountRequest = .{ .ns = ns, .filter = filter };
    try testing.expectEqual(@as(u64, 11), try client.count(io, ctx, &count, options));
    try expectSeen(impl.count_seen, io, &token, &count, &d);

    const indexes: Client.IndexRequest = .{ .ns = ns, .indexes = &.{.{ .name = "email_1", .keys = bson.literal(.{ .email = @as(i32, 1) }), .unique = true }} };
    try testing.expectError(error.CommandFailed, client.createIndexes(io, ctx, &indexes, options));
    try expectSeen(impl.indexes_seen, io, &token, &indexes, &d);

    const command: Client.CommandRequest = .{ .database = "admin", .body = bson.literal(.{ .ping = @as(i32, 1) }) };
    const reply = try client.command(io, ctx, &command, options);
    try testing.expectEqualSlices(u8, bson.literal(.{ .ok = 1.0 }).bytes, reply.bytes);
    try expectSeen(impl.command_seen, io, &token, &command, &d);

    const stats = client.stats().?;
    try testing.expectEqual(Client.PoolStats{ .connections = 3, .idle = 1, .in_use = 2, .waiting = 5 }, stats);
    try expectSeen(impl.stats_seen, null, null, null, null);

    client.close(io);
    try expectSeen(impl.close_seen, io, null, null, null);
    client.deinit();
    try expectSeen(impl.deinit_seen, null, null, null, null);
}

/// A client with the required methods alone, and no capabilities.
const BareClient = struct {
    calls: usize = 0,

    pub const capabilities: odm.Capabilities = .{};

    pub fn connect(self: *BareClient, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void {
        _ = .{ io, ctx, d };
        self.calls += 1;
    }

    pub fn ping(self: *BareClient, io: Io, ctx: core.Context, d: ?*odm.Diagnostics) odm.DriverError!void {
        _ = .{ io, ctx, d };
        self.calls += 1;
    }

    pub fn close(self: *BareClient, io: Io) void {
        _ = io;
        self.calls += 1;
    }

    pub fn deinit(self: *BareClient) void {
        self.calls += 1;
    }

    pub fn stats(self: *BareClient) ?Client.PoolStats {
        self.calls += 1;
        return null;
    }

    pub fn insert(self: *BareClient, io: Io, ctx: core.Context, request: *const Client.InsertRequest, options: Client.CallOptions) odm.DriverError!Client.InsertResult {
        _ = .{ io, ctx, options };
        self.calls += 1;
        return .{ .inserted = request.documents.len };
    }

    pub fn update(self: *BareClient, io: Io, ctx: core.Context, request: *const Client.UpdateRequest, options: Client.CallOptions) odm.DriverError!Client.UpdateResult {
        _ = .{ io, ctx, request, options };
        self.calls += 1;
        return .{ .matched = 0, .modified = 0 };
    }

    pub fn delete(self: *BareClient, io: Io, ctx: core.Context, request: *const Client.DeleteRequest, options: Client.CallOptions) odm.DriverError!Client.DeleteResult {
        _ = .{ io, ctx, request, options };
        self.calls += 1;
        return .{ .deleted = 0 };
    }

    pub fn find(self: *BareClient, io: Io, ctx: core.Context, request: *const Client.FindRequest, options: Client.CallOptions) odm.DriverError!odm.RawCursor {
        _ = .{ io, ctx, request, options };
        self.calls += 1;
        return error.Unavailable;
    }
};

test "a capability that is false gives Unsupported and names it" {
    const io = testing.io;
    var impl: BareClient = .{};
    const client: Client = .init(&impl);
    try testing.expectEqual(odm.Capabilities{}, client.capabilities());
    try testing.expect(client.vtable.aggregate == null and client.vtable.count == null);
    try testing.expect(client.vtable.create_indexes == null and client.vtable.command == null);

    const ctx: core.Context = .root;
    const ns: Client.Namespace = .{ .database = "app", .collection = "users" };
    var d: odm.Diagnostics = .{};
    const options: Client.CallOptions = .{ .allocator = testing.allocator, .diagnostics = &d };

    d.set(13, 2, "an error before", .{});
    const aggregate: Client.AggregateRequest = .{ .ns = ns, .pipeline = &.{} };
    try testing.expectError(error.Unsupported, client.aggregate(io, ctx, &aggregate, options));
    try testing.expectEqualStrings("odm: the driver has no capability 'aggregate'", d.message());
    try testing.expectEqual(@as(?i32, null), d.code);
    try testing.expectEqual(@as(?usize, null), d.index);

    const count: Client.CountRequest = .{ .ns = ns, .filter = .empty };
    try testing.expectError(error.Unsupported, client.count(io, ctx, &count, options));
    try testing.expectEqualStrings("odm: the driver has no capability 'count'", d.message());

    const indexes: Client.IndexRequest = .{ .ns = ns, .indexes = &.{} };
    try testing.expectError(error.Unsupported, client.createIndexes(io, ctx, &indexes, options));
    try testing.expectEqualStrings("odm: the driver has no capability 'indexes'", d.message());

    const command: Client.CommandRequest = .{ .database = "app", .body = bson.literal(.{ .ping = @as(i32, 1) }) };
    try testing.expectError(error.Unsupported, client.command(io, ctx, &command, options));
    try testing.expectEqualStrings("odm: the driver has no capability 'command'", d.message());

    // Without diagnostics the error is the same.
    try testing.expectError(error.Unsupported, client.count(io, ctx, &count, .{ .allocator = testing.allocator }));
    // None of them reached the client.
    try testing.expectEqual(@as(usize, 0), impl.calls);

    const insert: Client.InsertRequest = .{ .ns = ns, .documents = &.{ .empty, .empty } };
    try testing.expectEqual(@as(u64, 2), (try client.insert(io, ctx, &insert, options)).inserted);
    try testing.expectEqual(@as(?Client.PoolStats, null), client.stats());
    try testing.expectEqual(@as(usize, 2), impl.calls);
}

/// A driver that opens one client, the one inside it.
const OneClientDriver = struct {
    client: BareClient = .{},
    opened: usize = 0,
    last_config: ?*const odm.ConnectionConfig = null,
    last_io: ?Io = null,

    pub const name = "one-client";

    pub fn open(self: *OneClientDriver, io: Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!Client {
        self.opened += 1;
        self.last_config = config;
        self.last_io = io;
        if (config.uri.len == 0) return error.InvalidArgument;
        return .init(&self.client);
    }
};

test "Driver.init and RawCursor.init route to their methods" {
    const io = testing.io;
    var impl: OneClientDriver = .{};
    const driver: odm.Driver = .init(&impl);
    try testing.expectEqualStrings("one-client", driver.name());

    const config: odm.ConnectionConfig = .{ .uri = "fake://db", .password = "secret" };
    const client = try driver.open(io, &config);
    try testing.expectEqual(@as(usize, 1), impl.opened);
    try testing.expectEqual(&config, impl.last_config.?);
    try testing.expectEqual(io.userdata, impl.last_io.?.userdata);
    try testing.expectEqual(@as(*anyopaque, &impl.client), client.ptr);
    try testing.expectError(error.InvalidArgument, driver.open(io, &.{ .uri = "" }));
    try testing.expectEqual(@as(usize, 2), impl.opened);
    comptime std.debug.assert(odm.ConnectionConfig.zefir_sensitive);

    const documents = [_]bson.RawDocument{ bson.literal(.{ .n = @as(i32, 1) }), bson.literal(.{ .n = @as(i32, 2) }) };
    var list: ListCursor = .{ .documents = &documents };
    const cursor: odm.RawCursor = .init(&list);
    var token: core.CancellationToken = .init;
    const ctx = core.Context.root.withCancellation(&token);
    var d: odm.Diagnostics = .{};
    try testing.expectEqualSlices(u8, documents[0].bytes, (try cursor.next(io, ctx, &d)).?.bytes);
    try testing.expectEqual(&token, list.last_ctx.?.cancellation.?);
    try testing.expectEqual(@as(?*odm.Diagnostics, &d), list.last_diagnostics);
    try testing.expectEqualSlices(u8, documents[1].bytes, (try cursor.next(io, ctx, null)).?.bytes);
    try testing.expectEqual(@as(?*odm.Diagnostics, null), list.last_diagnostics);
    try testing.expect(try cursor.next(io, ctx, null) == null);
    try testing.expectEqual(@as(usize, 3), list.next_calls);
    cursor.deinit(io);
    try testing.expectEqual(@as(usize, 1), list.deinit_calls);
}
