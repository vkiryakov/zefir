//! Golden tests of the JSON codec (A2 of the spec): the exact JSON of
//! sample values and back, and the limits of a decode at their edges with
//! the defaults of rpc 1.6: 32 levels of nesting, 100 000 items. A hostile
//! body is refused before it costs more memory than the limits allow.

const std = @import("std");
const json = @import("json.zig");
const testing = std.testing;

const Status = enum { active, blocked };
const Address = struct { city: []const u8, zip: ?[5]u8 = null };
const Account = struct {
    id: u64,
    balance: i64,
    rate: f64,
    ratio: f32,
    small: i16,
    flags: [3]bool,
    status: Status,
    name: []const u8,
    nickname: ?[]const u8,
    tags: []const []const u8,
    addresses: []const Address,
    raw: [4]u8,
    note: ?u32 = 7,
};

const account: Account = .{
    .id = std.math.maxInt(u64),
    .balance = std.math.minInt(i64),
    .rate = 0.1,
    .ratio = 1.5,
    .small = std.math.minInt(i16),
    .flags = .{ true, false, true },
    .status = .blocked,
    .name = "Ada \"the\" Countess\n",
    .nickname = null,
    .tags = &.{ "a", "é", "😀" },
    .addresses = &.{ .{ .city = "London", .zip = .{ 49, 50, 51, 52, 53 } }, .{ .city = "Paris" } },
    .raw = .{ 0, 1, 254, 255 },
    .note = null,
};

const account_json =
    \\{"id":"18446744073709551615","balance":"-9223372036854775808","rate":0.1,"ratio":1.5,"small":-32768,"flags":[true,false,true],"status":"blocked","name":"Ada \"the\" Countess\n","nickname":null,"tags":["a","é","😀"],"addresses":[{"city":"London","zip":[49,50,51,52,53]},{"city":"Paris","zip":null}],"raw":[0,1,254,255],"note":null}
;

fn encodeAlloc(comptime T: type, value: T) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try json.encode(T, &value, &out.writer);
    return out.toOwnedSlice();
}

test "a sample value encodes to its golden JSON and decodes back" {
    const text = try encodeAlloc(Account, account);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(account_json, text);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var problem: json.Problem = .{};
    try testing.expectEqualDeep(account, try json.decode(Account, arena.allocator(), text, .{}, &problem));
}

test "the decoder takes the golden JSON in any order, with spaces, escapes and unknown fields" {
    const shuffled =
        \\ { "note" : null , "raw" : [0,1,254,255], "addresses": [{"zip":[49,50,51,52,53],"city":"London","floor":3},{"city":"Paris"}],
        \\   "tags": ["a", "\u00e9", "\ud83d\ude00"], "nickname": null, "name": "Ada \u0022the\u0022 Countess\n",
        \\   "status": "blocked", "flags": [true, false, true], "small": -32768, "ratio": 1.5e0, "rate": 1e-1,
        \\   "balance": "-9223372036854775808", "id": "18446744073709551615", "extra": {"deep": [[], {}]} }
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var problem: json.Problem = .{};
    const decoded = json.decode(Account, arena.allocator(), shuffled, .{}, &problem) catch |err| {
        std.debug.print("refused: {s} at {?s}\n", .{ problem.message, problem.field });
        return err;
    };
    try testing.expectEqualDeep(account, decoded);
}

test "integers past 2^53 keep every digit both ways" {
    const Wide = struct { a: u64, b: i64, c: u53, d: i33 };
    const value: Wide = .{ .a = 9007199254740993, .b = -9007199254740993, .c = std.math.maxInt(u53), .d = std.math.minInt(i33) };
    const text = try encodeAlloc(Wide, value);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\"a\":\"9007199254740993\",\"b\":\"-9007199254740993\",\"c\":\"9007199254740991\",\"d\":\"-4294967296\"}", text);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var problem: json.Problem = .{};
    try testing.expectEqualDeep(value, try json.decode(Wide, arena.allocator(), text, .{}, &problem));
}

test "floats read back exactly" {
    const samples = [_]f64{ 0.1, 0.2, 0.30000000000000004, 1e-7, 123456.789, 1e300, -2.5e-300, 5e-324, std.math.floatMax(f64), std.math.floatMin(f64), 9007199254740992 };
    for (samples) |x| {
        const text = try encodeAlloc(f64, x);
        defer testing.allocator.free(text);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var problem: json.Problem = .{};
        try testing.expectEqual(x, try json.decode(f64, arena.allocator(), text, .{}, &problem));
    }
    const singles = [_]f32{ 0.1, 1.0 / 3.0, 16777216, std.math.floatMax(f32), std.math.floatTrueMin(f32), -0.0 };
    for (singles) |x| {
        const text = try encodeAlloc(f32, x);
        defer testing.allocator.free(text);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var problem: json.Problem = .{};
        const back = try json.decode(f32, arena.allocator(), text, .{}, &problem);
        try testing.expectEqual(@as(u32, @bitCast(x)), @as(u32, @bitCast(back)));
    }
}

/// A body of `levels` arrays inside each other around `inner`.
fn nestedArrays(levels: usize, inner: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try out.appendNTimes(testing.allocator, '[', levels);
    try out.appendSlice(testing.allocator, inner);
    try out.appendNTimes(testing.allocator, ']', levels);
    return out.toOwnedSlice(testing.allocator);
}

/// `levels` slices inside each other around a u32.
fn Nested(comptime levels: usize) type {
    return if (levels == 0) u32 else []const Nested(levels - 1);
}

/// "[0]" `count` times after `prefix`, in `arena`.
fn indexPath(arena: *std.heap.ArenaAllocator, prefix: []const u8, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena.allocator(), prefix);
    for (0..count) |_| try out.appendSlice(arena.allocator(), "[0]");
    return out.items;
}

const Outcome = struct {
    problem: json.Problem = .{},
    failed: bool = false,
    /// Bytes that the arena took from the allocator under it.
    memory: usize = 0,
};

/// Decodes `bytes` as `T` with the default limits and reports what
/// happened and the memory it took; `arena` keeps the problem's path.
fn run(comptime T: type, arena: *std.heap.ArenaAllocator, bytes: []const u8) Outcome {
    var counting: std.testing.FailingAllocator = .init(arena.allocator(), .{});
    var inner: std.heap.ArenaAllocator = .init(counting.allocator());
    defer inner.deinit();
    var outcome: Outcome = .{};
    _ = json.decode(T, inner.allocator(), bytes, .{}, &outcome.problem) catch |err| {
        outcome.failed = true;
        if (err == error.OutOfMemory) outcome.problem.message = "out of memory";
        if (outcome.problem.field) |field| outcome.problem.field = arena.allocator().dupe(u8, field) catch "(no memory)";
    };
    outcome.memory = counting.allocated_bytes;
    return outcome;
}

fn expectAccepted(outcome: Outcome) !void {
    if (outcome.failed) {
        std.debug.print("refused: {s} at {?s}\n", .{ outcome.problem.message, outcome.problem.field });
        return error.TestUnexpectedRefusal;
    }
}

fn expectMemoryBelow(outcome: Outcome, limit: usize) !void {
    if (outcome.memory >= limit) {
        std.debug.print("the decode took {d} bytes; expected less than {d}\n", .{ outcome.memory, limit });
        return error.TestTooMuchMemory;
    }
}

fn expectRefusal(outcome: Outcome, field: ?[]const u8, message: []const u8) !void {
    try testing.expect(outcome.failed);
    try testing.expectEqualStrings(message, outcome.problem.message);
    if (field) |expected| {
        try testing.expectEqualStrings(expected, outcome.problem.field orelse "(null)");
    } else try testing.expect(outcome.problem.field == null);
}

test "32 levels of nesting decode, 33 do not, in typed values and skipped ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const ok = try nestedArrays(32, "1");
    defer testing.allocator.free(ok);
    try expectAccepted(run(Nested(32), &arena, ok));
    const deep = try nestedArrays(33, "1");
    defer testing.allocator.free(deep);
    try expectRefusal(run(Nested(33), &arena, deep), try indexPath(&arena, "", 32), "too deep");

    // An unknown field inside the top object: 1 + 31 levels pass, 1 + 32 do not.
    const Top = struct { a: u32 = 0 };
    const inner_ok = try nestedArrays(31, "");
    defer testing.allocator.free(inner_ok);
    const body_ok = try std.mem.concat(testing.allocator, u8, &.{ "{\"x\":", inner_ok, "}" });
    defer testing.allocator.free(body_ok);
    try expectAccepted(run(Top, &arena, body_ok));
    const inner_deep = try nestedArrays(32, "");
    defer testing.allocator.free(inner_deep);
    const body_deep = try std.mem.concat(testing.allocator, u8, &.{ "{\"x\":", inner_deep, "}" });
    defer testing.allocator.free(body_deep);
    try expectRefusal(run(Top, &arena, body_deep), try indexPath(&arena, "x", 31), "too deep");
}

test "an unknown subtree far deeper than the limit is refused at the limit, in little memory" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Top = struct { a: u32 = 0 };
    const levels = 100_000;
    const inner = try nestedArrays(levels, "{\"k\":1}");
    defer testing.allocator.free(inner);
    const body = try std.mem.concat(testing.allocator, u8, &.{ "{\"a\":1,\"x\":", inner, "}" });
    defer testing.allocator.free(body);
    const outcome = run(Top, &arena, body);
    try expectRefusal(outcome, try indexPath(&arena, "x", 31), "too deep");
    try expectMemoryBelow(outcome, 16 * 1024);
}

/// A body of `count` items: "[0,0,…]" inside `before` and `after`.
fn items(count: usize, before: []const u8, after: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, before);
    try out.append(testing.allocator, '[');
    for (0..count) |i| try out.appendSlice(testing.allocator, if (i == 0) "0" else ",0");
    try out.append(testing.allocator, ']');
    try out.appendSlice(testing.allocator, after);
    return out.toOwnedSlice(testing.allocator);
}

/// An object of `count` members with distinct keys: {"k0":0,"k1":0,…}.
fn members(count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try out.append(testing.allocator, '{');
    for (0..count) |i| try out.print(testing.allocator, "{s}\"k{d}\":0", .{ if (i == 0) "" else ",", i });
    try out.append(testing.allocator, '}');
    return out.toOwnedSlice(testing.allocator);
}

test "100 000 items decode, 100 001 do not, in arrays and objects, typed or skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Top = struct { a: u32 = 0 };

    const typed_ok = try items(100_000, "", "");
    defer testing.allocator.free(typed_ok);
    const typed = run([]const u32, &arena, typed_ok);
    try expectAccepted(typed);
    // The items are counted first and stored once: no copies left behind.
    try expectMemoryBelow(typed, 2 * 100_000 * @sizeOf(u32));
    const typed_over = try items(100_001, "", "");
    defer testing.allocator.free(typed_over);
    try expectRefusal(run([]const u32, &arena, typed_over), null, "too many items");

    const skipped_ok = try items(100_000, "{\"x\":", "}");
    defer testing.allocator.free(skipped_ok);
    const skipped = run(Top, &arena, skipped_ok);
    try expectAccepted(skipped);
    // Skipping keeps no item: the memory does not grow with them.
    try expectMemoryBelow(skipped, 16 * 1024);
    const skipped_over = try items(100_001, "{\"x\":", "}");
    defer testing.allocator.free(skipped_over);
    try expectRefusal(run(Top, &arena, skipped_over), "x", "too many items");

    const object_ok = try members(100_000);
    defer testing.allocator.free(object_ok);
    const keys = run(Top, &arena, object_ok);
    try expectAccepted(keys);
    // Unknown keys are kept until their object ends, to find a repeat:
    // a slice each, stored once.
    try expectMemoryBelow(keys, 2 * 100_000 * @sizeOf([]const u8));
    const object_over = try members(100_001);
    defer testing.allocator.free(object_over);
    try expectRefusal(run(Top, &arena, object_over), null, "too many items");
}

test "the unknown keys of an object are dropped when it ends" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.append(testing.allocator, '[');
    for (0..100_000) |i| try body.appendSlice(testing.allocator, if (i == 0) "{\"x\":1,\"y\":2,\"z\":3}" else ",{\"x\":1,\"y\":2,\"z\":3}");
    try body.append(testing.allocator, ']');
    const Point = struct { x: i32, y: i32 };
    const outcome = run([]const Point, &arena, body.items);
    try expectAccepted(outcome);
    // The points themselves and the arena's half again; no key of the
    // objects before.
    try expectMemoryBelow(outcome, 2 * 100_000 * @sizeOf(Point));
}

test "a repeated key among 100 000 unknown ones is found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = try members(99_999);
    defer testing.allocator.free(body);
    // "k12345" again as the last of 100 000 members.
    const repeated = try std.mem.concat(testing.allocator, u8, &.{ body[0 .. body.len - 1], ",\"k12345\":1}" });
    defer testing.allocator.free(repeated);
    const Top = struct { a: u32 = 0 };
    try expectRefusal(run(Top, &arena, repeated), "k12345", "duplicate key");
}

test "a decode out of memory says so at every allocation, never that the body is invalid" {
    const Item = struct { name: []const u8, tags: []const []const u8 = &.{}, n: u64 = 0 };
    const Body = struct { items: []const Item, note: ?[]const u8 = null };
    // Escapes, slices, a skipped subtree and more than 16 unknown keys in
    // one object: every kind of allocation a decode makes.
    const body =
        \\{"x":{"a":[1,{"b":"c\n"}],"d":{}},"items":[{"name":"a\tb","tags":["t\"","u"],"n":"5","zz":[[[]]]},
        \\{"name":"q","k1":1,"k2":2,"k3":3,"k4":4,"k5":5,"k6":6,"k7":7,"k8":8,"k9":9,"k10":10,"k11":11,"k12":12,
        \\"k13":13,"k14":14,"k15":15,"k16":16,"k17":17}],"note":"\"x\""}
    ;
    var backing: std.heap.ArenaAllocator = .init(testing.allocator);
    defer backing.deinit();
    var sites: usize = 0;
    while (true) : (sites += 1) {
        try testing.expect(sites < 1000);
        var failing: std.testing.FailingAllocator = .init(backing.allocator(), .{ .fail_index = sites });
        var problem: json.Problem = .{};
        if (json.decode(Body, failing.allocator(), body, .{}, &problem)) |value| {
            try testing.expectEqual(@as(usize, 2), value.items.len);
            try testing.expectEqualStrings("a\tb", value.items[0].name);
            try testing.expectEqualStrings("t\"", value.items[0].tags[0]);
            try testing.expectEqual(@as(u64, 5), value.items[0].n);
            try testing.expectEqualStrings("\"x\"", value.note.?);
            break;
        } else |err| {
            testing.expectEqual(error.OutOfMemory, err) catch |failure| {
                std.debug.print("allocation {d} failed: {s} at {?s}\n", .{ sites, problem.message, problem.field });
                return failure;
            };
        }
    }
    // Each of these allocations failed once, in a decode of its own.
    try testing.expect(sites >= 8);
}

test "a long string with escapes is decoded into one buffer" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"text\":\"");
    // 100 000 escaped line breaks, 200 000 bytes raw.
    for (0..100_000) |_| try body.appendSlice(testing.allocator, "\\n");
    try body.appendSlice(testing.allocator, "\"}");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Text = struct { text: []const u8 };
    const outcome = run(Text, &arena, body.items);
    try expectAccepted(outcome);
    try expectMemoryBelow(outcome, 2 * 200_000);

    var inner: std.heap.ArenaAllocator = .init(testing.allocator);
    defer inner.deinit();
    var problem: json.Problem = .{};
    const decoded = try json.decode(Text, inner.allocator(), body.items, .{}, &problem);
    try testing.expectEqual(@as(usize, 100_000), decoded.text.len);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfNone(u8, decoded.text, "\n"));
}
