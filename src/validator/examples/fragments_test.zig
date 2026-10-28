//! The parts of README.md, the guide of zefir-validator, that are not whole
//! examples, compiled: README.md shows them as lines of this file (and the
//! whole of rules.zig), and the tests check what the guide says of them.
//! readme_test.zig checks that README.md shows no Zig code that is not a
//! part of an example or of this file. Types of the same name in two
//! sections of the guide live in a namespace of their section.

const std = @import("std");
const h = @import("vtest");
const v = @import("validator");
const rules = @import("rules.zig");

pub const Line = struct {
    sku: []const u8,
    qty: u16,
    pack: u32,
    pub const field_rules = .{
        .sku = rules.sku,
        .qty = rules.quantity, // the tuple is the whole entry
        .pack = rules.quantity ++ .{v.divisibleBy(2)}, // ++ joins tuples
    };
};

test "the rules of rules.zig serve a u16 and a u32, each checked against its own field" {
    try h.expectValid(&Line{ .sku = "BOOK0042", .qty = 2, .pack = 6 });
    try h.expectAll(&Line{ .sku = "", .qty = 0, .pack = 1001 }, &.{
        .{ .code = "validation.not_empty", .field = "sku" },
        .{ .code = "validation.positive", .field = "qty" },
        .{ .code = "validation.max", .field = "pack" },
    });
    try h.expectAt(&Line{ .sku = "BOOK0042", .qty = 2, .pack = 3 }, "validation.divisible_by", "must be divisible by 2", "pack");
}

// ------------------------------------------------------------------ field_rules

const orders = struct {
    const Currency = enum { eur, usd, gbp, jpy };

    const Order = struct {
        id: []const u8,
        quantity: u32,
        currency: Currency,
        coupons: []const []const u8,
        note: ?[]const u8 = null,

        pub const field_rules = .{
            .id = v.uuid, // one rule
            .quantity = .{ v.positive, v.max(1000) }, // a tuple
            .currency = v.oneOf(.{ .eur, .usd }), // some tags of the enum
            .coupons = .{ v.maxItems(3), v.uniqueItems, v.each(v.alphanumeric) },
            .note = v.maxLength(500), // null skips the rule
        };
    };
};

test "the rules of a field run left to right, and the first that fails is its only violation" {
    const order: orders.Order = .{
        .id = "3f9c1a2e-8b4d-4c6a-9e1f-5a7b2c8d0e41",
        .quantity = 2,
        .currency = .eur,
        .coupons = &.{ "WELCOME10", "SPRING" },
    };
    try h.expectValid(&order);
    var bad = order;
    bad.quantity = 0; // v.positive fails, so v.max(1000) does not run
    bad.currency = .gbp;
    bad.coupons = &.{ "SPRING", "SPRING", "SPRING", "SPRING" }; // v.maxItems(3) fails: no other rule of the list, no item
    try h.expectAll(&bad, &.{
        .{ .code = "validation.positive", .field = "quantity" },
        .{ .code = "validation.one_of", .field = "currency" },
        .{ .code = "validation.max_items", .field = "coupons" },
    });
    bad = order;
    bad.quantity = 1001;
    bad.coupons = &.{ "SPRING", "spring-10" };
    try h.expectAll(&bad, &.{
        .{ .code = "validation.max", .field = "quantity" },
        .{ .code = "validation.alphanumeric", .field = "coupons[1]" },
    });
}

// ------------------------------------------------------------------ optional fields

const Address = struct {
    city: []const u8,
    zip: []const u8,

    pub const field_rules = .{
        .city = v.notBlank,
        .zip = .{ v.length(5, 5), v.digits },
    };
};

const Checkout = struct {
    billing: ?Address = null, // its rules run when it is there
    tip_percent: ?u8 = null,
    coupon: ?[]const u8 = null,

    pub const field_rules = .{
        .tip_percent = v.max(30),
        .coupon = v.notEmpty, // null passes, "" fails
    };
};

test "null skips an optional, and a value is walked without a segment of its own" {
    try h.expectValid(&Checkout{});
    try h.expectAt(&Checkout{ .billing = .{ .city = " ", .zip = "62701" } }, "validation.not_blank", "must not be blank", "billing.city");
    try h.expectAt(&Checkout{ .coupon = "" }, "validation.not_empty", "must not be empty", "coupon");
    try h.expectAt(&Checkout{ .tip_percent = 31 }, "validation.max", "must be at most 30", "tip_percent");
}

// ------------------------------------------------------------------ nested structs and lists

const Item = struct {
    sku: []const u8,
    qty: u16,
    pub const field_rules = .{ .sku = v.notEmpty, .qty = v.positive };
};

fn inStock(item: *const Item) bool {
    return item.qty <= 500;
}

const Cart = struct {
    items: []const Item,
    pub const field_rules = .{
        // the list as a whole, then each item; Item's own rules check its fields
        .items = .{
            v.notEmpty,
            v.maxItems(50),
            v.uniqueBy(.sku),
            v.each(v.custom("orders.out_of_stock", "must be in stock", inStock)),
        },
    };
};

test "a cart checks its list, then each item, then the fields of each item" {
    try h.expectAt(&Cart{ .items = &.{ .{ .sku = "a", .qty = 1 }, .{ .sku = "b", .qty = 0 } } }, "validation.positive", "must be greater than 0", "items[1].qty");
    try h.expectAt(&Cart{ .items = &.{ .{ .sku = "a", .qty = 1 }, .{ .sku = "a", .qty = 2 } } }, "validation.unique_items", "must not contain duplicate sku values", "items");
    try h.expectAt(&Cart{ .items = &.{.{ .sku = "a", .qty = 600 }} }, "orders.out_of_stock", "must be in stock", "items[0]");
    // An item whose rule fails is not entered: its empty sku is not
    // reported. The other items are checked.
    try h.expectAll(&Cart{ .items = &.{ .{ .sku = "", .qty = 600 }, .{ .sku = "b", .qty = 0 } } }, &.{
        .{ .code = "orders.out_of_stock", .field = "items[0]" },
        .{ .code = "validation.positive", .field = "items[1].qty" },
    });
}

// ------------------------------------------------------------------ names and transforms

const Account = struct {
    user_name: []const u8,

    pub const field_rules = .{
        .user_name = .{ v.rename("userName"), v.trim, v.notBlank, v.maxLength(100) },
    };
};

test "an entry gives a field its outside name, its transforms and its rules, in this order" {
    try std.testing.expectEqualStrings("userName", v.nameOf(Account, .user_name));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var account: Account = .{ .user_name = " Ann " };
    try v.transform(arena.allocator(), &account);
    try std.testing.expectEqualStrings("Ann", account.user_name);
    try h.expectValid(&account);
    var blank: Account = .{ .user_name = " \t" };
    try v.transform(arena.allocator(), &blank);
    try h.expectAt(&blank, "validation.not_blank", "must not be blank", "userName");
}

// ------------------------------------------------------------------ v.transformWith

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortTags(allocator: std.mem.Allocator, tags: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    if (std.sort.isSorted([]const u8, tags, {}, lessThan)) return tags; // nothing to change
    const copy = try allocator.dupe([]const u8, tags); // the list you got may be read-only, like a literal
    std.mem.sort([]const u8, copy, {}, lessThan);
    return copy;
}

const Post = struct {
    tags: []const []const u8,

    pub const field_rules = .{
        .tags = .{ v.transformWith(sortTags), v.maxItems(5), v.each(.{ v.trim, v.toLower }) },
    };
};

test "sortTags gets the tags already trimmed and lowercased, and keeps a sorted list" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Sorted before the transforms of the items, " zig" would stay first:
    // a space sorts before a letter.
    var post: Post = .{ .tags = &.{ " zig", "Ada" } };
    try v.transform(arena.allocator(), &post);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "ada", "zig" }), post.tags);
    // Nothing to change: the field keeps the same list.
    const sorted: []const []const u8 = &.{ "ada", "zig" };
    var clean: Post = .{ .tags = sorted };
    try v.transform(arena.allocator(), &clean);
    try std.testing.expect(clean.tags.ptr == sorted.ptr);
}

const cents = struct {
    fn toCents(_: std.mem.Allocator, euros: u32) error{Overflow}!u32 {
        return std.math.mul(u32, euros, 100);
    }

    const Order = struct {
        amount: u32,
        pub const field_rules = .{ .amount = v.transformWith(toCents) };
    };

    /// The amount of an order in cents. The switch names every error of
    /// v.transform: it compiles only because v.TransformError(Order) is
    /// exactly error{ OutOfMemory, Overflow }.
    fn accept(gpa: std.mem.Allocator, euros: u32) error{ OutOfMemory, AmountTooLarge }!u32 {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var order: Order = .{ .amount = euros };
        v.transform(arena.allocator(), &order) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory, // the server's failure
            error.Overflow => return error.AmountTooLarge, // an amount that does not fit in cents
        };
        return order.amount;
    }
};

test "the handler decides what each error of a transform means" {
    try std.testing.expectEqual(1200, try cents.accept(std.testing.allocator, 12));
    try std.testing.expectError(error.AmountTooLarge, cents.accept(std.testing.allocator, 50_000_000));
}

// ------------------------------------------------------------------ memory

test "a value that std.json decoded is transformed in the arena of its Parsed" {
    const gpa = std.testing.allocator;
    const body =
        \\{"tags": [" Zig", "comptime"]}
    ;
    var parsed = try std.json.parseFromSlice(Post, gpa, body, .{}); // var: v.transform changes parsed.value
    defer parsed.deinit(); // frees the decoded strings and what v.transform made
    try v.transform(parsed.arena.allocator(), &parsed.value);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "comptime", "zig" }), parsed.value.tags);
}

test "a value you allocated keeps your list, and you free your list" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const raw_tags: []const []const u8 = &.{ "zig", " Ada" };
    const tags = try gpa.dupe([]const u8, raw_tags);
    defer gpa.free(tags); // the original: v.transform never writes or frees it
    var post: Post = .{ .tags = tags };
    try v.transform(arena.allocator(), &post); // post.tags may now point into the arena
    try std.testing.expect(post.tags.ptr != tags.ptr);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "ada", "zig" }), post.tags);
    try std.testing.expectEqualDeep(raw_tags, tags);
}

// ------------------------------------------------------------------ v.custom

fn startsWithAt(s: []const u8) bool {
    return s.len > 0 and s[0] == '@';
}

fn isEven(n: u64) bool {
    return n % 2 == 0;
}

const Profile = struct {
    handle: [:0]const u8,
    seats: u16,
    pub const field_rules = .{
        .handle = v.custom("profiles.handle_format", "must start with @", startsWithAt),
        .seats = .{ v.positive, v.custom("profiles.odd_seats", "must be even", isEven) },
    };
};

test "v.custom reports its own code and message" {
    try h.expectValid(&Profile{ .handle = "@ada", .seats = 4 });
    try h.expectAll(&Profile{ .handle = "ada", .seats = 3 }, &.{
        .{ .code = "profiles.handle_format", .field = "handle" },
        .{ .code = "profiles.odd_seats", .field = "seats" },
    });
    try h.expectAt(&Profile{ .handle = "ada", .seats = 3 }, "profiles.handle_format", "must start with @", "handle");
    try h.expectAt(&Profile{ .handle = "@ada", .seats = 0 }, "validation.positive", "must be greater than 0", "seats");
}

// ------------------------------------------------------------------ preconditions

const Product = struct {
    price: f64,
    name: []const u8,

    pub const field_rules = .{
        .price = .{ v.finite.withMessage("price must be a number"), v.positive },
        .name = .{ v.utf8.withMessage("the name must be UTF-8"), v.maxLength(64) },
    };
};

test "a rule of the precondition, put first, gives it a message of your own" {
    try h.expectValid(&Product{ .price = 9.5, .name = "Tea" });
    try h.expectAt(&Product{ .price = std.math.nan(f64), .name = "Tea" }, "validation.finite", "price must be a number", "price");
    try h.expectAt(&Product{ .price = 9.5, .name = "\xff" }, "validation.utf8", "the name must be UTF-8", "name");
    try h.expectAt(&Product{ .price = -1, .name = "Tea" }, "validation.positive", "must be greater than 0", "price");
    // .withMessage on the rule itself keeps the precondition's own message.
    try h.expectFail(f64, v.positive.withMessage("must be above zero"), std.math.nan(f64), "validation.finite", "must be a finite number");
    try h.expectFail(f64, v.positive.withMessage("must be above zero"), -1, "validation.positive", "must be above zero");
}

// ------------------------------------------------------------------ testing a DTO package

const SignUp = struct {
    email: []const u8,

    pub const field_rules = .{
        .email = .{ v.trim, v.toLower, v.email },
    };
};

test "SignUp accepts an email with spaces around it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var req: SignUp = .{ .email = " Ada@Example.COM " };
    try v.transform(arena.allocator(), &req);
    var path_buf: [256]u8 = undefined;
    try std.testing.expectEqual(null, v.check(&req, &path_buf));
}
