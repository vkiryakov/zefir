//! `mongo.Collection`: a collection of MongoDB and its operations, written
//! once over `mongo.Client`, so the same on every driver. `Database`
//! gives it: `db.collection("users")`.
//!
//! Each operation takes `io` and the caller's `mongo.OperationContext`,
//! as the contract does, and makes one call of the contract. No operation
//! retries.
//!
//! Documents of operations — filters, updates, replacements, documents to
//! insert — come in three forms: a `bson.RawDocument`, a
//! `bson.OwnedDocument` (from `bson.Builder`), or a struct or an anonymous
//! literal that `bson.encode` writes. Lists are a slice, an array or a
//! tuple of them. Documents inside options, such as a collation, are
//! `bson.RawDocument`s; `bson.literal` writes constant ones.

const std = @import("std");
const errors = @import("../contract/errors.zig");
const Database = @import("Database.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const Collection = @This();

db: Database,
/// Borrowed; it must outlive the value.
name: []const u8,

/// The name of the collection: not empty, without `$` and NUL. Breaking it
/// is `error.InvalidArgument`, and nothing is sent.
fn checkName(c: Collection, diagnostics: ?*Diagnostics) Error!void {
    if (c.name.len == 0) return invalid(diagnostics, "the collection name is empty", .{});
    if (std.mem.findAny(u8, c.name, "\x00$")) |at| {
        const what = if (c.name[at] == 0) "a NUL" else "a '$'";
        return invalid(diagnostics, "a collection name holds no '$' and no NUL; this one holds {s} at byte {d}", .{ what, at });
    }
}

fn invalid(diagnostics: ?*Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    if (diagnostics) |d| d.set(null, null, fmt, args);
    return error.InvalidArgument;
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
