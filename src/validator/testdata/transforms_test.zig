//! `v.transform`: the transforms of `field_rules` on a value, its fields,
//! optionals and the items of its lists, nested parts first; copies of
//! slices; the memory it takes; the errors of `transformWith`; the roots it
//! takes; and `check` on the transformed value.
const std = @import("std");
const v = @import("validator");
const h = @import("vtest");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const CreateUserRequest = struct {
    user_name: []const u8,
    email: []const u8,
    nickname: ?[]const u8 = null,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .user_name = .{ v.rename("userName"), v.trim, v.notBlank, v.maxLength(100) },
        .email = .{ v.trim, v.toLower, v.email },
        .nickname = .{ v.trim, v.maxLength(30) }, // ?T: when the value is there
        .tags = v.each(.{ v.trim, v.notBlank, v.maxLength(30) }),
    };
};

test "transform, then checkAll: the rules check the transformed value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var req: CreateUserRequest = .{ .user_name = "  Ann ", .email = " Ann@Example.COM ", .tags = &.{" zig "} };
    try v.transform(arena.allocator(), &req);
    try testing.expectEqualStrings("Ann", req.user_name);
    try testing.expectEqualStrings("ann@example.com", req.email);
    try testing.expectEqual(null, req.nickname);
    try testing.expectEqual(1, req.tags.len);
    try testing.expectEqualStrings("zig", req.tags[0]);
    try h.expectValid(&req);
    // Blank once trimmed: the violation names the field by its outside name.
    var blank: CreateUserRequest = .{ .user_name = " \u{3000}\u{a0}", .email = "ann@example.com", .tags = &.{ "a", " " } };
    try v.transform(arena.allocator(), &blank);
    try h.expectAll(&blank, &.{
        .{ .code = "validation.not_blank", .field = "userName" },
        .{ .code = "validation.not_blank", .field = "tags[1]" },
    });
}

test "check and checkAll skip the transforms: they see the value as it is" {
    const raw: CreateUserRequest = .{ .user_name = "  Ann ", .email = " ann@example.com " };
    try h.expectAt(&raw, "validation.email", null, "email");
}

const Text = struct {
    both: []const u8 = "",
    start: []const u8 = "",
    end: []const u8 = "",
    lower: []const u8 = "",
    upper: []const u8 = "",
    pub const field_rules = .{
        .both = v.trim,
        .start = v.trimStart,
        .end = v.trimEnd,
        .lower = v.toLower,
        .upper = v.toUpper,
    };
};

test "the built-in transforms through v.transform" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var text: Text = .{
        .both = "\u{a0} a b \u{3000}",
        .start = "\t\u{2028} a ",
        .end = " a \r\n\u{85}",
        .lower = "\u{c4}RGER \u{dc}ber",
        .upper = "\u{e4}rger \u{fc}ber",
    };
    try v.transform(arena.allocator(), &text);
    try testing.expectEqualStrings("a b", text.both);
    try testing.expectEqualStrings("a ", text.start);
    try testing.expectEqualStrings(" a", text.end);
    // Only the ASCII letters change case.
    try testing.expectEqualStrings("\u{c4}rger \u{dc}ber", text.lower);
    try testing.expectEqualStrings("\u{e4}RGER \u{fc}BER", text.upper);
    // White_Space alone becomes empty; invalid UTF-8 stays as it is.
    var blank: Text = .{ .both = " \t\u{3000} ", .start = " ", .end = "\u{a0}" };
    try v.transform(arena.allocator(), &blank);
    try testing.expectEqualStrings("", blank.both);
    try testing.expectEqualStrings("", blank.start);
    try testing.expectEqualStrings("", blank.end);
    const bad: []const u8 = " \xff ";
    var invalid: Text = .{ .both = bad };
    try v.transform(arena.allocator(), &invalid);
    try testing.expectEqual(bad.ptr, invalid.both.ptr);
    try testing.expectEqual(bad.len, invalid.both.len);
}

test "the trims and a case change with nothing to change allocate nothing" {
    var text: Text = .{ .both = "  a  ", .start = " b", .end = "c ", .lower = "already lower \u{c4}", .upper = "ALREADY UPPER \u{e4}" };
    try v.transform(testing.failing_allocator, &text);
    try testing.expectEqualStrings("a", text.both);
    // A letter to change takes a new string.
    var mixed: Text = .{ .lower = "Mixed" };
    try testing.expectError(error.OutOfMemory, v.transform(testing.failing_allocator, &mixed));
}

test "an optional is transformed when the value is there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var present: CreateUserRequest = .{ .user_name = "a", .email = "a@b.co", .nickname = "  nick " };
    try v.transform(arena.allocator(), &present);
    try testing.expectEqualStrings("nick", present.nickname.?);
    var absent: CreateUserRequest = .{ .user_name = "a", .email = "a@b.co" };
    try v.transform(arena.allocator(), &absent);
    try testing.expectEqual(null, absent.nickname);
}

test "a slice is never written to: the first item that changes brings one copy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var counting: std.testing.FailingAllocator = .init(arena.allocator(), .{});
    const original = [_][]const u8{ "a", "b ", " c" };
    var req: CreateUserRequest = .{ .user_name = "a", .email = "a@b.co", .tags = &original };
    try v.transform(counting.allocator(), &req);
    try testing.expect(req.tags.ptr != @as([*]const []const u8, &original));
    try testing.expectEqual(3, req.tags.len);
    try testing.expectEqualStrings("a", req.tags[0]);
    try testing.expectEqualStrings("b", req.tags[1]);
    try testing.expectEqualStrings("c", req.tags[2]);
    try testing.expectEqualStrings("b ", original[1]);
    try testing.expectEqualStrings(" c", original[2]);
    try testing.expectEqual(1, counting.allocations);
    // Nothing to change: the same slice, and nothing allocated.
    const clean = [_][]const u8{ "a", "b" };
    req.tags = &clean;
    try v.transform(testing.failing_allocator, &req);
    try testing.expectEqual(@as([*]const []const u8, &clean), req.tags.ptr);
}

const Fixed = struct {
    codes: [3][]const u8,
    pub const field_rules = .{ .codes = v.each(v.toUpper) };
};

test "an array changes in place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fixed: Fixed = .{ .codes = .{ "ab", "CD", "e" } };
    try v.transform(arena.allocator(), &fixed);
    try testing.expectEqualStrings("AB", fixed.codes[0]);
    try testing.expectEqualStrings("CD", fixed.codes[1]);
    try testing.expectEqualStrings("E", fixed.codes[2]);
}

const Line = struct {
    sku: []const u8,
    note: ?[]const u8 = null,
    pub const field_rules = .{
        .sku = .{ v.trim, v.toUpper, v.notBlank },
        .note = v.trim,
    };
};

const Cart = struct {
    lines: []const Line,
    maybe_lines: []const ?Line = &.{},
    pub const field_rules = .{ .lines = v.notEmpty };
};

test "a slice of structs is copied when an item changes; the original items stay as they were" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const lines = [_]Line{ .{ .sku = "AB-1" }, .{ .sku = " cd-2 " }, .{ .sku = "EF-3", .note = " x " } };
    const maybe_lines = [_]?Line{ null, .{ .sku = "x" } };
    var cart: Cart = .{ .lines = &lines, .maybe_lines = &maybe_lines };
    try v.transform(arena.allocator(), &cart);
    try testing.expect(cart.lines.ptr != @as([*]const Line, &lines));
    try testing.expectEqualStrings("AB-1", cart.lines[0].sku);
    try testing.expectEqualStrings("CD-2", cart.lines[1].sku);
    try testing.expectEqualStrings("x", cart.lines[2].note.?);
    try testing.expectEqualStrings(" cd-2 ", lines[1].sku);
    try testing.expectEqual(null, cart.maybe_lines[0]);
    try testing.expectEqualStrings("X", cart.maybe_lines[1].?.sku);
    try h.expectValid(&cart);
}

const Person = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.trim };
};

const Team = struct {
    lead: Person,
    deputy: ?Person = null,
    members: []const Person = &.{},
    pub const field_rules = .{ .lead = v.rename("teamLead") };
};

test "nested structs change in place, an optional one when it is there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var team: Team = .{ .lead = .{ .name = " Ann " }, .deputy = .{ .name = "Bob " }, .members = &.{ .{ .name = "a" }, .{ .name = " c" } } };
    try v.transform(arena.allocator(), &team);
    try testing.expectEqualStrings("Ann", team.lead.name);
    try testing.expectEqualStrings("Bob", team.deputy.?.name);
    try testing.expectEqualStrings("c", team.members[1].name);
}

const Grid = struct {
    rows: []const []const []const u8,
    pub const field_rules = .{ .rows = v.each(v.each(v.trim)) };
};

test "each inside each transforms every item of every row; only the rows that changed are copied" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var counting: std.testing.FailingAllocator = .init(arena.allocator(), .{});
    const row0 = [_][]const u8{ "a", "b" };
    const row1 = [_][]const u8{ " c", "d" };
    const rows = [_][]const []const u8{ &row0, &row1 };
    var grid: Grid = .{ .rows = &rows };
    try v.transform(counting.allocator(), &grid);
    try testing.expect(grid.rows.ptr != @as([*]const []const []const u8, &rows));
    try testing.expectEqual(@as([*]const []const u8, &row0), grid.rows[0].ptr);
    try testing.expectEqualStrings("c", grid.rows[1][0]);
    try testing.expectEqualStrings(" c", row1[0]);
    // The changed row and the list of rows.
    try testing.expectEqual(2, counting.allocations);
}

// ------------------------------------------------------------------ order

var log_entries: [32][]const u8 = undefined;
var log_len: usize = 0;

fn record(entry: []const u8) void {
    log_entries[log_len] = entry;
    log_len += 1;
}

fn expectLog(expected: []const []const u8) !void {
    errdefer {
        std.debug.print("\n  transforms ran:", .{});
        for (log_entries[0..log_len]) |entry| std.debug.print(" [{s}]", .{entry});
        std.debug.print("\n", .{});
    }
    try testing.expectEqual(expected.len, log_len);
    for (expected, log_entries[0..log_len]) |e, a| try testing.expectEqualStrings(e, a);
}

/// A transform of strings that records `name` and the value it got.
fn Logged(comptime name: []const u8) type {
    return struct {
        fn run(_: Allocator, s: []const u8) []const u8 {
            record(name);
            if (s.len > 0) record(s);
            return s;
        }
    };
}

const Leaf = struct {
    a: []const u8 = "",
    b: []const u8 = "",
    pub const field_rules = .{
        .a = .{ v.trim, v.transformWith(Logged("leaf.a 1").run), v.transformWith(Logged("leaf.a 2").run) },
        .b = v.transformWith(Logged("leaf.b").run),
    };
};

fn wholeLeaf(_: Allocator, leaf: Leaf) Leaf {
    record("leaf");
    return leaf;
}

fn wholeList(_: Allocator, list: []const Leaf) []const Leaf {
    record("list");
    return list;
}

const Tree = struct {
    first: Leaf = .{},
    list: []const Leaf = &.{},
    last: []const u8 = "",
    pub const field_rules = .{
        .first = v.transformWith(wholeLeaf),
        .list = .{ v.transformWith(wholeList), v.each(v.transformWith(wholeLeaf)) },
        .last = v.transformWith(Logged("last").run),
    };
};

test "nested parts first, then the value's own transforms, left to right; fields in declaration order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tree: Tree = .{ .first = .{ .a = " x " }, .list = &.{ .{}, .{} } };
    log_len = 0;
    try v.transform(arena.allocator(), &tree);
    try expectLog(&.{
        // first: its fields, then the field's own transform; trim ran
        // before the first logged transform of `a`.
        "leaf.a 1", "x",        "leaf.a 2", "x",    "leaf.b",   "leaf",
        // list: each item (its fields, then the item transform), then the list
        "leaf.a 1", "leaf.a 2", "leaf.b",   "leaf", "leaf.a 1", "leaf.a 2",
        "leaf.b",   "leaf",     "list",     "last",
    });
}

// ------------------------------------------------------------------ errors and memory

fn shortTag(_: Allocator, tag: []const u8) error{TagTooLong}![]const u8 {
    if (tag.len > 8) return error.TagTooLong;
    return tag;
}

const Tagged = struct {
    name: []const u8,
    tags: []const []const u8 = &.{},
    trimmed: []const []const u8 = &.{},
    pub const field_rules = .{
        .name = v.trim,
        .tags = v.each(.{ v.trim, v.transformWith(shortTag) }),
        .trimmed = v.each(v.trim), // transforms alone
    };
};

/// `E` holds exactly the errors `names`.
fn expectErrorNames(comptime E: type, comptime names: []const []const u8) !void {
    const got = @typeInfo(E).error_set.error_names.?;
    try testing.expectEqual(names.len, got.len);
    inline for (names) |name| {
        const found = for (got) |g| {
            if (std.mem.eql(u8, g, name)) break true;
        } else false;
        if (!found) {
            std.debug.print("error.{s} is not in {s}\n", .{ name, @typeName(E) });
            return error.TestMissingError;
        }
    }
}

test "an error of a transformWith function stops the walk and comes back as it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tagged: Tagged = .{ .name = " a ", .tags = &.{ "ok", " far too long " }, .trimmed = &.{" t "} };
    try testing.expectError(error.TagTooLong, v.transform(arena.allocator(), &tagged));
    // The value may be partly transformed: the field before the failure is.
    try testing.expectEqualStrings("a", tagged.name);
    try testing.expectEqualStrings(" t ", tagged.trimmed[0]);
    var fine: Tagged = .{ .name = "a", .tags = &.{" ok "}, .trimmed = &.{" t "} };
    try v.transform(arena.allocator(), &fine);
    try testing.expectEqualStrings("ok", fine.tags[0]);
    try testing.expectEqualStrings("t", fine.trimmed[0]);
}

/// A transform whose error set the compiler infers.
fn canonicalCount(allocator: Allocator, text: []const u8) ![]const u8 {
    const count = try std.fmt.parseInt(u32, text, 10);
    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

const Counted = struct {
    count: []const u8,
    nested: ?Tagged = null,
    pub const field_rules = .{ .count = v.transformWith(canonicalCount) };
};

test "TransformError is exactly OutOfMemory and the errors of the transformWith functions reachable from the type" {
    try expectErrorNames(v.TransformError(Tagged), &.{ "OutOfMemory", "TagTooLong" });
    try expectErrorNames(v.TransformError([]const ?Tagged), &.{ "OutOfMemory", "TagTooLong" });
    try expectErrorNames(v.TransformError(CreateUserRequest), &.{"OutOfMemory"});
    try expectErrorNames(v.TransformError(u32), &.{"OutOfMemory"});
    // An inferred error set, and the errors of a nested struct.
    try expectErrorNames(v.TransformError(Counted), &.{ "OutOfMemory", "Overflow", "InvalidCharacter", "TagTooLong" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var counted: Counted = .{ .count = "007" };
    try v.transform(arena.allocator(), &counted);
    try testing.expectEqualStrings("7", counted.count);
    counted.count = "seven";
    try testing.expectError(error.InvalidCharacter, v.transform(arena.allocator(), &counted));
    // It is the error set of transform.
    try testing.expect(@typeInfo(@TypeOf(v.transform(testing.allocator, @as(*Tagged, undefined)))).error_union.error_set == v.TransformError(Tagged));
}

/// A transform in an arena of `gpa`, for checkAllAllocationFailures.
fn transformInArena(gpa: Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var req: CreateUserRequest = .{ .user_name = "Ann", .email = "Ann@B.CO", .tags = &.{ " x", "y " } };
    try v.transform(arena.allocator(), &req);
    try testing.expectEqualStrings("ann@b.co", req.email);
    try testing.expectEqualStrings("x", req.tags[0]);
}

test "error.OutOfMemory at any allocation stops the walk, and the arena frees what it took" {
    try testing.checkAllAllocationFailures(testing.allocator, transformInArena, .{});
}

// ------------------------------------------------------------------ roots

test "roots: a struct, an optional, a slice passed as &slice, an array" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var maybe: ?Person = .{ .name = " p " };
    try v.transform(a, &maybe);
    try testing.expectEqualStrings("p", maybe.?.name);
    var none: ?Person = null;
    try v.transform(a, &none);
    try testing.expectEqual(null, none);
    const people_items = [_]Person{.{ .name = " a" }};
    var people: []const Person = &people_items;
    try v.transform(a, &people);
    try testing.expect(people.ptr != @as([*]const Person, &people_items));
    try testing.expectEqualStrings("a", people[0].name);
    var array: [2]Person = .{ .{ .name = "a " }, .{ .name = "b" } };
    try v.transform(a, &array);
    try testing.expectEqualStrings("a", array[0].name);
}

test "a root type without transforms is left alone: nothing is read, written or allocated" {
    var number: u32 = 5;
    try v.transform(testing.failing_allocator, &number);
    var text: []const u8 = " x ";
    try v.transform(testing.failing_allocator, &text);
    try testing.expectEqualStrings(" x ", text);
    var plain: struct { name: []const u8 } = .{ .name = " x " };
    try v.transform(testing.failing_allocator, &plain);
    try testing.expectEqualStrings(" x ", plain.name);
    var unit: void = {};
    try v.transform(testing.failing_allocator, &unit);
    // Rules and names only.
    const Checked = struct {
        name: []const u8,
        pub const field_rules = .{ .name = .{ v.rename("fullName"), v.notBlank } };
    };
    var checked: Checked = .{ .name = " " };
    try v.transform(testing.failing_allocator, &checked);
    try testing.expectEqualStrings(" ", checked.name);
}

test "a root behind an under-aligned or volatile pointer is transformed through a copy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var person: Person = .{ .name = " p " };
    const under_aligned: *align(1) Person = &person;
    try v.transform(arena.allocator(), under_aligned);
    try testing.expectEqualStrings("p", person.name);
    person.name = " q ";
    const volatile_root: *volatile Person = &person;
    try v.transform(arena.allocator(), volatile_root);
    try testing.expectEqualStrings("q", person.name);
}

fn clampLevel(_: Allocator, level: u4) u4 {
    return @min(level, 9);
}

const Flags = packed struct {
    level: u4 = 0,
    rest: u4 = 0,
    pub const field_rules = .{ .level = v.transformWith(clampLevel) };
};

const Loose = struct {
    name: []const u8 align(1),
    flags: Flags = .{},
    pub const field_rules = .{ .name = v.trim };
};

test "a packed field and an under-aligned field are transformed as copies and written back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var loose: Loose = .{ .name = " n ", .flags = .{ .level = 12, .rest = 3 } };
    try v.transform(arena.allocator(), &loose);
    try testing.expectEqualStrings("n", loose.name);
    try testing.expectEqual(9, loose.flags.level);
    try testing.expectEqual(3, loose.flags.rest);
}

fn negativeZero(_: Allocator, x: f64) f64 {
    return if (x == 0) -0.0 else x;
}

const Reading = struct {
    value: f64,
    pub const field_rules = .{ .value = v.transformWith(negativeZero) };
};

test "a change to a value that compares equal is still a change: -0.0 for 0.0" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const readings = [_]Reading{.{ .value = 0.0 }};
    var list: []const Reading = &readings;
    try v.transform(arena.allocator(), &list);
    try testing.expect(std.math.signbit(list[0].value));
    try testing.expect(!std.math.signbit(readings[0].value));
}
