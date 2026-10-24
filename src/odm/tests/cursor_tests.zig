//! Tests of the reads of odm.Collection and of odm.Cursor on
//! odm.testing.FakeDriver: what find, findOne, findOneAs and count send,
//! how a cursor decodes, and how its lease lives.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const filter = @import("../query/filter.zig");
const options = @import("../query/options.zig");
const models = @import("models.zig");
const support = @import("support.zig");
const User = models.User;
const Shop = support.Shop;
const expectDocument = support.expectDocument;

const at: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };
const ann_id = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718293") catch unreachable;
const bob_id = bson.ObjectId.parseHex("652f8a1b9c0d4e5f60718294") catch unreachable;
const ann = bson.literal(.{ ._id = ann_id, .email = "ann@example.com", .name = "Ann", .age = @as(i64, 30), .status = "active", .createdAt = at });
const bob = bson.literal(.{ ._id = bob_id, .email = "bob@example.com", .name = "Bob", .status = "blocked", .createdAt = at });
// Without createdAt, which User needs.
const broken = bson.literal(.{ ._id = bob_id, .email = "cid@example.com", .name = "Cid" });

/// Whether `got` is byte for byte `want`.
fn expectBytes(want: bson.RawDocument, got: ?bson.RawDocument) !void {
    try testing.expectEqualSlices(u8, want.bytes, got.?.bytes);
}

test "find sends the encoded filter and options" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const users = acme.collection(User);

    // The filter, as filter.encode writes it, and no options.
    const literal = .{ .status = .active, .age = .{ .gte = 18 } };
    var all = try users.find(io, .root, literal, .{});
    all.deinit(io);
    const plain = shop.sent(io)[0].call.find;
    try testing.expectEqualStrings("acme", plain.ns.database);
    try testing.expectEqualStrings("users", plain.ns.collection);
    try expectBytes(try filter.encode(User, a, literal), plain.filter);
    try testing.expect(plain.sort == null and plain.projection == null);
    try testing.expectEqual(@as(u32, 0), plain.skip);
    try testing.expectEqual(@as(u32, 0), plain.limit);
    try testing.expectEqual(@as(?u32, null), plain.batch_size);

    // Each option on its own.
    var sorted = try users.find(io, .root, .{}, .{ .sort = .{ .status = .asc, .created_at = .desc } });
    sorted.deinit(io);
    try expectBytes(try options.sort(User, a, .{ .status = .asc, .created_at = .desc }), shop.sent(io)[1].call.find.sort);
    try expectDocument(.{}, shop.sent(io)[1].call.find.filter);
    var skipped = try users.find(io, .root, .{}, .{ .skip = 20 });
    skipped.deinit(io);
    try testing.expectEqual(@as(u32, 20), shop.sent(io)[2].call.find.skip);
    var limit: u32 = 10;
    _ = &limit;
    var limited = try users.find(io, .root, .{}, .{ .limit = limit });
    limited.deinit(io);
    try testing.expectEqual(@as(u32, 10), shop.sent(io)[3].call.find.limit);
    var batched = try users.find(io, .root, .{}, .{ .batch_size = 5 });
    batched.deinit(io);
    try testing.expectEqual(@as(?u32, 5), shop.sent(io)[4].call.find.batch_size);
    try testing.expectEqual(@as(usize, 0), shop.fake.counts(io).cursors);
}

test "next decodes into the caller's arena" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    try shop.fake.reply("fake://shared", .{ .documents = &.{ ann, bob } });
    var cursor = try acme.collection(User).find(io, .root, .{}, .{});
    defer cursor.deinit(io);
    var buffer: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const first = (try cursor.next(io, .root, fixed.allocator())).?;
    try testing.expectEqualSlices(u8, &ann_id.bytes, &first.id.?.bytes);
    try testing.expectEqualStrings("Ann", first.name);
    try testing.expectEqual(@as(u32, 30), first.age);
    // The strings are copies in the caller's arena.
    try testing.expect(fixed.ownsPtr(@constCast(first.name.ptr)) and fixed.ownsPtr(@constCast(first.email.ptr)));
    const second = (try cursor.next(io, .root, fixed.allocator())).?;
    try testing.expectEqual(User.Status.blocked, second.status);
    try testing.expectEqual(@as(u32, 0), second.age);
    try testing.expect(second.profile == null);
    try testing.expect(try cursor.next(io, .root, fixed.allocator()) == null);
    try testing.expectEqualStrings("", cursor.diagnostics().message());
}

test "a document that does not fit is DecodeFailed, and next goes on" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try shop.fake.reply("fake://shared", .{ .documents = &.{ ann, broken, bob } });
    var cursor = try acme.collection(User).find(io, .root, .{}, .{});
    defer cursor.deinit(io);
    _ = (try cursor.next(io, .root, arena.allocator())).?;
    try testing.expectError(error.DecodeFailed, cursor.next(io, .root, arena.allocator()));
    const d = cursor.diagnostics();
    try testing.expectEqual(@as(?anyerror, error.MissingField), d.cause);
    try testing.expectEqualStrings("createdAt", d.path());
    try testing.expect(d.message().len > 0);
    // The session's diagnostics are those of the find, which went well.
    try testing.expectEqual(@as(?anyerror, null), acme.diagnostics().cause);
    const third = (try cursor.next(io, .root, arena.allocator())).?;
    try testing.expectEqualStrings("Bob", third.name);
    // Each call of the cursor starts its diagnostics afresh.
    try testing.expectEqual(@as(?anyerror, null), cursor.diagnostics().cause);
    try testing.expect(try cursor.next(io, .root, arena.allocator()) == null);
}

test "nextRaw gives the driver's bytes" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    try shop.fake.reply("fake://shared", .{ .documents = &.{ ann, broken } });
    var cursor = try acme.collection(User).find(io, .root, .{}, .{});
    defer cursor.deinit(io);
    try expectBytes(ann, try cursor.nextRaw(io, .root));
    // A document that the model would not read comes as it is.
    try expectBytes(broken, try cursor.nextRaw(io, .root));
    try testing.expect(try cursor.nextRaw(io, .root) == null);
}

test "findOne gives null when nothing matches" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const users = acme.collection(User);

    try testing.expect(try users.findOne(io, .root, .{ .email = "nobody@example.com" }, .{}, arena.allocator()) == null);
    const find = shop.sent(io)[0].call.find;
    try testing.expectEqual(@as(u32, 1), find.limit);
    try expectDocument(.{ .email = "nobody@example.com" }, find.filter);

    // With a sort and a skip, and a document that matches.
    try shop.fake.reply("fake://shared", .{ .documents = &.{bob} });
    const found = (try users.findOne(io, .root, .{}, .{ .sort = .{ .age = .desc }, .skip = 2 }, arena.allocator())).?;
    try testing.expectEqualStrings("Bob", found.name);
    const second = shop.sent(io)[1].call.find;
    try testing.expectEqual(@as(u32, 1), second.limit);
    try testing.expectEqual(@as(u32, 2), second.skip);
    try expectDocument(.{ .age = @as(i32, -1) }, second.sort.?);
    // The cursors of findOne are gone, and so are their leases.
    try testing.expectEqual(@as(usize, 0), shop.fake.counts(io).cursors);
    try testing.expectEqual(@as(usize, 1), shop.registry.stats(io).leases);
}

const UserPreview = struct { name: []const u8, email: []const u8 };

test "findOneAs sends the projection and decodes P" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try shop.fake.reply("fake://shared", .{ .documents = &.{bson.literal(.{ .name = "Ann", .email = "ann@example.com" })} });
    const preview = (try acme.collection(User).findOneAs(UserPreview, io, .root, .{ .status = .active }, .{}, arena.allocator())).?;
    try testing.expectEqualStrings("Ann", preview.name);
    try testing.expectEqualStrings("ann@example.com", preview.email);
    const find = shop.sent(io)[0].call.find;
    try expectDocument(.{ .name = @as(i32, 1), .email = @as(i32, 1), ._id = @as(i32, 0) }, find.projection.?);
    try testing.expectEqual(@as(u32, 1), find.limit);

    // findAs gives a cursor of P, with the same projection.
    var cursor = try acme.collection(User).findAs(UserPreview, io, .root, .{}, .{});
    defer cursor.deinit(io);
    try expectDocument(.{ .name = @as(i32, 1), .email = @as(i32, 1), ._id = @as(i32, 0) }, shop.sent(io)[1].call.find.projection.?);
    try testing.expect(try cursor.next(io, .root, arena.allocator()) == null);
}

test "count" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    try shop.fake.reply("fake://shared", .{ .count = 3 });
    try testing.expectEqual(@as(u64, 3), try acme.collection(User).count(io, .root, .{ .status = .blocked }));
    const count = shop.sent(io)[0].call.count;
    try testing.expectEqualStrings("users", count.ns.collection);
    try expectDocument(.{ .status = "blocked" }, count.filter);
}

test "a cursor outlives its session" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try shop.fake.reply("fake://shared", .{ .documents = &.{ ann, bob } });
    // Both are given back in the middle of the test; a failed check before
    // that gives them back here, so that the registry's deinit finds no
    // lease.
    var acme = try shop.registry.tenant(io, "acme");
    var acme_held = true;
    defer if (acme_held) acme.deinit(io);
    var cursor = try acme.collection(User).find(io, .root, .{}, .{});
    var cursor_held = true;
    defer if (cursor_held) cursor.deinit(io);
    // The session and the cursor hold a lease each.
    try testing.expectEqual(@as(usize, 2), shop.registry.stats(io).leases);
    acme.deinit(io);
    acme_held = false;
    try testing.expectEqual(@as(usize, 1), shop.registry.stats(io).leases);
    try testing.expectEqualStrings("Ann", (try cursor.next(io, .root, arena.allocator())).?.name);
    try testing.expectEqualStrings("Bob", (try cursor.next(io, .root, arena.allocator())).?.name);
    cursor.deinit(io);
    cursor_held = false;
    try testing.expectEqual(@as(usize, 0), shop.registry.stats(io).leases);
    try testing.expectEqual(@as(usize, 0), shop.fake.counts(io).cursors);
}

test "a find that fails returns its lease" {
    const io = testing.io;
    var shop: Shop = undefined;
    try shop.init(io, .{});
    defer shop.deinit(io);
    var acme = try shop.registry.tenant(io, "acme");
    defer acme.deinit(io);

    try shop.fake.reply("fake://shared", .{ .failure = .{ .err = error.CommandFailed, .code = 2, .message = "bad query" } });
    try testing.expectError(error.CommandFailed, acme.collection(User).find(io, .root, .{}, .{}));
    try testing.expectEqual(@as(?i32, 2), acme.diagnostics().code);
    try testing.expectEqualStrings("bad query", acme.diagnostics().message());
    // Only the session's lease is left.
    try testing.expectEqual(@as(usize, 1), shop.registry.stats(io).leases);
}

test "Closed after a forced close" {
    const io = testing.io;
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var shop: Shop = undefined;
    try shop.init(io, .{ .drain_timeout = .fromMilliseconds(100) });
    defer shop.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try shop.fake.reply("fake://shared", .{ .documents = &.{ ann, bob } });
    // Both are given back in the middle of the test; a failed check before
    // that gives them back here, so that the registry's deinit finds no
    // lease.
    var acme = try shop.registry.tenant(io, "acme");
    var acme_held = true;
    defer if (acme_held) acme.deinit(io);
    var cursor = try acme.collection(User).find(io, .root, .{}, .{});
    var cursor_held = true;
    defer if (cursor_held) cursor.deinit(io);
    acme.deinit(io);
    acme_held = false;
    // The cursor holds the old generation past its drain: it is closed by
    // force.
    try shop.registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://next" });
    try testing.expectEqual(@as(usize, 1), shop.registry.stats(io).forced);
    try testing.expectError(error.Closed, cursor.next(io, .root, arena.allocator()));
    try testing.expectEqual(@as(usize, 0), shop.fake.counts(io).freed);
    // Its deinit still works, and its lease was the last: the generation goes.
    cursor.deinit(io);
    cursor_held = false;
    try testing.expectEqual(@as(usize, 0), shop.registry.stats(io).leases);
    try testing.expectEqual(@as(usize, 1), shop.fake.counts(io).freed);
}
