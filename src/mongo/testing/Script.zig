//! `mongo.testing.Script`: a scripted MongoDB server, the brain that
//! `FakeServer` serves on loopback to `mongo.Client`. It holds what the
//! server says about itself in hello, a handler that answers each command,
//! and the journal of the commands that came.
//!
//! ```zig
//! const docs = [_]bson.RawDocument{ bson.literal(.{ .name = "Ann" }), bson.literal(.{ .name = "Bob" }) };
//! var users: Script.Cursor = .{ .ns = "app.users", .batches = &.{ docs[0..1], docs[1..2] } };
//! var script: Script = .init(gpa, users.handler());
//! defer script.deinit();
//! script.hello.max_write_batch_size = 3; // tiny limits split writes
//! // ... serve it with FakeServer, and run the code under test on a client of it ...
//! try std.testing.expectEqualStrings("getMore", (try script.entry(io, 1)).name);
//! ```
//!
//! The ready handlers cover what tests need most: `Queue` answers in the
//! order given, `Cursor` serves a cursor from a list of batches with its
//! `getMore` and `killCursors`, `Write` answers each batch of a write with
//! its `n` and the items it refuses. A handler of your own is a type with
//! `pub fn answer(self: *T, io, arena, request) HandlerError!Answer`,
//! passed as `.init(&value)`. Handlers are called from many tasks at once:
//! guard their state with `std.Io` primitives, as the ready ones do.
//!
//! A handler answers with a reply, a reply after a delay, a closed
//! connection, a server that refuses connections, or a reply that breaks
//! OP_MSG. The replies of the ready handlers carry
//! only fields that mongod writes in its replies to the same commands, of
//! the same BSON types; the end-to-end tests check it against mongod.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const wire = @import("../wire.zig");
const opmsg = wire.opmsg;
const WriteKind = @import("../requests.zig").WriteKind;
const Script = @This();

/// What the server says about itself in hello: a standalone mongod of
/// MongoDB 7.0 with the default limits, unless a test changes them, such
/// as a `max_write_batch_size` of 3 to split a write of 10 items. Set it
/// before `FakeServer.serve` runs: the connections read it without a lock,
/// so a change while they are served races with them.
hello: wire.Hello = .{},
/// Answers every command that the server does not answer itself.
handler: Handler,
/// The memory of the journal.
allocator: Allocator,
mutex: Io.Mutex = .init,
journal: std.ArrayList(Recorded) = .empty,
connections: std.atomic.Value(u32) = .init(0),
accepted: std.atomic.Value(u32) = .init(0),
refusing: std.atomic.Value(bool) = .init(false),

/// A script whose commands go to `handler`, with an empty journal in
/// `allocator`. The allocator must be thread-safe, such as
/// `std.testing.allocator`: `FakeServer` serves each connection in a task
/// of its own, which records its commands in the journal and keeps its
/// buffers in the same allocator.
pub fn init(allocator: Allocator, handler: Handler) Script {
    return .{ .handler = handler, .allocator = allocator };
}

/// Frees the journal.
pub fn deinit(s: *Script) void {
    for (s.journal.items) |recorded| s.allocator.free(recorded.bytes);
    s.journal.deinit(s.allocator);
    s.* = undefined;
}

/// What a handler can fail with besides answering: memory, or the
/// cancelation of the task it runs in, such as a handler doing I/O of its
/// own.
pub const HandlerError = error{ OutOfMemory, Canceled };

/// Answers commands: `function(context, …)`.
pub const Handler = struct {
    context: *anyopaque,
    /// Answers `request`. `arena` lives until the answer is sent: build
    /// replies in it. `io` is the caller's, to wait with and to guard state.
    function: *const fn (context: *anyopaque, io: Io, arena: Allocator, request: *const Request) HandlerError!Answer,

    /// The handler of `context: *T`, where `T` has
    /// `pub fn answer(self: *T, io: std.Io, arena: std.mem.Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer`.
    pub fn init(context: anytype) Handler {
        const Ptr = @TypeOf(context);
        const T = @typeInfo(Ptr).pointer.child;
        const gen = struct {
            fn answer(ptr: *anyopaque, io: Io, arena: Allocator, request: *const Request) HandlerError!Answer {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return T.answer(self, io, arena, request);
            }
        };
        return .{ .context = context, .function = gen.answer };
    }
};

/// A command as the server read it.
pub const Request = struct {
    /// The number of the connection it came on: 1 for the first connection
    /// to the server, 2 for the next, and so on.
    connection: u32,
    /// The command's name, its first key: "find".
    name: []const u8,
    /// Its `$db`; empty when it has none.
    database: []const u8,
    /// The document of kind 0 as the client sent it: the command, with the
    /// fields the client adds, `$db` always, `maxTimeMS` under a deadline,
    /// `ordered` for a write.
    body: bson.RawDocument,
    /// The first section of kind 1, such as the documents of an insert.
    sequence: ?opmsg.Section,

    /// The request in `incoming`, which it points into.
    pub fn of(connection: u32, incoming: *const opmsg.Incoming) Request {
        var sequences = incoming.sequences();
        const database = if (incoming.body.get("$db") catch null) |value| switch (value) {
            .string => |text| text,
            else => "",
        } else "";
        return .{
            .connection = connection,
            .name = if (incoming.body.first() catch null) |first| first.key else "",
            .database = database,
            .body = incoming.body,
            .sequence = sequences.next(),
        };
    }
};

/// What the server does with a command.
pub const Answer = union(enum) {
    /// Answer with this document.
    reply: bson.RawDocument,
    /// Answer after a delay, never sooner: for deadlines, cancelation
    /// and closing.
    delayed: Delayed,
    /// Close the connection after reading the command, without a reply.
    close_connection,
    /// Close the connection without a reply, and refuse new connections
    /// until `acceptConnections`: the server is gone. Calls in flight see
    /// a lost connection, later calls an unavailable server.
    refuse_connections,
    /// Answer with a message that breaks OP_MSG: the client takes it as a
    /// protocol violation.
    malformed: Malformed,
};

pub const Delayed = struct {
    after: Io.Duration,
    reply: bson.RawDocument,
};

/// How a malformed reply breaks OP_MSG. Each holds `{ok: 1.0}`.
pub const Malformed = enum {
    /// It answers another request: its responseTo is not the requestID.
    wrong_response_to,
    /// It sets flag bit 2, which must be understood and is unknown.
    unknown_required_flag,
    /// It holds a section of kind 1 after its section of kind 0.
    sequence_in_reply,
    /// Its frame is whole, but the document in it is cut 3 bytes short:
    /// the length of the message leaves them out. Like the others, it
    /// leaves the connection open.
    truncated,
};

/// A command in the journal: copies that live until `deinit`.
pub const Entry = struct {
    connection: u32,
    name: []const u8,
    database: []const u8,
    body: bson.RawDocument,
    sequence: ?opmsg.Section,
};

const Recorded = struct {
    bytes: []u8,
    entry: Entry,
};

/// Adds a copy of `request` to the journal. `FakeServer` records every
/// command it reads after the handshake; a server of your own on a script
/// does the same.
pub fn record(s: *Script, io: Io, request: *const Request) Allocator.Error!void {
    const identifier: []const u8 = if (request.sequence) |q| q.identifier else "";
    const documents: []const u8 = if (request.sequence) |q| q.bytes else "";
    const parts = [_][]const u8{ request.body.bytes, request.name, request.database, identifier, documents };
    var len: usize = 0;
    for (parts) |part| len += part.len;
    const bytes = try s.allocator.alloc(u8, len);
    errdefer s.allocator.free(bytes);
    var copies: [parts.len][]const u8 = undefined;
    var at: usize = 0;
    for (parts, &copies) |part, *slot| {
        @memcpy(bytes[at..][0..part.len], part);
        slot.* = bytes[at..][0..part.len];
        at += part.len;
    }
    const copy: Entry = .{
        .connection = request.connection,
        .body = .{ .bytes = copies[0] },
        .name = copies[1],
        .database = copies[2],
        .sequence = if (request.sequence != null) .{ .identifier = copies[3], .bytes = copies[4] } else null,
    };
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    try s.journal.append(s.allocator, .{ .bytes = bytes, .entry = copy });
}

/// The handler's answer to `request`; it is not recorded here.
pub fn answer(s: *Script, io: Io, arena: Allocator, request: *const Request) HandlerError!Answer {
    return s.handler.function(s.handler.context, io, arena, request);
}

/// How many commands the journal holds.
pub fn received(s: *Script, io: Io) usize {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    return s.journal.items.len;
}

/// The command number `i` of the journal, from 0, or `error.NotReceived`
/// while the journal holds no more than `i` commands.
pub fn entry(s: *Script, io: Io, i: usize) error{NotReceived}!Entry {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    if (i >= s.journal.items.len) return error.NotReceived;
    return s.journal.items[i].entry;
}

/// How many commands of the journal are named `name`.
pub fn count(s: *Script, io: Io, name: []const u8) usize {
    s.mutex.lockUncancelable(io);
    defer s.mutex.unlock(io);
    var n: usize = 0;
    for (s.journal.items) |recorded| {
        if (std.mem.eql(u8, recorded.entry.name, name)) n += 1;
    }
    return n;
}

/// The number of a new connection, or null while the script refuses
/// connections.
pub fn openConnection(s: *Script) ?u32 {
    if (s.refusing.load(.acquire)) return null;
    return s.connections.fetchAdd(1, .monotonic) + 1;
}

/// How many connections `FakeServer.serve` accepted and served for the
/// script.
pub fn acceptedConnections(s: *const Script) u32 {
    return s.accepted.load(.acquire);
}

/// Refuses new connections until `acceptConnections`, as
/// `Answer.refuse_connections` does.
pub fn refuseConnections(s: *Script) void {
    s.refusing.store(true, .release);
}

pub fn acceptConnections(s: *Script) void {
    s.refusing.store(false, .release);
}

pub fn isRefusing(s: *const Script) bool {
    return s.refusing.load(.acquire);
}

/// `{ok: 1.0}`.
pub const ok: bson.RawDocument = bson.literal(.{ .ok = 1.0 });

/// A failure of a command, as mongod writes one.
pub const Failure = struct {
    code: i32,
    code_name: []const u8,
    errmsg: []const u8,
    /// errorLabels, such as "SystemOverloadedError" and "RetryableError".
    labels: []const []const u8 = &.{},
};

/// `{ok: 0.0, errmsg, code, codeName, errorLabels?}`, in `arena`.
pub fn failure(arena: Allocator, f: Failure) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(arena);
    try b.putDouble("ok", 0);
    try b.putString("errmsg", f.errmsg);
    try b.putInt32("code", f.code);
    try b.putString("codeName", f.code_name);
    if (f.labels.len > 0) {
        try b.beginArray("errorLabels");
        for (f.labels) |label| try b.putString("", label);
        try b.end();
    }
    return (try b.finish()).raw();
}

/// Which batch a reply of a cursor carries.
pub const CursorBatch = enum { first, next };

/// `{cursor: {firstBatch|nextBatch: documents, id, ns}, ok: 1.0}`, in
/// `arena`, as mongod answers find, aggregate and getMore.
pub fn cursorReply(arena: Allocator, ns: []const u8, id: i64, batch: CursorBatch, documents: []const bson.RawDocument) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(arena);
    try b.beginDocument("cursor");
    try b.beginArray(switch (batch) {
        .first => "firstBatch",
        .next => "nextBatch",
    });
    for (documents) |doc| try b.putDocument("", doc);
    try b.end();
    try b.putInt64("id", id);
    try b.putString("ns", ns);
    try b.end();
    try b.putDouble("ok", 1);
    return (try b.finish()).raw();
}

/// The reply of a ready handler whose script holds a document that is not
/// valid BSON.
const invalid_script = bson.literal(.{
    .ok = 0.0,
    .errmsg = "mongo.testing.Script: a document of the script is not valid BSON",
    .code = 2,
    .codeName = "BadValue",
});

/// The reply to a command that a ready handler has no answer for.
fn unexpected(arena: Allocator, comptime fmt: []const u8, args: anytype) HandlerError!Answer {
    const errmsg = try std.fmt.allocPrint(arena, fmt, args);
    return built(failure(arena, .{ .code = 59, .code_name = "CommandNotFound", .errmsg = errmsg }));
}

fn built(reply: bson.Builder.Error!bson.RawDocument) HandlerError!Answer {
    return .{ .reply = reply catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBson => invalid_script,
    } };
}

/// Answers each command with the next of `answers`, in their order. Past
/// the last, a command gets a failure with code 59 that names it.
pub const Queue = struct {
    answers: []const Answer,
    taken: std.atomic.Value(usize) = .init(0),

    pub fn handler(q: *Queue) Handler {
        return .init(q);
    }

    /// How many answers are left.
    pub fn left(q: *const Queue) usize {
        return q.answers.len -| q.taken.load(.monotonic);
    }

    pub fn answer(q: *Queue, io: Io, arena: Allocator, request: *const Request) HandlerError!Answer {
        _ = io;
        const i = q.taken.fetchAdd(1, .monotonic);
        if (i < q.answers.len) return q.answers[i];
        return unexpected(arena, "mongo.testing.Script.Queue: no answer left for '{s}'", .{request.name});
    }
};

/// A cursor on the server, from a list of batches. Its command, any
/// command but `getMore` and `killCursors`, opens it afresh and gets the
/// first batch; each `getMore` with its id and namespace gets the next
/// one; the reply of the last batch has id 0, and the cursor is gone.
/// `killCursors` ends it.
pub const Cursor = struct {
    /// The namespace of the cursor: the database, a dot, the collection,
    /// as in "app.fs.chunks".
    ns: []const u8,
    /// Its id while open; not 0.
    id: i64 = 42,
    /// The first batch, then the batch of each `getMore`.
    batches: []const []const bson.RawDocument,
    mutex: Io.Mutex = .init,
    /// The batch that the next `getMore` gets.
    next_batch: usize = 0,
    /// Whether the cursor is open on the server.
    open: bool = false,
    /// How many `getMore` came, answered or not.
    get_mores: u32 = 0,
    /// How many `killCursors` named the cursor's id.
    kills: u32 = 0,

    pub fn handler(c: *Cursor) Handler {
        return .init(c);
    }

    pub fn answer(c: *Cursor, io: Io, arena: Allocator, request: *const Request) HandlerError!Answer {
        try c.mutex.lock(io);
        defer c.mutex.unlock(io);
        if (std.mem.eql(u8, request.name, "getMore")) return built(c.getMore(arena, request));
        if (std.mem.eql(u8, request.name, "killCursors")) return built(c.kill(arena, request));
        c.next_batch = 1;
        c.open = c.batches.len > 1;
        const first: []const bson.RawDocument = if (c.batches.len > 0) c.batches[0] else &.{};
        return built(cursorReply(arena, c.ns, if (c.open) c.id else 0, .first, first));
    }

    fn getMore(c: *Cursor, arena: Allocator, request: *const Request) bson.Builder.Error!bson.RawDocument {
        c.get_mores += 1;
        const id = if (request.body.get("getMore") catch null) |value| value.asI64() catch 0 else 0;
        if (!c.open or id != c.id) {
            return failure(arena, .{ .code = 43, .code_name = "CursorNotFound", .errmsg = try std.fmt.allocPrint(arena, "cursor id {d} not found", .{id}) });
        }
        const collection = if (request.body.get("collection") catch null) |value| switch (value) {
            .string => |text| text,
            else => "",
        } else "";
        if (!sameNamespace(c.ns, request.database, collection)) {
            return failure(arena, .{ .code = 13, .code_name = "Unauthorized", .errmsg = try std.fmt.allocPrint(arena, "Requested getMore on namespace '{s}.{s}', but cursor belongs to a different namespace {s}", .{ request.database, collection, c.ns }) });
        }
        const batch = c.batches[c.next_batch];
        c.next_batch += 1;
        if (c.next_batch == c.batches.len) c.open = false;
        return cursorReply(arena, c.ns, if (c.open) c.id else 0, .next, batch);
    }

    fn kill(c: *Cursor, arena: Allocator, request: *const Request) bson.Builder.Error!bson.RawDocument {
        var killed: std.ArrayList(i64) = .empty;
        var not_found: std.ArrayList(i64) = .empty;
        if (request.body.get("cursors") catch null) |value| if (value == .array) {
            var it = value.array.iterator();
            while (it.next() catch null) |element| {
                const id = element.value.asI64() catch continue;
                if (id == c.id) c.kills += 1;
                if (id == c.id and c.open) {
                    c.open = false;
                    try killed.append(arena, id);
                } else try not_found.append(arena, id);
            }
        };
        var b: bson.Builder = .init(arena);
        for ([_][]const u8{ "cursorsKilled", "cursorsNotFound", "cursorsAlive", "cursorsUnknown" }, 0..) |key, i| {
            try b.beginArray(key);
            const ids: []const i64 = switch (i) {
                0 => killed.items,
                1 => not_found.items,
                else => &.{},
            };
            for (ids) |id| try b.putInt64("", id);
            try b.end();
        }
        try b.putDouble("ok", 1);
        return (try b.finish()).raw();
    }
};

/// Whether `ns` is `database` and `collection` joined by a dot.
fn sameNamespace(ns: []const u8, database: []const u8, collection: []const u8) bool {
    return ns.len == database.len + 1 + collection.len and
        std.mem.startsWith(u8, ns, database) and ns[database.len] == '.' and
        std.mem.endsWith(u8, ns, collection);
}

/// Answers the batches of writes, `insert`, `update` and `delete`, as
/// mongod does: each with its `n`, `nModified` for an update, and
/// `writeErrors` for the items of `refuse` that fall in it, indexed in the
/// batch. An ordered write stops at its first refused item, as the server
/// does; an unordered one goes on. It counts the items of every batch, so
/// that the indexes of `refuse` count in the whole write.
pub const Write = struct {
    /// The items to refuse, by their index in the whole write, in
    /// increasing order.
    refuse: []const Refusal = &.{},
    mutex: Io.Mutex = .init,
    /// How many items came so far: the index of the first item of the next
    /// batch.
    seen: usize = 0,

    pub const Refusal = struct {
        index: usize,
        code: i32 = 11000,
        errmsg: []const u8 = "E11000 duplicate key error",
    };

    pub fn handler(w: *Write) Handler {
        return .init(w);
    }

    pub fn answer(w: *Write, io: Io, arena: Allocator, request: *const Request) HandlerError!Answer {
        const kind = std.meta.stringToEnum(WriteKind, request.name) orelse
            return unexpected(arena, "mongo.testing.Script.Write answers insert, update and delete; got '{s}'", .{request.name});
        const items = countItems(request, kind);
        const ordered = if (request.body.get("ordered") catch null) |value| switch (value) {
            .boolean => |b| b,
            else => true,
        } else true;
        try w.mutex.lock(io);
        const offset = w.seen;
        w.seen += items;
        w.mutex.unlock(io);

        var refused: std.ArrayList(Refusal) = .empty;
        var n = items;
        for (w.refuse) |refusal| {
            if (refusal.index < offset or refusal.index >= offset + items) continue;
            if (ordered) {
                // The server stops at the first refused item.
                n = refusal.index - offset;
                try refused.append(arena, refusal);
                break;
            }
            n -= 1;
            try refused.append(arena, refusal);
        }
        return built(writeReply(arena, kind, n, offset, refused.items));
    }

    fn writeReply(arena: Allocator, kind: WriteKind, n: usize, offset: usize, refused: []const Refusal) bson.Builder.Error!bson.RawDocument {
        var b: bson.Builder = .init(arena);
        try putCount(&b, "n", n);
        if (kind == .update) try putCount(&b, "nModified", n);
        if (refused.len > 0) {
            try b.beginArray("writeErrors");
            for (refused) |refusal| {
                try b.beginDocument("");
                try putCount(&b, "index", refusal.index - offset);
                try b.putInt32("code", refusal.code);
                try b.putString("errmsg", refusal.errmsg);
                try b.end();
            }
            try b.end();
        }
        try b.putDouble("ok", 1);
        return (try b.finish()).raw();
    }
};

/// The items of a write: its section of kind 1, or else the array of its
/// body under the same name.
fn countItems(request: *const Request, kind: WriteKind) usize {
    var n: usize = 0;
    if (request.sequence) |sequence| {
        var docs = sequence.documents();
        while (docs.next()) |_| n += 1;
        return n;
    }
    const items = (request.body.get(kind.items()) catch null) orelse return 0;
    if (items != .array) return 0;
    var it = items.array.iterator();
    while (it.next() catch null) |_| n += 1;
    return n;
}

/// A count as mongod writes one: an int32.
fn putCount(b: *bson.Builder, key: []const u8, n: usize) bson.Builder.Error!void {
    if (std.math.cast(i32, n)) |small| return b.putInt32(key, small);
    return b.putInt64(key, std.math.cast(i64, n) orelse std.math.maxInt(i64));
}
