//! Tests of the options of reads: the literal of options of find and
//! findOne, the sort with the order of its keys, and the projection that
//! the type of a result makes. tests/compile_errors.zig holds the options
//! and projections that must not compile.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const options = @import("../query/options.zig");
const codec = @import("../model/codec.zig");
const models = @import("models.zig");
const User = models.User;
const Account = models.Account;

/// `got` is the document `expected`, byte for byte.
fn expectDoc(expected: anytype, got: bson.RawDocument) !void {
    const want = try bson.encode(testing.allocator, expected, .{});
    defer want.deinit();
    if (!std.mem.eql(u8, want.bytes, got.bytes)) {
        std.debug.print("expected {f}\n   found {f}\n", .{ want.raw(), got });
        return error.TestExpectedEqual;
    }
}

test "a sort keeps the order of its keys, under their BSON names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectDoc(.{ .status = @as(i32, 1), .createdAt = @as(i32, -1) }, try options.sort(User, a, .{ .status = .asc, .created_at = .desc }));
    try expectDoc(.{ .createdAt = @as(i32, -1), .status = @as(i32, 1) }, try options.sort(User, a, .{ .created_at = .desc, .status = .asc }));
    var direction: odm.Direction = .desc;
    _ = &direction;
    try expectDoc(.{ .age = @as(i32, -1), ._id = @as(i32, 1) }, try options.sort(User, a, .{ .age = direction, .id = .asc }));
    // Nested literals name the paths of structs and of lists of structs.
    try expectDoc(.{ .@"profile.city" = @as(i32, 1) }, try options.sort(User, a, .{ .profile = .{ .city = .asc } }));
    try expectDoc(.{ .@"items.qty" = @as(i32, -1), .@"address.zip" = @as(i32, 1) }, try options.sort(Account, a, .{ .items = .{ .qty = .desc }, .address = .{ .zip = .asc } }));
    try expectDoc(.{}, try options.sort(User, a, .{}));
}

test "find takes sort, skip, limit and batch_size; findOne sort and skip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try options.find(User, .find, a, .{ .sort = .{ .status = .asc, .created_at = .desc }, .skip = 5, .limit = 100, .batch_size = 2 });
    try expectDoc(.{ .status = @as(i32, 1), .createdAt = @as(i32, -1) }, all.sort.?);
    try testing.expectEqual(5, all.skip);
    try testing.expectEqual(100, all.limit);
    try testing.expectEqual(2, all.batch_size.?);

    // The defaults: no sort, no skip, no limit, the driver's batch size.
    const none = try options.find(User, .find, a, .{});
    try testing.expectEqual(null, none.sort);
    try testing.expectEqual(0, none.skip);
    try testing.expectEqual(0, none.limit);
    try testing.expectEqual(null, none.batch_size);

    // Counts known at run time; a ?u32 that is null sets nothing.
    var skip: u16 = 7;
    var limit: ?u32 = 30;
    var batch: ?u32 = null;
    _ = .{ &skip, &limit, &batch };
    const runtime = try options.find(User, .find, a, .{ .skip = skip, .limit = limit, .batch_size = batch });
    try testing.expectEqual(7, runtime.skip);
    try testing.expectEqual(30, runtime.limit);
    try testing.expectEqual(null, runtime.batch_size);
    limit = null;
    try testing.expectEqual(0, (try options.find(User, .find, a, .{ .limit = limit })).limit);
    try testing.expectEqual(null, (try options.find(User, .find, a, .{ .sort = .{} })).sort);

    const one = try options.find(User, .findOne, a, .{ .sort = .{ .age = .desc }, .skip = 3 });
    try expectDoc(.{ .age = @as(i32, -1) }, one.sort.?);
    try testing.expectEqual(3, one.skip);
    try testing.expectEqual(0, one.limit);
}

const UserPreview = struct { name: []const u8, email: []const u8 };

test "a projection comes from the fields of the result type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectDoc(.{ .name = @as(i32, 1), .email = @as(i32, 1), ._id = @as(i32, 0) }, try options.projection(User, UserPreview, a));
    try expectDoc(.{ ._id = @as(i32, 1), .name = @as(i32, 1) }, try options.projection(User, struct { id: ?bson.ObjectId, name: []const u8 }, a));
    try expectDoc(.{ .@"profile.city" = @as(i32, 1), ._id = @as(i32, 0) }, try options.projection(User, struct { profile: ?struct { city: []const u8 } }, a));
    try expectDoc(.{ .createdAt = @as(i32, 1), ._id = @as(i32, 0) }, try options.projection(User, struct { created_at: ?bson.DateTime }, a));
    // The id is always there, so a projection may take it as required; a
    // struct of the model's type is the whole field; a list of structs
    // takes a projection of its items.
    try expectDoc(.{ ._id = @as(i32, 1) }, try options.projection(User, struct { id: bson.ObjectId }, a));
    try expectDoc(.{ .profile = @as(i32, 1), ._id = @as(i32, 0) }, try options.projection(User, struct { profile: ?User.Profile }, a));
    try expectDoc(.{ .@"items.sku" = @as(i32, 1), .@"address.city" = @as(i32, 1), ._id = @as(i32, 0) }, try options.projection(Account, struct {
        items: []const struct { sku: []const u8 },
        address: struct { city: []const u8 },
    }, a));
}

test "a projection reads back by the keys of its model" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: odm.Diagnostics = .{};
    const doc = try bson.encode(testing.allocator, .{ .name = "Ann", .email = "a@b" }, .{});
    defer doc.deinit();
    const preview = try codec.decode(User, UserPreview, arena.allocator(), doc.raw(), &d);
    try testing.expectEqualStrings("Ann", preview.name);
    try testing.expectEqualStrings("a@b", preview.email);
}
