//! The indexes of a collection as `createIndexes` makes them: their
//! models, and the names that the index management spec gives them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bson = @import("../bson.zig");
const errors = @import("../contract/errors.zig");
const commands = @import("command.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;

/// An index to make, which `mongo.Collection.createIndexes` takes:
///
/// ```zig
/// _ = try users.createIndexes(io, op, &.{
///     .{ .keys = bson.literal(.{ .email = 1 }), .unique = true },
///     .{ .keys = bson.literal(.{ .created = 1 }), .expire_after_seconds = 24 * 3600 },
/// }, .{ .allocator = arena });
/// ```
///
/// Text, 2dsphere and wildcard indexes with options of their own are made
/// with `mongo.Database.runCommand`.
pub const IndexModel = struct {
    /// The fields of the index, in their order, each with its kind: 1
    /// ascending, -1 descending, or a string such as "text", "2dsphere"
    /// or "hashed": `bson.literal(.{ .email = 1, .age = -1 })`.
    keys: bson.RawDocument,
    /// Null: the name made of the keys, "email_1_age_-1".
    name: ?[]const u8 = null,
    /// No two documents have the same values of the keys.
    unique: bool = false,
    /// Only the documents that hold the fields of the keys are in it.
    sparse: bool = false,
    /// A TTL index: the server deletes a document this many seconds after
    /// the date in its field.
    expire_after_seconds: ?u32 = null,
    /// Only the documents that match it are in the index:
    /// `bson.literal(.{ .active = true })`.
    partial_filter_expression: ?bson.RawDocument = null,
    /// How the strings of the keys compare: `bson.literal(.{ .locale = "en" })`.
    collation: ?bson.RawDocument = null,
    /// Kept up to date, but not used by queries until unhidden.
    hidden: bool = false,
};

/// The name that the index management spec gives an index of `keys`, in
/// `allocator`: each key and its value joined by `_`, and the pairs
/// joined by `_`, so `{email: 1, age: -1}` is "email_1_age_-1" and
/// `{bio: "text"}` is "bio_text". A number goes as an integer when it is
/// one, a string as it is. Keys of another type, none at all, or broken
/// bytes are `error.InvalidArgument`, with `index`, the place of the
/// model in the list, in the diagnostics.
pub fn defaultName(allocator: Allocator, keys: bson.RawDocument, index: usize, diagnostics: ?*Diagnostics) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    var it = keys.iterator();
    var pairs: usize = 0;
    while (it.next() catch return commands.invalid(diagnostics, "the keys of index {d} " ++ commands.unwritable, .{index})) |key| : (pairs += 1) {
        if (pairs > 0) w.writeByte('_') catch return error.OutOfMemory;
        w.print("{s}_", .{key.key}) catch return error.OutOfMemory;
        const written = switch (key.value) {
            .int32 => |n| w.print("{d}", .{n}),
            .int64 => |n| w.print("{d}", .{n}),
            .double => |x| if (@trunc(x) == x and @abs(x) < 0x1p63) w.print("{d}", .{@as(i64, @intFromFloat(x))}) else w.print("{d}", .{x}),
            .string => |text| w.writeAll(text),
            else => |value| return commands.invalid(diagnostics, "key '{s}' of index {d} is of type {t}, of which no name is made: a key is a number, such as 1 or -1, or a string, such as \"text\"; or give the index a name", .{ key.key, index, value }),
        };
        written catch return error.OutOfMemory;
    }
    if (pairs == 0) return commands.invalid(diagnostics, "the keys of index {d} are empty: an index has at least one key", .{index});
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const testing = std.testing;

fn expectName(expected: []const u8, keys: bson.RawDocument) !void {
    const name = try defaultName(testing.allocator, keys, 0, null);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings(expected, name);
}

test "the name of an index joins each key and its value with _, and the pairs with _" {
    try expectName("email_1_age_-1", bson.literal(.{ .email = 1, .age = -1 }));
    try expectName("email_1", bson.literal(.{ .email = 1 }));
    try expectName("bio_text", bson.literal(.{ .bio = "text" }));
    try expectName("location_2dsphere_kind_1", bson.literal(.{ .location = "2dsphere", .kind = 1 }));
    try expectName("$**_1", bson.literal(.{ .@"$**" = 1 }));
    try expectName("address.city_1", bson.literal(.{ .@"address.city" = 1 }));
    try expectName("n_1", bson.literal(.{ .n = @as(i64, 1) }));
    // A double that holds an integer goes as the integer, as the shell
    // writes it; another goes as it is.
    try expectName("a_1_b_-1", bson.literal(.{ .a = 1.0, .b = -1.0 }));
    try expectName("a_0.5", bson.literal(.{ .a = 0.5 }));
}

test "keys of no name are InvalidArgument: none, another type, broken bytes" {
    var d: Diagnostics = .{};
    try testing.expectError(error.InvalidArgument, defaultName(testing.allocator, bson.literal(.{}), 2, &d));
    try testing.expectEqualStrings("the keys of index 2 are empty: an index has at least one key", d.message());
    try testing.expectError(error.InvalidArgument, defaultName(testing.allocator, bson.literal(.{ .a = 1, .b = true }), 0, &d));
    try testing.expectEqualStrings("key 'b' of index 0 is of type boolean, of which no name is made: a key is a number, such as 1 or -1, or a string, such as \"text\"; or give the index a name", d.message());
    const broken: bson.RawDocument = .{ .bytes = &.{ 9, 0, 0, 0, 0x10, 'a', 0, 1, 0 } };
    try testing.expectError(error.InvalidArgument, defaultName(testing.allocator, broken, 1, &d));
    try testing.expect(std.mem.startsWith(u8, d.message(), "the keys of index 1 cannot be written as BSON"));
}
