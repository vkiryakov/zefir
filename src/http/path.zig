//! The path of a request as the router sees it. The
//! path is split into segments first, and each segment is percent-decoded
//! after, so `%2F` stays a `/` inside its segment and never splits the
//! path. `.` and `..` are resolved per RFC 3986, never above the root; an
//! empty segment (`//`) matches no route; a trailing slash does not matter,
//! case does; invalid UTF-8 after decoding is a bad request (400).
const std = @import("std");

pub const Error = error{ InvalidRequest, OutOfMemory };

/// The parts of a request target (RFC 9112 §3.2).
pub const Target = struct {
    /// "/a/b": the path of origin form ("/a/b?x=1") and of absolute form
    /// ("http://host/a/b?x=1"), "/" when absolute form has none, and "*"
    /// for `OPTIONS *`.
    path: []const u8,
    /// What follows '?', without it; empty without a query.
    query: []const u8,
};

/// Splits a target that the parser took (origin form, absolute form with
/// http or https, or "*") into its path and its query; a fragment, which a
/// client should not send, is dropped.
pub fn splitTarget(target: []const u8) Target {
    var rest = target;
    if (rest.len > 0 and rest[0] != '/' and !std.mem.eql(u8, rest, "*")) {
        // Absolute form: the path starts after the authority.
        const scheme_end = (std.mem.find(u8, rest, "://") orelse return .{ .path = "/", .query = "" }) + "://".len;
        const authority = rest[scheme_end..];
        const end = std.mem.findAny(u8, authority, "/?#") orelse authority.len;
        rest = authority[end..];
        if (rest.len == 0 or rest[0] != '/') {
            const query = queryOf(rest);
            return .{ .path = "/", .query = query };
        }
    }
    const path_end = std.mem.findAny(u8, rest, "?#") orelse rest.len;
    return .{ .path = rest[0..path_end], .query = queryOf(rest[path_end..]) };
}

/// The query of what follows a path: "?a=1#f" is "a=1".
fn queryOf(after_path: []const u8) []const u8 {
    if (after_path.len == 0 or after_path[0] != '?') return "";
    const q = after_path[1..];
    return q[0 .. std.mem.findScalar(u8, q, '#') orelse q.len];
}

/// Whether `c` may be a byte of a literal segment of a route's pattern, of
/// the server's prefix or of a static mount: visible ASCII but '%', '?',
/// '#', '{' and '}'. The router compares those segments with the segments
/// of a path decoded, so a segment written encoded would never match, and
/// '?' and '#' never come in a path.
pub fn literalByte(c: u8) bool {
    return c >= 0x21 and c <= 0x7e and std.mem.findScalar(u8, "%?#{}", c) == null;
}

/// "" or "/api", "/api/v2": the server's prefix, and a mount of `.static`
/// but "/": segments of `literalByte`s, no empty or dot segment, no
/// trailing slash. The router compares it, segment by segment, with the
/// decoded segments of a path.
pub fn validPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (prefix[0] != '/') return false;
    var it = std.mem.splitScalar(u8, prefix[1..], '/');
    while (it.next()) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
        for (s) |c| {
            if (!literalByte(c)) return false;
        }
    }
    return true;
}

/// A path ready for the router.
pub const Normalized = struct {
    /// The decoded segments, without dot segments and without the trailing
    /// slash: "/a/b%2Fc/" is "a", "b/c"; the root "/" has none. They lie one
    /// after another in one buffer, joined by '/', so `rest` is a slice.
    segments: []const []const u8,
    /// The path had an empty segment, such as "/a//b": no route matches it.
    empty_segment: bool,

    /// The segments from `from` to the end, joined by '/': the value of a
    /// `{*rest}` parameter. `from` < `segments.len`.
    pub fn rest(n: Normalized, from: usize) []const u8 {
        const first = n.segments[from];
        const last = n.segments[n.segments.len - 1];
        return first.ptr[0 .. @intFromPtr(last.ptr) + last.len - @intFromPtr(first.ptr)];
    }
};

/// Normalizes `raw_path`, which starts with '/', into segments in
/// `arena`: each segment percent-decoded, then dot segments removed (RFC
/// 3986 §5.2.4), then the trailing slash dropped. A '%' without two hex
/// digits after it, or a segment that is not UTF-8 once decoded, is
/// `InvalidRequest`.
pub fn normalize(arena: std.mem.Allocator, raw_path: []const u8) Error!Normalized {
    if (raw_path.len == 0 or raw_path[0] != '/') return error.InvalidRequest;
    const body = raw_path[1..];
    const segments = try arena.alloc([]const u8, std.mem.countScalar(u8, body, '/') + 1);
    // Decoded segments never grow, and a separator takes the place of the
    // '/' before it: the buffer is a stack as large as the path.
    const buf = try arena.alloc(u8, body.len);
    var depth: usize = 0;
    var end: usize = 0;
    var it = std.mem.splitScalar(u8, body, '/');
    while (it.next()) |raw| {
        // The empty segment after a trailing slash is not a segment.
        if (raw.len == 0 and it.index == null) break;
        const start = if (depth == 0) 0 else end + 1;
        const decoded = try percentDecode(buf[start..], raw);
        if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidRequest;
        if (std.mem.eql(u8, decoded, ".")) continue;
        if (std.mem.eql(u8, decoded, "..")) {
            if (depth > 0) depth -= 1;
            end = if (depth == 0) 0 else @intFromPtr(segments[depth - 1].ptr) - @intFromPtr(buf.ptr) + segments[depth - 1].len;
            continue;
        }
        if (depth > 0) buf[end] = '/';
        segments[depth] = decoded;
        depth += 1;
        end = start + decoded.len;
    }
    var empty_segment = false;
    for (segments[0..depth]) |s| {
        if (s.len == 0) empty_segment = true;
    }
    return .{ .segments = segments[0..depth], .empty_segment = empty_segment };
}

/// Decodes `in` into `out` (at least as long): every '%' must come with
/// exactly two hex digits, `%2F` is '/', and '+' stays '+'.
pub fn percentDecode(out: []u8, in: []const u8) error{InvalidRequest}![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < in.len) : (n += 1) {
        if (in[i] != '%') {
            out[n] = in[i];
            i += 1;
            continue;
        }
        if (in.len - i < 3) return error.InvalidRequest;
        const hi = std.fmt.charToDigit(in[i + 1], 16) catch return error.InvalidRequest;
        const lo = std.fmt.charToDigit(in[i + 2], 16) catch return error.InvalidRequest;
        out[n] = hi << 4 | lo;
        i += 3;
    }
    return out[0..n];
}

const testing = std.testing;

fn expectSegments(expected: []const []const u8, raw: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const n = try normalize(arena_state.allocator(), raw);
    try testing.expect(!n.empty_segment);
    try testing.expectEqual(expected.len, n.segments.len);
    for (expected, n.segments) |want, got| try testing.expectEqualStrings(want, got);
}

test "path: %2F inside a parameter stays a slash in its value" {
    try expectSegments(&.{ "users", "a/b" }, "/users/a%2Fb");
    try expectSegments(&.{ "users", "a/b", "c" }, "/users/a%2fb/c");
    // The other escapes decode too; '+' is not a space in a path.
    try expectSegments(&.{ "files", "my file+1.txt" }, "/files/my%20file+1.txt");
}

test "path: dot segments, %2e%2e included" {
    try expectSegments(&.{ "a", "c" }, "/a/b/../c");
    try expectSegments(&.{"a"}, "/../a");
    try expectSegments(&.{ "a", "c" }, "/a/b/%2e%2e/c");
    try expectSegments(&.{ "a", "c" }, "/a/b/%2E%2E/c");
    try expectSegments(&.{ "a", "c" }, "/a/b/.%2e/c");
    try expectSegments(&.{ "a", "b" }, "/a/./b/.");
    try expectSegments(&.{ "a", "b" }, "/a/%2e/b");
    try expectSegments(&.{}, "/a/..");
    try expectSegments(&.{}, "/../../..");
    try expectSegments(&.{"a"}, "/a/b/..");
    // Not dot segments: dots inside a name, and three dots.
    try expectSegments(&.{ "a", "...", ".x", "x." }, "/a/.../.x/x.");
}

test "path: bad percent-encoding and invalid UTF-8 are InvalidRequest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "/a%zz", "/a%-0", "/a%+1", "/a%", "/a%4", "/%4/b", "/a/%ff", "/a/%c3%28", "/%e2%82", "a/b", "" }) |raw| {
        testing.expectError(error.InvalidRequest, normalize(arena, raw)) catch |err| {
            std.debug.print("path {s}\n", .{raw});
            return err;
        };
    }
    var out: [8]u8 = undefined;
    try testing.expectError(error.InvalidRequest, percentDecode(&out, "%1"));
    try testing.expectEqualStrings("é", try percentDecode(&out, "%C3%A9"));
    try expectSegments(&.{"café"}, "/caf%c3%a9");
}

test "path: case matters, a trailing slash does not, // matches nothing" {
    try expectSegments(&.{ "Users", "ID" }, "/Users/ID");
    try expectSegments(&.{ "a", "b" }, "/a/b/");
    try expectSegments(&.{}, "/");
    try expectSegments(&.{"a"}, "/a/./");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "//", "/a//b", "//a", "/a/b//", "/a/%2e//b" }) |raw| {
        const n = try normalize(arena, raw);
        testing.expect(n.empty_segment) catch |err| {
            std.debug.print("path {s}\n", .{raw});
            return err;
        };
    }
    // `..` after an empty segment removes it, as RFC 3986 says.
    try expectSegments(&.{ "a", "b" }, "/a//../b");
}

test "path: the segments lie in one buffer, so the rest is one slice" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const n = try normalize(arena_state.allocator(), "/files/x/../docs/a%2Fb/c.txt");
    try testing.expectEqual(4, n.segments.len);
    try testing.expectEqualStrings("files/docs/a/b/c.txt", n.rest(0));
    try testing.expectEqualStrings("docs/a/b/c.txt", n.rest(1));
    try testing.expectEqualStrings("c.txt", n.rest(3));
}

test "path: the path and query of origin and absolute targets" {
    const rows = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "/users/42?full=1", "/users/42", "full=1" },
        .{ "/users", "/users", "" },
        .{ "/a?", "/a", "" },
        .{ "/a?x=1#top", "/a", "x=1" },
        .{ "/a#top", "/a", "" },
        .{ "http://example.com/a/b?x=1", "/a/b", "x=1" },
        .{ "HTTPS://example.com:8443/a", "/a", "" },
        .{ "http://example.com", "/", "" },
        .{ "http://example.com?x=1", "/", "x=1" },
        .{ "http://user@example.com:80/a%2Fb", "/a%2Fb", "" },
        .{ "*", "*", "" },
    };
    for (rows) |row| {
        const t = splitTarget(row[0]);
        testing.expectEqualStrings(row[1], t.path) catch |err| {
            std.debug.print("target {s}\n", .{row[0]});
            return err;
        };
        try testing.expectEqualStrings(row[2], t.query);
    }
}
