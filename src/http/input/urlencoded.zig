//! `application/x-www-form-urlencoded`, the format of query strings and of
//! forms: pairs split on '&' and on the first '=', '+'
//! a space, `%HH` the byte HH. Stricter than std's decoder, which turns
//! `%-0` into NUL: a '%' comes with exactly two hex digits, and every name
//! and value is valid UTF-8 once decoded; else the request is bad (400).
const std = @import("std");
const Pair = @import("strings.zig").Pair;

pub const Error = error{ InvalidRequest, OutOfMemory };

/// The pairs of `text` (a query without its '?', or a form body), decoded
/// into `arena` where they need it. Empty pieces (`a=1&&b=2`, a trailing
/// '&') are skipped; a piece without '=' has an empty value. More than
/// `max_pairs` pairs is `InvalidRequest`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, max_pairs: u32) Error![]const Pair {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '&');
    while (it.next()) |piece| {
        if (piece.len > 0) count += 1;
    }
    if (count > max_pairs) return error.InvalidRequest;
    const pairs = try arena.alloc(Pair, count);
    var i: usize = 0;
    it.reset();
    while (it.next()) |piece| {
        if (piece.len == 0) continue;
        const eq = std.mem.findScalar(u8, piece, '=');
        pairs[i] = .{
            .name = try decode(arena, piece[0 .. eq orelse piece.len]),
            .value = if (eq) |at| try decode(arena, piece[at + 1 ..]) else "",
        };
        i += 1;
    }
    return pairs;
}

/// `raw` decoded: '+' is a space and `%HH` the byte HH. Without either,
/// `raw` itself.
pub fn decode(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (std.mem.findAny(u8, raw, "%+") == null) {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidRequest;
        return raw;
    }
    const out = try arena.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (n += 1) {
        switch (raw[i]) {
            '+' => {
                out[n] = ' ';
                i += 1;
            },
            '%' => {
                if (raw.len - i < 3) return error.InvalidRequest;
                const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return error.InvalidRequest;
                const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return error.InvalidRequest;
                out[n] = hi << 4 | lo;
                i += 3;
            },
            else => |c| {
                out[n] = c;
                i += 1;
            },
        }
    }
    if (!std.unicode.utf8ValidateSlice(out[0..n])) return error.InvalidRequest;
    return out[0..n];
}

const testing = std.testing;

test "query: + is a space, %HH a byte, and the pieces split on & and the first =" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pairs = try parse(arena, "q=++Milk+&a%2Bb=1%2B1&&eq=a=b&flag&caf%C3%A9=%E2%82%AC&", 100);
    try testing.expectEqual(5, pairs.len);
    for ([_][2][]const u8{
        .{ "q", "  Milk " },
        .{ "a+b", "1+1" },
        .{ "eq", "a=b" },
        .{ "flag", "" },
        .{ "café", "€" },
    }, pairs) |want, got| {
        try testing.expectEqualStrings(want[0], got.name);
        try testing.expectEqualStrings(want[1], got.value);
    }
    try testing.expectEqual(0, (try parse(arena, "", 100)).len);
    try testing.expectEqual(0, (try parse(arena, "&&", 0)).len);
    // Nothing to decode: the text itself, not a copy.
    const plain: []const u8 = "page=2";
    try testing.expectEqual(plain.ptr, (try parse(arena, plain, 1))[0].name.ptr);
}

test "query: bad percent-encoding, invalid UTF-8 and too many pairs are 400" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "a=%", "a=%4", "a=%zz", "a=%-0", "a=%+1", "%G0=1", "a=%FF", "a=%C3", "a=\xff", "\xc3=1", "a=%ED%A0%80" }) |text| {
        testing.expectError(error.InvalidRequest, parse(arena, text, 100)) catch |err| {
            std.debug.print("{s}\n", .{text});
            return err;
        };
    }
    // %00 is a byte like any other; UTF-8 has it.
    try testing.expectEqualStrings("a\x00b", (try parse(arena, "x=a%00b", 1))[0].value);
    try testing.expectEqual(3, (try parse(arena, "a=1&b=2&c=3", 3)).len);
    try testing.expectError(error.InvalidRequest, parse(arena, "a=1&b=2&c=3&d=4", 3));
}
