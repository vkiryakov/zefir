//! The results of the collection API's writes, which `Collection` names:
//! `mongo.Collection.InsertManyResult`. Each comes from the allocator of
//! the call's options, every slice and value an allocation of its own:
//! free it with `deinit` and that allocator, or with an arena at once.
//!
//! `write_errors` and `write_concern_errors` are empty in a result that
//! an operation returns: a write whose items the server refused is
//! `error.WriteFailed`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const contract = @import("../contract/results.zig");
const id = @import("id.zig");
const WriteResult = contract.WriteResult;
const WriteError = contract.WriteError;
const WriteConcernError = contract.WriteConcernError;

pub const InsertOneResult = struct {
    /// The `_id` of the document: its own, or the one the insert made.
    inserted_id: bson.Value = .null,
    write_errors: []const WriteError = &.{},
    write_concern_errors: []const WriteConcernError = &.{},

    pub fn deinit(r: *InsertOneResult, allocator: Allocator) void {
        contract.freeValue(allocator, r.inserted_id);
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
        for (r.inserted_ids) |value| contract.freeValue(allocator, value);
        allocator.free(r.inserted_ids);
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
    return .{ .inserted_id = inserted_id, .write_errors = lists.write_errors, .write_concern_errors = lists.write_concern_errors };
}

/// The result of insertMany of `docs`, as they went out, as `ofInsertOne`
/// makes it.
pub fn ofInsertMany(allocator: Allocator, merged: *WriteResult, docs: []const bson.RawDocument) Allocator.Error!InsertManyResult {
    errdefer merged.deinit(allocator);
    const ids = try allocator.alloc(bson.Value, docs.len);
    var made: usize = 0;
    errdefer {
        for (ids[0..made]) |value| contract.freeValue(allocator, value);
        allocator.free(ids);
    }
    for (docs, ids) |doc, *slot| {
        slot.* = try id.idOf(allocator, doc);
        made += 1;
    }
    const n = merged.n;
    const answered = merged.answered;
    const lists = take(allocator, merged);
    return .{
        .inserted_ids = ids,
        .inserted = n,
        .answered = answered,
        .write_errors = lists.write_errors,
        .write_concern_errors = lists.write_concern_errors,
    };
}

const Lists = struct {
    write_errors: []const WriteError,
    write_concern_errors: []const WriteConcernError,
};

/// The lists of errors of `merged`, which it hands over; what else it
/// holds is freed, and it is empty after it.
fn take(allocator: Allocator, merged: *WriteResult) Lists {
    const lists: Lists = .{ .write_errors = merged.write_errors, .write_concern_errors = merged.write_concern_errors };
    merged.write_errors = &.{};
    merged.write_concern_errors = &.{};
    merged.deinit(allocator);
    return lists;
}

fn freeErrors(allocator: Allocator, write_errors: []const WriteError, write_concern_errors: []const WriteConcernError) void {
    var lists: WriteResult = .{ .write_errors = write_errors, .write_concern_errors = write_concern_errors };
    lists.deinit(allocator);
}
