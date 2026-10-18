//! `wire.batch`: the items of a write in batches that fit the limits of
//! the connection they go through, as the Bulk API spec splits them.
//!
//! ```zig
//! var request: opmsg.Request = .{ .request_id = 0, .body = body, .database = "app", .ordered = true, .max_time_ms = budget, .sequence = .{ .identifier = "documents", .documents = items } };
//! var batches = try batch.Batches.init(request, .of(hello), &diagnostics);
//! while (batches.next()) |b| {
//!     request.sequence.?.documents = b.items;
//!     // send request, read the reply; b.offset shifts the indexes in it
//! }
//! ```

const std = @import("std");
const bson = @import("../bson.zig");
const opmsg = @import("opmsg.zig");
const Hello = @import("Hello.zig");
const errors = @import("../contract/errors.zig");

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
