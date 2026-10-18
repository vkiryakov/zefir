//! The cursors of the driver, by the rules of `mongo.Cursor`:
//!
//! - `openCursor` runs its command and takes the first batch of the reply,
//!   `cursor.firstBatch`. A reply without `cursor` is
//!   `error.ProtocolViolation`: the command may have run.
//! - `next` gives the documents of the batch, borrowed from the reply that
//!   holds it, also past the deadline. At the end of a batch it sends
//!   `getMore` under the deadline of its context, on any connection of the
//!   pool, to the cursor's namespace: `$db` is the part of `ns` before its
//!   first dot, `collection` the rest; with `batchSize` and `comment` of
//!   the options, and without `maxTimeMS`. The id and the namespace follow
//!   each reply.
//! - An error before `getMore` went out (the deadline, the token, the
//!   pool) leaves the cursor as it was. An error of the exchange,
//!   `CursorNotFound` (43) among them, ends it: `next` is `error.Closed`
//!   from then on.
//! - `close` and `deinit` send `killCursors` while the server holds the
//!   cursor, within `cursor_close_timeout` and with the task's cancelation
//!   held off meanwhile, and ignore the reply. `close` of the client sends
//!   it for every cursor still open, after the calls in flight ended.
//! - One task at a time uses a cursor, any task; in safe builds two at
//!   once panic. A cursor holds its batches in the client's memory:
//!   `deinit` every cursor before the client, which in safe builds panics
//!   otherwise.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const mongo = @import("../root.zig");
const bson = mongo.bson;
const wire = mongo.wire;
const Diagnostics = mongo.Diagnostics;
const OperationContext = mongo.OperationContext;
const Connection = @import("Connection.zig");
const command_ = @import("command.zig");
const connect_ = @import("connect.zig");
const time = @import("time.zig");
const List = std.DoublyLinkedList;
const Runner = command_.Runner;

/// The client's cursors that are not freed yet, which `close` of the
/// client ends, and how many of them the server holds.
pub const Registry = struct {
    mutex: Io.Mutex = .init,
    list: List = .{},
    live: usize = 0,
    /// The cursors whose id is not 0.
    open: usize = 0,

    /// How many cursors the server holds.
    pub fn openCount(reg: *Registry, io: Io) usize {
        reg.mutex.lockUncancelable(io);
        defer reg.mutex.unlock(io);
        return reg.open;
    }

    /// How many cursors are not freed yet.
    pub fn liveCount(reg: *Registry, io: Io) usize {
        reg.mutex.lockUncancelable(io);
        defer reg.mutex.unlock(io);
        return reg.live;
    }

    /// The id of `c` from now on, under the lock.
    fn setId(reg: *Registry, c: *Cursor, id: i64) void {
        if (c.id != 0 and id == 0) reg.open -= 1;
        c.id = id;
    }
};

/// Runs `command` and returns its cursor, with the first batch of its
/// reply; `deinit` it.
pub fn open(r: Runner, io: Io, op: OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!*Cursor {
    const d = options.diagnostics;
    try r.pool.enter(io, d);
    defer r.pool.leave(io);
    // The cursor holds the replies of its batches: the client's memory, as
    // `failure_reply` is.
    const reply = try command_.send(r, io, op, r.deadlineOf(io, op), .{ .database = command.database, .body = command.body }, r.gpa, d);
    errdefer reply.deinit();
    try wire.checkReply(reply.raw(), r.gpa, d, options.failure_reply);
    const first = try parse(reply.raw(), .first, d);
    if (std.mem.findScalar(u8, first.ns, '.') == null) return violation(d, "the namespace '{s}' of the cursor has no collection", .{first.ns});
    const ns = try r.gpa.dupe(u8, first.ns);
    errdefer r.gpa.free(ns);
    const comment: ?bson.OwnedDocument = if (options.comment) |value| try keepComment(r.gpa, value, d) else null;
    errdefer if (comment) |kept| kept.deinit();
    const c = try r.gpa.create(Cursor);
    c.* = .{
        .runner = r,
        .id = first.id,
        .ns = ns,
        .reply = reply,
        .batch = first.batch.iterator(),
        .batch_size = options.batch_size,
        .comment = comment,
        .diagnostics = d,
        .failure_reply = options.failure_reply,
    };
    const reg = r.cursors;
    reg.mutex.lockUncancelable(io);
    defer reg.mutex.unlock(io);
    reg.list.append(&c.node);
    reg.live += 1;
    if (c.id != 0) reg.open += 1;
    return c;
}

/// A cursor of the driver, in the client's memory.
pub const Cursor = struct {
    runner: Runner,
    node: List.Node = .{},
    // Guarded by the registry's mutex, which `close` of the client takes.
    /// The id on the server: 0 when it is exhausted, killed or unknown.
    id: i64,
    /// The namespace, "database.collection".
    ns: []u8,
    /// No more documents: closed, or ended by an error of a getMore.
    ended: bool = false,
    // The cursor's own: one task at a time uses it.
    /// The reply that holds the current batch.
    reply: bson.OwnedDocument,
    /// The documents of the current batch that `next` has not given yet.
    batch: bson.RawDocument.Iterator,
    batch_size: ?u32,
    /// `{comment: value}`: the comment of the options, kept for getMore.
    comment: ?bson.OwnedDocument,
    diagnostics: ?*Diagnostics,
    failure_reply: ?*?bson.OwnedDocument,
    /// `close` was called.
    closed: bool = false,
    /// In safe builds: a task is in a method of the cursor.
    busy: if (std.debug.runtime_safety) std.atomic.Value(bool) else void = if (std.debug.runtime_safety) .init(false) else {},

    pub fn next(c: *Cursor, io: Io, op: OperationContext) mongo.Error!?bson.RawDocument {
        c.runner.checkIo(io);
        c.enter();
        defer c.leave();
        while (true) {
            const id = c.state(io) orelse return fail(c.diagnostics, null, error.Closed, "the cursor is closed", .{});
            const element = c.batch.next() catch return c.broken(io, "a batch of the cursor is not valid BSON");
            if (element) |e| {
                if (e.value != .document) return c.broken(io, "a batch of the cursor holds something other than documents");
                return e.value.document;
            }
            if (id == 0) return null;
            try c.getMore(io, op, id);
        }
    }

    pub fn close(c: *Cursor, io: Io) void {
        c.runner.checkIo(io);
        c.enter();
        defer c.leave();
        c.closeOnce(io);
    }

    pub fn deinit(c: *Cursor, io: Io) void {
        c.runner.checkIo(io);
        c.enter();
        c.closeOnce(io);
        const r = c.runner;
        c.reply.deinit();
        r.gpa.free(c.ns);
        if (c.comment) |kept| kept.deinit();
        const reg = r.cursors;
        reg.mutex.lockUncancelable(io);
        reg.list.remove(&c.node);
        reg.live -= 1;
        reg.mutex.unlock(io);
        r.gpa.destroy(c);
    }

    /// In safe builds: a second task in a method of the cursor panics.
    fn enter(c: *Cursor) void {
        if (!std.debug.runtime_safety) return;
        if (c.busy.swap(true, .acquire)) @panic("zefir-mongo: a cursor used by two tasks at once: one task at a time calls next, close and deinit of a cursor");
    }

    fn leave(c: *Cursor) void {
        if (std.debug.runtime_safety) c.busy.store(false, .release);
    }

    fn closeOnce(c: *Cursor, io: Io) void {
        if (c.closed) return;
        c.closed = true;
        const reg = c.runner.cursors;
        reg.mutex.lockUncancelable(io);
        c.ended = true;
        const id = c.id;
        reg.setId(c, 0);
        reg.mutex.unlock(io);
        if (id != 0) kill(c.runner, io, c.ns, id);
    }

    /// The id, or null when the cursor has ended.
    fn state(c: *Cursor, io: Io) ?i64 {
        const reg = c.runner.cursors;
        reg.mutex.lockUncancelable(io);
        defer reg.mutex.unlock(io);
        return if (c.ended) null else c.id;
    }

    /// Ends the cursor; `id`, when given, is its id on the server from now
    /// on.
    fn end(c: *Cursor, io: Io, id: ?i64) void {
        const reg = c.runner.cursors;
        reg.mutex.lockUncancelable(io);
        defer reg.mutex.unlock(io);
        c.ended = true;
        if (id) |new| reg.setId(c, new);
    }

    fn broken(c: *Cursor, io: Io, comptime text: []const u8) mongo.Error {
        c.end(io, null);
        return violation(c.diagnostics, text, .{});
    }

    /// The next batch. An error before the command went out leaves the
    /// cursor as it was; an error of the exchange ends it.
    fn getMore(c: *Cursor, io: Io, op: OperationContext, id: i64) mongo.Error!void {
        const r = c.runner;
        const d = c.diagnostics;
        if (d) |x| x.* = .{};
        try r.pool.enter(io, d);
        defer r.pool.leave(io);
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const database, const collection = split(c.ns);
        const body = getMoreBody(arena.allocator(), id, collection, c.batch_size, c.comment) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidBson => fail(d, .send, error.InvalidArgument, "the getMore of the cursor cannot be written as BSON", .{}),
        };
        const reply = command_.send(r, io, op, r.deadlineOf(io, op), .{ .database = database, .body = body.raw() }, r.gpa, d) catch |err| {
            if (mongo.outcome(err) == .may_have_executed) c.end(io, null);
            return err;
        };
        errdefer reply.deinit();
        wire.checkReply(reply.raw(), r.gpa, d, c.failure_reply) catch |err| {
            // CursorNotFound: the server holds the cursor no more.
            c.end(io, if (mongo.ServerError.fromReply(reply.raw()).code == 43) 0 else null);
            return err;
        };
        const more = parse(reply.raw(), .next, d) catch |err| {
            c.end(io, null);
            return err;
        };
        const ns: ?[]u8 = if (std.mem.eql(u8, more.ns, c.ns)) null else ns: {
            if (std.mem.findScalar(u8, more.ns, '.') == null) {
                c.end(io, null);
                return violation(d, "the namespace '{s}' of the cursor has no collection", .{more.ns});
            }
            // The server has moved on past this batch: without it the
            // cursor cannot go on.
            break :ns r.gpa.dupe(u8, more.ns) catch {
                c.end(io, null);
                return error.OutOfMemory;
            };
        };
        const reg = r.cursors;
        var stale: ?[]u8 = null;
        reg.mutex.lockUncancelable(io);
        if (!c.ended) reg.setId(c, more.id);
        if (ns) |new| {
            stale = c.ns;
            c.ns = new;
        }
        reg.mutex.unlock(io);
        if (stale) |old| r.gpa.free(old);
        c.reply.deinit();
        c.reply = reply;
        c.batch = more.batch.iterator();
    }
};

/// For `close` of the client, once its calls ended: every cursor ends,
/// and `killCursors` goes for each one that the server holds, on a
/// connection of its own, within one `cursor_close_timeout` for all of
/// them. The task's cancelation waits until it is done.
pub fn closeAll(r: Runner, io: Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var arena: std.heap.ArenaAllocator = .init(r.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var kills: std.ArrayList(Kill) = .empty;
    const reg = r.cursors;
    reg.mutex.lockUncancelable(io);
    var it = reg.list.first;
    while (it) |node| : (it = node.next) {
        const c: *Cursor = @alignCast(@fieldParentPtr("node", node));
        c.ended = true;
        if (c.id == 0) continue;
        if (a.dupe(u8, c.ns)) |ns| kills.append(a, .{ .ns = ns, .id = c.id }) catch {} else |_| {}
        reg.setId(c, 0);
    }
    reg.mutex.unlock(io);
    if (kills.items.len == 0) return;
    const deadline: core.Deadline = .after(time.now(io), r.cursor_close_timeout);
    var attempt: connect_.Attempt = .{};
    const entry = r.opener.open(r.opener.context, io, .{ .deadline = deadline, .checkout = deadline }, &attempt, null) catch return;
    const conn = Connection.of(entry);
    defer conn.destroy();
    for (kills.items) |k| {
        const body = killBody(a, k.ns, k.id) catch return;
        const database, _ = split(k.ns);
        const reply = conn.exchange(.{ .database = database, .body = body.raw() }, a, deadline, null) catch return;
        reply.deinit();
    }
}

const Kill = struct { ns: []const u8, id: i64 };

/// Sends `killCursors` for cursor `id` of `ns` through the pool, with a
/// budget of `cursor_close_timeout`, and ignores the reply; the task's
/// cancelation waits until it is done.
fn kill(r: Runner, io: Io, ns: []const u8, id: i64) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    // A client closed or closing: its close kills what it finds open.
    r.pool.enter(io, null) catch return;
    defer r.pool.leave(io);
    var arena: std.heap.ArenaAllocator = .init(r.gpa);
    defer arena.deinit();
    const body = killBody(arena.allocator(), ns, id) catch return;
    const database, _ = split(ns);
    const op: OperationContext = .of(core.Context.root.withDeadline(.after(time.now(io), r.cursor_close_timeout)));
    const reply = command_.send(r, io, op, op.ctx.deadline, .{ .database = database, .body = body.raw() }, arena.allocator(), null) catch return;
    reply.deinit();
}

/// `{killCursors: collection, cursors: [id]}`.
fn killBody(a: Allocator, ns: []const u8, id: i64) bson.Builder.Error!bson.OwnedDocument {
    _, const collection = split(ns);
    var b: bson.Builder = .init(a);
    try b.putString("killCursors", collection);
    try b.beginArray("cursors");
    try b.putInt64("", id);
    try b.end();
    return b.finish();
}

/// `{getMore: id, collection, batchSize?, comment?}`; a `batchSize` of 0
/// leaves the size to the server, as none does.
fn getMoreBody(a: Allocator, id: i64, collection: []const u8, batch_size: ?u32, comment: ?bson.OwnedDocument) bson.Builder.Error!bson.OwnedDocument {
    var b: bson.Builder = .init(a);
    try b.putInt64("getMore", id);
    try b.putString("collection", collection);
    if (batch_size) |n| if (n > 0) {
        if (std.math.cast(i32, n)) |small| try b.putInt32("batchSize", small) else try b.putInt64("batchSize", n);
    };
    if (comment) |kept| if (kept.raw().get("comment") catch null) |value| try b.putValue("comment", value);
    return b.finish();
}

/// `{comment: value}` in `gpa`: the comment of a cursor, kept for its
/// getMore after the caller's memory is gone.
fn keepComment(gpa: Allocator, value: bson.Value, d: ?*Diagnostics) mongo.Error!bson.OwnedDocument {
    var b: bson.Builder = .init(gpa);
    defer b.deinit();
    b.putValue("comment", value) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => fail(d, null, error.InvalidArgument, "the comment of the cursor cannot be written as BSON", .{}),
    };
    return b.finish() catch error.OutOfMemory;
}

/// The database and the collection of a namespace "database.collection":
/// the collection is all after the first dot, "fs.chunks" of
/// "app.fs.chunks".
fn split(ns: []const u8) struct { []const u8, []const u8 } {
    const dot = std.mem.findScalar(u8, ns, '.') orelse return .{ ns, "" };
    return .{ ns[0..dot], ns[dot + 1 ..] };
}

/// The `cursor` of a reply: its id, namespace and batch.
const Parsed = struct { id: i64, ns: []const u8, batch: bson.RawDocument };

const Batch = enum { first, next };

fn parse(reply: bson.RawDocument, batch: Batch, d: ?*Diagnostics) mongo.Error!Parsed {
    const cursor = (reply.get("cursor") catch null) orelse return violation(d, "the reply holds no cursor; the command may have run", .{});
    if (cursor != .document) return violation(d, "cursor in the reply is not a document", .{});
    const id = if (cursor.document.get("id") catch null) |value| value.asI64() catch null else null;
    const ns = if (cursor.document.get("ns") catch null) |value| switch (value) {
        .string => |text| text,
        else => null,
    } else null;
    const key = switch (batch) {
        .first => "firstBatch",
        .next => "nextBatch",
    };
    const docs = (cursor.document.get(key) catch null) orelse return violation(d, "the cursor in the reply has no {s}", .{key});
    if (docs != .array) return violation(d, "{s} of the cursor in the reply is not an array", .{key});
    return .{
        .id = id orelse return violation(d, "the cursor in the reply has no id of an integer", .{}),
        .ns = ns orelse return violation(d, "the cursor in the reply has no ns", .{}),
        .batch = docs.array,
    };
}

fn fail(d: ?*Diagnostics, phase: ?Diagnostics.Phase, err: mongo.Error, comptime fmt: []const u8, args: anytype) mongo.Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}

fn violation(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) mongo.Error {
    return fail(d, .receive, error.ProtocolViolation, fmt, args);
}

const testing = std.testing;

test "a namespace splits at its first dot: the database before it, the collection after" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "app.users", "app", "users" },
        .{ "app.fs.chunks", "app", "fs.chunks" },
        .{ "app.$cmd.listCollections", "app", "$cmd.listCollections" },
    };
    for (cases) |case| {
        const ns, const database, const collection = case;
        const db, const coll = split(ns);
        try testing.expectEqualStrings(database, db);
        try testing.expectEqualStrings(collection, coll);
    }
}

test "getMore carries the id, the collection, a batchSize that is not 0 and the comment, in that order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comment = try keepComment(a, .{ .string = "tag" }, null);
    const full = try getMoreBody(a, 42, "fs.chunks", 7, comment);
    try testing.expectEqualSlices(u8, bson.literal(.{ .getMore = @as(i64, 42), .collection = "fs.chunks", .batchSize = 7, .comment = "tag" }).bytes, full.bytes);
    const bare = try getMoreBody(a, 42, "users", 0, null);
    try testing.expectEqualSlices(u8, bson.literal(.{ .getMore = @as(i64, 42), .collection = "users" }).bytes, bare.bytes);
    const kill_body = try killBody(a, "app.fs.chunks", 42);
    try testing.expectEqualSlices(u8, bson.literal(.{ .killCursors = "fs.chunks", .cursors = .{@as(i64, 42)} }).bytes, kill_body.bytes);
}
