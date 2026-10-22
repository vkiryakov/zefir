//! `odm.Collection(T)`: the typed operations on the collection of a model
//! in a tenant's database, and their results. A session gives it:
//!
//! ```zig
//! var acme = try registry.tenant(io, tenant_id);
//! defer acme.deinit(io);
//! const users = acme.collection(User);
//! const ann = try users.insertOne(io, ctx, .{ .email = "ann@example.com", .name = "Ann", .created_at = .now(io) });
//! _ = try users.updateOne(io, ctx, .{ .id = ann.id }, .{ .set = .{ .status = .blocked }, .inc = .{ .age = 1 } });
//! ```
//!
//! - The collection is `T.odm_schema.collection` in the database of the
//!   session; a collection reaches nothing else.
//! - An operation goes through its session, which serves one task at a
//!   time: it starts the session's diagnostics afresh, so that
//!   `session.diagnostics()` tells the details of its own error, and
//!   nothing after a success.
//! - insertOne, insertMany and replaceOne write whole documents: they check
//!   the `field_rules` of the model first (`ValidationFailed`, and nothing
//!   is sent), and leave the optionals that are null out of the document.
//!   The rules do not check updates and upsertOne.
//! - A value that BSON cannot hold, such as a string that is not UTF-8, is
//!   `EncodeFailed`, and nothing is sent.
//! - The BSON of a request lives in the working memory of the call, 2 KiB
//!   on the stack and then the registry's gpa, and goes when the call
//!   returns. What a call gives back is a value, or lives in the arena that
//!   the caller passes it.
//! - The registry counts each operation, and each one that failed
//!   (`registry.stats(io)`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const v = @import("validator");
const errors = @import("errors.zig");
const driver = @import("driver.zig");
const schema = @import("model/schema.zig");
const codec = @import("model/codec.zig");
const Session = @import("Session.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const Client = driver.Client;
const Insert = schema.Insert;
const Id = schema.Id;

/// The operations on the collection of the model `T` in the database of a
/// session; `session.collection(T)` gives it, and it is valid until the
/// session's `deinit`.
pub fn Collection(comptime T: type) type {
    comptime schema.check(T);
    return struct {
        session: *Session,

        const Self = @This();

        /// Inserts `doc`, after the `field_rules` of the model. A null id
        /// of type `?bson.ObjectId`, and an id of type `bson.ObjectId`,
        /// which `Insert(T)` lacks, are made by odm; an id of another type
        /// is the application's. The optionals that are null are left out
        /// of the document.
        pub fn insertOne(c: Self, io: Io, ctx: core.Context, doc: Insert(T)) Error!InsertOneResult(T) {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(insertOneIn(T, c.session, io, ctx, memory, &doc));
        }

        /// Inserts `docs` in one request, in their order: every document is
        /// checked by the `field_rules` first, then every one is encoded,
        /// and only then they go. The first that breaks a rule is
        /// `ValidationFailed`, with its index in the diagnostics, and
        /// nothing is sent; an empty list is `InvalidArgument`. The slice of
        /// ids is in `arena`. A unique index that refuses a document is
        /// `DuplicateKey`, with the index of the document; the ones before
        /// it went in.
        pub fn insertMany(c: Self, io: Io, ctx: core.Context, docs: []const Insert(T), arena: Allocator) Error!InsertManyResult(T) {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(insertManyIn(T, c.session, io, ctx, memory, docs, arena));
        }
    };
}

/// What insertOne gives: the id of the document, which odm made, or which
/// the application gave, and then it is borrowed from the document.
pub fn InsertOneResult(comptime T: type) type {
    return struct { id: Id(T) };
}

/// What insertMany gives: the ids of the documents, in their order, in the
/// arena of the call.
pub fn InsertManyResult(comptime T: type) type {
    return struct { ids: []const Id(T) };
}

/// What updateOne, updateMany and replaceOne give: the documents that the
/// filter matched, and those of them that changed.
pub const UpdateResult = struct { matched: u64, modified: u64 };

/// What upsertOne gives.
pub fn UpsertResult(comptime T: type) type {
    return struct {
        matched: u64,
        modified: u64,
        /// Not null when the upsert inserted a document: the id that the
        /// server made, an ObjectId, or the one that the filter or
        /// `set_on_insert` gave, borrowed from the caller.
        upserted_id: ?Id(T),
    };
}

/// What deleteOne and deleteMany give.
pub const DeleteResult = struct { deleted: u64 };

/// The size of the buffer on the stack that the working memory of a call
/// takes first.
pub const memory_size = 2048;

/// One call through a session: its working memory, and its part in the
/// rules of the session. `begin` makes the checks of the session in safe
/// builds and starts its diagnostics afresh; `finish` counts the operation
/// in the registry; `end` frees the memory and lets the next call through
/// the session go. For the collections, queries and `runCommand` of odm. It
/// stays where it is between `begin` and `end`.
pub const Call = struct {
    session: *Session,
    buffer: [memory_size]u8,
    first: std.heap.BufferFirstAllocator,
    arena: std.heap.ArenaAllocator,

    /// Starts a call through `s`, and gives its working memory: an arena
    /// over the buffer, then over the registry's gpa.
    pub fn begin(call: *Call, s: *Session, io: Io) Allocator {
        enter(s, io);
        call.session = s;
        call.first = .init(&call.buffer, s.registry.gpa);
        call.arena = .init(call.first.allocator());
        return call.arena.allocator();
    }

    pub fn end(call: *Call) void {
        call.arena.deinit();
        leave(call.session);
    }

    /// `result`, counted as an operation, and as an error when it is one.
    pub fn finish(call: *Call, result: anytype) @TypeOf(result) {
        const r = call.session.registry;
        _ = r.operations.fetchAdd(1, .monotonic);
        if (result) |_| {} else |_| _ = r.operation_errors.fetchAdd(1, .monotonic);
        return result;
    }
};

/// The start of a call through `s`: in safe builds a session given back,
/// or one that another task is calling through, panics. Then the
/// diagnostics of the session start afresh.
pub fn enter(s: *Session, io: Io) void {
    if (std.debug.runtime_safety) {
        if (s.released) @panic("zefir-odm: a collection used after the deinit of its session");
    }
    s.registry.checkUse(io);
    if (std.debug.runtime_safety) {
        if (s.busy.swap(true, .acquire)) @panic("zefir-odm: a session used by two tasks at once: take a session for each task");
    }
    s.diag = .{};
}

/// The end of a call through `s`.
pub fn leave(s: *Session) void {
    if (std.debug.runtime_safety) s.busy.store(false, .release);
}

/// The collection of the model `T` in the database of `s`.
pub fn namespace(comptime T: type, s: *const Session) Client.Namespace {
    return .{ .database = s.database(), .collection = T.odm_schema.collection };
}

/// The options of a call of the driver through `s`: the results in the
/// working memory, the details of an error in the session's diagnostics.
pub fn callOptions(s: *Session, memory: Allocator) Client.CallOptions {
    return .{ .allocator = memory, .diagnostics = &s.diag };
}

/// `err`, with the text in `d`.
pub fn fail(d: *Diagnostics, err: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
    d.set(null, null, fmt, args);
    return err;
}

fn insertOneIn(comptime T: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, doc: *const Insert(T)) Error!InsertOneResult(T) {
    const id = newId(T, s, io, doc);
    const value = codec.fromInsert(T, doc.*, id);
    try check(&value, &s.diag, null);
    const encoded = try encodeDocument(T, memory, &value, .insert, &s.diag, null);
    const request: Client.InsertRequest = .{ .ns = namespace(T, s), .documents = &.{encoded} };
    _ = try s.generation.client.insert(io, ctx, &request, callOptions(s, memory));
    return .{ .id = id };
}

fn insertManyIn(comptime T: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, docs: []const Insert(T), arena: Allocator) Error!InsertManyResult(T) {
    if (docs.len == 0) return fail(&s.diag, error.InvalidArgument, "odm: insertMany needs at least one document", .{});
    const ids = try arena.alloc(Id(T), docs.len);
    errdefer arena.free(ids);
    for (docs, ids, 0..) |*doc, *id, i| {
        id.* = newId(T, s, io, doc);
        const value = codec.fromInsert(T, doc.*, id.*);
        try check(&value, &s.diag, i);
    }
    const encoded = try memory.alloc(bson.RawDocument, docs.len);
    for (docs, ids, encoded, 0..) |*doc, id, *raw, i| {
        const value = codec.fromInsert(T, doc.*, id);
        raw.* = try encodeDocument(T, memory, &value, .insert, &s.diag, i);
    }
    const request: Client.InsertRequest = .{ .ns = namespace(T, s), .documents = encoded };
    _ = try s.generation.client.insert(io, ctx, &request, callOptions(s, memory));
    return .{ .ids = ids };
}

/// The id of the document of an insert: made by the registry's generator
/// when it is null or a `bson.ObjectId`, else the document's own.
fn newId(comptime T: type, s: *Session, io: Io, doc: *const Insert(T)) Id(T) {
    const name = comptime schema.idName(T);
    return switch (comptime schema.idKind(T)) {
        .optional_object_id => @field(doc, name) orelse s.registry.ids.next(io),
        .object_id => s.registry.ids.next(io),
        .given => @field(doc, name),
    };
}

/// The `field_rules` of the model on `value.*`: the first rule it breaks
/// is `ValidationFailed`, with the rule, the path and a text in `d`, and
/// `index` for a document of insertMany.
pub fn check(value: anytype, d: *Diagnostics, index: ?usize) error{ValidationFailed}!void {
    var path: [512]u8 = undefined;
    const violation = v.check(value, &path) orelse return;
    const field = violation.field orelse "";
    const sep: []const u8 = if (field.len > 0) ": " else "";
    if (index) |i| {
        d.set(null, i, "odm: document {d}: {s}{s}{s}", .{ i, field, sep, violation.message });
    } else {
        d.set(null, null, "odm: {s}{s}{s}", .{ field, sep, violation.message });
    }
    d.violation = .{ .code = violation.code, .message = violation.message };
    d.setPath(field);
    return error.ValidationFailed;
}

const unencodable = "a string is not UTF-8, a bson.RawDocument in it is not valid, or documents nest deeper than 100";

/// The document of `value.*` for `mode`, in `memory`; `EncodeFailed` with
/// a text in `d`, and `index` for a document of insertMany.
pub fn encodeDocument(comptime T: type, memory: Allocator, value: *const T, comptime mode: codec.Mode, d: *Diagnostics, index: ?usize) Error!bson.RawDocument {
    const doc = codec.encode(T, memory, value, mode) catch |err| switch (err) {
        error.EncodeFailed => {
            if (index) |i| {
                d.set(null, i, "odm: document {d} did not become BSON: " ++ unencodable, .{i});
            } else {
                d.set(null, null, "odm: the document did not become BSON: " ++ unencodable, .{});
            }
            return error.EncodeFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return doc.raw();
}
