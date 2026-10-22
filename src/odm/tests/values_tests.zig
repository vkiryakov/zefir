//! Tests of the value rules that filters, sorts and updates share: how a
//! literal of conditions is told from a value of a field, how the fields of
//! a literal known at compile time are read, which values known at run time
//! a field takes, and how values known at compile time are checked.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const values = @import("../query/values.zig");
const models = @import("models.zig");
const User = models.User;

test "a literal is told from a value of the field's type" {
    try testing.expect(values.isLiteral(@TypeOf(.{ .city = "Paris" }), User.Profile));
    try testing.expect(!values.isLiteral(User.Profile, User.Profile));
    try testing.expect(!values.isLiteral(?User.Profile, User.Profile));
    // The empty literal is a literal too, and so is a literal of operators.
    try testing.expect(values.isLiteral(@TypeOf(.{}), User.Profile));
    try testing.expect(values.isLiteral(@TypeOf(.{ .gte = 18 }), u32));
    // Values of other types are not literals: a tuple is a list, and the
    // types of BSON are values of their own.
    try testing.expect(!values.isLiteral(@TypeOf(.{ "a", "b" }), []const []const u8));
    try testing.expect(!values.isLiteral(bson.ObjectId, User.Profile));
    try testing.expect(!values.isLiteral(u32, u32));
}

test "the comptime fields of a literal keep their values" {
    const literal = .{ .age = 18, .status = .active, .p = null, .s = "x" };
    const L = @TypeOf(literal);
    inline for (.{ "age", "status", "p", "s" }) |name| try testing.expect(values.isComptime(L, name));
    try testing.expectEqual(18, comptime values.comptimeValue(L, "age"));
    try testing.expectEqual(.active, comptime values.comptimeValue(L, "status"));
    try testing.expectEqual(null, comptime values.comptimeValue(L, "p"));
    try testing.expectEqualStrings("x", comptime values.comptimeValue(L, "s"));

    var x: u32 = 18;
    _ = &x;
    try testing.expect(!values.isComptime(@TypeOf(.{ .age = x }), "age"));
    // The items of a tuple are fields too: one known, one not.
    const R = @TypeOf(.{ x, 2 });
    try testing.expect(!values.isComptime(R, "0"));
    try testing.expect(values.isComptime(R, "1"));
    try testing.expectEqual(2, comptime values.comptimeValue(R, "1"));
}

test "fits takes a runtime value that the field holds without narrowing" {
    const Other = enum { active, blocked };
    const yes = .{
        .{ u8, u32 },
        .{ u16, i32 },
        .{ u32, i64 },
        .{ i32, i64 },
        .{ f64, f64 },
        .{ []u8, []const u8 },
        .{ [:0]const u8, []const u8 },
        .{ *const [3]u8, []const u8 },
        .{ User.Status, User.Status },
        .{ bson.ObjectId, bson.ObjectId },
        .{ []const u32, []const u32 },
        .{ [3]u32, []const u32 },
        // Lists of narrower items, a list for a list of the same length, a
        // value or an optional one for an optional field, a struct of the
        // field's type.
        .{ []const u16, []const u32 },
        .{ *const [3]u32, []const u32 },
        .{ [2]u32, [2]u32 },
        .{ u16, ?u32 },
        .{ ?u16, ?u32 },
        .{ User.Profile, User.Profile },
        .{ []const []const u8, []const []const u8 },
    };
    inline for (yes) |pair| {
        testing.expect(values.fits(pair[0], pair[1])) catch |err| {
            std.debug.print("fits({s}, {s}) is false\n", .{ @typeName(pair[0]), @typeName(pair[1]) });
            return err;
        };
    }
    const no = .{
        .{ u32, u8 },
        .{ i32, u32 },
        .{ u32, i32 },
        .{ u64, i64 },
        .{ f32, f64 },
        .{ i64, f64 },
        .{ Other, User.Status },
        .{ []const u64, []const u32 },
        .{ []const u8, u32 },
        // A slice for a list of a fixed length, a list of another length,
        // an optional value for a field that is not optional, a string for
        // a list, a struct of another type.
        .{ []const u32, [2]u32 },
        .{ [3]u32, [2]u32 },
        .{ ?u32, u32 },
        .{ []const u8, []const u32 },
        .{ models.Address, User.Profile },
    };
    inline for (no) |pair| {
        testing.expect(!values.fits(pair[0], pair[1])) catch |err| {
            std.debug.print("fits({s}, {s}) is true\n", .{ @typeName(pair[0]), @typeName(pair[1]) });
            return err;
        };
    }
}

test "comptimeProblem checks values known at compile time" {
    try testing.expectEqualStrings("is u8, and 300 is out of its range", comptime values.comptimeProblem(u8, 300).?);
    try testing.expectEqualStrings("is u32, and -1 is out of its range", comptime values.comptimeProblem(u32, -1).?);
    try testing.expectEqualStrings(
        "is tests.models.User.Status, which has no tag 'actve'; did you mean 'active'?",
        comptime values.comptimeProblem(User.Status, .actve).?,
    );
    try testing.expectEqualStrings("is []const u8, and its value is not UTF-8", comptime values.comptimeProblem([]const u8, "\xff").?);
    // Values in range, tags of the enum, UTF-8, null for an optional.
    try testing.expectEqual(null, comptime values.comptimeProblem(u8, 255));
    try testing.expectEqual(null, comptime values.comptimeProblem(i32, -1));
    try testing.expectEqual(null, comptime values.comptimeProblem(User.Status, .blocked));
    try testing.expectEqual(null, comptime values.comptimeProblem([]const u8, "Zoë"));
    try testing.expectEqual(null, comptime values.comptimeProblem(?u32, null));
    try testing.expectEqual(null, comptime values.comptimeProblem(?u32, 5));
    try testing.expectEqualStrings("is u32, and -5 is out of its range", comptime values.comptimeProblem(?u32, -5).?);
    // A typed integer known at compile time is checked by its value, and
    // an integer for a double by whether the double holds it exactly.
    try testing.expectEqual(null, comptime values.comptimeProblem(u32, @as(u64, 5)));
    try testing.expectEqual(null, comptime values.comptimeProblem(f64, 1 << 53));
    try testing.expectEqualStrings("is f64, and 9007199254740993 is out of its range", comptime values.comptimeProblem(f64, (1 << 53) + 1).?);
    // The items of a list: the first one that does not fit.
    try testing.expectEqualStrings("is u16, and 70000 is out of its range", comptime values.comptimeProblem([]const u16, .{ 1, 70000 }).?);
    try testing.expectEqual(null, comptime values.comptimeProblem([]const []const u8, .{ "a", "b" }));
}
