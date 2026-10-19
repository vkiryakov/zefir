//! The options of the collection API's operations, which `Collection`
//! names: `mongo.Collection.InsertManyOptions`. Each one has the fields of
//! all: `allocator`, `comment`, `diagnostics` and `failure_reply`. An
//! option at its default is not sent. A `failure_reply` slot must hold
//! null: a call fills it on an error of the server only, and never frees
//! what is there.
//!
//! There is no `maxTimeMS`: the deadline comes from the context only, and
//! the client writes it. There is no `writeConcern` or `readConcern`
//! either: a standalone server writes with `w: 1`; who needs them puts
//! them in the body of `mongo.Client.write` or `runCommand`.

const std = @import("std");
const bson = @import("../bson.zig");
const errors = @import("../errors.zig");
const results = @import("results.zig");
const Diagnostics = errors.Diagnostics;

pub const InsertOneOptions = struct {
    /// The memory of the result, and of the call's scratch, which is
    /// freed before the call returns.
    allocator: std.mem.Allocator,
    /// Let the document past the collection's validator.
    bypass_document_validation: bool = false,
    /// Sent with the command, for the server's logs and profiler.
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
    /// After `error.WriteFailed`, or an error of `mongo.Client.write`, all
    /// that is known of the write, from `allocator`: free it with `deinit`.
    /// After `WriteFailed`, the whole result with its errors.
    partial: ?*results.InsertOneResult = null,
};

pub const InsertManyOptions = struct {
    /// The memory of the result, and of the call's scratch, which is
    /// freed before the call returns.
    allocator: std.mem.Allocator,
    /// Whether the server stops at the first document it refuses, and no
    /// batch follows; false inserts all it can.
    ordered: bool = true,
    /// Let the documents past the collection's validator.
    bypass_document_validation: bool = false,
    /// Sent with each batch, for the server's logs and profiler.
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
    /// After `error.WriteFailed`, or an error of `mongo.Client.write`, all
    /// that is known of the write, from `allocator`: free it with `deinit`.
    /// It holds the `_id`s of all the documents, made before the first
    /// batch, the documents inserted, how many went out in batches that the
    /// server answered, and the refused ones by their index in the list.
    /// After `IncompleteWrite`, `answered` says how far the write is known
    /// to have come; the documents after it may be checked by their `_id`.
    partial: ?*results.InsertManyResult = null,
};

/// Which index the server uses for the filter, by name or by keys.
pub const Hint = union(enum) {
    /// The name of the index, such as "email_1".
    name: []const u8,
    /// The keys of the index as it was made: `bson.literal(.{ .email = 1 })`.
    keys: bson.RawDocument,
};

pub const UpdateOptions = struct {
    /// The memory of the result, and of the call's scratch, which is
    /// freed before the call returns.
    allocator: std.mem.Allocator,
    /// Insert a document when none matches the filter; the server makes
    /// its `_id`, and the result reports it.
    upsert: bool = false,
    /// `arrayFilters`: the items of arrays that an update operator with
    /// `$[<name>]` changes, such as `bson.literal(.{ .high = .{ .@"$gte" = 100 } })`.
    array_filters: ?[]const bson.RawDocument = null,
    /// How strings compare in the filter: `bson.literal(.{ .locale = "fr" })`.
    collation: ?bson.RawDocument = null,
    hint: ?Hint = null,
    /// Variables that the filter and the update read as `$$name`.
    let: ?bson.RawDocument = null,
    /// Let the changed documents past the collection's validator.
    bypass_document_validation: bool = false,
    /// Sent with the command, for the server's logs and profiler.
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
    /// After `error.WriteFailed`, or an error of `mongo.Client.write`, all
    /// that is known of the write, from `allocator`: free it with `deinit`.
    /// After `WriteFailed`, the whole result with its errors.
    partial: ?*results.UpdateResult = null,
};

/// The options of `replaceOne`: those of an update, without
/// `array_filters`.
pub const ReplaceOptions = struct {
    /// The memory of the result, and of the call's scratch, which is
    /// freed before the call returns.
    allocator: std.mem.Allocator,
    /// Insert the replacement when no document matches the filter; the
    /// server makes its `_id`, unless it has one, and the result reports
    /// it.
    upsert: bool = false,
    collation: ?bson.RawDocument = null,
    hint: ?Hint = null,
    /// Variables that the filter reads as `$$name`.
    let: ?bson.RawDocument = null,
    /// Let the replacement past the collection's validator.
    bypass_document_validation: bool = false,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
    /// After `error.WriteFailed`, or an error of `mongo.Client.write`, all
    /// that is known of the write, from `allocator`: free it with `deinit`.
    /// After `WriteFailed`, the whole result with its errors.
    partial: ?*results.UpdateResult = null,
};

pub const DeleteOptions = struct {
    /// The memory of the result, and of the call's scratch, which is
    /// freed before the call returns.
    allocator: std.mem.Allocator,
    collation: ?bson.RawDocument = null,
    hint: ?Hint = null,
    /// Variables that the filter reads as `$$name`.
    let: ?bson.RawDocument = null,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
    /// After `error.WriteFailed`, or an error of `mongo.Client.write`, all
    /// that is known of the write, from `allocator`: free it with `deinit`.
    /// After `WriteFailed`, the whole result with its errors.
    partial: ?*results.DeleteResult = null,
};

/// Which version of the document a `findOneAnd*` returns.
pub const ReturnDocument = enum {
    /// As it was before the write; null when the write inserted it.
    before,
    /// As the write left it: `new: true`.
    after,
};

pub const FindOneAndUpdateOptions = struct {
    /// The memory of the document returned, and of the call's scratch,
    /// which is freed before the call returns.
    allocator: std.mem.Allocator,
    /// The order in which the first document is chosen when the filter
    /// matches several: `bson.literal(.{ .age = -1 })`.
    sort: ?bson.RawDocument = null,
    /// The fields of the document returned: `bson.literal(.{ .name = 1 })`.
    projection: ?bson.RawDocument = null,
    /// Insert a document when none matches the filter.
    upsert: bool = false,
    return_document: ReturnDocument = .before,
    array_filters: ?[]const bson.RawDocument = null,
    collation: ?bson.RawDocument = null,
    hint: ?Hint = null,
    let: ?bson.RawDocument = null,
    bypass_document_validation: bool = false,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, `Timeout` by code 50 or `WriteFailed`, the
    /// whole reply of the server, from `allocator`: free it with `deinit`.
    /// The slot must hold null: the call fills it on such an error only,
    /// and never frees what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

/// The options of `findOneAndReplace`: those of `findOneAndUpdate`,
/// without `array_filters`.
pub const FindOneAndReplaceOptions = struct {
    /// The memory of the document returned, and of the call's scratch,
    /// which is freed before the call returns.
    allocator: std.mem.Allocator,
    sort: ?bson.RawDocument = null,
    projection: ?bson.RawDocument = null,
    upsert: bool = false,
    return_document: ReturnDocument = .before,
    collation: ?bson.RawDocument = null,
    hint: ?Hint = null,
    let: ?bson.RawDocument = null,
    bypass_document_validation: bool = false,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, `Timeout` by code 50 or `WriteFailed`, the
    /// whole reply of the server, from `allocator`: free it with `deinit`.
    /// The slot must hold null: the call fills it on such an error only,
    /// and never frees what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const FindOneAndDeleteOptions = struct {
    /// The memory of the document returned, and of the call's scratch,
    /// which is freed before the call returns.
    allocator: std.mem.Allocator,
    /// The order in which the first document is chosen when the filter
    /// matches several.
    sort: ?bson.RawDocument = null,
    /// The fields of the document returned.
    projection: ?bson.RawDocument = null,
    collation: ?bson.RawDocument = null,
    hint: ?Hint = null,
    let: ?bson.RawDocument = null,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, `Timeout` by code 50 or `WriteFailed`, the
    /// whole reply of the server, from `allocator`: free it with `deinit`.
    /// The slot must hold null: the call fills it on such an error only,
    /// and never frees what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const FindOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns; the cursor holds its batches in the memory of the client.
    allocator: std.mem.Allocator,
    /// The order of the documents: `bson.literal(.{ .age = -1 })`.
    sort: ?bson.RawDocument = null,
    /// The fields of each document: `bson.literal(.{ .name = 1 })`.
    projection: ?bson.RawDocument = null,
    /// How many of the matching documents to pass over first.
    skip: u32 = 0,
    /// How many documents to give at most; 0 gives all.
    limit: u32 = 0,
    /// How many documents each batch holds, the first and those of every
    /// `getMore`; null leaves it to the server.
    batch_size: ?u32 = null,
    hint: ?Hint = null,
    collation: ?bson.RawDocument = null,
    /// Variables that the filter reads as `$$name`.
    let: ?bson.RawDocument = null,
    /// Whether a sort too large for memory may use the disk; null leaves
    /// it to the server.
    allow_disk_use: ?bool = null,
    /// Sent with the command and with each `getMore`, for the server's
    /// logs and profiler.
    comment: ?bson.Value = null,
    /// The details of an error of the call. The cursor keeps those of its
    /// `getMore`s: `cursor.diagnostics()`.
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, of the command, the
    /// whole reply of the server, from the client's allocator: free it with
    /// `deinit`. The slot must hold null: the call fills it on such an
    /// error only, and never frees what is there. The cursor keeps the reply
    /// of a refused `getMore`: `cursor.failureReply()`.
    failure_reply: ?*?bson.OwnedDocument = null,
};

/// The options of `findOne`: those of `find` that choose the document.
pub const FindOneOptions = struct {
    /// The memory of the document returned, and of the call's scratch,
    /// which is freed before the call returns.
    allocator: std.mem.Allocator,
    /// Which document comes first when the filter matches several.
    sort: ?bson.RawDocument = null,
    projection: ?bson.RawDocument = null,
    skip: u32 = 0,
    hint: ?Hint = null,
    collation: ?bson.RawDocument = null,
    let: ?bson.RawDocument = null,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, of the command or of
    /// a `getMore`, the whole reply of the server, from `allocator`: free it
    /// with `deinit`. The slot must hold null: the call fills it on such an
    /// error only, and never frees what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const AggregateOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns; the cursor holds its batches in the memory of the client.
    allocator: std.mem.Allocator,
    /// How many documents each batch holds, the first and those of every
    /// `getMore`; null leaves it to the server. A pipeline that ends in
    /// `$out` or `$merge` runs with the server's batch size: one of 0
    /// would keep it from running.
    batch_size: ?u32 = null,
    /// Whether stages too large for memory may use the disk; null leaves
    /// it to the server.
    allow_disk_use: ?bool = null,
    hint: ?Hint = null,
    collation: ?bson.RawDocument = null,
    /// Variables that the stages read as `$$name`.
    let: ?bson.RawDocument = null,
    /// Let the documents that `$out` or `$merge` writes past the
    /// collection's validator.
    bypass_document_validation: bool = false,
    /// Sent with the command and with each `getMore`, for the server's
    /// logs and profiler.
    comment: ?bson.Value = null,
    /// The details of an error of the call. The cursor keeps those of its
    /// `getMore`s: `cursor.diagnostics()`.
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, of the command, the
    /// whole reply of the server, from the client's allocator: free it with
    /// `deinit`. The slot must hold null: the call fills it on such an
    /// error only, and never frees what is there. The cursor keeps the reply
    /// of a refused `getMore`: `cursor.failureReply()`.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const CountDocumentsOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns.
    allocator: std.mem.Allocator,
    /// How many of the matching documents to pass over before counting.
    skip: u32 = 0,
    /// How many documents to count at most; 0 counts all.
    limit: u32 = 0,
    hint: ?Hint = null,
    collation: ?bson.RawDocument = null,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, of the command or of
    /// a `getMore`, the whole reply of the server, from `allocator`: free it
    /// with `deinit`. The slot must hold null: the call fills it on such an
    /// error only, and never frees what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const EstimatedDocumentCountOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns.
    allocator: std.mem.Allocator,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const DistinctOptions = struct {
    /// The memory of the values returned, and of the call's scratch,
    /// which is freed before the call returns.
    allocator: std.mem.Allocator,
    /// How strings compare, in the filter and among the values:
    /// `bson.literal(.{ .locale = "en", .strength = 1 })`.
    collation: ?bson.RawDocument = null,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const CreateIndexesOptions = struct {
    /// The memory of the names returned, and of the call's scratch, which
    /// is freed before the call returns.
    allocator: std.mem.Allocator,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const ListIndexesOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns; the cursor holds its batches in the memory of the client.
    allocator: std.mem.Allocator,
    /// How many indexes each batch holds; null leaves it to the server.
    batch_size: ?u32 = null,
    /// Sent with the command and with each `getMore`.
    comment: ?bson.Value = null,
    /// The details of an error of the call. The cursor keeps those of its
    /// `getMore`s: `cursor.diagnostics()`.
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, of the command, the
    /// whole reply of the server, from the client's allocator: free it with
    /// `deinit`. The slot must hold null: the call fills it on such an
    /// error only, and never frees what is there. The cursor keeps the reply
    /// of a refused `getMore`: `cursor.failureReply()`.
    failure_reply: ?*?bson.OwnedDocument = null,
};

/// The options of `dropIndex` and `dropIndexes`.
pub const DropIndexOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns.
    allocator: std.mem.Allocator,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

/// The options of `Collection.drop` and `Database.drop`.
pub const DropOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns.
    allocator: std.mem.Allocator,
    comment: ?bson.Value = null,
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, the whole reply of
    /// the server, from `allocator`: free it with `deinit`. The slot must
    /// hold null: the call fills it on such an error only, and never frees
    /// what is there.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const ListCollectionsOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns; the cursor holds its batches in the memory of the client.
    allocator: std.mem.Allocator,
    /// Only the collections whose documents of `listCollections` match it:
    /// `bson.literal(.{ .name = "users" })`.
    filter: ?bson.RawDocument = null,
    /// Only the name and the type of each collection, without its options
    /// and info, and without the locks that reading them takes.
    name_only: bool = false,
    /// Only the collections the user may act on, for a user without the
    /// right to list all.
    authorized_collections: bool = false,
    /// How many collections each batch holds; null leaves it to the
    /// server.
    batch_size: ?u32 = null,
    /// Sent with the command only, never with a `getMore`, as the
    /// enumerate collections spec says.
    comment: ?bson.Value = null,
    /// The details of an error of the call. The cursor keeps those of its
    /// `getMore`s: `cursor.diagnostics()`.
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, of the command, the
    /// whole reply of the server, from the client's allocator: free it with
    /// `deinit`. The slot must hold null: the call fills it on such an
    /// error only, and never frees what is there. The cursor keeps the reply
    /// of a refused `getMore`: `cursor.failureReply()`.
    failure_reply: ?*?bson.OwnedDocument = null,
};

pub const RunCursorCommandOptions = struct {
    /// The memory of the call's scratch, which is freed before the call
    /// returns; the cursor holds its batches in the memory of the client.
    allocator: std.mem.Allocator,
    /// The `batchSize` of each `getMore`; null leaves it to the server.
    /// The first batch is the command's, such as its `cursor.batchSize`.
    batch_size: ?u32 = null,
    /// The details of an error of the call. The cursor keeps those of its
    /// `getMore`s: `cursor.diagnostics()`.
    diagnostics: ?*Diagnostics = null,
    /// After `CommandFailed`, or `Timeout` by code 50, of the command, the
    /// whole reply of the server, from the client's allocator: free it with
    /// `deinit`. The slot must hold null: the call fills it on such an
    /// error only, and never frees what is there. The cursor keeps the reply
    /// of a refused `getMore`: `cursor.failureReply()`.
    failure_reply: ?*?bson.OwnedDocument = null,
};
