//! `mongo.Collection`: a collection of MongoDB and its operations, written
//! once over `mongo.Client`, so the same on every driver. `Database`
//! gives it: `db.collection("users")`.
//!
//! ```zig
//! const User = struct {
//!     _id: ?bson.ObjectId = null, // null: the insert makes one
//!     email: []const u8,
//!     age: i32,
//! };
//! const users = db.collection("users");
//! const ann = try users.insertOne(io, op, User{ .email = "ann@example.com", .age = 30 }, .{ .allocator = arena });
//! _ = try users.updateOne(io, op, .{ ._id = ann.inserted_id }, .{ .@"$inc" = .{ .age = 1 } }, .{ .allocator = arena });
//! ```
//!
//! Each operation takes `io` and the caller's `mongo.OperationContext`,
//! as the contract does, and makes one call of the contract. No operation
//! retries. The name is checked before each one: an empty name, or one
//! with `$` or NUL, is `error.InvalidArgument`, and nothing is sent.
//!
//! Documents of operations — filters, updates, replacements, documents to
//! insert — come in three forms: a `bson.RawDocument`, a
//! `bson.OwnedDocument` (from `bson.Builder`), or a struct or an anonymous
//! literal that `bson.encode` writes, nulls as BSON null. They are
//! borrowed until the operation returns. A list — the documents of
//! `insertMany`, a pipeline — is a slice, an array or a tuple of them;
//! `.{}` is the empty document, and the empty list where a list goes:
//! `find(.{})` finds all, `aggregate(.{})` runs no stage. A type that fits
//! none of the forms stops the build with the name of the operation and
//! the path of the field. Documents inside options, such as a collation,
//! are `bson.RawDocument`s; `bson.literal` writes constant ones.
//!
//! An insert gives a document without `_id` an ObjectId of the database's
//! generator as its first field, and reports the `_id` of every document,
//! its own or made.
//!
//! A write may run in part. One that ran to its end, but whose items the
//! server refused or whose write concern failed, is `error.WriteFailed`:
//! the first error is in `mongo.Diagnostics`, and the whole result, with
//! the errors by their index in the whole list, goes to `options.partial`.
//! An error of the contract, `IncompleteWrite` among them, passes as it
//! is, and `partial` gets what is known:
//!
//! ```zig
//! var partial: mongo.Collection.InsertManyResult = .{};
//! defer partial.deinit(gpa);
//! const result = users.insertMany(io, op, docs, .{ .allocator = gpa, .ordered = false, .partial = &partial }) catch |err| switch (err) {
//!     // The server answered all: only the items of write_errors are not in (11000: a duplicate key).
//!     error.WriteFailed => return report(partial.write_errors),
//!     // In up to partial.answered, but for write_errors; after it, unknown or not sent.
//!     error.IncompleteWrite => return reconcile(partial.inserted_ids, partial.answered),
//!     else => return err,
//! };
//! ```
//!
//! Results come from `options.allocator`; free them with `deinit`. The
//! scratch memory of a call, such as the documents a struct is written
//! to, comes from it too and is freed before the call returns. A cursor,
//! which `find`, `aggregate` and `listIndexes` give, belongs to the
//! driver: `deinit` it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const errors = @import("../contract/errors.zig");
const requests = @import("../contract/requests.zig");
const contract_results = @import("../contract/results.zig");
const Cursor = @import("../contract/Cursor.zig");
const Database = @import("Database.zig");
const document = @import("document.zig");
const id = @import("id.zig");
const index = @import("index.zig");
const options_ = @import("options.zig");
const results = @import("results.zig");
const commands = @import("command.zig");
const cursors = @import("cursors.zig");
const Writer = commands.Writer;
const argument = commands.argument;
const unwritten = commands.unwritten;
const unwritable = commands.unwritable;
const invalid = commands.invalid;
const violation = commands.violation;
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const OperationContext = requests.OperationContext;
const WriteResult = contract_results.WriteResult;
const Collection = @This();

db: Database,
/// Borrowed; it must outlive the value.
name: []const u8,

pub const InsertOneOptions = options_.InsertOneOptions;
pub const InsertManyOptions = options_.InsertManyOptions;
pub const UpdateOptions = options_.UpdateOptions;
pub const ReplaceOptions = options_.ReplaceOptions;
pub const DeleteOptions = options_.DeleteOptions;
pub const FindOneAndUpdateOptions = options_.FindOneAndUpdateOptions;
pub const FindOneAndReplaceOptions = options_.FindOneAndReplaceOptions;
pub const FindOneAndDeleteOptions = options_.FindOneAndDeleteOptions;
pub const FindOptions = options_.FindOptions;
pub const FindOneOptions = options_.FindOneOptions;
pub const AggregateOptions = options_.AggregateOptions;
pub const CountDocumentsOptions = options_.CountDocumentsOptions;
pub const EstimatedDocumentCountOptions = options_.EstimatedDocumentCountOptions;
pub const DistinctOptions = options_.DistinctOptions;
pub const CreateIndexesOptions = options_.CreateIndexesOptions;
pub const ListIndexesOptions = options_.ListIndexesOptions;
pub const DropIndexOptions = options_.DropIndexOptions;
pub const DropOptions = options_.DropOptions;
pub const IndexModel = index.IndexModel;
pub const ReturnDocument = options_.ReturnDocument;
pub const Hint = options_.Hint;
pub const InsertOneResult = results.InsertOneResult;
pub const InsertManyResult = results.InsertManyResult;
pub const UpdateResult = results.UpdateResult;
pub const DeleteResult = results.DeleteResult;

/// Inserts `doc`: `insert` with the document in a section of kind 1. A
/// document without `_id` gets an ObjectId first; the result reports the
/// `_id`.
pub fn insertOne(c: Collection, io: Io, op: OperationContext, doc: anytype, options: InsertOneOptions) Error!InsertOneResult {
    comptime document.expectDocument("insertOne", "document", @TypeOf(doc));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.writeBody(a, "insert", .{ .bypass_document_validation = options.bypass_document_validation, .comment = options.comment }, options.diagnostics);
    const inserts: Inserts = .{ .io = io, .ids = c.db.ids, .arena = a, .diagnostics = options.diagnostics, .one = true };
    const items = [_]bson.RawDocument{try inserts.prepare(0, doc)};
    return c.runWrite(io, op, .{ .kind = .insert, .body = body, .items = &items }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    }, InsertOneResult, options.partial, items[0], results.ofInsertOne);
}

/// Inserts the documents of the list `docs`, in batches that the driver
/// cuts by the server's limits. Each document without `_id` gets an
/// ObjectId first; the result reports the `_id` of each, by its index in
/// the list. An empty list is `error.InvalidArgument`.
pub fn insertMany(c: Collection, io: Io, op: OperationContext, docs: anytype, options: InsertManyOptions) Error!InsertManyResult {
    comptime document.expectList("insertMany", "documents", @TypeOf(docs));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.writeBody(a, "insert", .{ .bypass_document_validation = options.bypass_document_validation, .comment = options.comment }, options.diagnostics);
    const inserts: Inserts = .{ .io = io, .ids = c.db.ids, .arena = a, .diagnostics = options.diagnostics, .one = false };
    const items = try document.mapItems(a, docs, inserts, Inserts.prepare);
    if (items.len == 0) return invalid(options.diagnostics, "insertMany has no documents: it needs at least one", .{});
    return c.runWrite(io, op, .{ .kind = .insert, .body = body, .items = items, .ordered = options.ordered }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    }, InsertManyResult, options.partial, items, results.ofInsertMany);
}

/// Updates the first document that `filter` matches. `update` is a
/// document of update operators, its first key such as `$set`, or a
/// pipeline: a list of stages. Anything else, `.{}` among it, is
/// `error.InvalidArgument`.
pub fn updateOne(c: Collection, io: Io, op: OperationContext, filter: anytype, update: anytype, options: UpdateOptions) Error!UpdateResult {
    comptime document.expectDocument("updateOne", "filter", @TypeOf(filter));
    comptime expectUpdate("updateOne", @TypeOf(update));
    return c.updateWith(io, op, filter, update, false, options);
}

/// Updates every document that `filter` matches, as `updateOne` updates
/// one: one statement with `multi: true`.
pub fn updateMany(c: Collection, io: Io, op: OperationContext, filter: anytype, update: anytype, options: UpdateOptions) Error!UpdateResult {
    comptime document.expectDocument("updateMany", "filter", @TypeOf(filter));
    comptime expectUpdate("updateMany", @TypeOf(update));
    return c.updateWith(io, op, filter, update, true, options);
}

/// Replaces the first document that `filter` matches with `replacement`,
/// a document whose first key is no update operator (that is
/// `error.InvalidArgument`); the document keeps its `_id`.
pub fn replaceOne(c: Collection, io: Io, op: OperationContext, filter: anytype, replacement: anytype, options: ReplaceOptions) Error!UpdateResult {
    comptime document.expectDocument("replaceOne", "filter", @TypeOf(filter));
    comptime expectReplacement("replaceOne", @TypeOf(replacement));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.writeBody(a, "update", .{ .let = options.let, .bypass_document_validation = options.bypass_document_validation, .comment = options.comment }, options.diagnostics);
    const statement = try updateStatement(a, .{
        .q = try argument(a, filter, "the filter", options.diagnostics),
        .u = .{ .document = try replacementOf(a, replacement, options.diagnostics) },
        .u_name = "the replacement",
        .upsert = options.upsert,
        .collation = options.collation,
        .hint = options.hint,
    }, options.diagnostics);
    return c.runWrite(io, op, .{ .kind = .update, .body = body, .items = &.{statement} }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    }, UpdateResult, options.partial, {}, results.ofUpdate);
}

/// Deletes the first document that `filter` matches: limit 1.
pub fn deleteOne(c: Collection, io: Io, op: OperationContext, filter: anytype, options: DeleteOptions) Error!DeleteResult {
    comptime document.expectDocument("deleteOne", "filter", @TypeOf(filter));
    return c.deleteWith(io, op, filter, 1, options);
}

/// Deletes every document that `filter` matches: limit 0. `.{}` matches
/// all.
pub fn deleteMany(c: Collection, io: Io, op: OperationContext, filter: anytype, options: DeleteOptions) Error!DeleteResult {
    comptime document.expectDocument("deleteMany", "filter", @TypeOf(filter));
    return c.deleteWith(io, op, filter, 0, options);
}

fn updateWith(c: Collection, io: Io, op: OperationContext, filter: anytype, update: anytype, multi: bool, options: UpdateOptions) Error!UpdateResult {
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.writeBody(a, "update", .{ .let = options.let, .bypass_document_validation = options.bypass_document_validation, .comment = options.comment }, options.diagnostics);
    const statement = try updateStatement(a, .{
        .q = try argument(a, filter, "the filter", options.diagnostics),
        .u = try changeOf(a, update, options.diagnostics),
        .u_name = "the update",
        .multi = multi,
        .upsert = options.upsert,
        .array_filters = options.array_filters,
        .collation = options.collation,
        .hint = options.hint,
    }, options.diagnostics);
    return c.runWrite(io, op, .{ .kind = .update, .body = body, .items = &.{statement} }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    }, UpdateResult, options.partial, {}, results.ofUpdate);
}

fn deleteWith(c: Collection, io: Io, op: OperationContext, filter: anytype, limit: i32, options: DeleteOptions) Error!DeleteResult {
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.writeBody(a, "delete", .{ .let = options.let, .comment = options.comment }, options.diagnostics);
    var w: Writer = .init(a, options.diagnostics);
    try w.document("q", try argument(a, filter, "the filter", options.diagnostics), "the filter");
    try w.int32("limit", limit);
    if (options.collation) |collation| try w.document("collation", collation, "the collation");
    if (options.hint) |hint| try w.hint(hint);
    const statement = try w.finish();
    return c.runWrite(io, op, .{ .kind = .delete, .body = body, .items = &.{statement} }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    }, DeleteResult, options.partial, {}, results.ofDelete);
}

/// Finds the documents that `filter` matches, `.{}` all of them: `find`,
/// whose cursor gives them batch by batch, borrowed until its next call:
///
/// ```zig
/// var adults = try users.find(io, op, .{ .age = .{ .@"$gte" = 18 } }, .{ .allocator = arena, .sort = bson.literal(.{ .age = -1 }) });
/// defer adults.deinit(io);
/// while (try adults.next(io, op)) |doc| try show(try bson.decode(User, arena, doc, .{}));
/// ```
///
/// A limit equal to the batch size asks for one more document in the
/// first batch, so that the server does not leave the cursor open.
pub fn find(c: Collection, io: Io, op: OperationContext, filter: anytype, options: FindOptions) Error!Cursor {
    comptime document.expectDocument("find", "filter", @TypeOf(filter));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var first_batch: ?u64 = null;
    if (options.batch_size) |n| {
        first_batch = if (options.limit != 0 and n == options.limit) @as(u64, n) + 1 else n;
    }
    const body = try c.findBody(a, .{
        .filter = try argument(a, filter, "the filter", options.diagnostics),
        .sort = options.sort,
        .projection = options.projection,
        .hint = options.hint,
        .skip = options.skip,
        .limit = options.limit,
        .batch_size = first_batch,
        .comment = options.comment,
        .collation = options.collation,
        .allow_disk_use = options.allow_disk_use,
        .let = options.let,
    }, options.diagnostics);
    return c.db.client.openCursor(io, op, .{ .database = c.db.name, .body = body }, .{
        .batch_size = options.batch_size,
        .comment = options.comment,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
}

/// The first document that `filter` matches, the first in `sort` when it
/// matches several, as a copy in `options.allocator`; null when none
/// does. `find` with `limit: 1` and `singleBatch: true`, whose cursor is
/// freed before the call returns.
pub fn findOne(c: Collection, io: Io, op: OperationContext, filter: anytype, options: FindOneOptions) Error!?bson.OwnedDocument {
    comptime document.expectDocument("findOne", "filter", @TypeOf(filter));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.findBody(a, .{
        .filter = try argument(a, filter, "the filter", options.diagnostics),
        .sort = options.sort,
        .projection = options.projection,
        .hint = options.hint,
        .skip = options.skip,
        .limit = 1,
        .single_batch = true,
        .comment = options.comment,
        .collation = options.collation,
        .let = options.let,
    }, options.diagnostics);
    const cursor = try c.db.client.openCursor(io, op, .{ .database = c.db.name, .body = body }, .{
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    defer cursor.deinit(io);
    return cursor.nextOwned(io, op, options.allocator);
}

/// What a `find` command carries besides its name, in the order it goes.
const Find = struct {
    filter: bson.RawDocument,
    sort: ?bson.RawDocument = null,
    projection: ?bson.RawDocument = null,
    hint: ?Hint = null,
    skip: u32 = 0,
    limit: u32 = 0,
    batch_size: ?u64 = null,
    single_batch: bool = false,
    comment: ?bson.Value = null,
    collation: ?bson.RawDocument = null,
    allow_disk_use: ?bool = null,
    let: ?bson.RawDocument = null,
};

fn findBody(c: Collection, a: Allocator, f: Find, diagnostics: ?*Diagnostics) Error!bson.RawDocument {
    var w: Writer = .init(a, diagnostics);
    try w.string("find", c.name);
    try w.document("filter", f.filter, "the filter");
    if (f.sort) |sort| try w.document("sort", sort, "the sort");
    if (f.projection) |projection| try w.document("projection", projection, "the projection");
    if (f.hint) |hint| try w.hint(hint);
    if (f.skip != 0) try w.count("skip", f.skip);
    if (f.limit != 0) try w.count("limit", f.limit);
    if (f.batch_size) |n| try w.count("batchSize", n);
    if (f.single_batch) try w.boolean("singleBatch", true);
    if (f.comment) |value| try w.value("comment", value, "the comment");
    if (f.collation) |collation| try w.document("collation", collation, "the collation");
    if (f.allow_disk_use) |allow| try w.boolean("allowDiskUse", allow);
    if (f.let) |let| try w.document("let", let, "let");
    return w.finish();
}

/// Updates the first document that `filter` matches, the first in `sort`
/// when it matches several, and returns it: as it was, or as the update
/// left it with `.return_document = .after`. `update` is as `updateOne`
/// takes it. Null when no document matched, or when an upsert inserted it
/// and `return_document` is `.before`. The document is a copy in
/// `options.allocator`.
pub fn findOneAndUpdate(c: Collection, io: Io, op: OperationContext, filter: anytype, update: anytype, options: FindOneAndUpdateOptions) Error!?bson.OwnedDocument {
    comptime document.expectDocument("findOneAndUpdate", "filter", @TypeOf(filter));
    comptime expectUpdate("findOneAndUpdate", @TypeOf(update));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.findAndModifyBody(a, .{
        .query = try argument(a, filter, "the filter", options.diagnostics),
        .sort = options.sort,
        .change = try changeOf(a, update, options.diagnostics),
        .change_name = "the update",
        .new = options.return_document == .after,
        .fields = options.projection,
        .upsert = options.upsert,
        .bypass_document_validation = options.bypass_document_validation,
        .array_filters = options.array_filters,
        .collation = options.collation,
        .hint = options.hint,
        .let = options.let,
        .comment = options.comment,
    }, options.diagnostics);
    return c.findAndModify(io, op, body, options.allocator, options.diagnostics, options.failure_reply);
}

/// Replaces the first document that `filter` matches, as `replaceOne`
/// does, and returns it as `findOneAndUpdate` does.
pub fn findOneAndReplace(c: Collection, io: Io, op: OperationContext, filter: anytype, replacement: anytype, options: FindOneAndReplaceOptions) Error!?bson.OwnedDocument {
    comptime document.expectDocument("findOneAndReplace", "filter", @TypeOf(filter));
    comptime expectReplacement("findOneAndReplace", @TypeOf(replacement));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.findAndModifyBody(a, .{
        .query = try argument(a, filter, "the filter", options.diagnostics),
        .sort = options.sort,
        .change = .{ .document = try replacementOf(a, replacement, options.diagnostics) },
        .change_name = "the replacement",
        .new = options.return_document == .after,
        .fields = options.projection,
        .upsert = options.upsert,
        .bypass_document_validation = options.bypass_document_validation,
        .collation = options.collation,
        .hint = options.hint,
        .let = options.let,
        .comment = options.comment,
    }, options.diagnostics);
    return c.findAndModify(io, op, body, options.allocator, options.diagnostics, options.failure_reply);
}

/// Deletes the first document that `filter` matches, the first in `sort`
/// when it matches several, and returns it; null when none matched. The
/// document is a copy in `options.allocator`.
pub fn findOneAndDelete(c: Collection, io: Io, op: OperationContext, filter: anytype, options: FindOneAndDeleteOptions) Error!?bson.OwnedDocument {
    comptime document.expectDocument("findOneAndDelete", "filter", @TypeOf(filter));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.findAndModifyBody(a, .{
        .query = try argument(a, filter, "the filter", options.diagnostics),
        .sort = options.sort,
        .fields = options.projection,
        .collation = options.collation,
        .hint = options.hint,
        .let = options.let,
        .comment = options.comment,
    }, options.diagnostics);
    return c.findAndModify(io, op, body, options.allocator, options.diagnostics, options.failure_reply);
}

/// What a `findAndModify` command carries besides its name.
const Modify = struct {
    query: bson.RawDocument,
    sort: ?bson.RawDocument = null,
    /// The update or the replacement; null removes the document.
    change: ?Change = null,
    /// What `change` is to the caller, for the diagnostics.
    change_name: []const u8 = "",
    new: bool = false,
    fields: ?bson.RawDocument = null,
    upsert: bool = false,
    bypass_document_validation: bool = false,
    array_filters: ?[]const bson.RawDocument = null,
    collation: ?bson.RawDocument = null,
    hint: ?Hint = null,
    let: ?bson.RawDocument = null,
    comment: ?bson.Value = null,
};

fn findAndModifyBody(c: Collection, a: Allocator, m: Modify, diagnostics: ?*Diagnostics) Error!bson.RawDocument {
    var w: Writer = .init(a, diagnostics);
    try w.string("findAndModify", c.name);
    try w.document("query", m.query, "the filter");
    if (m.sort) |sort| try w.document("sort", sort, "the sort");
    if (m.change) |change| switch (change) {
        .document => |doc| try w.document("update", doc, m.change_name),
        .pipeline => |stages| try w.documents("update", stages, "the pipeline of the update"),
    } else try w.boolean("remove", true);
    if (m.new) try w.boolean("new", true);
    if (m.fields) |fields| try w.document("fields", fields, "the projection");
    if (m.upsert) try w.boolean("upsert", true);
    if (m.bypass_document_validation) try w.boolean("bypassDocumentValidation", true);
    if (m.array_filters) |filters| try w.documents("arrayFilters", filters, "array_filters");
    if (m.collation) |collation| try w.document("collation", collation, "the collation");
    if (m.hint) |hint| try w.hint(hint);
    if (m.let) |let| try w.document("let", let, "let");
    if (m.comment) |value| try w.value("comment", value, "the comment");
    return w.finish();
}

/// Runs `body`, a findAndModify, and returns a copy of the `value` of its
/// reply in `allocator`, or null.
fn findAndModify(c: Collection, io: Io, op: OperationContext, body: bson.RawDocument, allocator: Allocator, diagnostics: ?*Diagnostics, failure_reply: ?*?bson.OwnedDocument) Error!?bson.OwnedDocument {
    const reply = try c.db.client.runCommand(io, op, .{ .database = c.db.name, .body = body }, .{
        .allocator = allocator,
        .diagnostics = diagnostics,
        .failure_reply = failure_reply,
    });
    defer reply.deinit();
    // The write ran, but not with its write concern: as for the other
    // writes, that is WriteFailed, and Timeout for MaxTimeMSExpired.
    if (reply.raw().get("writeConcernError") catch null) |concern| {
        if (concern != .document) return violation(diagnostics, "writeConcernError in the reply of findAndModify is not a document");
        if (failure_reply) |slot| slot.* = try reply.raw().dupe(allocator);
        if (diagnostics) |d| d.setServer(.receive, concern.document);
        return if (errors.ServerError.fromReply(concern.document).code == 50) error.Timeout else error.WriteFailed;
    }
    const value = (reply.raw().get("value") catch null) orelse
        return violation(diagnostics, "the reply of findAndModify holds no value; the command may have run");
    return switch (value) {
        .null => null,
        .document => |doc| try doc.dupe(allocator),
        else => violation(diagnostics, "the value in the reply of findAndModify is neither a document nor null"),
    };
}

/// Runs the aggregation `pipeline`, a list of stages, `.{}` the empty one:
/// `aggregate`, whose cursor gives the documents of its last stage:
///
/// ```zig
/// var by_city = try users.aggregate(io, op, .{
///     .{ .@"$match" = .{ .active = true } },
///     .{ .@"$group" = .{ ._id = "$city", .n = .{ .@"$sum" = 1 } } },
/// }, .{ .allocator = arena });
/// defer by_city.deinit(io);
/// ```
pub fn aggregate(c: Collection, io: Io, op: OperationContext, pipeline: anytype, options: AggregateOptions) Error!Cursor {
    comptime document.expectList("aggregate", "pipeline", @TypeOf(pipeline));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const stages = document.encodeList(a, pipeline) catch |err| return unwritten(err, options.diagnostics, "the pipeline");
    var w: Writer = .init(a, options.diagnostics);
    try w.string("aggregate", c.name);
    try w.documents("pipeline", stages, "the pipeline");
    if (options.allow_disk_use) |allow| try w.boolean("allowDiskUse", allow);
    // By the CRUD spec, a pipeline that writes runs with the server's
    // batch size: a batch size of 0 would keep it from running.
    try w.cursor(if (writes(stages)) null else options.batch_size);
    if (options.bypass_document_validation) try w.boolean("bypassDocumentValidation", true);
    if (options.collation) |collation| try w.document("collation", collation, "the collation");
    if (options.hint) |hint| try w.hint(hint);
    if (options.comment) |value| try w.value("comment", value, "the comment");
    if (options.let) |let| try w.document("let", let, "let");
    return c.db.client.openCursor(io, op, .{ .database = c.db.name, .body = try w.finish() }, .{
        .batch_size = options.batch_size,
        .comment = options.comment,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
}

/// Whether the last of `stages` writes its documents: `$out` or `$merge`.
fn writes(stages: []const bson.RawDocument) bool {
    if (stages.len == 0) return false;
    const first = (stages[stages.len - 1].first() catch return false) orelse return false;
    return std.mem.eql(u8, first.key, "$out") or std.mem.eql(u8, first.key, "$merge");
}

/// The stage of `countDocuments` that counts what comes to it.
const count_stage = bson.literal(.{ .@"$group" = .{ ._id = 1, .n = .{ .@"$sum" = 1 } } });

/// How many documents `filter` matches, `.{}` all of them, counted by the
/// server one by one: `aggregate` with `$match`, then `$skip` and
/// `$limit` when given, then `$group`. Exact, as `estimatedDocumentCount`
/// is not.
pub fn countDocuments(c: Collection, io: Io, op: OperationContext, filter: anytype, options: CountDocumentsOptions) Error!u64 {
    comptime document.expectDocument("countDocuments", "filter", @TypeOf(filter));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const match = try argument(a, filter, "the filter", options.diagnostics);
    var w: Writer = .init(a, options.diagnostics);
    try w.string("aggregate", c.name);
    try w.beginArray("pipeline");
    try w.beginDocument("");
    try w.document("$match", match, "the filter");
    try w.end();
    if (options.skip != 0) {
        try w.beginDocument("");
        try w.count("$skip", options.skip);
        try w.end();
    }
    if (options.limit != 0) {
        try w.beginDocument("");
        try w.count("$limit", options.limit);
        try w.end();
    }
    try w.document("", count_stage, "the pipeline");
    try w.end();
    try w.cursor(null);
    if (options.collation) |collation| try w.document("collation", collation, "the collation");
    if (options.hint) |hint| try w.hint(hint);
    if (options.comment) |value| try w.value("comment", value, "the comment");
    const cursor = try c.db.client.openCursor(io, op, .{ .database = c.db.name, .body = try w.finish() }, .{
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    defer cursor.deinit(io);
    // No document: nothing matched.
    const counted = (try cursor.next(io, op)) orelse return 0;
    return countIn(counted, options.diagnostics, "the result of countDocuments");
}

/// How many documents the collection holds, by its metadata: `count`
/// without a query. Fast, but after an unclean shutdown it may be off
/// until the server counts again; `countDocuments` is exact.
pub fn estimatedDocumentCount(c: Collection, io: Io, op: OperationContext, options: EstimatedDocumentCountOptions) Error!u64 {
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    var w: Writer = .init(scratch.allocator(), options.diagnostics);
    try w.string("count", c.name);
    if (options.comment) |value| try w.value("comment", value, "the comment");
    const reply = try c.db.client.runCommand(io, op, .{ .database = c.db.name, .body = try w.finish() }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    defer reply.deinit();
    return countIn(reply.raw(), options.diagnostics, "the reply of count");
}

/// The values that the field `field`, a name or a dotted path, takes in
/// the documents that `filter` matches, `.{}` in all of them, each once:
/// `distinct`. The result is a BSON array, a document whose keys are "0",
/// "1", …, in `options.allocator`; its `iterator()` gives the values:
///
/// ```zig
/// const cities = try users.distinct(io, op, "address.city", .{ .active = true }, .{ .allocator = arena });
/// var it = cities.raw().iterator();
/// while (try it.next()) |element| try show(element.value);
/// ```
pub fn distinct(c: Collection, io: Io, op: OperationContext, field: []const u8, filter: anytype, options: DistinctOptions) Error!bson.OwnedDocument {
    comptime document.expectDocument("distinct", "filter", @TypeOf(filter));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const query = try argument(a, filter, "the filter", options.diagnostics);
    var w: Writer = .init(a, options.diagnostics);
    try w.string("distinct", c.name);
    try w.string("key", field);
    try w.document("query", query, "the filter");
    if (options.collation) |collation| try w.document("collation", collation, "the collation");
    if (options.comment) |value| try w.value("comment", value, "the comment");
    const reply = try c.db.client.runCommand(io, op, .{ .database = c.db.name, .body = try w.finish() }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    defer reply.deinit();
    const values = (reply.raw().get("values") catch null) orelse return violation(options.diagnostics, "the reply of distinct holds no values");
    if (values != .array) return violation(options.diagnostics, "values in the reply of distinct is not an array");
    return values.array.dupe(options.allocator);
}

/// The `n` of `doc`, a count: a whole number, 0 or more, of any numeric
/// type.
fn countIn(doc: bson.RawDocument, diagnostics: ?*Diagnostics, comptime what: []const u8) Error!u64 {
    const n = (doc.get("n") catch null) orelse return violation(diagnostics, what ++ " holds no n");
    const count = n.asI64() catch return violation(diagnostics, what ++ " holds an n that is not a count: a whole number, 0 or more");
    return std.math.cast(u64, count) orelse violation(diagnostics, what ++ " holds an n that is not a count: a whole number, 0 or more");
}

/// Makes the indexes of `models`, in one `createIndexes`, and returns
/// their names in the order of the models: a model's own name, or the one
/// made of its keys, "email_1_age_-1". An index that exists already with
/// the same keys and options is no error. The names come from
/// `options.allocator`, each and the slice: free them so, or with an
/// arena. No models is `error.InvalidArgument`.
pub fn createIndexes(c: Collection, io: Io, op: OperationContext, models: []const IndexModel, options: CreateIndexesOptions) Error![]const []const u8 {
    try c.begin(options.diagnostics);
    if (models.len == 0) return invalid(options.diagnostics, "createIndexes has no models: it needs at least one", .{});
    const gpa = options.allocator;
    const names = try gpa.alloc([]const u8, models.len);
    var made: usize = 0;
    errdefer {
        for (names[0..made]) |name| gpa.free(name);
        gpa.free(names);
    }
    for (models, names, 0..) |model, *name, i| {
        name.* = if (model.name) |own| try gpa.dupe(u8, own) else try index.defaultName(gpa, model.keys, i, options.diagnostics);
        made += 1;
    }
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var w: Writer = .init(a, options.diagnostics);
    try w.string("createIndexes", c.name);
    try w.beginArray("indexes");
    for (models, names, 0..) |model, name, i| {
        try w.beginDocument("");
        try w.document("key", model.keys, try std.fmt.allocPrint(a, "the keys of index {d}", .{i}));
        try w.string("name", name);
        if (model.unique) try w.boolean("unique", true);
        if (model.sparse) try w.boolean("sparse", true);
        if (model.expire_after_seconds) |seconds| try w.count("expireAfterSeconds", seconds);
        if (model.partial_filter_expression) |filter| try w.document("partialFilterExpression", filter, try std.fmt.allocPrint(a, "the partial filter expression of index {d}", .{i}));
        if (model.collation) |collation| try w.document("collation", collation, try std.fmt.allocPrint(a, "the collation of index {d}", .{i}));
        if (model.hidden) try w.boolean("hidden", true);
        try w.end();
    }
    try w.end();
    if (options.comment) |value| try w.value("comment", value, "the comment");
    const reply = try c.db.client.runCommand(io, op, .{ .database = c.db.name, .body = try w.finish() }, .{
        .allocator = gpa,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    reply.deinit();
    return names;
}

/// The indexes of the collection, each a document with its `name`, `key`
/// and options: `listIndexes`, whose cursor gives them. A collection that
/// is not there has no indexes: the code 26 (NamespaceNotFound) of the
/// server is an empty cursor, as the official drivers make it, and leaves
/// nothing in the diagnostics or in `failure_reply`.
pub fn listIndexes(c: Collection, io: Io, op: OperationContext, options: ListIndexesOptions) Error!Cursor {
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    var w: Writer = .init(scratch.allocator(), options.diagnostics);
    try w.string("listIndexes", c.name);
    try w.cursor(options.batch_size);
    if (options.comment) |value| try w.value("comment", value, "the comment");
    const body = try w.finish();
    // The code of the server's error tells a missing collection, so the
    // call needs diagnostics; the driver keeps them for the getMores of
    // the cursor, so they live with it when the caller passed none.
    const own: ?*cursors.WithDiagnostics = if (options.diagnostics == null) try .create(options.allocator) else null;
    const diagnostics = options.diagnostics orelse &own.?.diagnostics;
    const cursor = c.db.client.openCursor(io, op, .{ .database = c.db.name, .body = body }, .{
        .batch_size = options.batch_size,
        .comment = options.comment,
        .diagnostics = diagnostics,
        .failure_reply = options.failure_reply,
    }) catch |err| {
        const missing = err == error.CommandFailed and diagnostics.server != null and diagnostics.server.?.code == 26;
        if (own) |o| o.destroy();
        if (!missing) return err;
        if (options.diagnostics) |d| d.* = .{};
        if (options.failure_reply) |slot| if (slot.*) |doc| {
            doc.deinit();
            slot.* = null;
        };
        return cursors.empty();
    };
    return if (own) |o| o.wrap(cursor) else cursor;
}

/// Drops the index `name`: `dropIndexes` with its name. `"*"`, which
/// would drop all of them, is `error.InvalidArgument`: that is what
/// `dropIndexes` does.
pub fn dropIndex(c: Collection, io: Io, op: OperationContext, name: []const u8, options: DropIndexOptions) Error!void {
    try c.begin(options.diagnostics);
    if (std.mem.eql(u8, name, "*")) return invalid(options.diagnostics, "dropIndex(\"*\") would drop every index of the collection: dropIndexes does that", .{});
    return c.dropIndexesNamed(io, op, name, options);
}

/// Drops every index of the collection but the one of `_id`: `dropIndexes`
/// with `"*"`.
pub fn dropIndexes(c: Collection, io: Io, op: OperationContext, options: DropIndexOptions) Error!void {
    try c.begin(options.diagnostics);
    return c.dropIndexesNamed(io, op, "*", options);
}

fn dropIndexesNamed(c: Collection, io: Io, op: OperationContext, name: []const u8, options: DropIndexOptions) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    var w: Writer = .init(scratch.allocator(), options.diagnostics);
    try w.string("dropIndexes", c.name);
    try w.string("index", name);
    if (options.comment) |value| try w.value("comment", value, "the comment");
    const reply = try c.db.client.runCommand(io, op, .{ .database = c.db.name, .body = try w.finish() }, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    reply.deinit();
}

/// Drops the collection with its documents and indexes: `drop`. A
/// collection that is not there is no error: the code 26
/// (NamespaceNotFound) of the servers before 7.0 is taken as success, as
/// the official drivers take it, and leaves nothing in the diagnostics or
/// in `failure_reply`.
pub fn drop(c: Collection, io: Io, op: OperationContext, options: DropOptions) Error!void {
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    var w: Writer = .init(scratch.allocator(), options.diagnostics);
    try w.string("drop", c.name);
    if (options.comment) |value| try w.value("comment", value, "the comment");
    // The code of the server's error tells success from failure, so the
    // call has diagnostics of its own, which go to the caller's on an
    // error.
    var own: Diagnostics = .{};
    const reply = c.db.client.runCommand(io, op, .{ .database = c.db.name, .body = try w.finish() }, .{
        .allocator = options.allocator,
        .diagnostics = &own,
        .failure_reply = options.failure_reply,
    }) catch |err| {
        if (err == error.CommandFailed) if (own.server) |server| if (server.code == 26) {
            if (options.failure_reply) |slot| if (slot.*) |doc| {
                doc.deinit();
                slot.* = null;
            };
            return;
        };
        if (options.diagnostics) |d| d.* = own;
        return err;
    };
    reply.deinit();
}

/// Stops the build unless `T` is an update: a document, or a list of the
/// stages of a pipeline.
fn expectUpdate(comptime operation: []const u8, comptime T: type) void {
    if (document.kind(T) == .list) document.expectList(operation, "update", T) else document.expectDocument(operation, "update", T);
}

/// Stops the build unless `T` is a document: a replacement is never a list.
fn expectReplacement(comptime operation: []const u8, comptime T: type) void {
    if (document.kind(T) == .list) {
        @compileError("mongo.Collection." ++ operation ++ ": replacement: a replacement is one document, not a list; a pipeline updates, with updateOne or updateMany");
    }
    document.expectDocument(operation, "replacement", T);
}

/// What the `u` of a statement holds.
const Change = union(enum) {
    /// A document of update operators, or a replacement.
    document: bson.RawDocument,
    /// The stages of a pipeline.
    pipeline: []const bson.RawDocument,
};

/// The update `value`: a pipeline when it is a list, at least one stage
/// long, or else a document whose first key is an update operator.
fn changeOf(a: Allocator, value: anytype, diagnostics: ?*Diagnostics) Error!Change {
    if (comptime document.kind(@TypeOf(value)) == .list) {
        const stages = document.encodeList(a, value) catch |err| return unwritten(err, diagnostics, "the pipeline of the update");
        if (stages.len == 0) return invalid(diagnostics, "the update is an empty pipeline: a pipeline needs at least one stage", .{});
        return .{ .pipeline = stages };
    }
    const doc = try argument(a, value, "the update", diagnostics);
    const first = (doc.first() catch return invalid(diagnostics, "the update " ++ unwritable, .{})) orelse
        return invalid(diagnostics, "the update is empty: it starts with an update operator, such as $set, or it is a pipeline", .{});
    if (first.key.len == 0 or first.key[0] != '$') {
        return invalid(diagnostics, "the update starts with '{s}', not with an update operator such as $set: to replace the whole document, use replaceOne", .{first.key});
    }
    return .{ .document = doc };
}

/// The replacement `value`: a document whose first key is no update
/// operator; `{}` is one.
fn replacementOf(a: Allocator, value: anytype, diagnostics: ?*Diagnostics) Error!bson.RawDocument {
    const doc = try argument(a, value, "the replacement", diagnostics);
    const first = doc.first() catch return invalid(diagnostics, "the replacement " ++ unwritable, .{});
    if (first) |element| if (element.key.len > 0 and element.key[0] == '$') {
        return invalid(diagnostics, "the replacement starts with the update operator '{s}': to change fields of the document, use updateOne", .{element.key});
    };
    return doc;
}

/// A statement of `update`: `{q, u, multi?, upsert?, arrayFilters?, collation?, hint?}`.
const UpdateStatement = struct {
    q: bson.RawDocument,
    u: Change,
    /// What `u` is to the caller, for the diagnostics.
    u_name: []const u8,
    multi: bool = false,
    upsert: bool = false,
    array_filters: ?[]const bson.RawDocument = null,
    collation: ?bson.RawDocument = null,
    hint: ?Hint = null,
};

fn updateStatement(a: Allocator, s: UpdateStatement, diagnostics: ?*Diagnostics) Error!bson.RawDocument {
    var w: Writer = .init(a, diagnostics);
    try w.document("q", s.q, "the filter");
    switch (s.u) {
        .document => |doc| try w.document("u", doc, s.u_name),
        .pipeline => |stages| try w.documents("u", stages, "the pipeline of the update"),
    }
    if (s.multi) try w.boolean("multi", true);
    if (s.upsert) try w.boolean("upsert", true);
    if (s.array_filters) |filters| try w.documents("arrayFilters", filters, "array_filters");
    if (s.collation) |collation| try w.document("collation", collation, "the collation");
    if (s.hint) |hint| try w.hint(hint);
    return w.finish();
}

/// What the body of a write may carry besides its name.
const Body = struct {
    let: ?bson.RawDocument = null,
    bypass_document_validation: bool = false,
    comment: ?bson.Value = null,
};

/// The body of a write without its items: `{<command>: <collection>,
/// let?, bypassDocumentValidation?, comment?}`.
fn writeBody(c: Collection, a: Allocator, command: []const u8, body: Body, diagnostics: ?*Diagnostics) Error!bson.RawDocument {
    var w: Writer = .init(a, diagnostics);
    try w.string(command, c.name);
    if (body.let) |let| try w.document("let", let, "let");
    if (body.bypass_document_validation) try w.boolean("bypassDocumentValidation", true);
    if (body.comment) |value| try w.value("comment", value, "the comment");
    return w.finish();
}

/// Makes the documents of an insert as it sends them, each with its `_id`.
const Inserts = struct {
    io: Io,
    ids: *bson.ObjectId.Generator,
    arena: Allocator,
    diagnostics: ?*Diagnostics,
    /// The document of insertOne, rather than one of a list.
    one: bool,

    fn prepare(self: Inserts, i: usize, value: anytype) Error!bson.RawDocument {
        return id.withId(self.arena, self.io, self.ids, value) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidBson => if (self.one)
                invalid(self.diagnostics, "the document " ++ unwritable, .{})
            else
                invalid(self.diagnostics, "document {d} of the list " ++ unwritable, .{i}),
        };
    }
};

/// What the parts of a write share with the contract's call.
const WriteCommon = struct {
    allocator: Allocator,
    diagnostics: ?*Diagnostics,
    failure_reply: ?*?bson.OwnedDocument,
};

/// A write of an operation, as it goes to the contract.
const Write = struct {
    kind: requests.WriteKind,
    /// The command without its items.
    body: bson.RawDocument,
    items: []const bson.RawDocument,
    ordered: bool = true,
};

/// Sends `write` and makes the operation's result of its merged one with
/// `make(allocator, merged, context)`, which takes it over. A write that
/// ran to its end with writeErrors or a writeConcernError is
/// `error.WriteFailed`, with the first of them in the diagnostics; an
/// error of the contract passes as it is. After either, `partial` gets
/// the result of all that is known: the batches that the server answered,
/// with the indexes of their errors in the whole list.
fn runWrite(c: Collection, io: Io, op: OperationContext, write: Write, common: WriteCommon, comptime R: type, partial: ?*R, context: anytype, comptime make: anytype) Error!R {
    // What the driver knew when the write failed.
    var known: WriteResult = .{};
    var merged = c.db.client.write(io, op, .{
        .database = c.db.name,
        .kind = write.kind,
        .body = write.body,
        .items = write.items,
        .ordered = write.ordered,
    }, .{
        .allocator = common.allocator,
        .diagnostics = common.diagnostics,
        .failure_reply = common.failure_reply,
        .partial = if (partial != null) &known else null,
    }) catch |err| {
        if (partial) |slot| slot.* = try make(common.allocator, &known, context);
        return err;
    };
    if (merged.write_errors.len == 0 and merged.write_concern_errors.len == 0) return make(common.allocator, &merged, context);
    if (common.diagnostics) |d| refused(d, &merged);
    if (partial) |slot| {
        slot.* = try make(common.allocator, &merged, context);
    } else merged.deinit(common.allocator);
    return error.WriteFailed;
}

/// The diagnostics of `error.WriteFailed`: the first item that the server
/// refused, or else the first write concern that failed, with the
/// server's errmsg as the message.
fn refused(d: *Diagnostics, merged: *const WriteResult) void {
    if (merged.write_errors.len > 0) {
        const first = merged.write_errors[0];
        if (first.message.len > 0) {
            d.set(.receive, null, "{s}", .{first.message});
        } else d.set(.receive, null, "the server refused item {d} of the write with code {d}", .{ first.index, first.code });
        d.server = .{ .code = first.code };
    } else {
        const first = merged.write_concern_errors[0];
        if (first.message.len > 0) {
            d.set(.receive, null, "{s}", .{first.message});
        } else d.set(.receive, null, "the write concern failed with code {d}", .{first.code});
        d.server = .{ .code = first.code };
    }
}

/// Starts an operation: the caller's diagnostics afresh, and the name.
fn begin(c: Collection, diagnostics: ?*Diagnostics) Error!void {
    if (diagnostics) |d| d.* = .{};
    try c.checkName(diagnostics);
}

/// The name of the collection: not empty, without `$` and NUL. Breaking it
/// is `error.InvalidArgument`, and nothing is sent.
fn checkName(c: Collection, diagnostics: ?*Diagnostics) Error!void {
    if (c.name.len == 0) return invalid(diagnostics, "the collection name is empty", .{});
    if (std.mem.findAny(u8, c.name, "\x00$")) |at| {
        const what = if (c.name[at] == 0) "a NUL" else "a '$'";
        return invalid(diagnostics, "a collection name holds no '$' and no NUL; this one holds {s} at byte {d}", .{ what, at });
    }
}

test "a collection name is not empty and holds no $ and no NUL" {
    const testing = std.testing;
    const db: Database = .init(undefined, "app", undefined);
    var d: Diagnostics = .{};
    try db.collection("users").checkName(&d);
    try db.collection("fs.chunks").checkName(&d);
    try testing.expectError(error.InvalidArgument, db.collection("").checkName(&d));
    try testing.expectEqualStrings("the collection name is empty", d.message());
    try testing.expectError(error.InvalidArgument, db.collection("a$b").checkName(&d));
    try testing.expectEqualStrings("a collection name holds no '$' and no NUL; this one holds a '$' at byte 1", d.message());
    try testing.expectError(error.InvalidArgument, db.collection("ab\x00").checkName(&d));
    try testing.expectEqualStrings("a collection name holds no '$' and no NUL; this one holds a NUL at byte 2", d.message());
}
