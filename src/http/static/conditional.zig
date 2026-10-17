//! Conditional requests and ranges of static files (RFC 9110 §13 and §14),
//! as design section 13 takes them: the validators `ETag` and
//! `Last-Modified`; `If-None-Match`, which beats `If-Modified-Since`, for a
//! 304; one byte range of a GET for a 206, several for the whole file, a
//! range past the end for a 416; `If-Range`, without which a resumed
//! download of a changed file would mix two versions. Pure.
const std = @import("std");
const date = @import("../h1/date.zig");

/// The validators of a file, as its response gives them.
pub const Validators = struct {
    /// `"<mtime in ns, hex>-<size, hex>"`, with its quotes.
    etag: []const u8,
    /// The time of `Last-Modified`, in seconds since 1970-01-01 UTC.
    last_modified: i64,
};

/// Room for an `ETag`: two numbers in hex, a dash, a sign, two quotes.
pub const etag_max = 2 + 1 + 24 + 1 + 16 + 1;

/// The strong `ETag` of a file: its modification time in nanoseconds and
/// its size, in hex: `"18a0c2f4e1b3d000-1f40"`.
pub fn etag(buffer: *[etag_max]u8, mtime: std.Io.Timestamp, size: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "\"{x}-{x}\"", .{ mtime.nanoseconds, size }) catch unreachable; // fits by etag_max
}

/// The time of `Last-Modified`: the file's modification time in whole
/// seconds, never later than `now`, the response's `Date` (RFC 9110
/// §8.8.2.1).
pub fn lastModified(mtime: std.Io.Timestamp, now: std.Io.Timestamp) i64 {
    return @min(mtime.toSeconds(), now.toSeconds());
}

/// Whether a GET or HEAD is answered 304 Not Modified. `If-None-Match`
/// (each of its fields, a list of entity tags or `*`) decides when it
/// came, by the weak comparison: `W/"x"` matches `"x"`. Without it,
/// `If-Modified-Since` does, when the file has not changed since its date;
/// a date that does not parse is ignored.
pub fn notModified(if_none_match: []const []const u8, if_modified_since: ?[]const u8, v: Validators) bool {
    if (if_none_match.len > 0) {
        for (if_none_match) |value| if (matchesAny(value, v.etag)) return true;
        return false;
    }
    const since = parseDate(if_modified_since orelse return false) orelse return false;
    return v.last_modified <= since;
}

/// `*`, or a tag of the list `value` whose opaque part is that of `tag`.
fn matchesAny(value: []const u8, tag: []const u8) bool {
    if (std.mem.eql(u8, std.mem.trim(u8, value, " \t"), "*")) return true;
    var tags: TagIterator = .{ .rest = value };
    while (tags.next()) |t| {
        if (std.mem.eql(u8, t.opaque_tag, tag)) return true;
    }
    return false;
}

const Tag = struct { weak: bool, opaque_tag: []const u8 };

/// The entity tags of a list, `"a", W/"b"`; it stops at the first element
/// that is not one. A tag may hold a comma: the list is read tag by tag,
/// not split at commas.
const TagIterator = struct {
    rest: []const u8,

    fn next(it: *TagIterator) ?Tag {
        var s = std.mem.trimStart(u8, it.rest, " \t,");
        if (s.len == 0) return null;
        const weak = std.mem.startsWith(u8, s, "W/");
        if (weak) s = s[2..];
        if (s.len < 2 or s[0] != '"') return null;
        const end = std.mem.findScalar(u8, s[1..], '"') orelse return null;
        const tag = s[0 .. end + 2];
        for (tag[1 .. tag.len - 1]) |c| {
            // etagc: visible ASCII but '"', or a byte past ASCII.
            if (c < 0x21 or c == 0x7f) return null;
        }
        it.rest = s[tag.len..];
        return .{ .weak = weak, .opaque_tag = tag };
    }
};

fn parseDate(text: []const u8) ?i64 {
    return date.parseHttpDate(std.mem.trim(u8, text, " \t"));
}

/// What a `Range` asks of a file of `size` bytes.
pub const Range = union(enum) {
    /// The whole file, 200: a range that is not of bytes, a malformed one,
    /// several ranges, or a file of no bytes.
    whole,
    /// One range of bytes, 206.
    part: struct { start: u64, len: u64 },
    /// A range wholly past the end, 416.
    unsatisfiable,
};

/// The range of `value`, the `Range` of a GET (RFC 9110 §14.2): `bytes=a-b`
/// (`b` past the end means the end), `bytes=a-` (from `a` on) or
/// `bytes=-n` (the last `n` bytes); the unit in any case. One range is
/// served alone; several are answered with the whole file; a range whose
/// start lies past the end, or the last 0 bytes, is unsatisfiable. A
/// malformed value is ignored.
pub fn range(value: []const u8, size: u64) Range {
    const eq = std.mem.findScalar(u8, value, '=') orelse return .whole;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..eq], " \t"), "bytes")) return .whole;
    var specs = std.mem.splitScalar(u8, value[eq + 1 ..], ',');
    var found: ?Spec = null;
    var count: usize = 0;
    while (specs.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t");
        // Empty elements of a list do not count (RFC 9110 §5.6.1).
        if (text.len == 0) continue;
        found = parseSpec(text) orelse return .whole;
        count += 1;
    }
    const spec = found orelse return .whole;
    if (count > 1 or size == 0) return .whole;
    switch (spec) {
        .from => |f| {
            if (f.first >= size) return .unsatisfiable;
            const last = @min(f.last orelse size - 1, size - 1);
            return .{ .part = .{ .start = f.first, .len = last - f.first + 1 } };
        },
        .suffix => |n| {
            if (n == 0) return .unsatisfiable;
            const len = @min(n, size);
            return .{ .part = .{ .start = size - len, .len = len } };
        },
    }
}

const Spec = union(enum) {
    /// `a-b` or `a-`.
    from: struct { first: u64, last: ?u64 },
    /// `-n`.
    suffix: u64,
};

fn parseSpec(text: []const u8) ?Spec {
    const dash = std.mem.findScalar(u8, text, '-') orelse return null;
    if (dash == 0) return .{ .suffix = digits(text[1..]) orelse return null };
    const first = digits(text[0..dash]) orelse return null;
    if (dash + 1 == text.len) return .{ .from = .{ .first = first, .last = null } };
    const last = digits(text[dash + 1 ..]) orelse return null;
    // A range that ends before it begins is invalid.
    if (last < first) return null;
    return .{ .from = .{ .first = first, .last = last } };
}

/// One or more digits, as a number; past the largest u64 it stays there.
fn digits(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var n: u64 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n *| 10 +| (c - '0');
    }
    return n;
}

/// Whether `If-Range` lets the range of a GET apply: an entity tag that is
/// the file's by the strong comparison (a weak tag never is), or a date
/// that is exactly its `Last-Modified`. Otherwise the file has changed, or
/// may have, and goes out whole.
pub fn ifRange(value: []const u8, v: Validators) bool {
    const text = std.mem.trim(u8, value, " \t");
    if (text.len > 0 and (text[0] == '"' or std.mem.startsWith(u8, text, "W/"))) {
        var tags: TagIterator = .{ .rest = text };
        const tag = tags.next() orelse return false;
        // One tag, and nothing after it.
        if (std.mem.trim(u8, tags.rest, " \t").len != 0) return false;
        return !tag.weak and std.mem.eql(u8, tag.opaque_tag, v.etag);
    }
    return (date.parseHttpDate(text) orelse return false) == v.last_modified;
}

const testing = std.testing;

test "etag and lastModified" {
    var buffer: [etag_max]u8 = undefined;
    try testing.expectEqualStrings("\"18a0c2f4e1b3d000-1f40\"", etag(&buffer, .fromNanoseconds(0x18a0c2f4e1b3d000), 8000));
    try testing.expectEqualStrings("\"0-0\"", etag(&buffer, .fromNanoseconds(0), 0));
    // The extremes fit.
    _ = etag(&buffer, .fromNanoseconds(std.math.minInt(i96)), std.math.maxInt(u64));
    _ = etag(&buffer, .fromNanoseconds(std.math.maxInt(i96)), std.math.maxInt(u64));
    const second = std.time.ns_per_s;
    try testing.expectEqual(100, lastModified(.fromNanoseconds(100 * second + 999), .fromNanoseconds(200 * second)));
    // A file "from the future" is never newer than the response.
    try testing.expectEqual(200, lastModified(.fromNanoseconds(500 * second), .fromNanoseconds(200 * second + 5)));
}

const file_validators: Validators = .{ .etag = "\"abc-10\"", .last_modified = 784_111_777 };

test "notModified: If-None-Match beats If-Modified-Since; weak comparison; * matches" {
    const imf = "Sun, 06 Nov 1994 08:49:37 GMT";
    try testing.expect(notModified(&.{"\"abc-10\""}, null, file_validators));
    try testing.expect(notModified(&.{"W/\"abc-10\""}, null, file_validators));
    try testing.expect(notModified(&.{"\"x\", \"abc-10\""}, null, file_validators));
    try testing.expect(notModified(&.{ "\"x\"", "\"y\", W/\"abc-10\"" }, null, file_validators));
    try testing.expect(notModified(&.{"*"}, null, file_validators));
    try testing.expect(notModified(&.{" * "}, null, file_validators));
    // A tag with a comma in it is one tag.
    try testing.expect(!notModified(&.{"\"abc,-10\""}, null, file_validators));
    try testing.expect(!notModified(&.{"\"abc-1\""}, null, file_validators));
    try testing.expect(!notModified(&.{"abc-10"}, null, file_validators));
    // If-None-Match came and does not match: If-Modified-Since is not read.
    try testing.expect(!notModified(&.{"\"other\""}, imf, file_validators));
    // Without If-None-Match: not modified since the date or later.
    try testing.expect(notModified(&.{}, imf, file_validators));
    try testing.expect(notModified(&.{}, "Mon, 07 Nov 1994 08:49:37 GMT", file_validators));
    try testing.expect(notModified(&.{}, "Sunday, 06-Nov-94 08:49:37 GMT", file_validators));
    try testing.expect(!notModified(&.{}, "Sun, 06 Nov 1994 08:49:36 GMT", file_validators));
    try testing.expect(!notModified(&.{}, "yesterday", file_validators));
    try testing.expect(!notModified(&.{}, null, file_validators));
}

test "range: one range, a suffix, several, unsatisfiable and malformed" {
    const rows = [_]struct { []const u8, Range }{
        .{ "bytes=0-99", .{ .part = .{ .start = 0, .len = 100 } } },
        .{ "bytes=900-", .{ .part = .{ .start = 900, .len = 100 } } },
        .{ "bytes=990-2000", .{ .part = .{ .start = 990, .len = 10 } } },
        .{ "bytes=999-999", .{ .part = .{ .start = 999, .len = 1 } } },
        .{ "bytes=-100", .{ .part = .{ .start = 900, .len = 100 } } },
        .{ "bytes=-2000", .{ .part = .{ .start = 0, .len = 1000 } } },
        .{ "Bytes=0-0", .{ .part = .{ .start = 0, .len = 1 } } },
        .{ "bytes= 5-9 ", .{ .part = .{ .start = 5, .len = 5 } } },
        .{ "bytes=5-9,", .{ .part = .{ .start = 5, .len = 5 } } },
        .{ "bytes=0-99999999999999999999999", .{ .part = .{ .start = 0, .len = 1000 } } },
        .{ "bytes=0-1,5-6", .whole },
        .{ "bytes=0-1, 2000-", .whole },
        .{ "bytes=1000-", .unsatisfiable },
        .{ "bytes=1000-1001", .unsatisfiable },
        .{ "bytes=99999999999999999999999-", .unsatisfiable },
        .{ "bytes=-0", .unsatisfiable },
        .{ "bytes=5-1", .whole },
        .{ "bytes=a-b", .whole },
        .{ "bytes=-", .whole },
        .{ "bytes=", .whole },
        .{ "bytes=1", .whole },
        .{ "bytes=+1-2", .whole },
        .{ "bytes=0-1,x", .whole },
        .{ "items=0-1", .whole },
        .{ "0-1", .whole },
    };
    for (rows) |row| {
        testing.expectEqual(row[1], range(row[0], 1000)) catch |err| {
            std.debug.print("range {s}\n", .{row[0]});
            return err;
        };
    }
    // A file of no bytes has no range to give.
    try testing.expectEqual(Range.whole, range("bytes=0-", 0));
    try testing.expectEqual(Range.whole, range("bytes=-5", 0));
}

test "ifRange: a strong tag that matches, or the exact date" {
    try testing.expect(ifRange("\"abc-10\"", file_validators));
    try testing.expect(ifRange(" \"abc-10\" ", file_validators));
    try testing.expect(!ifRange("W/\"abc-10\"", file_validators));
    try testing.expect(!ifRange("\"stale\"", file_validators));
    try testing.expect(!ifRange("\"abc-10\", \"x\"", file_validators));
    try testing.expect(ifRange("Sun, 06 Nov 1994 08:49:37 GMT", file_validators));
    try testing.expect(!ifRange("Sun, 06 Nov 1994 08:49:38 GMT", file_validators));
    try testing.expect(!ifRange("Mon, 07 Nov 1994 08:49:37 GMT", file_validators));
    try testing.expect(!ifRange("whenever", file_validators));
    try testing.expect(!ifRange("", file_validators));
}
