//! The cookies of a request as pairs (RFC 6265 §5.4): the `name=value`
//! pieces of its `Cookie` fields, separated by ';', in order. A value loses
//! the quotes around it; a piece without '=' is skipped; names are
//! case-sensitive, and nothing is percent-decoded. Of two cookies with one
//! name the first wins: the mapping takes the first.
const std = @import("std");
const h1 = @import("../h1/head.zig");
const Pair = @import("strings.zig").Pair;

/// The cookies of `fields`, in order, as `ctx.request.cookie` reads them.
pub fn parse(arena: std.mem.Allocator, fields: []const h1.Field) std.mem.Allocator.Error![]const Pair {
    var count: usize = 0;
    for (fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "cookie")) continue;
        var pieces = std.mem.splitScalar(u8, f.value, ';');
        while (pieces.next()) |piece| {
            if (std.mem.findScalar(u8, piece, '=') != null) count += 1;
        }
    }
    const pairs = try arena.alloc(Pair, count);
    var i: usize = 0;
    for (fields) |f| {
        if (!std.ascii.eqlIgnoreCase(f.name, "cookie")) continue;
        var pieces = std.mem.splitScalar(u8, f.value, ';');
        while (pieces.next()) |piece| {
            const item = std.mem.trim(u8, piece, " \t");
            const eq = std.mem.findScalar(u8, item, '=') orelse continue;
            var value = std.mem.trim(u8, item[eq + 1 ..], " \t");
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
            pairs[i] = .{ .name = std.mem.trim(u8, item[0..eq], " \t"), .value = value };
            i += 1;
        }
    }
    return pairs;
}

test "cookies: every piece of every Cookie field, in order, quotes dropped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const pairs = try parse(arena_state.allocator(), &.{
        .{ .name = "Cookie", .value = "theme=dark; session=\"abc 1\";flag; empty=" },
        .{ .name = "x-other", .value = "a=b" },
        .{ .name = "cookie", .value = " session = other ;Lang=en" },
    });
    try std.testing.expectEqual(5, pairs.len);
    for ([_][2][]const u8{
        .{ "theme", "dark" },
        .{ "session", "abc 1" },
        .{ "empty", "" },
        .{ "session", "other" },
        .{ "Lang", "en" },
    }, pairs) |want, got| {
        try std.testing.expectEqualStrings(want[0], got.name);
        try std.testing.expectEqualStrings(want[1], got.value);
    }
}
