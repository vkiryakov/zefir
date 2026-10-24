//! A BSON document whose bytes belong to an allocator, such as a copy made
//! with `RawDocument.dupe`. Free it with `deinit`. It holds no pointer into
//! itself, so it may be moved or copied, but only one copy is freed.

const std = @import("std");
const RawDocument = @import("RawDocument.zig");
const OwnedDocument = @This();

/// The whole document; the bytes belong to `allocator`.
bytes: []const u8,
allocator: std.mem.Allocator,

/// The document to read; it lives until `deinit`.
pub fn raw(doc: OwnedDocument) RawDocument {
    return .{ .bytes = doc.bytes };
}

pub fn deinit(doc: OwnedDocument) void {
    doc.allocator.free(doc.bytes);
}
