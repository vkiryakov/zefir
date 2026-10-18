//! Reading BSON under `RawDocument`: one element at a time, every length
//! checked against the bytes there are, and the check of a whole document.
//! No input makes it read out of bounds, overflow or recurse: a broken
//! document gives `error.InvalidBson`.

const std = @import("std");
const bson = @import("../bson.zig");
const Element = bson.Element;
const Value = bson.Value;

/// Whether `bytes` are framed as one document: the length at the front
/// is their number, and the last byte is 0. The elements are not checked.
pub fn isDocument(bytes: []const u8) bool {
    if (bytes.len < 5 or bytes.len > std.math.maxInt(i32)) return false;
    const len = std.mem.readInt(i32, bytes[0..4], .little);
    return len == bytes.len and bytes[bytes.len - 1] == 0;
}

/// The element at `pos` of a document whose final 0 is at `end`, and the
/// position after it. Nested documents are checked only as `isDocument`
/// checks them.
pub fn element(bytes: []const u8, pos: usize, end: usize) bson.Error!struct { Element, usize } {
    if (end >= bytes.len or pos >= end) return error.InvalidBson;
    // A 0 here would end the document before its end.
    const kind = std.enums.fromInt(bson.Type, bytes[pos]) orelse return error.InvalidBson;
    var r: Reader = .{ .bytes = bytes, .pos = pos + 1, .end = end };
    const key = try r.cstring();
    const value: Value = switch (kind) {
        .double => .{ .double = @bitCast(try r.int(u64)) },
        .string => .{ .string = try r.string() },
        .document => .{ .document = try r.document() },
        .array => .{ .array = try r.document() },
        .binary => .{ .binary = try r.binary() },
        .undefined => .undefined,
        .object_id => .{ .object_id = .{ .bytes = (try r.fixed(12)).* } },
        .boolean => .{ .boolean = switch ((try r.fixed(1))[0]) {
            0 => false,
            1 => true,
            else => return error.InvalidBson,
        } },
        .date_time => .{ .date_time = .{ .milliseconds = try r.int(i64) } },
        .null => .null,
        .regex => regex: {
            const pattern = try r.cstring();
            break :regex .{ .regex = .{ .pattern = pattern, .options = try r.cstring() } };
        },
        .db_pointer => pointer: {
            const namespace = try r.string();
            break :pointer .{ .db_pointer = .{ .namespace = namespace, .id = .{ .bytes = (try r.fixed(12)).* } } };
        },
        .javascript => .{ .javascript = try r.string() },
        .symbol => .{ .symbol = try r.string() },
        .javascript_with_scope => .{ .javascript_with_scope = try r.codeWithScope() },
        .int32 => .{ .int32 = try r.int(i32) },
        .timestamp => timestamp: {
            // The uint64 is little-endian: the increment comes first.
            const increment = try r.int(u32);
            break :timestamp .{ .timestamp = .{ .seconds = try r.int(u32), .increment = increment } };
        },
        .int64 => .{ .int64 = try r.int(i64) },
        .decimal128 => .{ .decimal128 = .{ .bytes = (try r.fixed(16)).* } },
        .min_key => .min_key,
        .max_key => .max_key,
    };
    return .{ .{ .key = key, .value = value }, r.pos };
}

/// The most levels `validate` walks: a stored document of
/// `bson.max_depth` levels inside the three levels of a reply,
/// `reply.cursor.firstBatch`.
pub const max_levels = bson.max_depth + 3;

/// Checks every element of the document `bytes` and of the documents in
/// it, with at most `levels` (and at most `max_levels`) documents inside
/// one another, `bytes` included. Walks with a stack of its own rather
/// than recursion.
pub fn validate(bytes: []const u8, levels: usize) bson.Error!void {
    if (!isDocument(bytes) or levels == 0) return error.InvalidBson;
    const limit = @min(levels, max_levels);
    const Frame = struct { bytes: []const u8, pos: usize };
    var stack: [max_levels]Frame = undefined;
    stack[0] = .{ .bytes = bytes, .pos = 4 };
    var depth: usize = 1;
    while (depth > 0) {
        const frame = &stack[depth - 1];
        const end = frame.bytes.len - 1;
        if (frame.pos == end) {
            depth -= 1;
            continue;
        }
        const found, const after = try element(frame.bytes, frame.pos, end);
        frame.pos = after;
        const inner: []const u8 = switch (found.value) {
            .document, .array => |doc| doc.bytes,
            .javascript_with_scope => |code| code.scope.bytes,
            else => continue,
        };
        if (depth == limit) return error.InvalidBson;
        stack[depth] = .{ .bytes = inner, .pos = 4 };
        depth += 1;
    }
}

/// Reads values of a document body: `pos` moves forward, and nothing is
/// read at `end` or past it.
const Reader = struct {
    bytes: []const u8,
    pos: usize,
    /// The first index a value may not reach: the document's final 0, or
    /// the end of a code with scope.
    end: usize,

    fn fixed(r: *Reader, comptime n: usize) bson.Error!*const [n]u8 {
        if (r.end - r.pos < n) return error.InvalidBson;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }

    fn int(r: *Reader, comptime T: type) bson.Error!T {
        return std.mem.readInt(T, try r.fixed(@sizeOf(T)), .little);
    }

    /// The next `n` bytes.
    fn take(r: *Reader, n: usize) bson.Error![]const u8 {
        if (r.end - r.pos < n) return error.InvalidBson;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }

    /// An int32 length that may not be negative.
    fn length(r: *Reader) bson.Error!usize {
        const len = try r.int(i32);
        if (len < 0) return error.InvalidBson;
        return @intCast(len);
    }

    /// A string: an int32 length that counts the 0, the bytes, the 0.
    fn string(r: *Reader) bson.Error![]const u8 {
        const n = try r.length();
        if (n == 0) return error.InvalidBson;
        const bytes = try r.take(n);
        if (bytes[n - 1] != 0) return error.InvalidBson;
        return bytes[0 .. n - 1];
    }

    /// Bytes up to a 0, which is skipped.
    fn cstring(r: *Reader) bson.Error![]const u8 {
        const zero = std.mem.findScalarPos(u8, r.bytes[0..r.end], r.pos, 0) orelse return error.InvalidBson;
        defer r.pos = zero + 1;
        return r.bytes[r.pos..zero];
    }

    fn document(r: *Reader) bson.Error!bson.RawDocument {
        if (r.end - r.pos < 4) return error.InvalidBson;
        const len = std.mem.readInt(i32, r.bytes[r.pos..][0..4], .little);
        if (len < 5) return error.InvalidBson;
        const bytes = try r.take(@intCast(len));
        if (bytes[bytes.len - 1] != 0) return error.InvalidBson;
        return .{ .bytes = bytes };
    }

    fn binary(r: *Reader) bson.Error!bson.Binary {
        const n = try r.length();
        const subtype: bson.Binary.Subtype = @fromBackingInt((try r.fixed(1))[0]);
        var bytes = try r.take(n);
        if (subtype == .binary_old) {
            // The data repeats its length, less the 4 bytes of that length.
            if (n < 4) return error.InvalidBson;
            if (std.mem.readInt(i32, bytes[0..4], .little) != n - 4) return error.InvalidBson;
            bytes = bytes[4..];
        }
        return .{ .subtype = subtype, .bytes = bytes };
    }

    /// An int32 length of the whole value, a string and a document, which
    /// fill exactly that length.
    fn codeWithScope(r: *Reader) bson.Error!bson.JavaScriptWithScope {
        const start = r.pos;
        const n = try r.length();
        // 4 for the length, 5 for an empty string, 5 for an empty document.
        if (n < 14 or r.end - start < n) return error.InvalidBson;
        var inner: Reader = .{ .bytes = r.bytes, .pos = r.pos, .end = start + n };
        const code = try inner.string();
        const scope = try inner.document();
        if (inner.pos != inner.end) return error.InvalidBson;
        r.pos = inner.end;
        return .{ .code = code, .scope = scope };
    }
};
