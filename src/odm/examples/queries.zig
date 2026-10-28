//! Reading and changing documents, without a server: filters, sorts,
//! cursors, projections, updates, upserts, queries built at run time and
//! the raw paths, on the users of models.zig. odm writes each typed call as
//! BSON and hands it to the driver; here the driver is
//! `odm.testing.FakeDriver`, and the program prints what it got, as
//! Extended JSON.

const std = @import("std");
const core = @import("core");
const odm = @import("odm");
const bson = @import("mongo-bson");
const User = @import("models.zig").User;
const FakeDriver = odm.testing.FakeDriver;

/// A part of a user: the fields of a list on a page.
const Preview = struct { name: []const u8, email: []const u8 };

/// The optional conditions of a search, as a handler of zefir-http takes
/// them from the query string of a request.
const Search = struct {
    min_age: ?u32 = null,
    city: ?[]const u8 = null,
    status: ?User.Status = null,
};

/// The users that `search` asks for, the oldest first, 50 at a time. Each
/// condition that is there narrows it: several `where` are an AND.
fn search(users: odm.Collection(User), io: std.Io, ctx: core.Context, arena: std.mem.Allocator, s: Search) !odm.Cursor(User) {
    var q = users.query(arena);
    if (s.min_age) |age| q = q.where(.{ .age = .{ .gte = age } });
    if (s.city) |city| q = q.where(.{ .address = .{ .city = city } });
    if (s.status) |status| q = q.where(.{ .status = status });
    return q.sort(.{ .age = .desc }).limit(50).execute(io, ctx);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;

    var fake: FakeDriver = .init(init.gpa);
    defer fake.deinit();
    var registry: odm.Registry = .init(init.gpa, io, fake.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "main", .{ .uri = "fake://shop" });
    try registry.provisionTenant(io, .root, .{ .tenant = "acme", .connection = .{ .existing = "main" }, .database = "acme", .version = 1 });
    var acme = try registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users = acme.collection(User);
    const ctx: core.Context = .root;
    // The memory of what comes back: strings of documents, ids, the
    // conditions of queries. One arena for the whole program here; a
    // service takes one per request.
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lyon: User.Address = .{ .city = "Lyon", .country = "FR" };
    const joined: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };

    // Reading. The fake answers the next find with two users.
    try fake.reply("fake://shop", .{ .documents = &.{
        (try bson.encode(arena, .{ .email = "cleo@example.com", .name = "Cleo", .age = 41, .address = lyon, .createdAt = joined }, .{})).raw(),
        (try bson.encode(arena, .{ .email = "ann@example.com", .name = "Ann", .age = 30, .address = lyon, .createdAt = joined }, .{})).raw(),
    } });
    var adults = try users.find(io, ctx, .{ .status = .active, .age = .{ .gte = 18 } }, .{ .sort = .{ .age = .desc }, .limit = 100 });
    defer adults.deinit(io);
    try show(out, &fake, io, "adults");
    // Each document is decoded into the arena: the user lives as long as
    // the arena does, not as long as the cursor.
    while (try adults.next(io, ctx, arena)) |user| try out.print("  {s}, {d}\n", .{ user.name, user.age });

    // null matches a field that is null or missing; only missing is exists.
    var some = try users.find(io, ctx, .{ .nickname = null }, .{});
    some.deinit(io);
    try show(out, &fake, io, "null");
    some = try users.find(io, ctx, .{ .nickname = .{ .exists = false } }, .{});
    some.deinit(io);
    try show(out, &fake, io, "missing");
    // A literal of fields of a struct: conditions on its paths. The whole
    // document only with eq.
    some = try users.find(io, ctx, .{ .address = .{ .city = "Lyon" } }, .{});
    some.deinit(io);
    try show(out, &fake, io, "path");
    some = try users.find(io, ctx, .{ .address = .{ .eq = lyon } }, .{});
    some.deinit(io);
    try show(out, &fake, io, "whole");
    // Lists: an item, all of these items, a size.
    some = try users.find(io, ctx, .{ .tags = "vip" }, .{});
    some.deinit(io);
    try show(out, &fake, io, "item");
    some = try users.find(io, ctx, .{ .tags = .{ .all = .{ "vip", "staff" } }, .profile = .{ .exists = true } }, .{});
    some.deinit(io);
    try show(out, &fake, io, "all");
    // Either condition, and a pattern.
    some = try users.find(io, ctx, .{ .@"or" = .{ .{ .age = .{ .lt = 18 } }, .{ .status = .blocked } } }, .{ .skip = 20, .limit = 10 });
    some.deinit(io);
    try show(out, &fake, io, "or");
    // A projection: the server sends only the fields of Preview.
    _ = try users.findOneAs(Preview, io, ctx, .{ .email = .{ .regex = "@example\\.com$" } }, .{ .sort = .{ .name = .asc } }, arena);
    try show(out, &fake, io, "preview");
    _ = try users.count(io, ctx, .{ .status = .blocked });
    try show(out, &fake, io, "count");

    // Changing. An id that a find gave, say Ann's.
    const ann = try bson.ObjectId.parseHex("6ad571408b9f503e4a218a8b");
    _ = try users.updateOne(io, ctx, .{ .id = ann }, .{ .set = .{ .status = .blocked }, .inc = .{ .age = 1 } });
    try show(out, &fake, io, "block");
    // An optional is set to a value, and cleared by unset: odm writes no
    // null.
    _ = try users.updateOne(io, ctx, .{ .id = ann }, .{ .set = .{ .nickname = "annie" } });
    try show(out, &fake, io, "nickname");
    _ = try users.updateOne(io, ctx, .{ .id = ann }, .{ .unset = .{.nickname} });
    try show(out, &fake, io, "unset");
    // A path into a struct that is always there; an optional struct only
    // whole.
    _ = try users.updateOne(io, ctx, .{ .id = ann }, .{ .set = .{ .address = .{ .city = "Porto" }, .profile = User.Profile{ .bio = "Green tea" } } });
    try show(out, &fake, io, "move");
    // Lists: items in, items out; each path once per update.
    _ = try users.updateOne(io, ctx, .{ .id = ann }, .{ .add_to_set = .{ .tags = .{ .each = &.{ "vip", "staff" } } } });
    try show(out, &fake, io, "tags");
    _ = try users.updateOne(io, ctx, .{ .id = ann }, .{ .pull = .{ .tags = "student" } });
    try show(out, &fake, io, "untag");
    _ = try users.updateMany(io, ctx, .{ .status = .blocked }, .{ .set = .{ .status = .active } });
    try show(out, &fake, io, "unblock");
    // Dan in, unless he is there: the filter's equality, set and
    // set_on_insert give every required field of the document it may
    // insert.
    _ = try users.upsertOne(io, ctx, .{ .email = "dan@example.com" }, .{
        .set = .{ .name = "Dan", .address = lyon },
        .set_on_insert = .{ .created_at = joined },
    });
    try show(out, &fake, io, "upsert");
    _ = try users.replaceOne(io, ctx, .{ .id = ann }, .{ .email = "ann@example.org", .name = "Ann", .address = lyon, .created_at = joined });
    try show(out, &fake, io, "replace");
    _ = try users.deleteMany(io, ctx, .{ .status = .blocked, .created_at = .{ .lt = joined } });
    try show(out, &fake, io, "delete");

    // At run time: a search whose conditions come from a request, and a
    // change of the fields that a form sent.
    var found = try search(users, io, ctx, arena, .{ .min_age = 18, .city = "Lyon" });
    found.deinit(io);
    try show(out, &fake, io, "search");
    const new_name: ?[]const u8 = "Ann B.";
    const new_city: ?[]const u8 = null;
    var change = odm.Update(User).init(arena);
    if (new_name) |name| change = change.with(.{ .set = .{ .name = name } });
    if (new_city) |city| change = change.with(.{ .set = .{ .address = .{ .city = city } } });
    _ = try users.updateOne(io, ctx, .{ .id = ann }, change);
    try show(out, &fake, io, "form");

    // The raw paths: a pipeline and a command, which odm passes on as they
    // are, and does not check against the model.
    var groups = try users.aggregateRaw(struct { _id: []const u8, n: i32 }, io, ctx, .{
        .{ .@"$match" = .{ .age = .{ .@"$gte" = 18 } } },
        .{ .@"$group" = .{ ._id = "$status", .n = .{ .@"$sum" = 1 } } },
    });
    groups.deinit(io);
    try show(out, &fake, io, "groups");
    const stats = try acme.runCommand(io, ctx, .{ .collStats = "users" }, arena);
    try show(out, &fake, io, "command");
    try out.print("  the reply: {f}\n", .{stats});
    try out.flush();
}

/// Prints the latest call that odm sent the fake, after `label`.
fn show(out: *std.Io.Writer, fake: *FakeDriver, io: std.Io, label: []const u8) !void {
    const journal = fake.journal(io);
    try out.print("{s}: ", .{label});
    switch (journal[journal.len - 1].call) {
        .find => |f| {
            try out.print("find {f}", .{f.filter});
            if (f.sort) |sort| try out.print(" sort {f}", .{sort});
            if (f.projection) |projection| try out.print(" projection {f}", .{projection});
            if (f.skip != 0) try out.print(" skip {d}", .{f.skip});
            if (f.limit != 0) try out.print(" limit {d}", .{f.limit});
        },
        .count => |c| try out.print("count {f}", .{c.filter}),
        .update => |u| try out.print("update {t}{s} {f} {f}", .{ u.mode, if (u.upsert) " upsert" else "", u.filter, u.update }),
        .delete => |d| try out.print("delete {s} {f}", .{ if (d.many) "many" else "one", d.filter }),
        .aggregate => |a| {
            try out.writeAll("aggregate");
            for (a.pipeline) |stage| try out.print(" {f}", .{stage});
        },
        .command => |c| try out.print("command {f}", .{c.body}),
        else => |call| try out.print("{t}", .{call}),
    }
    try out.writeAll("\n");
}
