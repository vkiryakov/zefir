//! What the operations of `mongo.Collection` and `mongo.Database` share
//! to write their commands: a writer of command bodies whose errors are
//! the contract's, and the errors of their checks. Not part of the API.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const errors = @import("../errors.zig");
const document = @import("document.zig");
const Hint = @import("options.zig").Hint;
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;

/// The document `value` of an argument, of the three forms, in `a`.
pub fn argument(a: Allocator, value: anytype, comptime what: []const u8, diagnostics: ?*Diagnostics) Error!bson.RawDocument {
    return document.encode(a, value) catch |err| unwritten(err, diagnostics, what);
}

pub fn unwritten(err: bson.Builder.Error, diagnostics: ?*Diagnostics, what: []const u8) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => invalid(diagnostics, "{s} " ++ unwritable, .{what}),
    };
}

pub const unwritable = "cannot be written as BSON: it holds a string that is not UTF-8, a broken document, a value of a deprecated type, or more than 100 levels";

pub fn invalid(diagnostics: ?*Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    if (diagnostics) |d| d.set(null, null, fmt, args);
    return error.InvalidArgument;
}

pub fn violation(diagnostics: ?*Diagnostics, comptime text: []const u8) Error {
    if (diagnostics) |d| d.set(.receive, null, text, .{});
    return error.ProtocolViolation;
}

/// A `bson.Builder` for the commands of operations, in their scratch
/// memory, whose errors are the contract's: a part that cannot be written
/// is `error.InvalidArgument`, and the diagnostics name it.
pub const Writer = struct {
    b: bson.Builder,
    diagnostics: ?*Diagnostics,

    pub fn init(arena: Allocator, diagnostics: ?*Diagnostics) Writer {
        return .{ .b = .init(arena), .diagnostics = diagnostics };
    }

    pub fn string(w: *Writer, key: []const u8, text: []const u8) Error!void {
        w.b.putString(key, text) catch |err| return w.fail(err, key);
    }

    pub fn boolean(w: *Writer, key: []const u8, value_: bool) Error!void {
        w.b.putBoolean(key, value_) catch |err| return w.fail(err, key);
    }

    pub fn int32(w: *Writer, key: []const u8, value_: i32) Error!void {
        w.b.putInt32(key, value_) catch |err| return w.fail(err, key);
    }

    /// A count, such as a limit: an int32 when it fits, as mongod writes
    /// one, an int64 otherwise.
    pub fn count(w: *Writer, key: []const u8, n: u64) Error!void {
        const put = if (std.math.cast(i32, n)) |small| w.b.putInt32(key, small) else w.b.putInt64(key, std.math.cast(i64, n) orelse std.math.maxInt(i64));
        put catch |err| return w.fail(err, key);
    }

    /// A document, checked whole as `RawDocument.validate` checks it.
    pub fn document(w: *Writer, key: []const u8, doc: bson.RawDocument, what: []const u8) Error!void {
        w.b.putDocument(key, doc) catch |err| return w.fail(err, what);
    }

    /// Opens a document under `key`; in an array, `key` is empty.
    pub fn beginDocument(w: *Writer, key: []const u8) Error!void {
        w.b.beginDocument(key) catch |err| return w.fail(err, key);
    }

    /// Opens an array under `key`.
    pub fn beginArray(w: *Writer, key: []const u8) Error!void {
        w.b.beginArray(key) catch |err| return w.fail(err, key);
    }

    pub fn end(w: *Writer) Error!void {
        w.b.end() catch |err| return w.fail(err, "the command");
    }

    /// `cursor`: `{}`, or `{batchSize: n}`.
    pub fn cursor(w: *Writer, batch_size: ?u32) Error!void {
        try w.beginDocument("cursor");
        if (batch_size) |n| try w.count("batchSize", n);
        try w.end();
    }

    /// An array of documents.
    pub fn documents(w: *Writer, key: []const u8, docs: []const bson.RawDocument, what: []const u8) Error!void {
        w.b.beginArray(key) catch |err| return w.fail(err, what);
        for (docs) |doc| w.b.putDocument("", doc) catch |err| return w.fail(err, what);
        w.b.end() catch |err| return w.fail(err, what);
    }

    /// `hint`: the name of an index, or its keys.
    pub fn hint(w: *Writer, value_: Hint) Error!void {
        switch (value_) {
            .name => |name| try w.string("hint", name),
            .keys => |keys| try w.document("hint", keys, "the hint"),
        }
    }

    /// A value of any BSON type but the deprecated ones; a string must be
    /// UTF-8.
    pub fn value(w: *Writer, key: []const u8, value_: bson.Value, what: []const u8) Error!void {
        w.b.put(key, value_) catch |err| return w.fail(err, what);
    }

    pub fn finish(w: *Writer) Error!bson.RawDocument {
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
