//! Outside names: `v.rename` in `field_rules`, the names in the paths of
//! violations (those of `validateSelf` and `v.fail` included), and the table
//! of names that codecs read through `v.nameOf` and `v.fieldNamed`.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;

const Address = struct {
    city_name: []const u8,
    zip: []const u8 = "00000",
    pub const field_rules = .{
        .city_name = .{ v.rename("cityName"), v.notEmpty },
        .zip = v.digits,
    };
};

const Item = struct {
    display_name: []const u8,
    qty: u32 = 1,
    pub const field_rules = .{
        .display_name = .{ v.rename("displayName"), v.notBlank },
        .qty = .{ v.rename("quantity"), v.positive },
    };
};

const Order = struct {
    user_name: []const u8 = "ann",
    note: []const u8 = "n",
    address: Address = .{ .city_name = "Paris" },
    billing: ?Address = null,
    items: []const Item = &.{},
    tags: []const []const u8 = &.{},
    matrix: [2][2]u32 = .{ .{ 1, 1 }, .{ 1, 1 } },
    pub const field_rules = .{
        .user_name = .{ v.rename("userName"), v.notBlank, v.maxLength(10) },
        .note = v.notEmpty, // no rename: the Zig name
        .address = v.rename("shippingAddress"),
        .billing = v.rename("billingAddress"),
        .items = .{ v.rename("lineItems"), v.maxItems(10) },
        .tags = .{ v.rename("labels"), v.each(v.notEmpty) },
        .matrix = .{ v.rename("grid"), v.each(v.each(v.positive)) },
    };
};

test "paths name each field by its outside name, at every level" {
    try h.expectAt(&Order{ .user_name = " " }, "validation.not_blank", "must not be blank", "userName");
    try h.expectAt(&Order{ .note = "" }, "validation.not_empty", null, "note");
    try h.expectAt(&Order{ .address = .{ .city_name = "" } }, "validation.not_empty", null, "shippingAddress.cityName");
    try h.expectAt(&Order{ .billing = .{ .city_name = "x", .zip = "x1" } }, "validation.digits", null, "billingAddress.zip");
    try h.expectAt(&Order{ .items = &.{ .{ .display_name = "a" }, .{ .display_name = "b" }, .{ .display_name = " " } } }, "validation.not_blank", null, "lineItems[2].displayName");
    try h.expectAt(&Order{ .items = &.{.{ .display_name = "a", .qty = 0 }} }, "validation.positive", null, "lineItems[0].quantity");
    try h.expectAt(&Order{ .tags = &.{ "a", "" } }, "validation.not_empty", null, "labels[1]");
    try h.expectAt(&Order{ .matrix = .{ .{ 1, 1 }, .{ 0, 1 } } }, "validation.positive", null, "grid[1][0]");
    // The rule of a list itself, and a list at the root.
    const many: [11]Item = @splat(.{ .display_name = "a" });
    try h.expectAt(&Order{ .items = &many }, "validation.max_items", null, "lineItems");
    const items: []const Item = &.{ .{ .display_name = "a" }, .{ .display_name = "" } };
    try h.expectAt(&items, "validation.not_blank", null, "[1].displayName");
    const maybe: ?Order = .{ .user_name = "" };
    try h.expectAt(&maybe, "validation.not_blank", null, "userName");
}

test "checkAll reports every violation at its outside path" {
    try h.expectAll(&Order{ .user_name = "", .address = .{ .city_name = "" }, .items = &.{.{ .display_name = "", .qty = 0 }} }, &.{
        .{ .code = "validation.not_blank", .field = "userName" },
        .{ .code = "validation.not_empty", .field = "shippingAddress.cityName" },
        .{ .code = "validation.not_blank", .field = "lineItems[0].displayName" },
        .{ .code = "validation.positive", .field = "lineItems[0].quantity" },
    });
}

const Booking = struct {
    check_in: u32,
    check_out: u32,
    guests: u32 = 1,
    pub const field_rules = .{
        .check_in = v.rename("checkIn"),
        .check_out = v.rename("checkOut"),
    };
    pub fn validateSelf(b: *const Booking) ?v.Violation {
        if (b.check_out <= b.check_in) return v.fail(Booking, .check_out, "bookings.check_out_too_early", "must be after the check-in date");
        // Hand-built results name fields by their Zig names too.
        if (b.guests == 0) return .{ .code = "bookings.no_guests", .message = "must have a guest", .field = "guests" };
        if (b.guests > 9) return .{ .code = "bookings.too_many_guests", .message = "must have at most 9 guests", .field = "check_in" };
        return null;
    }
};

const Trip = struct {
    bookings: []const Booking,
    pub const field_rules = .{ .bookings = v.rename("stays") };
};

test "a validateSelf violation is reported at the outside name of its field; v.fail holds the Zig name" {
    try h.expectAll(&Trip{ .bookings = &.{ .{ .check_in = 1, .check_out = 2 }, .{ .check_in = 5, .check_out = 3 } } }, &.{
        .{ .code = "bookings.check_out_too_early", .field = "stays[1].checkOut" },
    });
    try h.expectAll(&Booking{ .check_in = 1, .check_out = 2, .guests = 10 }, &.{.{ .code = "bookings.too_many_guests", .field = "checkIn" }});
    try h.expectAll(&Booking{ .check_in = 1, .check_out = 2, .guests = 0 }, &.{.{ .code = "bookings.no_guests", .field = "guests" }});
    const failed = v.fail(Booking, .check_out, "bookings.check_out_too_early", "must be after the check-in date");
    try testing.expectEqualStrings("check_out", failed.field.?);
    // check writes the outside name into path_buf, and only when it fits.
    var exact: ["stays[1].checkOut".len]u8 = undefined;
    const trip: Trip = .{ .bookings = &.{ .{ .check_in = 1, .check_out = 2 }, .{ .check_in = 5, .check_out = 3 } } };
    try h.expectField("stays[1].checkOut", (v.check(&trip, &exact) orelse return error.NoViolation).field);
    var short: ["stays[1].checkOut".len - 1]u8 = undefined;
    try h.expectField(null, (v.check(&trip, &short) orelse return error.NoViolation).field);
}

test "nameOf gives the outside name of a field, the Zig name without v.rename" {
    try testing.expectEqualStrings("userName", v.nameOf(Order, .user_name));
    try testing.expectEqualStrings("note", v.nameOf(Order, .note));
    try testing.expectEqualStrings("lineItems", v.nameOf(Order, .items));
    try testing.expectEqualStrings("cityName", v.nameOf(Address, .city_name));
    // A struct without field_rules has its Zig names.
    const Plain = struct { user_name: []const u8, id: u64 };
    try testing.expectEqualStrings("user_name", v.nameOf(Plain, .user_name));
    // A compile-time value.
    comptime std.debug.assert(std.mem.eql(u8, v.nameOf(Order, .matrix), "grid"));
}

test "fieldNamed finds a field by its outside name, at run time and at compile time" {
    try testing.expectEqual(.user_name, v.fieldNamed(Order, "userName").?);
    try testing.expectEqual(.note, v.fieldNamed(Order, "note").?);
    // A renamed field is not found by its Zig name.
    try testing.expectEqual(null, v.fieldNamed(Order, "user_name"));
    try testing.expectEqual(null, v.fieldNamed(Order, "unknown"));
    try testing.expectEqual(null, v.fieldNamed(Order, ""));
    var buf: [16]u8 = undefined;
    const key = try std.fmt.bufPrint(&buf, "line{s}", .{"Items"});
    try testing.expectEqual(.items, v.fieldNamed(Order, key).?);
    comptime std.debug.assert(v.fieldNamed(Order, "grid").? == .matrix);
    // Every field comes back from its outside name.
    inline for (@typeInfo(Order).@"struct".field_names) |name| {
        const field = @field(std.meta.FieldEnum(Order), name);
        try testing.expectEqual(field, v.fieldNamed(Order, v.nameOf(Order, field)).?);
    }
}

const Versioned = struct {
    comptime version: u32 = 2,
    name: []const u8,
    pub const field_rules = .{ .name = v.rename("fullName") };
};

test "a comptime field keeps its Zig name and is not found from outside" {
    try testing.expectEqualStrings("version", v.nameOf(Versioned, .version));
    try testing.expectEqual(null, v.fieldNamed(Versioned, "version"));
    try testing.expectEqual(.name, v.fieldNamed(Versioned, "fullName").?);
}

/// Names and transforms only, those of list items too: nothing for the
/// check walk.
const NamesOnly = struct {
    user_name: []const u8,
    email: []const u8,
    tags: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    pub const field_rules = .{
        .user_name = v.rename("userName"),
        .email = .{ v.rename("eMail"), v.trim },
        .tags = v.each(v.trim),
        .rows = .{ v.rename("grid"), v.each(v.each(v.trim)) },
    };
};

/// The fields of `NamesOnly` without `field_rules`.
const NoRules = struct {
    user_name: []const u8,
    email: []const u8,
    tags: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
};

/// The allocations of a `checkAll` of `value` that finds nothing.
fn emptyReportAllocations(value: anytype) !usize {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const report = try v.checkAll(counting.allocator(), value);
    defer report.deinit();
    try testing.expectEqual(0, report.violations.len);
    return counting.allocations;
}

test "a field with only a name or transforms has no rules: the check walk reports nothing and does not descend" {
    const tags: []const []const u8 = &.{ " a ", "" };
    const rows: []const []const []const u8 = &.{ tags, tags };
    const one: NamesOnly = .{ .user_name = "", .email = " ", .tags = tags, .rows = rows };
    try h.expectValid(&one);
    // A walk that visited a field or an item would push its path into the
    // report's arena: it takes no more memory than for the same fields
    // without field_rules, or for a list of numbers.
    try testing.expectEqual(try emptyReportAllocations(&NoRules{ .user_name = "", .email = " ", .tags = tags, .rows = rows }), try emptyReportAllocations(&one));
    const many: [1000]NamesOnly = @splat(one);
    const list: []const NamesOnly = &many;
    const plain_many: [1000]NoRules = @splat(.{ .user_name = "", .email = " ", .tags = tags, .rows = rows });
    const plain_list: []const NoRules = &plain_many;
    try testing.expectEqual(try emptyReportAllocations(&plain_list), try emptyReportAllocations(&list));
    const numbers: []const u32 = &.{ 1, 2, 3 };
    try testing.expectEqual(try emptyReportAllocations(&numbers), try emptyReportAllocations(&list));
    // A list whose items have rules is visited.
    const items: [1000]Item = @splat(.{ .display_name = "a" });
    const checked: []const Item = &items;
    try testing.expect(try emptyReportAllocations(&checked) > try emptyReportAllocations(&numbers));
}

const Grid = struct {
    rows: []const []const []const u8,
    pub const field_rules = .{ .rows = .{ v.maxItems(5000), v.each(v.each(v.trim)) } };
};

test "a list whose each holds transforms alone is checked by its own rules, and its items are not visited" {
    const row: []const []const u8 = &.{ " a ", "b" };
    const grid: Grid = .{ .rows = &.{ row, row, row } };
    // check writes the path of every value it visits into path_buf: here
    // only the field itself.
    var path_buf: [32]u8 = @splat(0xaa);
    try testing.expect(v.check(&grid, &path_buf) == null);
    try testing.expectEqualStrings("rows", path_buf[0..4]);
    try testing.expect(std.mem.allEqual(u8, path_buf[4..], 0xaa));
}

/// Outside names alone, for a codec: nothing for either walk.
const Profile = struct {
    display_name: []const u8,
    pub const field_rules = .{ .display_name = v.rename("displayName") };
};

const Holder = struct {
    n: u32 = 1,
    profile: *const Profile,
    choice: union(enum) { profile: Profile, none: void } = .none,
    pub const field_rules = .{ .n = v.positive };
};

test "a struct with outside names alone may sit behind a pointer or in a union: no walk would skip anything there" {
    comptime v.assertRules(Holder);
    const profile: Profile = .{ .display_name = "" };
    try h.expectValid(&Holder{ .profile = &profile, .choice = .{ .profile = profile } });
    try h.expectAt(&Holder{ .n = 0, .profile = &profile }, "validation.positive", null, "n");
    var holder: Holder = .{ .profile = &profile };
    try v.transform(testing.failing_allocator, &holder);
}

const Dotted = struct {
    @"a.b": u32,
    pub const field_rules = .{ .@"a.b" = .{ v.rename("ab"), v.positive } };
};

test "a Zig field name with a dot is fine once v.rename gives the path another name" {
    try h.expectAt(&Dotted{ .@"a.b" = 0 }, "validation.positive", null, "ab");
}
