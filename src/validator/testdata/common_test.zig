//! The common rules on every field type they accept: `notEmpty` and `empty`
//! on each string kind and on lists of every item kind, `equals` and
//! `notEquals` on integers, floats, bools, enums and strings, `oneOf` and
//! `noneOf` on strings, enums and integers, optionals and list items.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const math = std.math;
const testing = std.testing;

const code = "validation.not_empty";
const message = "must not be empty";

const Role = enum { admin, user };

test "notEmpty has its documented code and default message" {
    try h.expectRule(v.notEmpty, code, message);
}

test "notEmpty counts the bytes of every string kind without decoding them" {
    inline for (.{ []const u8, [:0]const u8 }) |S| {
        try h.expectFail(S, v.notEmpty, "", code, message);
        try h.expectPass(S, v.notEmpty, "a");
        try h.expectPass(S, v.notEmpty, " "); // whitespace-only is not empty
        try h.expectPass(S, v.notEmpty, "\x00");
        try h.expectPass(S, v.notEmpty, "\xff"); // invalid UTF-8 is still one byte
    }
    var no_bytes: [0]u8 = .{};
    var one_byte = [_]u8{'x'};
    try h.expectFail([]u8, v.notEmpty, &no_bytes, code, message);
    try h.expectPass([]u8, v.notEmpty, &one_byte);
    var no_bytes_z = [_:0]u8{};
    var one_byte_z = [_:0]u8{'x'};
    try h.expectFail([:0]u8, v.notEmpty, &no_bytes_z, code, message);
    try h.expectPass([:0]u8, v.notEmpty, &one_byte_z);
}

test "notEmpty on ?[]const u8 and ??[]const u8: null skips the rule, the empty string is a present value" {
    try h.expectPass(?[]const u8, v.notEmpty, null);
    try h.expectFail(?[]const u8, v.notEmpty, "", code, message);
    try h.expectPass(?[]const u8, v.notEmpty, "a");
    try h.expectPass(??[]const u8, v.notEmpty, null);
    try h.expectPass(??[]const u8, v.notEmpty, @as(?[]const u8, null));
    try h.expectFail(??[]const u8, v.notEmpty, @as(?[]const u8, ""), code, message);
    try h.expectPass(??[]const u8, v.notEmpty, @as(?[]const u8, "a"));
}

test "notEmpty inside each: slices and arrays of strings, null items skipped with their index kept" {
    const Dto = struct {
        names: []const []const u8 = &.{},
        pair: [2][]const u8 = .{ "a", "b" },
        maybe: []const ?[]const u8 = &.{},
        pub const field_rules = .{
            .names = v.each(v.notEmpty),
            .pair = v.each(v.notEmpty),
            .maybe = v.each(v.notEmpty),
        };
    };
    try h.expectValid(&Dto{ .names = &.{ "a", " " }, .maybe = &.{ null, "b" } });
    try h.expectAt(&Dto{ .names = &.{ "a", "" } }, code, message, "names[1]");
    try h.expectAt(&Dto{ .pair = .{ "", "b" } }, code, message, "pair[0]");
    try h.expectAt(&Dto{ .maybe = &.{ null, null, "" } }, code, message, "maybe[2]");
    try h.expectAll(&Dto{ .names = &.{ "", "a", "" }, .pair = .{ "a", "" }, .maybe = &.{ "", null } }, &.{
        .{ .code = code, .field = "names[0]" },
        .{ .code = code, .field = "names[2]" },
        .{ .code = code, .field = "pair[1]" },
        .{ .code = code, .field = "maybe[0]" },
    });
}

test "notEmpty counts the items of a list, null items included" {
    try h.expectFail([]const u32, v.notEmpty, &.{}, code, message);
    try h.expectPass([]const u32, v.notEmpty, &.{0});
    var no_items: [0]u32 = .{};
    var two_items = [_]u32{ 1, 2 };
    try h.expectFail([]u32, v.notEmpty, &no_items, code, message);
    try h.expectPass([]u32, v.notEmpty, &two_items);
    try h.expectFail([]const ?u32, v.notEmpty, &.{}, code, message);
    try h.expectPass([]const ?u32, v.notEmpty, &.{null});
    try h.expectPass([]const []const u8, v.notEmpty, &.{""}); // one item; the item's own rules judge ""
    try h.expectPass([]const Role, v.notEmpty, &.{.user});
    try h.expectFail([]const bool, v.notEmpty, &.{}, code, message);
    try h.expectPass(?[]const u32, v.notEmpty, null);
    try h.expectFail(?[]const u32, v.notEmpty, &.{}, code, message);
}

test "notEmpty on a list runs before the rules of its items" {
    const Dto = struct {
        tags: []const []const u8,
        pub const field_rules = .{ .tags = .{ v.notEmpty, v.each(v.notEmpty) } };
    };
    try h.expectAt(&Dto{ .tags = &.{} }, code, message, "tags");
    try h.expectAt(&Dto{ .tags = &.{ "a", "" } }, code, message, "tags[1]");
    try h.expectValid(&Dto{ .tags = &.{"a"} });
}

const empty_code = "validation.empty";
const empty_message = "must be empty";
const equals_code = "validation.equals";
const not_equals_code = "validation.not_equals";
const finite_code = "validation.finite";
const finite_message = "must be a finite number";

/// The integer and float types every comparison runs on.
const ints = .{ u8, i8, u64, i64, u128, i128, usize };
const floats = .{ f16, f32, f64, f80, f128, c_longdouble };

/// A non-exhaustive enum, one with a single named tag, and one with sparse
/// tag values.
const Open = enum(u8) { a, b, _ };
const OpenOne = enum(u8) { only, _ };
const Sparse = enum(u32) { low = 1, high = 1_000_000 };

fn decimal(comptime prefix: []const u8, comptime n: comptime_int) []const u8 {
    return std.fmt.comptimePrint("{s}{d}", .{ prefix, n });
}

test "empty has its documented code and default message" {
    try h.expectRule(v.empty, empty_code, empty_message);
}

test "empty counts the bytes of every string kind without decoding them" {
    inline for (.{ []const u8, [:0]const u8 }) |S| {
        try h.expectPass(S, v.empty, "");
        inline for (.{ " ", "\t", "\x00", "a", "\u{200b}", "\xff" }) |s| try h.expectFail(S, v.empty, s, empty_code, empty_message);
    }
    var no_bytes: [0]u8 = .{};
    var one_byte = [_]u8{'x'};
    try h.expectPass([]u8, v.empty, &no_bytes);
    try h.expectFail([]u8, v.empty, &one_byte, empty_code, empty_message);
    var no_bytes_z = [_:0]u8{};
    var one_byte_z = [_:0]u8{'x'};
    try h.expectPass([:0]u8, v.empty, &no_bytes_z);
    try h.expectFail([:0]u8, v.empty, &one_byte_z, empty_code, empty_message);
}

test "empty counts the items of a list, null items included" {
    try h.expectPass([]const u32, v.empty, &.{});
    try h.expectFail([]const u32, v.empty, &.{0}, empty_code, empty_message);
    try h.expectFail([]const ?u32, v.empty, &.{null}, empty_code, empty_message);
    try h.expectFail([]const []const u8, v.empty, &.{""}, empty_code, empty_message);
    try h.expectPass([]const Role, v.empty, &.{});
    var no_items: [0]u32 = .{};
    var two_items = [_]u32{ 1, 2 };
    try h.expectPass([]u32, v.empty, &no_items);
    try h.expectFail([]u32, v.empty, &two_items, empty_code, empty_message);
}

test "empty on ?T and ??T skips null, and inside each it checks every item" {
    try h.expectPass(?[]const u8, v.empty, null);
    try h.expectPass(?[]const u8, v.empty, "");
    try h.expectFail(?[]const u8, v.empty, "a", empty_code, empty_message);
    try h.expectPass(??[]const u32, v.empty, @as(?[]const u32, null));
    try h.expectFail(??[]const u32, v.empty, @as(?[]const u32, &.{1}), empty_code, empty_message);
    const Dto = struct {
        notes: []const []const u8 = &.{},
        groups: [2][]const u32 = .{ &.{}, &.{} },
        pub const field_rules = .{ .notes = v.each(v.empty), .groups = v.each(v.empty) };
    };
    try h.expectValid(&Dto{ .notes = &.{ "", "" } });
    try h.expectAt(&Dto{ .notes = &.{ "", "x" } }, empty_code, empty_message, "notes[1]");
    try h.expectAt(&Dto{ .groups = .{ &.{}, &.{1} } }, empty_code, empty_message, "groups[1]");
}

test "equals and notEquals have their documented codes and default messages" {
    try h.expectRule(v.equals(5), equals_code, "must be equal to 5");
    try h.expectRule(v.notEquals(5), not_equals_code, "must not be equal to 5");
    try h.expectRule(v.equals(-0.0), equals_code, "must be equal to 0");
    try h.expectRule(v.equals(0.1), equals_code, "must be equal to 0.1");
    try h.expectRule(v.notEquals(false), not_equals_code, "must not be equal to false");
    try h.expectRule(v.equals(.admin), equals_code, "must be equal to admin");
    try h.expectRule(v.equals("tab\there"), equals_code, "must be equal to tab\\there");
}

test "equals and notEquals on every integer width: minInt and maxInt, typed parameters, exact above 2^53" {
    inline for (ints) |T| {
        const lo = math.minInt(T);
        const hi = math.maxInt(T);
        try h.expectPass(T, v.equals(hi), hi);
        try h.expectFail(T, v.equals(hi), hi - 1, equals_code, comptime decimal("must be equal to ", hi));
        try h.expectPass(T, v.equals(lo), lo);
        try h.expectFail(T, v.equals(lo), lo + 1, equals_code, comptime decimal("must be equal to ", lo));
        try h.expectFail(T, v.notEquals(lo), lo, not_equals_code, comptime decimal("must not be equal to ", lo));
        try h.expectPass(T, v.notEquals(lo), hi);
        try h.expectFail(T, v.notEquals(hi), hi, not_equals_code, comptime decimal("must not be equal to ", hi));
        try h.expectPass(T, v.notEquals(hi), lo);
        // A typed parameter converts to the field type.
        try h.expectPass(T, v.equals(@as(u8, 7)), 7);
        try h.expectFail(T, v.equals(@as(u8, 7)), 8, equals_code, "must be equal to 7");
    }
    // Exact where a double would round: 9007199254740993 is 2^53 + 1.
    try h.expectPass(u64, v.equals(9007199254740993), 9007199254740993);
    try h.expectFail(u64, v.equals(9007199254740993), 9007199254740992, equals_code, "must be equal to 9007199254740993");
    try h.expectFail(u64, v.notEquals(9007199254740993), 9007199254740993, not_equals_code, "must not be equal to 9007199254740993");
    try h.expectPass(u64, v.notEquals(9007199254740993), 9007199254740992);
}

test "equals and notEquals on every float type: -0.0 equals 0, the parameter is rounded to the field type, NaN and infinities report validation.finite" {
    inline for (floats) |F| {
        const tiny = math.floatTrueMin(F);
        const negative_zero = -@as(F, 0.0);
        inline for (.{ math.nan(F), -math.nan(F), math.snan(F), math.inf(F), -math.inf(F) }) |bad| {
            try h.expectFail(F, v.equals(0.5), bad, finite_code, finite_message);
            try h.expectFail(F, v.notEquals(0.5), bad, finite_code, finite_message);
            // IEEE says NaN != 0, but the precondition comes first.
            try h.expectFail(F, v.notEquals(0), bad, finite_code, finite_message);
        }
        try h.expectPass(F, v.equals(0), negative_zero);
        try h.expectPass(F, v.equals(-0.0), 0.0);
        try h.expectFail(F, v.notEquals(0), negative_zero, not_equals_code, "must not be equal to 0");
        try h.expectPass(F, v.notEquals(0), tiny);
        try h.expectFail(F, v.equals(0), tiny, equals_code, "must be equal to 0");
        try h.expectPass(F, v.equals(0.5), 0.5);
        try h.expectFail(F, v.equals(0.5), math.nextAfter(F, 0.5, 1), equals_code, "must be equal to 0.5");
        // An integer parameter is exact in every float type; 0.1 is rounded
        // to the field type, as a decoder rounds the value.
        try h.expectPass(F, v.equals(2), 2);
        try h.expectPass(F, v.equals(0.1), 0.1);
        try h.expectPass(F, v.equals(-math.floatMax(F)), -math.floatMax(F));
    }
    try h.expectFail(f64, v.equals(0.3), @as(f64, 0.1) + @as(f64, 0.2), equals_code, "must be equal to 0.3"); // no epsilon
    try h.expectPass(f64, v.equals(@as(f32, 0.5)), 0.5);
    try h.expectFail(f64, v.equals(1e300), 1e299, equals_code, "must be equal to 1e300");
    try h.expectFail(f32, v.equals(1e-7), 0, equals_code, "must be equal to 1e-7");
    try h.expectFail(f32, v.equals(0.1), math.nextAfter(f32, 0.1, 1), equals_code, "must be equal to 0.1");
}

test "equals and notEquals on bool and enums: exhaustive, non-exhaustive with an unnamed value, a single named tag, sparse values" {
    try h.expectPass(bool, v.equals(true), true);
    try h.expectFail(bool, v.equals(true), false, equals_code, "must be equal to true");
    try h.expectFail(bool, v.notEquals(false), false, not_equals_code, "must not be equal to false");
    try h.expectPass(bool, v.notEquals(false), true);
    try h.expectPass(Role, v.equals(.admin), .admin);
    try h.expectFail(Role, v.equals(.admin), .user, equals_code, "must be equal to admin");
    try h.expectPass(Role, v.equals(Role.user), .user); // an enum value as the parameter
    try h.expectFail(Role, v.notEquals(.user), .user, not_equals_code, "must not be equal to user");
    try h.expectPass(Open, v.equals(.b), .b);
    // An unnamed value never equals a tag, so it always passes notEquals.
    try h.expectFail(Open, v.equals(.b), @fromBackingInt(200), equals_code, "must be equal to b");
    try h.expectPass(Open, v.notEquals(.a), @fromBackingInt(200));
    try h.expectPass(OpenOne, v.equals(.only), .only);
    try h.expectFail(OpenOne, v.equals(.only), @fromBackingInt(9), equals_code, "must be equal to only");
    try h.expectPass(OpenOne, v.notEquals(.only), @fromBackingInt(9));
    try h.expectPass(Sparse, v.equals(.high), .high);
    try h.expectFail(Sparse, v.equals(.high), .low, equals_code, "must be equal to high");
    try h.expectFail(Sparse, v.notEquals(.low), .low, not_equals_code, "must not be equal to low");
}

test "equals and notEquals on every string kind compare bytes exactly; the message shows the parameter escaped" {
    inline for (.{ []const u8, [:0]const u8 }) |S| {
        try h.expectPass(S, v.equals("admin"), "admin");
        inline for (.{ "Admin", "admin ", " admin", "", "admin\x00", "adm" }) |s| try h.expectFail(S, v.equals("admin"), s, equals_code, "must be equal to admin");
        try h.expectFail(S, v.notEquals("root"), "root", not_equals_code, "must not be equal to root");
        // The empty string is a present value: notEquals passes it (add v.notEmpty to reject it).
        try h.expectPass(S, v.notEquals("root"), "");
        try h.expectPass(S, v.notEquals("root"), "\xff");
    }
    var mutable = "abc".*;
    try h.expectPass([]u8, v.equals("abc"), &mutable);
    var mutable_z = [_:0]u8{ 'a', 'b', 'd' };
    try h.expectFail([:0]u8, v.equals("abc"), &mutable_z, equals_code, "must be equal to abc");
    try h.expectFail([]const u8, v.equals("\u{e9}"), "e\u{301}", equals_code, "must be equal to \u{e9}"); // no Unicode normalization
    try h.expectPass([]const u8, v.equals(@as([]const u8, "x")), "x"); // a []const u8 parameter
    try h.expectFail([]const u8, v.equals("tab\there"), "tab", equals_code, "must be equal to tab\\there");
    try h.expectFail([]const u8, v.equals("say \"hi\""), "hi", equals_code, "must be equal to say \\\"hi\\\"");
    try h.expectFail([]const u8, v.notEquals("a\u{2028}b"), "a\u{2028}b", not_equals_code, "must not be equal to a\\xe2\\x80\\xa8b");
}

test "equals and notEquals on ?T and ??T: null skips the rule, so equals(true) on ?bool passes null" {
    try h.expectPass(?bool, v.equals(true), null);
    try h.expectFail(?bool, v.equals(true), false, equals_code, "must be equal to true");
    try h.expectPass(?bool, v.equals(true), true);
    try h.expectPass(??u8, v.equals(3), null);
    try h.expectPass(??u8, v.equals(3), @as(?u8, null));
    try h.expectFail(??u8, v.equals(3), @as(?u8, 4), equals_code, "must be equal to 3");
    try h.expectPass(?f64, v.notEquals(0), null);
    try h.expectFail(?f64, v.notEquals(0), math.nan(f64), finite_code, finite_message);
    try h.expectPass(?Role, v.notEquals(.admin), null);
    try h.expectFail(?Role, v.notEquals(.admin), .admin, not_equals_code, "must not be equal to admin");
    try h.expectFail(?[]const u8, v.equals("a"), "", equals_code, "must be equal to a");
    try h.expectPass(??[]const u8, v.notEquals("root"), @as(?[]const u8, null));
}

test "equals and notEquals inside each: arrays, slices, optional items and nested lists" {
    const Dto = struct {
        flags: [3]bool = .{ true, true, true },
        names: []const ?[]const u8 = &.{},
        grid: [2][2]u8 = .{ .{ 1, 1 }, .{ 1, 1 } },
        pub const field_rules = .{
            .flags = v.each(v.equals(true)),
            .names = v.each(v.notEquals("root")),
            .grid = v.each(v.each(v.equals(1))),
        };
    };
    try h.expectValid(&Dto{ .names = &.{ null, "alice" } });
    try h.expectAt(&Dto{ .flags = .{ true, false, true } }, equals_code, "must be equal to true", "flags[1]");
    try h.expectAt(&Dto{ .names = &.{ null, "a", "root" } }, not_equals_code, "must not be equal to root", "names[2]");
    try h.expectAt(&Dto{ .grid = .{ .{ 1, 1 }, .{ 1, 2 } } }, equals_code, "must be equal to 1", "grid[1][1]");
    try h.expectAll(&Dto{ .flags = .{ false, true, false }, .names = &.{ "root", null } }, &.{
        .{ .code = equals_code, .field = "flags[0]" },
        .{ .code = equals_code, .field = "flags[2]" },
        .{ .code = not_equals_code, .field = "names[0]" },
    });
}

test "equals and notEquals keep a default message of exactly 512 bytes and fall back above it" {
    // "must be equal to " is 17 bytes, "must not be equal to " 21.
    const fits = &@as([495]u8, @splat('x'));
    const over = &@as([496]u8, @splat('x'));
    try testing.expectEqual(512, v.equals(fits).message.len);
    try h.expectFail([]const u8, v.equals(fits), "y", equals_code, "must be equal to " ++ fits);
    try h.expectFail([]const u8, v.equals(over), "y", equals_code, "must be equal to the expected value");
    try h.expectPass([]const u8, v.equals(over), over);
    const fits_not = &@as([491]u8, @splat('x'));
    const over_not = &@as([492]u8, @splat('x'));
    try testing.expectEqual(512, v.notEquals(fits_not).message.len);
    try h.expectFail([]const u8, v.notEquals(fits_not), fits_not, not_equals_code, "must not be equal to " ++ fits_not);
    try h.expectFail([]const u8, v.notEquals(over_not), over_not, not_equals_code, "must not be equal to the forbidden value");
    try h.expectPass([]const u8, v.notEquals(over_not), "y");
    // The parameter counts as the message shows it: a quote is escaped to two bytes.
    const quotes_fit = &@as([247]u8, @splat('"'));
    const quotes_over = &@as([248]u8, @splat('"'));
    try testing.expectEqual(511, v.equals(quotes_fit).message.len);
    try h.expectFail([]const u8, v.equals(quotes_over), "y", equals_code, "must be equal to the expected value");
}

const one_of_code = "validation.one_of";
const none_of_code = "validation.none_of";

test "oneOf and noneOf have their documented codes and default messages, with one value and with many" {
    try h.expectRule(v.oneOf(.{ "a", "b" }), one_of_code, "must be one of: a, b");
    try h.expectRule(v.oneOf(.{.admin}), one_of_code, "must be admin");
    try h.expectRule(v.noneOf(.{ "admin", "root" }), none_of_code, "must not be one of: admin, root");
    try h.expectRule(v.noneOf(.{"root"}), none_of_code, "must not be root");
    try h.expectRule(v.oneOf(.{ "", "x" }), one_of_code, "must be one of: \"\", x");
    try h.expectRule(v.oneOf(.{"\u{2028}"}), one_of_code, "must be \\xe2\\x80\\xa8");
    try h.expectRule(v.oneOf([_]u8{ 1, 2, 3 }), one_of_code, "must be one of: 1, 2, 3");
}

test "oneOf on every string kind compares bytes exactly; the list may be a tuple or an array, and may hold \"\"" {
    const rule = v.oneOf(.{ "a", "b" });
    inline for (.{ []const u8, [:0]const u8 }) |S| {
        try h.expectPass(S, rule, "a");
        try h.expectPass(S, rule, "b");
        inline for (.{ "c", "A", "", "a ", " a", "ab" }) |s| try h.expectFail(S, rule, s, one_of_code, "must be one of: a, b");
    }
    var mutable = "b".*;
    try h.expectPass([]u8, rule, &mutable);
    var mutable_z = [_:0]u8{'z'};
    try h.expectFail([:0]u8, rule, &mutable_z, one_of_code, "must be one of: a, b");
    try h.expectPass([]const u8, v.oneOf(.{ "", "a" }), "");
    try h.expectFail([]const u8, v.oneOf(.{ "", "a" }), "b", one_of_code, "must be one of: \"\", a");
    try h.expectFail([]const u8, v.oneOf(.{"caf\u{e9}"}), "cafe\u{301}", one_of_code, "must be caf\u{e9}"); // no Unicode normalization
    const countries = [_][]const u8{ "DE", "FR", "US" };
    try h.expectPass([]const u8, v.oneOf(countries), "FR");
    try h.expectFail([]const u8, v.oneOf(countries), "XX", one_of_code, "must be one of: DE, FR, US");
    try h.expectPass([]const u8, v.oneOf(.{ @as([]const u8, "x"), "y" }), "x");
}

test "noneOf on strings matches exactly: no prefixes, case folding or look-alike characters" {
    const rule = v.noneOf(.{ "admin", "root", "system" });
    const text = "must not be one of: admin, root, system";
    try h.expectFail([]const u8, rule, "root", none_of_code, text);
    try h.expectFail([:0]const u8, rule, "admin", none_of_code, text);
    // The empty string is not listed, so it passes: add v.notEmpty to reject it.
    inline for (.{ "alice", "Admin", "", "ad", "roots", "r\u{43e}\u{43e}t" }) |s| try h.expectPass([]const u8, rule, s);
    try h.expectFail([]const u8, v.noneOf(.{"root"}), "root", none_of_code, "must not be root");
}

test "oneOf and noneOf on enums: exhaustive, non-exhaustive with an unnamed value, every tag listed, sparse values" {
    try h.expectPass(Role, v.oneOf(.{.admin}), .admin);
    try h.expectFail(Role, v.oneOf(.{.admin}), .user, one_of_code, "must be admin");
    try h.expectPass(Role, v.oneOf(.{ .admin, .user }), .user); // every tag: the rule pins the set
    try h.expectPass(Role, v.oneOf(.{ Role.admin, Role.user }), .admin); // enum values as the list
    try h.expectPass(Role, v.oneOf([_]Role{.user}), .user); // an array of the field's enum
    try h.expectFail(Role, v.noneOf(.{.user}), .user, none_of_code, "must not be user");
    try h.expectPass(Role, v.noneOf(.{.user}), .admin);
    try h.expectPass(Open, v.oneOf(.{ .a, .b }), .b);
    try h.expectFail(Open, v.oneOf(.{ .a, .b }), @fromBackingInt(9), one_of_code, "must be one of: a, b");
    // A non-exhaustive enum may list every named tag in noneOf: its unnamed values pass.
    try h.expectPass(Open, v.noneOf(.{ .a, .b }), @fromBackingInt(77));
    try h.expectFail(Open, v.noneOf(.{ .a, .b }), .a, none_of_code, "must not be one of: a, b");
    try h.expectPass(OpenOne, v.noneOf(.{.only}), @fromBackingInt(1));
    try h.expectPass(Sparse, v.oneOf(.{.high}), .high);
    try h.expectFail(Sparse, v.oneOf(.{.high}), .low, one_of_code, "must be high");
}

test "oneOf and noneOf on integers of every width: minInt and maxInt, typed values, exact above 2^53, a tiny type" {
    inline for (ints) |T| {
        const lo = math.minInt(T);
        const hi = math.maxInt(T);
        const ends = v.oneOf(.{ lo, hi });
        const ends_message = comptime std.fmt.comptimePrint("must be one of: {d}, {d}", .{ lo, hi });
        try h.expectPass(T, ends, lo);
        try h.expectPass(T, ends, hi);
        try h.expectFail(T, ends, lo + 1, one_of_code, ends_message);
        const not_ends = v.noneOf(.{ lo, hi });
        try h.expectFail(T, not_ends, hi, none_of_code, comptime std.fmt.comptimePrint("must not be one of: {d}, {d}", .{ lo, hi }));
        try h.expectPass(T, not_ends, hi - 1);
        try h.expectPass(T, v.oneOf(.{ @as(u8, 7), 9 }), 7);
    }
    try h.expectPass(u64, v.oneOf(.{9007199254740993}), 9007199254740993);
    try h.expectFail(u64, v.oneOf(.{9007199254740993}), 9007199254740992, one_of_code, "must be 9007199254740993");
    try h.expectPass(u64, v.oneOf([_]u64{ math.maxInt(u64), 0 }), math.maxInt(u64));
    // noneOf may leave one value of a tiny type; oneOf may list every value.
    try h.expectPass(u1, v.noneOf(.{0}), 1);
    try h.expectFail(u1, v.noneOf(.{0}), 0, none_of_code, "must not be 0");
    try h.expectPass(u1, v.oneOf(.{ 0, 1 }), 1);
}

test "oneOf and noneOf on ?T and ??T skip null, and inside each they check every item" {
    try h.expectPass(?Role, v.oneOf(.{.admin}), null);
    try h.expectFail(?Role, v.oneOf(.{.admin}), .user, one_of_code, "must be admin");
    try h.expectPass(??[]const u8, v.noneOf(.{"root"}), @as(?[]const u8, null));
    try h.expectFail(??[]const u8, v.noneOf(.{"root"}), @as(?[]const u8, "root"), none_of_code, "must not be root");
    try h.expectPass(?u32, v.oneOf(.{ 1, 2 }), null);
    const Dto = struct {
        tags: []const []const u8 = &.{},
        roles: [2]Role = .{ .admin, .admin },
        codes: []const ?u16 = &.{},
        pub const field_rules = .{
            .tags = v.each(v.oneOf(.{ "red", "green" })),
            .roles = v.each(v.noneOf(.{.user})),
            .codes = v.each(v.oneOf([_]u16{ 200, 404 })),
        };
    };
    try h.expectValid(&Dto{ .tags = &.{ "red", "green" }, .codes = &.{ null, 404 } });
    try h.expectAt(&Dto{ .tags = &.{ "red", "blue" } }, one_of_code, "must be one of: red, green", "tags[1]");
    try h.expectAt(&Dto{ .roles = .{ .admin, .user } }, none_of_code, "must not be user", "roles[1]");
    try h.expectAt(&Dto{ .codes = &.{ null, 500 } }, one_of_code, "must be one of: 200, 404", "codes[1]");
    try h.expectAll(&Dto{ .tags = &.{"x"}, .roles = .{ .user, .user } }, &.{
        .{ .code = one_of_code, .field = "tags[0]" },
        .{ .code = none_of_code, .field = "roles[0]" },
        .{ .code = none_of_code, .field = "roles[1]" },
    });
}

test "oneOf / noneOf: a list whose default message would exceed 512 bytes falls back" {
    // "must be one of: " is 16 bytes and ", " 2: two values of 247 bytes make 512.
    const a = &@as([247]u8, @splat('a'));
    const b = &@as([247]u8, @splat('b'));
    const b_over = &@as([248]u8, @splat('b'));
    try testing.expectEqual(512, v.oneOf(.{ a, b }).message.len);
    try h.expectFail([]const u8, v.oneOf(.{ a, b }), "z", one_of_code, "must be one of: " ++ a ++ ", " ++ b);
    try h.expectFail([]const u8, v.oneOf(.{ a, b_over }), "z", one_of_code, "must be one of the allowed values");
    try h.expectPass([]const u8, v.oneOf(.{ a, b_over }), b_over);
    // "must not be one of: " is 20 bytes.
    const c = &@as([245]u8, @splat('c'));
    const d = &@as([245]u8, @splat('d'));
    const d_over = &@as([246]u8, @splat('d'));
    try testing.expectEqual(512, v.noneOf(.{ c, d }).message.len);
    try h.expectFail([]const u8, v.noneOf(.{ c, d }), c, none_of_code, "must not be one of: " ++ c ++ ", " ++ d);
    try h.expectFail([]const u8, v.noneOf(.{ c, d_over }), d_over, none_of_code, "must not be one of the forbidden values");
    // Many short values fall back the same way: a message never cuts a list.
    const many = comptime blk: {
        var out: [50][]const u8 = undefined;
        for (&out, 0..) |*slot, i| slot.* = std.fmt.comptimePrint("value_{d:0>3}", .{i});
        break :blk out;
    };
    try h.expectPass([]const u8, v.oneOf(many), "value_049");
    try h.expectFail([]const u8, v.oneOf(many), "value_050", one_of_code, "must be one of the allowed values");
    try h.expectFail([]const u8, v.noneOf(many), "value_000", none_of_code, "must not be one of the forbidden values");
    // One value: "must be " is 8 bytes.
    const one = &@as([504]u8, @splat('s'));
    const one_over = &@as([505]u8, @splat('s'));
    try h.expectFail([]const u8, v.oneOf(.{one}), "z", one_of_code, "must be " ++ one);
    try h.expectFail([]const u8, v.oneOf(.{one_over}), "z", one_of_code, "must be one of the allowed values");
}

test "oneOf and noneOf take lists of thousands of values" {
    const codes = comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var out: [2000][]const u8 = undefined;
        for (&out, 0..) |*slot, i| slot.* = std.fmt.comptimePrint("SKU-{d:0>6}", .{i});
        break :blk out;
    };
    try h.expectPass([]const u8, v.oneOf(codes), "SKU-001999");
    try h.expectFail([]const u8, v.oneOf(codes), "SKU-002000", one_of_code, "must be one of the allowed values");
    const first = codes[0..1400].*;
    try h.expectFail([]const u8, v.noneOf(first), "SKU-001399", none_of_code, "must not be one of the forbidden values");
    try h.expectPass([]const u8, v.noneOf(first), "SKU-001400");
}
