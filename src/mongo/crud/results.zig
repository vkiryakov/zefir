//! The results of the collection API's writes, which `Collection` names:
//! `mongo.Collection.InsertManyResult`. Each comes from the allocator of
//! the call's options, every slice and value an allocation of its own:
//! free it with `deinit` and that allocator, or with an arena at once.
//!
//! `write_errors` and `write_concern_errors` are empty in a result that
//! an operation returns: a write whose items the server refused is
//! `error.WriteFailed`, and the result with them goes to the `partial` of
//! the options. Their indexes count in the whole list of the operation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const client_results = @import("../results.zig");
const id = @import("id.zig");
const WriteResult = client_results.WriteResult;
const WriteError = client_results.WriteError;
const WriteConcernError = client_results.WriteConcernError;

pub const InsertOneResult = struct {
    /// The `_id` of the document: its own, or the one the insert made.
    inserted_id: bson.Value = .null,
    write_errors: []const WriteError = &.{},
    write_concern_errors: []const WriteConcernError = &.{},

    pub fn deinit(r: *InsertOneResult, allocator: Allocator) void {
        client_results.freeValue(allocator, r.inserted_id);
        freeErrors(allocator, r.write_errors, r.write_concern_errors);
        r.* = .{};
    }
};

pub const InsertManyResult = struct {
    /// The `_id` of each document, by its index in the list: its own, or
    /// the one the insert made.
    inserted_ids: []const bson.Value = &.{},
    /// How many documents the server inserted.
    inserted: u64 = 0,
    /// How many documents went out in batches that the server answered.
    answered: usize = 0,
    /// The documents the server refused, by their index in the list.
    write_errors: []const WriteError = &.{},
    /// One per batch whose write concern failed.
    write_concern_errors: []const WriteConcernError = &.{},

    pub fn deinit(r: *InsertManyResult, allocator: Allocator) void {
        for (r.inserted_ids) |value| client_results.freeValue(allocator, value);
        allocator.free(r.inserted_ids);
        freeErrors(allocator, r.write_errors, r.write_concern_errors);
        r.* = .{};
    }
};

pub const UpdateResult = struct {
    /// How many documents matched the filter: the server's `n` less the
    /// upserts.
    matched: u64 = 0,
    /// How many of them the write changed: `nModified`.
    modified: u64 = 0,
    /// The `_id` of the document that an upsert inserted, which the
    /// server made unless the document had one.
    upserted_id: ?bson.Value = null,
    write_errors: []const WriteError = &.{},
    write_concern_errors: []const WriteConcernError = &.{},

    pub fn deinit(r: *UpdateResult, allocator: Allocator) void {
        if (r.upserted_id) |value| client_results.freeValue(allocator, value);
        freeErrors(allocator, r.write_errors, r.write_concern_errors);
        r.* = .{};
    }
};

pub const DeleteResult = struct {
    /// How many documents the server deleted.
    deleted: u64 = 0,
    write_errors: []const WriteError = &.{},
    write_concern_errors: []const WriteConcernError = &.{},

    pub fn deinit(r: *DeleteResult, allocator: Allocator) void {
        freeErrors(allocator, r.write_errors, r.write_concern_errors);
        r.* = .{};
    }
};

/// The result of insertOne of `doc`, as it went out, from the merged result
/// of its write, which it takes over: `merged` is empty after it, and on
/// an error too.
pub fn ofInsertOne(allocator: Allocator, merged: *WriteResult, doc: bson.RawDocument) Allocator.Error!InsertOneResult {
    errdefer merged.deinit(allocator);
    const inserted_id = try id.idOf(allocator, doc);
    const lists = take(allocator, merged);
    if (lists.upserted_id) |value| client_results.freeValue(allocator, value);
    return .{ .inserted_id = inserted_id, .write_errors = lists.write_errors, .write_concern_errors = lists.write_concern_errors };
}

/// The result of insertMany of `docs`, as they went out, as `ofInsertOne`
/// makes it.
pub fn ofInsertMany(allocator: Allocator, merged: *WriteResult, docs: []const bson.RawDocument) Allocator.Error!InsertManyResult {
    errdefer merged.deinit(allocator);
    const ids = try allocator.alloc(bson.Value, docs.len);
    var made: usize = 0;
    errdefer {
        for (ids[0..made]) |value| client_results.freeValue(allocator, value);
        allocator.free(ids);
    }
    for (docs, ids) |doc, *slot| {
        slot.* = try id.idOf(allocator, doc);
        made += 1;
    }
    const n = merged.n;
    const answered = merged.answered;
    const lists = take(allocator, merged);
    if (lists.upserted_id) |value| client_results.freeValue(allocator, value);
    return .{
        .inserted_ids = ids,
        .inserted = n,
        .answered = answered,
        .write_errors = lists.write_errors,
        .write_concern_errors = lists.write_concern_errors,
    };
}

/// The result of updateOne, updateMany or replaceOne, of their one
/// statement, from the merged result of its write, which it takes over:
/// `merged` is empty after it.
pub fn ofUpdate(allocator: Allocator, merged: *WriteResult, _: void) Allocator.Error!UpdateResult {
    const n = merged.n;
    const modified = merged.modified;
    const upserts = merged.upserted.len;
    const lists = take(allocator, merged);
    return .{
        .matched = n -| upserts,
        .modified = modified,
        .upserted_id = lists.upserted_id,
        .write_errors = lists.write_errors,
        .write_concern_errors = lists.write_concern_errors,
    };
}

/// The result of deleteOne or deleteMany, as `ofUpdate` makes it.
pub fn ofDelete(allocator: Allocator, merged: *WriteResult, _: void) Allocator.Error!DeleteResult {
    const n = merged.n;
    const lists = take(allocator, merged);
    if (lists.upserted_id) |value| client_results.freeValue(allocator, value);
    return .{ .deleted = n, .write_errors = lists.write_errors, .write_concern_errors = lists.write_concern_errors };
}

const Lists = struct {
    /// The `_id` of the first upsert: a write of one statement has at most
    /// one.
    upserted_id: ?bson.Value,
    write_errors: []const WriteError,
    write_concern_errors: []const WriteConcernError,
};

/// The lists of errors of `merged` and the `_id` of its first upsert,
/// which it hands over; what else it holds is freed, and it is empty
/// after it.
fn take(allocator: Allocator, merged: *WriteResult) Lists {
    var lists: Lists = .{ .upserted_id = null, .write_errors = merged.write_errors, .write_concern_errors = merged.write_concern_errors };
    for (merged.upserted, 0..) |upserted, i| {
        if (i == 0) lists.upserted_id = upserted.id else client_results.freeValue(allocator, upserted.id);
    }
    allocator.free(merged.upserted);
    merged.* = .{};
    return lists;
}

fn freeErrors(allocator: Allocator, write_errors: []const WriteError, write_concern_errors: []const WriteConcernError) void {
    var lists: WriteResult = .{ .write_errors = write_errors, .write_concern_errors = write_concern_errors };
    lists.deinit(allocator);
}
