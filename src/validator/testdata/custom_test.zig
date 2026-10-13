//! `v.custom` on every parameter form its predicate may take: the field type
//! itself, any type the field type coerces to, `*const` of either, and an
//! `inline fn`; on scalar, string, struct, union and optional fields, inside
//! `each`, several on one field; code and message limits; and predicates as
//! a service writes them.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

fn isEven(n: u32) bool {
    return n % 2 == 0;
}
fn isEvenPtr(n: *const u32) bool {
    return n.* % 2 == 0;
}
fn isEvenWide(n: u64) bool {
    return n % 2 == 0;
}
fn isEvenSigned(n: i64) bool {
    return @rem(n, 2) == 0;
}
fn isEvenWidePtr(n: *const u64) bool {
    return n.* % 2 == 0;
}
fn isEvenOptional(n: ?u32) bool {
    return (n orelse 1) % 2 == 0;
}
fn isEvenErrorUnion(n: anyerror!u32) bool {
    const value = n catch return false;
    return value % 2 == 0;
}
inline fn isEvenInline(n: u32) bool {
    return n % 2 == 0;
}
fn isWhole(x: f64) bool {
    return @round(x) == x;
}
fn isHandle(s: []const u8) bool {
    return s.len > 1 and s[0] == '@';
}
fn isHandleZ(s: [:0]const u8) bool {
    return s.len > 1 and s[0] == '@';
}
fn isHandlePtr(s: *const []const u8) bool {
    return s.len > 1 and s.*[0] == '@';
}

const even = "numbers.even";
const even_message = "must be even";
const handle = "users.handle";
const handle_message = "must start with @";

test "custom carries its own code and message" {
    try h.expectRule(v.custom(even, even_message, isEven), even, even_message);
}

test "custom takes the field type by value or by *const pointer" {
    try h.expectPass(u32, v.custom(even, even_message, isEven), 4);
    try h.expectFail(u32, v.custom(even, even_message, isEven), 3, even, even_message);
    try h.expectPass(u32, v.custom(even, even_message, isEvenPtr), 4);
    try h.expectFail(u32, v.custom(even, even_message, isEvenPtr), 3, even, even_message);
    try h.expectPass(u32, v.custom(even, even_message, isEvenInline), 4);
    try h.expectFail(u32, v.custom(even, even_message, isEvenInline), 3, even, even_message);
}

test "custom takes a wider integer or float, ?P, E!P and *const of a wider type" {
    inline for (.{ u8, u16, u32 }) |T| {
        try h.expectFail(T, v.custom(even, even_message, isEvenWide), 3, even, even_message);
        try h.expectFail(T, v.custom(even, even_message, isEvenSigned), 3, even, even_message);
        try h.expectPass(T, v.custom(even, even_message, isEvenWidePtr), 4);
    }
    inline for (.{ i8, i16, i32, i64 }) |T| {
        try h.expectFail(T, v.custom(even, even_message, isEvenSigned), -3, even, even_message);
        try h.expectPass(T, v.custom(even, even_message, isEvenSigned), -4);
    }
    try h.expectFail(u8, v.custom(even, even_message, isEven), 3, even, even_message);
    inline for (.{ f16, f32, f64 }) |F| {
        try h.expectFail(F, v.custom("numbers.whole", "must be whole", isWhole), 2.5, "numbers.whole", "must be whole");
        try h.expectPass(F, v.custom("numbers.whole", "must be whole", isWhole), 2);
    }
    try h.expectFail(u32, v.custom(even, even_message, isEvenOptional), 3, even, even_message);
    try h.expectPass(u32, v.custom(even, even_message, isEvenOptional), 4);
    try h.expectFail(u32, v.custom(even, even_message, isEvenErrorUnion), 3, even, even_message);
    try h.expectPass(u32, v.custom(even, even_message, isEvenErrorUnion), 4);
}

test "custom takes []const u8 for every string kind" {
    inline for (.{ []const u8, [:0]const u8 }) |S| {
        try h.expectFail(S, v.custom(handle, handle_message, isHandle), "bob", handle, handle_message);
        try h.expectPass(S, v.custom(handle, handle_message, isHandle), "@bob");
    }
    var mutable = "bob".*;
    try h.expectFail([]u8, v.custom(handle, handle_message, isHandle), &mutable, handle, handle_message);
    var mutable_z = [_:0]u8{ 'b', 'o', 'b' };
    try h.expectFail([:0]u8, v.custom(handle, handle_message, isHandle), &mutable_z, handle, handle_message);
    try h.expectFail([:0]u8, v.custom(handle, handle_message, isHandleZ), &mutable_z, handle, handle_message);
    try h.expectPass([]const u8, v.custom(handle, handle_message, isHandlePtr), "@bob");
    try h.expectFail([]const u8, v.custom(handle, handle_message, isHandlePtr), "", handle, handle_message);
}

const Item = struct {
    sku: []const u8,
    qty: u32,
};

fn hasStock(item: *const Item) bool {
    return item.qty > 0;
}
fn hasLongSku(item: Item) bool {
    return item.sku.len == 8;
}
fn allInStock(items: []const Item) bool {
    for (items) |item| {
        if (item.qty == 0) return false;
    }
    return true;
}

test "custom on struct, union and optional fields: null skips the predicate" {
    const stock = v.custom("orders.out_of_stock", "must be in stock", hasStock);
    try h.expectFail(Item, stock, .{ .sku = "ABCDEFGH", .qty = 0 }, "orders.out_of_stock", "must be in stock");
    try h.expectPass(Item, stock, .{ .sku = "ABCDEFGH", .qty = 1 });
    try h.expectPass(?Item, stock, null);
    try h.expectFail(?Item, v.custom("orders.bad_sku", "must have an 8-byte sku", hasLongSku), .{ .sku = "X", .qty = 1 }, "orders.bad_sku", "must have an 8-byte sku");
    const Choice = union(enum) { id: u32, name: []const u8 };
    const by_id = v.custom("lookups.by_id", "must be an id", struct {
        fn isId(c: Choice) bool {
            return c == .id;
        }
    }.isId);
    try h.expectFail(Choice, by_id, .{ .name = "x" }, "lookups.by_id", "must be an id");
    try h.expectPass(Choice, by_id, .{ .id = 7 });
    try h.expectPass(??u32, v.custom(even, even_message, isEven), @as(?u32, null));
    try h.expectFail(??u32, v.custom(even, even_message, isEven), @as(?u32, 5), even, even_message);
}

test "custom takes []const T for a []T field" {
    var cart = [_]Item{ .{ .sku = "A", .qty = 1 }, .{ .sku = "B", .qty = 0 } };
    const all = v.custom("orders.all_in_stock", "must all be in stock", allInStock);
    try h.expectFail([]Item, all, &cart, "orders.all_in_stock", "must all be in stock");
    cart[1].qty = 2;
    try h.expectPass([]Item, all, &cart);
}

fn hasBytes(s: []allowzero const u8) bool {
    return s.len > 0;
}
fn hasVolatileBytes(s: []volatile u8) bool {
    return s.len > 0;
}

test "custom on []volatile u8 and []allowzero const u8 takes a parameter with the same attributes" {
    var none: [0]u8 = .{};
    var one = [_]u8{'a'};
    const volatile_bytes = v.custom("t.bytes", "must have bytes", hasVolatileBytes);
    try h.expectFail([]volatile u8, volatile_bytes, &none, "t.bytes", "must have bytes");
    try h.expectPass([]volatile u8, volatile_bytes, &one);
    const allowzero_bytes = v.custom("t.bytes", "must have bytes", hasBytes);
    try h.expectFail([]allowzero const u8, allowzero_bytes, "", "t.bytes", "must have bytes");
    try h.expectPass([]allowzero const u8, allowzero_bytes, "a");
}

test "custom inside each: the item type is what the predicate receives; null items are skipped" {
    const Dto = struct {
        nums: []const u32 = &.{},
        items: []const ?Item = &.{},
        pub const field_rules = .{
            .nums = v.each(.{ v.custom(even, even_message, isEven), v.custom("numbers.even_ptr", "must be even too", isEvenPtr) }),
            .items = v.each(v.custom("orders.out_of_stock", "must be in stock", hasStock)),
        };
    };
    try h.expectValid(&Dto{ .nums = &.{ 2, 4 }, .items = &.{ null, .{ .sku = "A", .qty = 1 } } });
    try h.expectAt(&Dto{ .nums = &.{ 2, 5 } }, even, even_message, "nums[1]");
    try h.expectAt(&Dto{ .items = &.{ null, .{ .sku = "A", .qty = 0 } } }, "orders.out_of_stock", "must be in stock", "items[1]");
    try h.expectAll(&Dto{ .nums = &.{ 1, 2, 3 } }, &.{
        .{ .code = even, .field = "nums[0]" },
        .{ .code = even, .field = "nums[2]" },
    });
}

test "several customs on one field run left to right; the first failing one is reported" {
    const small = v.custom("numbers.small", "must be small", struct {
        fn isSmall(n: u32) bool {
            return n < 100;
        }
    }.isSmall);
    const rules = .{ small, v.custom(even, even_message, isEven) };
    try h.expectFail(u32, rules, 101, "numbers.small", "must be small");
    try h.expectFail(u32, rules, 51, even, even_message);
    try h.expectPass(u32, rules, 50);
    try h.expectAll(&h.One(u32, rules){ .x = 101 }, &.{.{ .code = "numbers.small", .field = "x" }});
}

test "custom accepts codes at the edges of the grammar" {
    const code128 = "a." ++ @as([126]u8, @splat('b'));
    try testing.expectEqual(v.max_code_bytes, code128.len);
    try h.expectFail(u32, v.custom(code128, even_message, isEven), 1, code128, even_message);
    inline for (.{ "a.b", "validationx.y", "rpcx.y", "x.validation", "a_1.b_2.c_3", "orders.v2.limit" }) |code| {
        try h.expectFail(u32, v.custom(code, even_message, isEven), 1, code, even_message);
    }
}

test "custom accepts a 512-byte message and counts bytes, not characters; braces are literal" {
    const m512 = @as([v.max_message_bytes]u8, @splat('m'));
    try h.expectFail(u32, v.custom(even, &m512, isEven), 1, even, &m512);
    const cyrillic = "должно быть чётным";
    try h.expectFail(u32, v.custom(even, cyrillic, isEven), 1, even, cyrillic);
    const euros = comptime blk: {
        var out: []const u8 = "";
        for (0..170) |_| out = out ++ "\u{20AC}";
        break :blk out ++ "ab";
    };
    try testing.expectEqual(v.max_message_bytes, euros.len);
    try h.expectFail(u32, v.custom(even, euros, isEven), 1, even, euros);
    try h.expectFail(u32, v.custom(even, "{even} braces {", isEven), 1, even, "{even} braces {");
}

const Money = struct {
    cents: i64,

    fn isNotNegative(money: *const Money) bool {
        return money.cents >= 0;
    }
};

fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-' or s[s.len - 1] == '-') return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

test "predicates as a service writes them: a struct method by *const, a slug check, std predicates" {
    const Listing = struct {
        price: Money,
        slug: []const u8,
        title: [:0]const u8,
        pin: [4]u8,
        pub const field_rules = .{
            .price = v.custom("listings.negative_price", "must not be negative", Money.isNotNegative),
            .slug = v.custom("listings.slug", "must be a slug", isSlug),
            .title = v.custom("listings.title_utf8", "must be valid UTF-8", std.unicode.utf8ValidateSlice),
            .pin = v.each(v.custom("listings.pin_digit", "must be a digit", std.ascii.isDigit)),
        };
    };
    const good: Listing = .{ .price = .{ .cents = 1999 }, .slug = "red-bike-2", .title = "Велосипед", .pin = "1234".* };
    try h.expectValid(&good);
    var bad = good;
    bad.price = .{ .cents = -1 };
    try h.expectAt(&bad, "listings.negative_price", "must not be negative", "price");
    bad = good;
    bad.slug = "Red-Bike";
    try h.expectAt(&bad, "listings.slug", "must be a slug", "slug");
    bad = good;
    bad.title = "\xff";
    try h.expectAt(&bad, "listings.title_utf8", "must be valid UTF-8", "title");
    bad = good;
    bad.pin = "12a4".*;
    try h.expectAt(&bad, "listings.pin_digit", "must be a digit", "pin[2]");
}
