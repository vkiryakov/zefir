//! `wire.batch`: the items of a write in batches that fit the limits of
//! the connection they go through, and the replies of the batches merged
//! into one `mongo.WriteResult`, as the Bulk API spec splits and merges
//! them.
//!
//! ```zig
//! var request: opmsg.Request = .{ .request_id = 0, .body = body, .database = "app", .ordered = true, .max_time_ms = budget, .sequence = .{ .identifier = "documents", .documents = items } };
//! var batches = try batch.Batches.init(request, .of(hello), &diagnostics);
//! var merge: batch.Merge = .{};
//! defer merge.deinit(options.allocator);
//! while (batches.next()) |b| {
//!     request.sequence.?.documents = b.items;
//!     // Send request and read the reply, then check its ok with
//!     // wire.checkReply; an error on the way is merge.fail(…, err, b, options).
//!     switch (try merge.add(options.allocator, b, reply.raw(), request.ordered.?, options.diagnostics)) {
//!         .more => {},
//!         .done => break,
//!         .timeout => return merge.fail(options.allocator, error.Timeout, b, options),
//!     }
//! }
//! return merge.result(options.allocator);
//! ```

const std = @import("std");
const bson = @import("../bson.zig");
const opmsg = @import("opmsg.zig");
const Hello = @import("Hello.zig");
const errors = @import("../contract/errors.zig");
const requests = @import("../contract/requests.zig");
const results = @import("../contract/results.zig");
const Allocator = std.mem.Allocator;
const Diagnostics = errors.Diagnostics;

/// What a batch must fit in.
pub const Limits = struct {
    /// The most items in one batch.
    max_write_batch_size: u32 = 100_000,
    /// The longest message of one batch, the command with its items.
    max_message_size_bytes: u32 = 48_000_000,

    /// The limits of a connection, from its hello. `maxBsonObjectSize`
    /// plays no part: an item larger than it, within a message, goes out,
    /// and the server refuses that item alone (error 10334).
    pub fn of(hello: Hello) Limits {
        return .{ .max_write_batch_size = hello.max_write_batch_size, .max_message_size_bytes = hello.max_message_size_bytes };
    }
};

pub const Batch = struct {
    /// The index of its first item in the whole request: indexes in the
    /// reply of the batch count from it.
    offset: usize,
    items: []const bson.RawDocument,
};

/// The items of a request in batches of at most `max_write_batch_size`
/// items, each in a message of at most `max_message_size_bytes`. A batch
/// takes items while both hold, and at least one.
pub const Batches = struct {
    items: []const bson.RawDocument,
    /// The bytes of a message of this write without its items.
    overhead: usize,
    limits: Limits,
    /// Where the next batch starts.
    offset: usize = 0,

    /// The batches of the items of `request.sequence`. The request holds
    /// every field its messages will carry, `max_time_ms` among them when
    /// they carry one, since each takes room. An item that does not fit a
    /// message even alone is `error.InvalidArgument`, before any batch.
    pub fn init(request: opmsg.Request, limits: Limits, diagnostics: ?*errors.Diagnostics) error{InvalidArgument}!Batches {
        const sequence = request.sequence orelse return .{ .items = &.{}, .overhead = 0, .limits = limits };
        var empty = request;
        empty.sequence = .{ .identifier = sequence.identifier, .documents = &.{} };
        const overhead = empty.length();
        for (sequence.documents, 0..) |item, i| {
            if (overhead + item.bytes.len > limits.max_message_size_bytes) {
                if (diagnostics) |d| d.set(null, null, "item {d} of the write is {d} bytes; with the command, its message would be {d} bytes, and the server takes {d} at most", .{
                    i, item.bytes.len, overhead + item.bytes.len, limits.max_message_size_bytes,
                });
                return error.InvalidArgument;
            }
        }
        return .{ .items = sequence.documents, .overhead = overhead, .limits = limits };
    }

    /// The next batch, or null after the last.
    pub fn next(b: *Batches) ?Batch {
        if (b.offset == b.items.len) return null;
        const max_items = @max(1, b.limits.max_write_batch_size);
        var size = b.overhead + b.items[b.offset].bytes.len;
        var end = b.offset + 1;
        while (end < b.items.len and end - b.offset < max_items) : (end += 1) {
            const len = b.items[end].bytes.len;
            if (size + len > b.limits.max_message_size_bytes) break;
            size += len;
        }
        defer b.offset = end;
        return .{ .offset = b.offset, .items = b.items[b.offset..end] };
    }
};

/// The replies of a write's batches, merged as the Bulk API spec merges
/// them: `n` and `nModified` summed, the indexes of `writeErrors` and
/// `upserted` shifted by the offset of their batch, so that they count in
/// the whole request, and the `writeConcernError` of each batch kept.
/// These errors are soft: a write that has them still succeeds, and the
/// collection API makes `error.WriteFailed` of them.
///
/// Everything it holds comes from the allocator passed to `add`: pass the
/// same one to every call, `deinit` included.
pub const Merge = struct {
    n: u64 = 0,
    modified: u64 = 0,
    upserted: std.ArrayList(results.Upserted) = .empty,
    write_errors: std.ArrayList(results.WriteError) = .empty,
    write_concern_errors: std.ArrayList(results.WriteConcernError) = .empty,
    /// How many items went out in the batches merged.
    answered: usize = 0,

    /// What the write does after a batch.
    pub const Next = enum {
        /// Send the next batch, if there is one.
        more,
        /// The write is ordered and the server refused an item of this
        /// batch: it stopped there, and no batch follows.
        done,
        /// An item or the write concern of this batch failed with
        /// MaxTimeMSExpired (code 50): the write fails with
        /// `error.Timeout`, which `fail` gives, with the batch merged.
        timeout,
    };

    /// Merges the reply of `at`, a reply whose `ok` is 1. A reply that is
    /// not one of a write, such as one that names an item outside its
    /// batch or counts below zero, is `error.ProtocolViolation`, and the
    /// merge stays as it was.
    pub fn add(m: *Merge, allocator: Allocator, at: Batch, reply: bson.RawDocument, ordered: bool, diagnostics: ?*Diagnostics) errors.Error!Next {
        const marks = [3]usize{ m.upserted.items.len, m.write_errors.items.len, m.write_concern_errors.items.len };
        errdefer m.rollback(allocator, marks);
        var n: u64 = 0;
        var modified: u64 = 0;
        // The first error of code 50 in the reply, for the diagnostics.
        var expired: ?struct { message: []const u8, code_name: []const u8 } = null;
        var refused = false;
        var it = reply.iterator();
        while (it.next() catch return violation(diagnostics, "the reply of a write is not valid BSON", .{})) |element| {
            const key = element.key;
            if (eql(key, "n")) {
                n = try count(key, element.value, diagnostics);
            } else if (eql(key, "nModified")) {
                modified = try count(key, element.value, diagnostics);
            } else if (eql(key, "upserted")) {
                var entries = try array(key, element.value, diagnostics);
                while (entries.next() catch return violation(diagnostics, "upserted in the reply of a write is not valid BSON", .{})) |entry| {
                    const doc = try document("an item of upserted", entry.value, diagnostics);
                    const index = try itemIndex(doc, at, diagnostics);
                    const id = (doc.get("_id") catch null) orelse return violation(diagnostics, "an item of upserted in the reply of a write has no _id", .{});
                    try m.upserted.ensureUnusedCapacity(allocator, 1);
                    m.upserted.appendAssumeCapacity(.{ .index = index, .id = try results.dupeValue(allocator, id) });
                }
            } else if (eql(key, "writeErrors")) {
                var entries = try array(key, element.value, diagnostics);
                while (entries.next() catch return violation(diagnostics, "writeErrors in the reply of a write is not valid BSON", .{})) |entry| {
                    const doc = try document("an item of writeErrors", entry.value, diagnostics);
                    const index = try itemIndex(doc, at, diagnostics);
                    const failure = try serverError("an item of writeErrors", doc, diagnostics);
                    if (failure.code == 50 and expired == null) expired = .{ .message = failure.message, .code_name = failure.code_name orelse "MaxTimeMSExpired" };
                    try m.write_errors.ensureUnusedCapacity(allocator, 1);
                    const message = try allocator.dupe(u8, failure.message);
                    errdefer allocator.free(message);
                    const details = try dupeDocument(allocator, failure.details);
                    m.write_errors.appendAssumeCapacity(.{ .index = index, .code = failure.code, .message = message, .details = details });
                    refused = true;
                }
            } else if (eql(key, "writeConcernError")) {
                const doc = try document(key, element.value, diagnostics);
                const failure = try serverError(key, doc, diagnostics);
                if (failure.code == 50 and expired == null) expired = .{ .message = failure.message, .code_name = failure.code_name orelse "MaxTimeMSExpired" };
                try m.write_concern_errors.ensureUnusedCapacity(allocator, 1);
                const message = try allocator.dupe(u8, failure.message);
                errdefer allocator.free(message);
                const details = try dupeDocument(allocator, failure.details);
                m.write_concern_errors.appendAssumeCapacity(.{ .code = failure.code, .message = message, .details = details });
            }
        }
        const total = std.math.add(u64, m.n, n) catch return violation(diagnostics, "n of the write is beyond u64", .{});
        const total_modified = std.math.add(u64, m.modified, modified) catch return violation(diagnostics, "nModified of the write is beyond u64", .{});
        m.n = total;
        m.modified = total_modified;
        m.answered += at.items.len;
        if (expired) |e| {
            if (diagnostics) |d| {
                d.set(.receive, null, "{s}", .{e.message});
                d.server = .{ .code = 50, .code_name = .init(e.code_name) };
            }
            return .timeout;
        }
        return if (ordered and refused) .done else .more;
    }

    /// The merged result, from `allocator`; the merge is empty after it.
    /// Free the result with `WriteResult.deinit`.
    pub fn result(m: *Merge, allocator: Allocator) Allocator.Error!results.WriteResult {
        // Slices of their exact length, so that WriteResult.deinit can free them.
        const upserted = try allocator.dupe(results.Upserted, m.upserted.items);
        errdefer allocator.free(upserted);
        const write_errors = try allocator.dupe(results.WriteError, m.write_errors.items);
        errdefer allocator.free(write_errors);
        const write_concern_errors = try allocator.dupe(results.WriteConcernError, m.write_concern_errors.items);
        const merged: results.WriteResult = .{
            .n = m.n,
            .modified = m.modified,
            .upserted = upserted,
            .write_errors = write_errors,
            .write_concern_errors = write_concern_errors,
            .answered = m.answered,
        };
        m.upserted.deinit(allocator);
        m.write_errors.deinit(allocator);
        m.write_concern_errors.deinit(allocator);
        m.* = .{};
        return merged;
    }

    /// The error of a write that stopped at the batch `at`, by the rules of
    /// a write: at the first batch the error itself; at a later one, after
    /// batches that the server answered, `error.IncompleteWrite`, with
    /// `err` in `Diagnostics.reason`, whose class says whether the batch
    /// `at` reached the server. `Diagnostics.batch_offset` is the offset of
    /// `at`, and `options.partial`, when set, gets the merge so far.
    pub fn fail(m: *Merge, allocator: Allocator, err: errors.Error, at: Batch, options: requests.WriteOptions) errors.Error {
        if (options.diagnostics) |d| d.batch_offset = at.offset;
        if (options.partial) |partial| partial.* = m.result(allocator) catch return error.OutOfMemory;
        if (at.offset == 0) return err;
        if (options.diagnostics) |d| d.reason = err;
        return error.IncompleteWrite;
    }

    /// Frees what the merge holds.
    pub fn deinit(m: *Merge, allocator: Allocator) void {
        m.rollback(allocator, .{ 0, 0, 0 });
        m.upserted.deinit(allocator);
        m.write_errors.deinit(allocator);
        m.write_concern_errors.deinit(allocator);
        m.* = .{};
    }

    /// Frees the entries after `marks`, the lengths of the lists before.
    fn rollback(m: *Merge, allocator: Allocator, marks: [3]usize) void {
        for (m.upserted.items[marks[0]..]) |upserted| results.freeValue(allocator, upserted.id);
        m.upserted.shrinkRetainingCapacity(marks[0]);
        for (m.write_errors.items[marks[1]..]) |write_error| freeFailure(allocator, write_error.message, write_error.details);
        m.write_errors.shrinkRetainingCapacity(marks[1]);
        for (m.write_concern_errors.items[marks[2]..]) |concern| freeFailure(allocator, concern.message, concern.details);
        m.write_concern_errors.shrinkRetainingCapacity(marks[2]);
    }
};

fn freeFailure(allocator: Allocator, message: []const u8, details: ?bson.RawDocument) void {
    allocator.free(message);
    if (details) |doc| allocator.free(doc.bytes);
}

fn dupeDocument(allocator: Allocator, doc: ?bson.RawDocument) Allocator.Error!?bson.RawDocument {
    const d = doc orelse return null;
    return .{ .bytes = try allocator.dupe(u8, d.bytes) };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn count(key: []const u8, value: bson.Value, diagnostics: ?*Diagnostics) errors.Error!u64 {
    const n = value.asI64() catch return violation(diagnostics, "{s} in the reply of a write is not an integer", .{key});
    return std.math.cast(u64, n) orelse violation(diagnostics, "{s} in the reply of a write is {d}, below zero", .{ key, n });
}

fn array(key: []const u8, value: bson.Value, diagnostics: ?*Diagnostics) errors.Error!bson.RawDocument.Iterator {
    return switch (value) {
        .array => |items| items.iterator(),
        else => violation(diagnostics, "{s} in the reply of a write is not an array", .{key}),
    };
}

fn document(what: []const u8, value: bson.Value, diagnostics: ?*Diagnostics) errors.Error!bson.RawDocument {
    return switch (value) {
        .document => |doc| doc,
        else => violation(diagnostics, "{s} in the reply of a write is not a document", .{what}),
    };
}

/// The `index` of an item of `upserted` or `writeErrors`, in the whole
/// request: an index into its batch, shifted by the batch's offset.
fn itemIndex(doc: bson.RawDocument, at: Batch, diagnostics: ?*Diagnostics) errors.Error!usize {
    const value = (doc.get("index") catch null) orelse return violation(diagnostics, "an item of the reply of a write has no index", .{});
    const index = value.asI64() catch return violation(diagnostics, "the index of an item of the reply of a write is not an integer", .{});
    if (index < 0 or index >= at.items.len) {
        return violation(diagnostics, "the reply of a write names item {d} of a batch of {d}", .{ index, at.items.len });
    }
    return at.offset + @as(usize, @intCast(index));
}

/// The code, codeName, errmsg and errInfo of an item of `writeErrors` or
/// of a `writeConcernError`, slices into the reply.
const Failure = struct {
    code: i32,
    code_name: ?[]const u8,
    message: []const u8,
    details: ?bson.RawDocument,
};

fn serverError(what: []const u8, doc: bson.RawDocument, diagnostics: ?*Diagnostics) errors.Error!Failure {
    var failure: Failure = .{ .code = 0, .code_name = null, .message = "", .details = null };
    var has_code = false;
    var it = doc.iterator();
    while (it.next() catch return violation(diagnostics, "{s} is not valid BSON", .{what})) |element| {
        if (eql(element.key, "code")) {
            const code = element.value.asI64() catch return violation(diagnostics, "the code of {s} is not an integer", .{what});
            failure.code = std.math.cast(i32, code) orelse return violation(diagnostics, "the code of {s} is {d}, beyond int32", .{ what, code });
            has_code = true;
        } else if (eql(element.key, "codeName")) {
            if (element.value == .string) failure.code_name = element.value.string;
        } else if (eql(element.key, "errmsg")) {
            // The server may leave it out when the reply would grow too large.
            if (element.value == .string) failure.message = element.value.string;
        } else if (eql(element.key, "errInfo")) {
            if (element.value == .document) failure.details = element.value.document;
        }
    }
    if (!has_code) return violation(diagnostics, "{s} has no code", .{what});
    return failure;
}

fn violation(diagnostics: ?*Diagnostics, comptime fmt: []const u8, args: anytype) error{ProtocolViolation} {
    if (diagnostics) |d| d.set(.receive, null, fmt, args);
    return error.ProtocolViolation;
}
