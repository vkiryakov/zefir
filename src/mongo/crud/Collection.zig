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
//! `insertMany` — is a slice, an array or a tuple of them; `.{}` is the
//! empty document, and the empty list where a list goes. A type that fits
//! none of the forms stops the build with the name of the operation and
//! the path of the field. Documents inside options, such as a collation,
//! are `bson.RawDocument`s; `bson.literal` writes constant ones.
//!
//! An insert gives a document without `_id` an ObjectId of the database's
//! generator as its first field, and reports the `_id` of every document,
//! its own or made.
//!
//! Results come from `options.allocator`; free them with `deinit`. The
//! scratch memory of a call, such as the documents a struct is written
//! to, comes from it too and is freed before the call returns.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const errors = @import("../contract/errors.zig");
const requests = @import("../contract/requests.zig");
const contract_results = @import("../contract/results.zig");
const Database = @import("Database.zig");
const document = @import("document.zig");
const id = @import("id.zig");
const options_ = @import("options.zig");
const results = @import("results.zig");
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
pub const InsertOneResult = results.InsertOneResult;
pub const InsertManyResult = results.InsertManyResult;

/// Inserts `doc`: `insert` with the document in a section of kind 1. A
/// document without `_id` gets an ObjectId first; the result reports the
/// `_id`.
pub fn insertOne(c: Collection, io: Io, op: OperationContext, doc: anytype, options: InsertOneOptions) Error!InsertOneResult {
    comptime document.expectDocument("insertOne", "document", @TypeOf(doc));
    try c.begin(options.diagnostics);
    var scratch: std.heap.ArenaAllocator = .init(options.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const body = try c.insertBody(a, options.bypass_document_validation, options.comment, options.diagnostics);
    const inserts: Inserts = .{ .io = io, .ids = c.db.ids, .arena = a, .diagnostics = options.diagnostics, .one = true };
    const items = [_]bson.RawDocument{try inserts.prepare(0, doc)};
    var merged = try c.runWrite(io, op, .insert, body, &items, true, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    return results.ofInsertOne(options.allocator, &merged, items[0]);
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
    const body = try c.insertBody(a, options.bypass_document_validation, options.comment, options.diagnostics);
    const inserts: Inserts = .{ .io = io, .ids = c.db.ids, .arena = a, .diagnostics = options.diagnostics, .one = false };
    const items = try document.mapItems(a, docs, inserts, Inserts.prepare);
    if (items.len == 0) return invalid(options.diagnostics, "insertMany has no documents: it needs at least one", .{});
    var merged = try c.runWrite(io, op, .insert, body, items, options.ordered, .{
        .allocator = options.allocator,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    });
    return results.ofInsertMany(options.allocator, &merged, items);
}

/// The body of an insert, without its documents.
fn insertBody(c: Collection, a: Allocator, bypass: bool, comment: ?bson.Value, diagnostics: ?*Diagnostics) Error!bson.RawDocument {
    var w: Writer = .init(a, diagnostics);
    try w.string("insert", c.name);
    if (bypass) try w.boolean("bypassDocumentValidation", true);
    if (comment) |value| try w.value("comment", value, "the comment");
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

/// Sends the write and returns its merged result, from `common.allocator`.
/// A write that ran to its end with writeErrors or a writeConcernError is
/// `error.WriteFailed`. An error of the contract passes as it is.
fn runWrite(c: Collection, io: Io, op: OperationContext, kind: requests.WriteKind, body: bson.RawDocument, items: []const bson.RawDocument, ordered: bool, common: WriteCommon) Error!WriteResult {
    var merged = try c.db.client.write(io, op, .{
        .database = c.db.name,
        .kind = kind,
        .body = body,
        .items = items,
        .ordered = ordered,
    }, .{
        .allocator = common.allocator,
        .diagnostics = common.diagnostics,
        .failure_reply = common.failure_reply,
    });
    if (merged.write_errors.len > 0 or merged.write_concern_errors.len > 0) {
        merged.deinit(common.allocator);
        return error.WriteFailed;
    }
    return merged;
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

const unwritable = "cannot be written as BSON: it holds a string that is not UTF-8, a broken document, a value of a deprecated type, or more than 100 levels";

fn invalid(diagnostics: ?*Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    if (diagnostics) |d| d.set(null, null, fmt, args);
    return error.InvalidArgument;
}

/// A `bson.Builder` for the commands of operations, in their scratch
/// memory, whose errors are the contract's: a part that cannot be written
/// is `error.InvalidArgument`, and the diagnostics name it.
const Writer = struct {
    b: bson.Builder,
    diagnostics: ?*Diagnostics,

    fn init(arena: Allocator, diagnostics: ?*Diagnostics) Writer {
        return .{ .b = .init(arena), .diagnostics = diagnostics };
    }

    fn string(w: *Writer, key: []const u8, text: []const u8) Error!void {
        w.b.putString(key, text) catch |err| return w.fail(err, key);
    }

    fn boolean(w: *Writer, key: []const u8, value_: bool) Error!void {
        w.b.putBoolean(key, value_) catch |err| return w.fail(err, key);
    }

    /// A value of any BSON type but the deprecated ones; a string must be
    /// UTF-8.
    fn value(w: *Writer, key: []const u8, value_: bson.Value, what: []const u8) Error!void {
        w.b.put(key, value_) catch |err| return w.fail(err, what);
    }

    fn finish(w: *Writer) Error!bson.RawDocument {
        const doc = w.b.finish() catch |err| return w.fail(err, "the command");
        return doc.raw();
    }

    fn fail(w: *Writer, err: bson.Builder.Error, what: []const u8) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidBson => invalid(w.diagnostics, "{s} " ++ unwritable, .{what}),
        };
    }
};

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
