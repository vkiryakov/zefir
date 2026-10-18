//! The result of a batched write: the replies of its batches merged, as
//! the Bulk API spec merges them.

const std = @import("std");
const bson = @import("bson.zig");
const Allocator = std.mem.Allocator;

/// What a write did. `writeErrors` and `writeConcernError` are soft here:
/// a write whose items the server refused still returns its result; the
/// collection API turns them into `error.WriteFailed`.
///
/// Every slice, and every string, document and value in its items, is an
/// allocation of its own from the call's allocator, so `deinit` frees the
/// result with that allocator; `wire.batch` builds results so. An
/// arena frees it all at once instead.
pub const WriteResult = struct {
    /// insert: documents inserted; update: documents matched, upserts
    /// included; delete: documents deleted.
    n: u64 = 0,
    /// update: documents modified (`nModified`).
    modified: u64 = 0,
    /// The upserts, by the index of their item in the whole request.
    upserted: []const Upserted = &.{},
    /// The items the server refused, by their index in the whole request.
    write_errors: []const WriteError = &.{},
    /// One per batch whose write concern failed.
    write_concern_errors: []const WriteConcernError = &.{},
    /// How many items went out in batches that the server answered.
    answered: usize = 0,

    pub fn deinit(result: *WriteResult, allocator: Allocator) void {
        for (result.upserted) |upserted| freeValue(allocator, upserted.id);
        allocator.free(result.upserted);
        for (result.write_errors) |write_error| {
            allocator.free(write_error.message);
            if (write_error.details) |details| allocator.free(details.bytes);
        }
        allocator.free(result.write_errors);
        for (result.write_concern_errors) |concern| {
            allocator.free(concern.message);
            if (concern.details) |details| allocator.free(details.bytes);
        }
        allocator.free(result.write_concern_errors);
        result.* = .{};
    }
};

/// An update or a replace that inserted the document it did not find.
pub const Upserted = struct {
    /// The index of the item in the whole request.
    index: usize,
    /// The `_id` of the inserted document.
    id: bson.Value,
};

/// An item that the server refused, such as a duplicate key (11000).
pub const WriteError = struct {
    /// The index of the item in the whole request.
    index: usize,
    code: i32,
    /// The errmsg; the server may leave it empty when the reply would grow
    /// too large.
    message: []const u8,
    /// The `errInfo` of the server, as it is.
    details: ?bson.RawDocument = null,
};

/// A batch whose write concern the server could not satisfy. The items
/// were written.
pub const WriteConcernError = struct {
    code: i32,
    message: []const u8,
    /// The `errInfo` of the server, as it is.
    details: ?bson.RawDocument = null,
};

/// A copy of `value` whose strings, documents and bytes are allocations of
/// their own in `allocator`, as a `WriteResult` holds an `_id`; free it
/// with `freeValue`.
pub fn dupeValue(allocator: Allocator, value: bson.Value) Allocator.Error!bson.Value {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .javascript => |code| .{ .javascript = try allocator.dupe(u8, code) },
        .symbol => |symbol| .{ .symbol = try allocator.dupe(u8, symbol) },
        .document => |doc| .{ .document = .{ .bytes = try allocator.dupe(u8, doc.bytes) } },
        .array => |doc| .{ .array = .{ .bytes = try allocator.dupe(u8, doc.bytes) } },
        .binary => |binary| .{ .binary = .{ .subtype = binary.subtype, .bytes = try allocator.dupe(u8, binary.bytes) } },
        .regex => |regex| regex: {
            const pattern = try allocator.dupe(u8, regex.pattern);
            errdefer allocator.free(pattern);
            break :regex .{ .regex = .{ .pattern = pattern, .options = try allocator.dupe(u8, regex.options) } };
        },
        .db_pointer => |pointer| .{ .db_pointer = .{ .namespace = try allocator.dupe(u8, pointer.namespace), .id = pointer.id } },
        .javascript_with_scope => |code| code: {
            const text = try allocator.dupe(u8, code.code);
            errdefer allocator.free(text);
            break :code .{ .javascript_with_scope = .{ .code = text, .scope = .{ .bytes = try allocator.dupe(u8, code.scope.bytes) } } };
        },
        else => value,
    };
}

/// Frees a value that `dupeValue` made.
pub fn freeValue(allocator: Allocator, value: bson.Value) void {
    switch (value) {
        .string, .javascript, .symbol => |text| allocator.free(text),
        .document, .array => |doc| allocator.free(doc.bytes),
        .binary => |binary| allocator.free(binary.bytes),
        .regex => |regex| {
            allocator.free(regex.pattern);
            allocator.free(regex.options);
        },
        .db_pointer => |pointer| allocator.free(pointer.namespace),
        .javascript_with_scope => |code| {
            allocator.free(code.code);
            allocator.free(code.scope.bytes);
        },
        else => {},
    }
}
