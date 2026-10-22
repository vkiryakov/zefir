//! `odm.Collection(T)`: the typed operations on the collection of a model
//! in a tenant's database, and their results. A session gives it:
//!
//! ```zig
//! var acme = try registry.tenant(io, tenant_id);
//! defer acme.deinit(io);
//! const users = acme.collection(User);
//! const ann = try users.insertOne(io, ctx, .{ .email = "ann@example.com", .name = "Ann", .created_at = .now(io) });
//! _ = try users.updateOne(io, ctx, .{ .id = ann.id }, .{ .set = .{ .status = .blocked }, .inc = .{ .age = 1 } });
//! var adults = try users.find(io, ctx, .{ .status = .active, .age = .{ .gte = 18 } }, .{ .sort = .{ .age = .desc }, .limit = 100 });
//! defer adults.deinit(io);
//! while (try adults.next(io, ctx, arena)) |user| _ = user; // the strings of user live in arena
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
const filter_ = @import("query/filter.zig");
const options_ = @import("query/options.zig");
const update_ = @import("query/update.zig");
const values = @import("query/values.zig");
const leases = @import("registry/generation.zig");
const cursors = @import("Cursor.zig");
const Session = @import("Session.zig");
const Query = @import("query/Query.zig").Query;
const Cursor = cursors.Cursor;
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

        /// The first document that `filter` matches, decoded into `arena`,
        /// or null. `options` is a literal of `sort` and `skip`.
        pub fn findOne(c: Self, io: Io, ctx: core.Context, filter: anytype, options: anytype, arena: Allocator) Error!?T {
            return c.findOneAs(T, io, ctx, filter, options, arena);
        }

        /// As `findOne`, into `P`, a projection of the model: a struct of
        /// fields of `T`, of their types or their optionals. The server
        /// sends only those fields.
        pub fn findOneAs(c: Self, comptime P: type, io: Io, ctx: core.Context, filter: anytype, options: anytype, arena: Allocator) Error!?P {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(findOneIn(T, P, c.session, io, ctx, memory, filter, options, arena));
        }

        /// A cursor over the documents that `filter` matches. `options` is
        /// a literal of `sort`, `skip`, `limit` and `batch_size`:
        /// `.{ .sort = .{ .age = .desc }, .limit = 100 }`. `deinit` it.
        pub fn find(c: Self, io: Io, ctx: core.Context, filter: anytype, options: anytype) Error!Cursor(T) {
            return c.findAs(T, io, ctx, filter, options);
        }

        /// As `find`, with documents of `P`, a projection of the model.
        pub fn findAs(c: Self, comptime P: type, io: Io, ctx: core.Context, filter: anytype, options: anytype) Error!Cursor(P) {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(findIn(T, P, c.session, io, ctx, memory, filter, options));
        }

        /// How many documents `filter` matches; the capability `count` of
        /// the driver, else `Unsupported`.
        pub fn count(c: Self, io: Io, ctx: core.Context, filter: anytype) Error!u64 {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(countIn(T, c.session, io, ctx, memory, filter));
        }

        /// Changes the first document that `filter` matches by `update`, a
        /// literal of operators or an `odm.Update(T)`:
        /// `.{ .set = .{ .status = .blocked }, .inc = .{ .age = 1 } }`. The
        /// rules of the model do not check it.
        pub fn updateOne(c: Self, io: Io, ctx: core.Context, filter: anytype, update: anytype) Error!UpdateResult {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(updateIn(T, c.session, io, ctx, memory, filter, update, .one));
        }

        /// As `updateOne`, on every document that `filter` matches.
        pub fn updateMany(c: Self, io: Io, ctx: core.Context, filter: anytype, update: anytype) Error!UpdateResult {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(updateIn(T, c.session, io, ctx, memory, filter, update, .many));
        }

        /// Changes the first document that `filter` matches by `update`, or,
        /// when none does, inserts the document that the server builds from
        /// the equalities of the filter and the operators of the update. Both
        /// are literals: the build checks that the document it may insert
        /// gets every required field of the model, its id too when the
        /// application gives it; `set_on_insert` works here only. The rules
        /// of the model do not check it.
        pub fn upsertOne(c: Self, io: Io, ctx: core.Context, filter: anytype, update: anytype) Error!UpsertResult(T) {
            comptime {
                update_.checkUpsert(T, @TypeOf(filter), @TypeOf(update));
                requireWholeId(T, @TypeOf(filter), @TypeOf(update));
            }
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(upsertIn(T, c.session, io, ctx, memory, filter, update));
        }

        /// Replaces the first document that `filter` matches by
        /// `replacement`, after the `field_rules` of the model. The server
        /// keeps the document's `_id`, so `replacement`'s id is not read,
        /// and its optionals that are null leave the document.
        pub fn replaceOne(c: Self, io: Io, ctx: core.Context, filter: anytype, replacement: T) Error!UpdateResult {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(replaceIn(T, c.session, io, ctx, memory, filter, &replacement));
        }

        /// Deletes the first document that `filter` matches.
        pub fn deleteOne(c: Self, io: Io, ctx: core.Context, filter: anytype) Error!DeleteResult {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(deleteIn(T, c.session, io, ctx, memory, filter, false));
        }

        /// Deletes every document that `filter` matches: `.{}` deletes all
        /// the documents of the collection.
        pub fn deleteMany(c: Self, io: Io, ctx: core.Context, filter: anytype) Error!DeleteResult {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(deleteIn(T, c.session, io, ctx, memory, filter, true));
        }

        /// A raw aggregation, through the capability `aggregate` of the
        /// driver: `pipeline` is a tuple, a slice or an array of stages that
        /// `bson.encode` writes — literals, structs, `bson.RawDocument`s —
        /// which nothing checks against the model. The results decode into
        /// `R` by its field names. A raw path reaches what the login of the
        /// connection may reach: a `$out` or a `$merge` into another
        /// database too.
        pub fn aggregateRaw(c: Self, comptime R: type, io: Io, ctx: core.Context, pipeline: anytype) Error!Cursor(R) {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(aggregateIn(T, R, c.session, io, ctx, memory, pipeline));
        }

        /// Creates the indexes of `T.odm_schema.indexes`, through the
        /// capability `indexes` of the driver; the same ones again are not
        /// an error. An index without a name gets MongoDB's, such as
        /// "status_1_createdAt_-1". A model without indexes sends nothing.
        pub fn ensureIndexes(c: Self, io: Io, ctx: core.Context) Error!void {
            var call: Call = undefined;
            const memory = call.begin(c.session, io);
            defer call.end();
            return call.finish(ensureIndexesIn(T, c.session, io, ctx, memory));
        }

        /// A find to build at run time, with no condition yet; `arena`
        /// holds its conditions and the documents of its `first`.
        pub fn query(c: Self, arena: Allocator) Query(T) {
            return .{ .session = c.session, .arena = arena, .conditions = .init(arena) };
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

/// The BSON of `filter`, a filter of `T`, in `memory`; `EncodeFailed` or
/// `InvalidArgument` with a text in `d`.
pub fn encodeFilter(comptime T: type, memory: Allocator, filter: anytype, d: *Diagnostics) Error!bson.RawDocument {
    return filter_.encode(T, memory, filter) catch |err| switch (err) {
        error.EncodeFailed => fail(d, err, "odm: the filter did not become BSON: a string is not UTF-8, a pattern holds NUL, or documents nest deeper than 100", .{}),
        error.InvalidArgument => fail(d, err, "odm: an and, or or nor of the filter takes an empty []const odm.Filter({s}); it needs one filter at least", .{@typeName(T)}),
        error.OutOfMemory => err,
    };
}

/// The BSON of `update`, an update of `T` for `use`, in `memory`;
/// `EncodeFailed` or `InvalidArgument` with a text in `d`.
fn encodeUpdate(comptime T: type, memory: Allocator, update: anytype, comptime use: update_.Use, d: *Diagnostics) Error!bson.RawDocument {
    return update_.encode(T, memory, update, use) catch |err| switch (err) {
        error.EncodeFailed => fail(d, err, "odm: the update did not become BSON: a string is not UTF-8, a pattern of pull holds NUL, or documents nest deeper than 100", .{}),
        error.InvalidArgument => {
            // Only an odm.Update gives it: no with, or two with that
            // conflict, which the compiler cannot see.
            const built = comptime @hasDecl(@TypeOf(update), "odm_update_model");
            if (built and update.last == null) return fail(d, err, "odm: the odm.Update({s}) changes nothing: it has no with", .{@typeName(T)});
            if (built) return fail(d, err, "odm: two with of the odm.Update({s}) change one path, or two paths of which one holds the other", .{@typeName(T)});
            return fail(d, err, "odm: the update breaks a rule of odm", .{});
        },
        error.OutOfMemory => err,
    };
}

/// The projection that a read of `T` into `P` sends, or null when `P` is
/// the model itself.
pub fn projectionOf(comptime T: type, comptime P: type, memory: Allocator) Error!?bson.RawDocument {
    if (P == T) return null;
    return try options_.projection(T, P, memory);
}

/// The decoder of the documents of `T` into `P`, the model or a
/// projection of it, for a cursor.
pub fn decoderOf(comptime T: type, comptime P: type) *const cursors.Decode(P) {
    return &struct {
        fn decode(arena: Allocator, raw: bson.RawDocument, d: *Diagnostics) cursors.DecodeError!P {
            return codec.decode(T, P, arena, raw, d) catch |err| return decodeFailure(P, err, d);
        }
    }.decode;
}

/// `err` of a decode into `P`, with its text in `d`; the path and the cause
/// are there already.
pub fn decodeFailure(comptime P: type, err: cursors.DecodeError, d: *Diagnostics) cursors.DecodeError {
    switch (err) {
        error.DecodeFailed => d.set(null, null, "odm: a document of the server does not fit {s}", .{@typeName(P)}),
        error.InvalidBson => d.set(null, null, "odm: a document of the server is not valid BSON", .{}),
        error.OutOfMemory => {},
    }
    return err;
}

/// A cursor over the documents of `request`, holding a lease of its own on
/// the generation of `s`: a cursor may outlive its session.
pub fn openCursor(comptime T: type, comptime P: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, request: *const Client.FindRequest) Error!Cursor(P) {
    leases.acquire(s.registry, io, s.generation);
    errdefer leases.release(s.registry, io, s.generation);
    const raw = try s.generation.client.find(io, ctx, request, callOptions(s, memory));
    return .{ .registry = s.registry, .generation = s.generation, .raw = raw, .decode = decoderOf(T, P) };
}

/// The first document of `request`, decoded into `arena`, or null. The
/// cursor of the driver lives only in the call, under the lease of the
/// session.
pub fn readFirst(comptime T: type, comptime P: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, request: *const Client.FindRequest, arena: Allocator) Error!?P {
    const raw = try s.generation.client.find(io, ctx, request, callOptions(s, memory));
    defer raw.deinit(io);
    const doc = try raw.next(io, ctx, &s.diag) orelse return null;
    return try decoderOf(T, P)(arena, doc, &s.diag);
}

/// How many documents of `T` `filter` matches.
pub fn countIn(comptime T: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, filter: anytype) Error!u64 {
    const request: Client.CountRequest = .{ .ns = namespace(T, s), .filter = try encodeFilter(T, memory, filter, &s.diag) };
    return s.generation.client.count(io, ctx, &request, callOptions(s, memory));
}

fn findOneIn(comptime T: type, comptime P: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, filter: anytype, options: anytype, arena: Allocator) Error!?P {
    const parts = try options_.find(T, .findOne, memory, options);
    const request: Client.FindRequest = .{
        .ns = namespace(T, s),
        .filter = try encodeFilter(T, memory, filter, &s.diag),
        .sort = parts.sort,
        .projection = try projectionOf(T, P, memory),
        .skip = parts.skip,
        .limit = 1,
    };
    return readFirst(T, P, s, io, ctx, memory, &request, arena);
}

fn findIn(comptime T: type, comptime P: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, filter: anytype, options: anytype) Error!Cursor(P) {
    const parts = try options_.find(T, .find, memory, options);
    const request: Client.FindRequest = .{
        .ns = namespace(T, s),
        .filter = try encodeFilter(T, memory, filter, &s.diag),
        .sort = parts.sort,
        .projection = try projectionOf(T, P, memory),
        .skip = parts.skip,
        .limit = parts.limit,
        .batch_size = parts.batch_size,
    };
    return openCursor(T, P, s, io, ctx, memory, &request);
}

fn aggregateIn(comptime T: type, comptime R: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, pipeline: anytype) Error!Cursor(R) {
    const request: Client.AggregateRequest = .{ .ns = namespace(T, s), .pipeline = try encodePipeline(memory, pipeline, &s.diag) };
    leases.acquire(s.registry, io, s.generation);
    errdefer leases.release(s.registry, io, s.generation);
    const raw = try s.generation.client.aggregate(io, ctx, &request, callOptions(s, memory));
    return .{ .registry = s.registry, .generation = s.generation, .raw = raw, .decode = rawDecoder(R) };
}

/// The stages of `pipeline`, a tuple, a slice or an array of documents, in
/// `memory`.
fn encodePipeline(memory: Allocator, pipeline: anytype, d: *Diagnostics) Error![]const bson.RawDocument {
    const L = @TypeOf(pipeline);
    if (comptime values.TupleOf(L)) |Tuple| {
        const items: Tuple = if (comptime @typeInfo(L) == .pointer) pipeline.* else pipeline;
        const names = @typeInfo(Tuple).@"struct".field_names;
        const stages = try memory.alloc(bson.RawDocument, names.len);
        inline for (names, 0..) |name, i| stages[i] = try encodeStage(memory, @field(items, name), i, d);
        return stages;
    }
    if (comptime !values.isList(L)) @compileError("odm: the pipeline of aggregateRaw is a tuple, a slice or an array of documents; got " ++ @typeName(L));
    const stages = try memory.alloc(bson.RawDocument, pipeline.len);
    for (pipeline, stages, 0..) |stage, *raw, i| raw.* = try encodeStage(memory, stage, i, d);
    return stages;
}

fn encodeStage(memory: Allocator, stage: anytype, i: usize, d: *Diagnostics) Error!bson.RawDocument {
    const doc = bson.encode(memory, stage, .{}) catch |err| switch (err) {
        error.InvalidBson => return fail(d, error.EncodeFailed, "odm: stage {d} of the pipeline did not become BSON: a string is not UTF-8, a document in it is not valid, or documents nest deeper than 100", .{i}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return doc.raw();
}

/// The decoder of the results of an aggregateRaw into `R`, by the names of
/// its fields.
fn rawDecoder(comptime R: type) *const cursors.Decode(R) {
    return &struct {
        fn decode(arena: Allocator, raw: bson.RawDocument, d: *Diagnostics) cursors.DecodeError!R {
            var where: bson.DecodeDiagnostics = .{};
            return bson.decode(R, arena, raw, .{ .diagnostics = &where }) catch |err| switch (err) {
                error.InvalidBson => decodeFailure(R, error.InvalidBson, d),
                error.OutOfMemory => error.OutOfMemory,
                else => |cause| {
                    d.cause = cause;
                    d.setPath(where.path());
                    return decodeFailure(R, error.DecodeFailed, d);
                },
            };
        }
    }.decode;
}

/// An index of a model as the driver gets it, with the keys by their BSON
/// paths.
const IndexOf = struct {
    name: []const u8,
    keys: []const Key,
    unique: bool,
    sparse: bool,
    expire_after_seconds: ?u32,

    const Key = struct { path: []const u8, order: schema.IndexOrder };
};

/// The indexes of the schema of `T`, each named as MongoDB names it unless
/// the schema names it: the BSON path and the order of each key, joined by
/// '_'.
fn indexesOf(comptime T: type) []const IndexOf {
    comptime {
        @setEvalBranchQuota(schema.eval_quota);
        var out: []const IndexOf = &.{};
        for (T.odm_schema.indexes) |index| {
            var keys: []const IndexOf.Key = &.{};
            var name: []const u8 = "";
            for (index.keys, 0..) |key, i| {
                const path = bsonPath(T, @tagName(key));
                const order: schema.IndexOrder = switch (key) {
                    inline else => |o| o,
                };
                keys = keys ++ &[_]IndexOf.Key{.{ .path = path, .order = order }};
                const value = switch (order) {
                    .asc => "1",
                    .desc => "-1",
                    .text => "text",
                    .hashed => "hashed",
                };
                name = name ++ (if (i == 0) "" else "_") ++ path ++ "_" ++ value;
            }
            out = out ++ &[_]IndexOf{.{ .name = index.name orelse name, .keys = keys, .unique = index.unique, .sparse = index.sparse, .expire_after_seconds = index.expire_after_seconds }};
        }
        return out;
    }
}

/// The BSON path of the path `path` of `T`: the key of its first field
/// from the schema, then the Zig names.
fn bsonPath(comptime T: type, comptime path: []const u8) []const u8 {
    const dot = std.mem.findScalar(u8, path, '.') orelse return schema.keyOf(T, path);
    return schema.keyOf(T, path[0..dot]) ++ path[dot..];
}

fn ensureIndexesIn(comptime T: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator) Error!void {
    const indexes = comptime indexesOf(T);
    if (indexes.len == 0) return;
    var specs: [indexes.len]Client.IndexSpec = undefined;
    inline for (indexes, &specs) |index, *spec| {
        spec.* = .{
            .name = index.name,
            .keys = keysOf(memory, index.keys) catch |err| return switch (err) {
                error.InvalidBson => fail(&s.diag, error.EncodeFailed, "odm: the keys of the index {s} did not become BSON", .{index.name}),
                error.OutOfMemory => error.OutOfMemory,
            },
            .unique = index.unique,
            .sparse = index.sparse,
            .expire_after_seconds = index.expire_after_seconds,
        };
    }
    const request: Client.IndexRequest = .{ .ns = namespace(T, s), .indexes = &specs };
    return s.generation.client.createIndexes(io, ctx, &request, callOptions(s, memory));
}

/// The document of the keys of an index: `1` and `-1` as int32, "text"
/// and "hashed" as strings.
fn keysOf(memory: Allocator, comptime keys: []const IndexOf.Key) bson.Builder.Error!bson.RawDocument {
    var b: bson.Builder = .init(memory);
    defer b.deinit();
    inline for (keys) |key| switch (key.order) {
        .asc => try b.putInt32(key.path, 1),
        .desc => try b.putInt32(key.path, -1),
        .text => try b.putString(key.path, "text"),
        .hashed => try b.putString(key.path, "hashed"),
    };
    const doc = try b.finish();
    return doc.raw();
}

/// The body of `Session.runCommand`.
pub fn runCommandIn(s: *Session, io: Io, ctx: core.Context, memory: Allocator, command: anytype, arena: Allocator) Error!bson.RawDocument {
    const body = bson.encode(memory, command, .{}) catch |err| switch (err) {
        error.InvalidBson => return fail(&s.diag, error.EncodeFailed, "odm: the command did not become BSON: a string is not UTF-8, a document in it is not valid, or documents nest deeper than 100", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const request: Client.CommandRequest = .{ .database = s.database(), .body = body.raw() };
    return s.generation.client.command(io, ctx, &request, .{ .allocator = arena, .diagnostics = &s.diag });
}

fn updateIn(comptime T: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, filter: anytype, update: anytype, comptime mode: Client.UpdateMode) Error!UpdateResult {
    const request: Client.UpdateRequest = .{
        .ns = namespace(T, s),
        .filter = try encodeFilter(T, memory, filter, &s.diag),
        .update = try encodeUpdate(T, memory, update, .update, &s.diag),
        .mode = mode,
    };
    const result = try s.generation.client.update(io, ctx, &request, callOptions(s, memory));
    return .{ .matched = result.matched, .modified = result.modified };
}

fn upsertIn(comptime T: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, filter: anytype, update: anytype) Error!UpsertResult(T) {
    const request: Client.UpdateRequest = .{
        .ns = namespace(T, s),
        .filter = try encodeFilter(T, memory, filter, &s.diag),
        .update = try encodeUpdate(T, memory, update, .upsert, &s.diag),
        .mode = .one,
        .upsert = true,
    };
    const result = try s.generation.client.update(io, ctx, &request, callOptions(s, memory));
    const id: ?Id(T) = if (result.upserted_id) |server| try upsertedId(T, update_.upsertId(T, filter, update), server, &s.diag) else null;
    return .{ .matched = result.matched, .modified = result.modified, .upserted_id = id };
}

/// The id of the document that an upsert inserted: the one that its
/// literals gave, else the ObjectId that the server made.
fn upsertedId(comptime T: type, given: ?Id(T), server: bson.Value, d: *Diagnostics) Error!Id(T) {
    if (given) |id| return id;
    // An id that the application gives comes whole from the literals
    // (requireWholeId), so only an ObjectId comes from the server.
    if (comptime Id(T) == bson.ObjectId) switch (server) {
        .object_id => |id| return id,
        else => {},
    };
    d.set(null, null, "odm: the server gave the document that the upsert inserted an _id of BSON type {t}, not an ObjectId", .{server});
    d.cause = error.WrongType;
    d.setPath("_id");
    return error.DecodeFailed;
}

/// Stops the build when the id of `T` is one that the application gives,
/// and the literals of an upsert give it by the paths of its fields, not
/// whole: the result of upsertOne holds the id that they give.
fn requireWholeId(comptime T: type, comptime F: type, comptime U: type) void {
    if (schema.idKind(T) != .given) return;
    const id = schema.idName(T);
    const Field = @FieldType(T, id);
    if (@hasField(F, id)) {
        const V = @FieldType(F, id);
        if (!filter_.isConditions(values.top(T, id), V) or @hasField(V, "eq")) return;
    }
    if (@hasField(U, "set_on_insert") and @hasField(@FieldType(U, "set_on_insert"), id)) {
        if (!values.isLiteral(@FieldType(@FieldType(U, "set_on_insert"), id), Field)) return;
    }
    @compileError("odm: upsertOne of " ++ @typeName(T) ++ " gives its id '" ++ id ++ "' by paths into it: give the whole " ++ @typeName(Field) ++ " by equality in the filter or in set_on_insert");
}

fn replaceIn(comptime T: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, filter: anytype, replacement: *const T) Error!UpdateResult {
    try check(replacement, &s.diag, null);
    const request: Client.UpdateRequest = .{
        .ns = namespace(T, s),
        .filter = try encodeFilter(T, memory, filter, &s.diag),
        .update = try encodeDocument(T, memory, replacement, .replace, &s.diag, null),
        .mode = .replace,
    };
    const result = try s.generation.client.update(io, ctx, &request, callOptions(s, memory));
    return .{ .matched = result.matched, .modified = result.modified };
}

fn deleteIn(comptime T: type, s: *Session, io: Io, ctx: core.Context, memory: Allocator, filter: anytype, many: bool) Error!DeleteResult {
    const request: Client.DeleteRequest = .{ .ns = namespace(T, s), .filter = try encodeFilter(T, memory, filter, &s.diag), .many = many };
    const result = try s.generation.client.delete(io, ctx, &request, callOptions(s, memory));
    return .{ .deleted = result.deleted };
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
