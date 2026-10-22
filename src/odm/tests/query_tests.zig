//! Tests of odm.Query on odm.testing.FakeDriver: the find that a query
//! built at run time sends, and only when it runs.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const models = @import("models.zig");
const support = @import("support.zig");
const User = models.User;
const Shop = support.Shop;
const expectDocument = support.expectDocument;

const at: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };
const ann_id = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293") catch unreachable;
const ann = bson.literal(.{ ._id = ann_id, .email = "ann@example.com", .name = "Ann", .age = @as(i64, 30), .status = "active", .createdAt = at });

/// The search of design §4.9: optional conditions of a handler.
fn search(users: odm.Collection(User), io: Io, arena: std.mem.Allocator, min_age: ?u32, active_only: bool) !void {
    var q = users.query(arena);
    if (min_age) |age| q = q.where(.{ .age = .{ .gte = age } });
    if (active_only) q = q.where(.{ .status = .active });
    var page = try q.sort(.{ .age = .desc }).limit(50).execute(io, .root);
    defer page.deinit(io);
}

test "the conditions of where are an AND, in call order" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const users = acme.collection(User);

    try search(users, io, arena.allocator(), null, false);
    try search(users, io, arena.allocator(), 30, false);
    try search(users, io, arena.allocator(), 30, true);
    try search(users, io, arena.allocator(), null, true);
    const sent = shop.sent(io);
    try testing.expectEqual(@as(usize, 4), sent.len);
    try expectDocument(.{}, sent[0].call.find.filter);
    try expectDocument(.{ .age = .{ .@"$gte" = @as(i64, 30) } }, sent[1].call.find.filter);
    try expectDocument(.{ .@"$and" = .{ .{ .age = .{ .@"$gte" = @as(i64, 30) } }, .{ .status = "active" } } }, sent[2].call.find.filter);
    try expectDocument(.{ .status = "active" }, sent[3].call.find.filter);
    for (sent) |entry| {
        try expectDocument(.{ .age = @as(i32, -1) }, entry.call.find.sort.?);
        try testing.expectEqual(@as(u32, 50), entry.call.find.limit);
        try testing.expectEqualStrings("users", entry.call.find.ns.collection);
    }
    try testing.expectEqual(@as(u64, 4), shop.registry.stats(io).operations);
}

test "a second sort replaces the first" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const q = acme.collection(User).query(arena.allocator());

    var first = try q.sort(.{ .age = .desc }).sort(.{ .name = .asc }).execute(io, .root);
    first.deinit(io);
    try expectDocument(.{ .name = @as(i32, 1) }, shop.sent(io)[0].call.find.sort.?);
    // Directions known at run time, and a path into a struct.
    var direction: odm.Direction = .asc;
    _ = &direction;
    var second = try q.sort(.{ .created_at = direction, .profile = .{ .city = .desc } }).execute(io, .root);
    second.deinit(io);
    try expectDocument(.{ .createdAt = @as(i32, 1), .@"profile.city" = @as(i32, -1) }, shop.sent(io)[1].call.find.sort.?);
    // The query itself did not change, and .{} is no sort.
    var third = try q.sort(.{}).execute(io, .root);
    third.deinit(io);
    try testing.expect(shop.sent(io)[2].call.find.sort == null);
}

test "nothing goes out before execute" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var skip: u32 = 40;
    _ = &skip;
    const q = acme.collection(User).query(arena.allocator()).where(.{ .status = .blocked }).sort(.{ .email = .asc }).skip(skip).limit(20).batchSize(5);
    try testing.expectEqual(@as(usize, 0), shop.sent(io).len);
    var cursor = try q.execute(io, .root);
    defer cursor.deinit(io);
    const find = shop.sent(io)[0].call.find;
    try expectDocument(.{ .status = "blocked" }, find.filter);
    try expectDocument(.{ .email = @as(i32, 1) }, find.sort.?);
    try testing.expectEqual(@as(u32, 40), find.skip);
    try testing.expectEqual(@as(u32, 20), find.limit);
    try testing.expectEqual(@as(?u32, 5), find.batch_size);
    try testing.expect(find.projection == null);
}

test "first decodes into the query's arena" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    var buffer: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const q = acme.collection(User).query(fixed.allocator()).where(.{ .name = "Ann" }).sort(.{ .age = .desc }).skip(1);
    try shop.fake.reply("fake://shared", .{ .documents = &.{ann} });
    const found = (try q.first(io, .root)).?;
    try testing.expectEqualStrings("Ann", found.name);
    try testing.expect(fixed.ownsPtr(@constCast(found.name.ptr)));
    const find = shop.sent(io)[0].call.find;
    try testing.expectEqual(@as(u32, 1), find.limit);
    try testing.expectEqual(@as(u32, 1), find.skip);
    try expectDocument(.{ .age = @as(i32, -1) }, find.sort.?);
    // Nothing matches: null, and no cursor left behind.
    try testing.expect(try q.first(io, .root) == null);
    try testing.expectEqual(@as(usize, 0), shop.fake.counts(io).cursors);
    try testing.expectEqual(@as(usize, 1), shop.registry.stats(io).leases);
}

test "count of a query" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try shop.fake.reply("fake://shared", .{ .count = 4 });
    const q = acme.collection(User).query(arena.allocator()).where(.{ .age = .{ .lt = 18 } }).limit(3);
    try testing.expectEqual(@as(u64, 4), try q.count(io, .root));
    try expectDocument(.{ .age = .{ .@"$lt" = @as(i64, 18) } }, shop.sent(io)[0].call.count.filter);
}

const UserPreview = struct { name: []const u8, email: []const u8 };

test "executeAs with a projection" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try shop.fake.reply("fake://shared", .{ .documents = &.{bson.literal(.{ .name = "Ann", .email = "ann@example.com" })} });
    var cursor = try acme.collection(User).query(arena.allocator()).where(.{ .status = .active }).executeAs(UserPreview, io, .root);
    defer cursor.deinit(io);
    try expectDocument(.{ .name = @as(i32, 1), .email = @as(i32, 1), ._id = @as(i32, 0) }, shop.sent(io)[0].call.find.projection.?);
    try testing.expectEqualStrings("ann@example.com", (try cursor.next(io, .root, arena.allocator())).?.email);
}

test "an error of a where comes out of execute" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var not_utf8_buffer = "\xff".*;
    const not_utf8: []const u8 = &not_utf8_buffer;
    // Later where calls change nothing once one failed.
    const q = acme.collection(User).query(arena.allocator()).where(.{ .name = not_utf8 }).where(.{ .age = 3 });
    try testing.expectError(error.EncodeFailed, q.execute(io, .root));
    try testing.expect(std.mem.startsWith(u8, acme.diagnostics().message(), "odm: the filter did not become BSON"));
    try testing.expectError(error.EncodeFailed, q.first(io, .root));
    try testing.expectError(error.EncodeFailed, q.count(io, .root));
    try testing.expectEqual(@as(usize, 0), shop.sent(io).len);
    const s = shop.registry.stats(io);
    try testing.expectEqual(@as(usize, 1), s.leases);
    try testing.expectEqual(@as(u64, 3), s.operation_errors);
}
