//! Optionals and upserts on mongod (design Р46, Р47), each test in a
//! database of its own on mongo-plain, read back past odm through the
//! client of an `Admin`:
//!
//! - an optional that is null never reaches the server, at any depth, and
//!   a null item of a list stays;
//! - `.f = null` finds a missing field and a null of another writer, and
//!   the model reads both as null;
//! - inc and push create a missing field;
//! - a sparse unique index admits documents without the field;
//! - what upsertOne inserts reads back as the model;
//! - what the server does with `in`, `nin` and `all` in the filter of an
//!   upsert, which upsertOne refuses: through the raw contract.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("odm");
const mongo = @import("mongo");
const e2e = @import("root.zig");
const within = e2e.within;

/// A model with each kind of field that a document may lack: optional
/// values, an optional struct, an optional list, a struct with an optional
/// inside, and a list whose items may be null.
const Person = struct {
    id: ?bson.ObjectId = null,
    email: []const u8,
    nickname: ?[]const u8 = null,
    status: Status = .active,
    address: Address,
    profile: ?Profile = null,
    tags: []const []const u8 = &.{},
    labels: ?[]const []const u8 = null,
    scores: []const ?i32 = &.{},
    visits: ?i32 = null,

    pub const Status = enum { active, blocked };
    pub const Address = struct { city: []const u8, zip: ?[]const u8 = null };
    pub const Profile = struct { bio: []const u8, site: ?[]const u8 = null };

    pub const odm_schema: odm.Schema(Person) = .{
        .collection = "people",
        .id = .id,
        // Every key optional: unique only with sparse.
        .indexes = &.{.{ .keys = &.{.{ .nickname = .asc }}, .unique = true, .sparse = true }},
    };
};

/// A registry of mongo-plain with the tenant "doc" on `database`, which
/// the caller dropped.
fn open(registry: *odm.Registry, io: Io, database: []const u8) !void {
    try registry.registerConnection(io, "shared", .{ .uri = e2e.servers.plain });
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), .{ .tenant = "doc", .connection = .{ .existing = "shared" }, .database = database, .version = 1 });
}

/// The document of `id` in "people" of `database`, as the server holds it.
fn stored(admin: *e2e.Admin, io: Io, database: []const u8, id: bson.ObjectId) !bson.OwnedDocument {
    const doc = try admin.collection(database, "people").findOne(io, e2e.op(io), .{ ._id = id }, .{ .allocator = testing.allocator });
    return doc orelse error.TestDocumentMissing;
}

/// The server holds the document of `id` as `expected`, byte for byte:
/// what bson.encode writes of it.
fn expectStored(admin: *e2e.Admin, io: Io, database: []const u8, id: bson.ObjectId, expected: anytype) !void {
    const doc = try stored(admin, io, database, id);
    defer doc.deinit();
    const want = try bson.encode(testing.allocator, expected, .{});
    defer want.deinit();
    if (!std.mem.eql(u8, want.bytes, doc.bytes)) {
        std.debug.print("  expected {f}\n    stored {f}\n", .{ want.raw(), doc.raw() });
        return error.TestExpectedEqual;
    }
}

test "no null field reaches the server" {
    try e2e.onZio(noNullField);
}

fn noNullField(io: Io) !void {
    const database = "odm_nulls";
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    try admin.dropDatabase(io, database);
    defer admin.dropDatabaseAtEnd(io, database);
    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, database);
    var session = try registry.tenant(io, "doc");
    defer session.deinit(io);
    const people = session.collection(Person);
    const ctx = within(io, .fromSeconds(10));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // insertOne: no nickname, labels, visits, address.zip or profile.site;
    // the null item of scores stays.
    const ann = try people.insertOne(io, ctx, .{ .email = "ann@example.com", .address = .{ .city = "Lyon" }, .profile = .{ .bio = "hi" }, .scores = &.{ 1, null, 3 } });
    try expectStored(&admin, io, database, ann.id, .{ ._id = ann.id, .email = "ann@example.com", .status = .active, .address = .{ .city = "Lyon" }, .profile = .{ .bio = "hi" }, .tags = &.{}, .scores = .{ 1, null, 3 } });
    const read = (try people.findOne(io, ctx, .{ .id = ann.id }, .{}, arena.allocator())).?;
    try testing.expectEqual(@as(?[]const u8, null), read.nickname);
    try testing.expectEqual(@as(?[]const u8, null), read.profile.?.site);
    try testing.expectEqual(@as(?[]const u8, null), read.address.zip);
    try testing.expectEqualSlices(?i32, &.{ 1, null, 3 }, read.scores);

    // insertMany, the same way for each document.
    const list = [_]Person{
        .{ .email = "bo@example.com", .address = .{ .city = "Oslo", .zip = null }, .labels = null, .visits = null },
        .{ .email = "cy@example.com", .nickname = "cy", .address = .{ .city = "Rome", .zip = "00100" } },
    };
    const many = try people.insertMany(io, ctx, &list, arena.allocator());
    try expectStored(&admin, io, database, many.ids[0], .{ ._id = many.ids[0], .email = "bo@example.com", .status = .active, .address = .{ .city = "Oslo" }, .tags = &.{}, .scores = &.{} });
    try expectStored(&admin, io, database, many.ids[1], .{ ._id = many.ids[1], .email = "cy@example.com", .nickname = "cy", .status = .active, .address = .{ .city = "Rome", .zip = "00100" }, .tags = &.{}, .scores = &.{} });

    // replaceOne: the null nickname leaves the document.
    const replaced = try people.replaceOne(io, ctx, .{ .id = many.ids[1] }, .{ .email = "cy@example.com", .address = .{ .city = "Rome" }, .profile = .{ .bio = "new" } });
    try testing.expectEqual(@as(u64, 1), replaced.modified);
    try expectStored(&admin, io, database, many.ids[1], .{ ._id = many.ids[1], .email = "cy@example.com", .status = .active, .address = .{ .city = "Rome" }, .profile = .{ .bio = "new" }, .tags = &.{}, .scores = &.{} });

    // A subdocument in the value of a set goes without its nulls too.
    const set = try people.updateOne(io, ctx, .{ .id = ann.id }, .{ .set = .{ .profile = Person.Profile{ .bio = "set", .site = null } } });
    try testing.expectEqual(@as(u64, 1), set.modified);
    try expectStored(&admin, io, database, ann.id, .{ ._id = ann.id, .email = "ann@example.com", .status = .active, .address = .{ .city = "Lyon" }, .profile = .{ .bio = "set" }, .tags = &.{}, .scores = .{ 1, null, 3 } });

    // A null filter on the optional finds the three documents without it.
    try testing.expectEqual(@as(u64, 3), try people.count(io, ctx, .{ .nickname = null }));
}

test "a null filter finds a missing field and another writer's null" {
    try e2e.onZio(nullFilter);
}

fn nullFilter(io: Io) !void {
    const database = "odm_nullfind";
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    try admin.dropDatabase(io, database);
    defer admin.dropDatabaseAtEnd(io, database);
    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, database);
    var session = try registry.tenant(io, "doc");
    defer session.deinit(io);
    const people = session.collection(Person);
    const ctx = within(io, .fromSeconds(10));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const missing = try people.insertOne(io, ctx, .{ .email = "miss@example.com", .address = .{ .city = "Rome" } });
    _ = try people.insertOne(io, ctx, .{ .email = "zed@example.com", .nickname = "zed", .address = .{ .city = "Oslo" } });
    // Another writer stores the null itself.
    var raw = try admin.collection(database, "people").insertOne(io, e2e.op(io), .{ .email = "raw@example.com", .nickname = null, .address = .{ .city = "Rome" } }, .{ .allocator = testing.allocator });
    defer raw.deinit(testing.allocator);
    const raw_id = raw.inserted_id.object_id;
    {
        const doc = try stored(&admin, io, database, raw_id);
        defer doc.deinit();
        try testing.expect((try doc.raw().get("nickname")).? == .null);
        const odm_doc = try stored(&admin, io, database, missing.id);
        defer odm_doc.deinit();
        try testing.expectEqual(@as(?bson.Value, null), try odm_doc.raw().get("nickname"));
    }

    var cursor = try people.find(io, ctx, .{ .nickname = null }, .{ .sort = .{ .email = .asc } });
    defer cursor.deinit(io);
    const first = (try cursor.next(io, ctx, arena.allocator())).?;
    try testing.expectEqualStrings("miss@example.com", first.email);
    try testing.expectEqual(@as(?[]const u8, null), first.nickname);
    const second = (try cursor.next(io, ctx, arena.allocator())).?;
    try testing.expectEqualStrings("raw@example.com", second.email);
    try testing.expectEqual(@as(?[]const u8, null), second.nickname);
    try testing.expectEqual(raw_id, second.id.?);
    try testing.expectEqual(@as(?Person, null), try cursor.next(io, ctx, arena.allocator()));

    try testing.expectEqual(@as(u64, 2), try people.count(io, ctx, .{ .nickname = null }));
    // Only the missing field: exists = false.
    try testing.expectEqual(@as(u64, 1), try people.count(io, ctx, .{ .nickname = .{ .exists = false } }));
    try testing.expectEqual(@as(u64, 1), try people.count(io, ctx, .{ .nickname = "zed" }));
}

test "inc and push create a missing field" {
    try e2e.onZio(createMissing);
}

fn createMissing(io: Io) !void {
    const database = "odm_create";
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    try admin.dropDatabase(io, database);
    defer admin.dropDatabaseAtEnd(io, database);
    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, database);
    var session = try registry.tenant(io, "doc");
    defer session.deinit(io);
    const people = session.collection(Person);
    const ctx = within(io, .fromSeconds(10));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const kim = try people.insertOne(io, ctx, .{ .email = "kim@example.com", .address = .{ .city = "Kyiv" } });
    {
        const doc = try stored(&admin, io, database, kim.id);
        defer doc.deinit();
        try testing.expectEqual(@as(?bson.Value, null), try doc.raw().get("visits"));
        try testing.expectEqual(@as(?bson.Value, null), try doc.raw().get("labels"));
    }
    const changed = try people.updateOne(io, ctx, .{ .id = kim.id }, .{ .inc = .{ .visits = 2 }, .push = .{ .labels = "new" } });
    try testing.expectEqual(@as(u64, 1), changed.matched);
    try testing.expectEqual(@as(u64, 1), changed.modified);
    {
        const doc = try stored(&admin, io, database, kim.id);
        defer doc.deinit();
        try testing.expectEqual(@as(i32, 2), (try doc.raw().get("visits")).?.int32);
        const labels = (try doc.raw().get("labels")).?.array;
        try testing.expectEqualStrings("new", (try labels.get("0")).?.string);
        try testing.expectEqual(@as(?bson.Value, null), try labels.get("1"));
    }
    const read = (try people.findOne(io, ctx, .{ .id = kim.id }, .{}, arena.allocator())).?;
    try testing.expectEqual(@as(?i32, 2), read.visits);
    try testing.expectEqual(@as(usize, 1), read.labels.?.len);
    try testing.expectEqualStrings("new", read.labels.?[0]);

    // Once there, they go on as usual.
    _ = try people.updateOne(io, ctx, .{ .id = kim.id }, .{ .inc = .{ .visits = 1 }, .push = .{ .labels = "next" } });
    const again = (try people.findOne(io, ctx, .{ .id = kim.id }, .{}, arena.allocator())).?;
    try testing.expectEqual(@as(?i32, 3), again.visits);
    try testing.expectEqual(@as(usize, 2), again.labels.?.len);
    try testing.expectEqualStrings("next", again.labels.?[1]);
}

test "a sparse unique index admits documents without the field" {
    try e2e.onZio(sparseUnique);
}

fn sparseUnique(io: Io) !void {
    const database = "odm_sparse";
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    try admin.dropDatabase(io, database);
    defer admin.dropDatabaseAtEnd(io, database);
    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, database);
    var session = try registry.tenant(io, "doc");
    defer session.deinit(io);
    const people = session.collection(Person);
    const ctx = within(io, .fromSeconds(10));

    try people.ensureIndexes(io, ctx);
    try expectIndex(&admin, io, database, "nickname_1");
    // Two documents without a nickname: the index holds neither.
    _ = try people.insertOne(io, ctx, .{ .email = "s1@example.com", .address = .{ .city = "Bern" } });
    _ = try people.insertOne(io, ctx, .{ .email = "s2@example.com", .address = .{ .city = "Bern" } });
    _ = try people.insertOne(io, ctx, .{ .email = "s3@example.com", .nickname = "kit", .address = .{ .city = "Bern" } });
    try testing.expectError(error.DuplicateKey, people.insertOne(io, ctx, .{ .email = "s4@example.com", .nickname = "kit", .address = .{ .city = "Bern" } }));
    try testing.expectEqual(@as(?i32, 11000), session.diagnostics().code);
    try testing.expectEqual(@as(u64, 3), try people.count(io, ctx, .{}));
    try testing.expectEqual(@as(u64, 2), try people.count(io, ctx, .{ .nickname = null }));
}

/// The collection "people" of `database` has the index `name`, unique and
/// sparse.
fn expectIndex(admin: *e2e.Admin, io: Io, database: []const u8, name: []const u8) !void {
    const op = e2e.op(io);
    const cursor = try admin.collection(database, "people").listIndexes(io, op, .{ .allocator = testing.allocator });
    defer cursor.deinit(io);
    while (try cursor.next(io, op)) |index| {
        const got = (try index.get("name")) orelse continue;
        if (!std.mem.eql(u8, got.string, name)) continue;
        try testing.expect((try index.get("unique")).?.boolean);
        try testing.expect((try index.get("sparse")).?.boolean);
        return;
    }
    std.debug.print("  no index {s} in {s}.people\n", .{ name, database });
    return error.TestIndexMissing;
}

test "what upsertOne inserts reads back as the model" {
    try e2e.onZio(upsertReads);
}

fn upsertReads(io: Io) !void {
    const database = "odm_upsert";
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    try admin.dropDatabase(io, database);
    defer admin.dropDatabaseAtEnd(io, database);
    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, database);
    var session = try registry.tenant(io, "doc");
    defer session.deinit(io);
    const people = session.collection(Person);
    const ctx = within(io, .fromSeconds(10));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The equalities of the filter, set, set_on_insert, inc and push give
    // the document every required field.
    const filter = .{ .email = "eve@example.com", .status = .blocked };
    const new: []const []const u8 = &.{"new"};
    const changes = .{
        .set = .{ .address = Person.Address{ .city = "Riga", .zip = null } },
        .set_on_insert = .{ .tags = new },
        .inc = .{ .visits = 1 },
        .push = .{ .labels = "first" },
    };
    const inserted = try people.upsertOne(io, ctx, filter, changes);
    try testing.expectEqual(@as(u64, 0), inserted.matched);
    const id = inserted.upserted_id.?;
    const eve = (try people.findOne(io, ctx, .{ .id = id }, .{}, arena.allocator())).?;
    try testing.expectEqual(id, eve.id.?);
    try testing.expectEqualStrings("eve@example.com", eve.email);
    try testing.expectEqual(Person.Status.blocked, eve.status);
    try testing.expectEqualStrings("Riga", eve.address.city);
    try testing.expectEqual(@as(?[]const u8, null), eve.address.zip);
    try testing.expectEqual(@as(usize, 1), eve.tags.len);
    try testing.expectEqualStrings("new", eve.tags[0]);
    try testing.expectEqual(@as(?i32, 1), eve.visits);
    try testing.expectEqualStrings("first", eve.labels.?[0]);
    try testing.expectEqual(@as(?[]const u8, null), eve.nickname);
    try testing.expectEqual(@as(?Person.Profile, null), eve.profile);
    try testing.expectEqual(@as(usize, 0), eve.scores.len);
    {
        // No null went in, the zip of the address neither.
        const doc = try stored(&admin, io, database, id);
        defer doc.deinit();
        try testing.expectEqual(@as(?bson.Value, null), try doc.raw().getPath("address.zip"));
        try testing.expectEqual(@as(?bson.Value, null), try doc.raw().get("nickname"));
    }

    // The same upsert again changes the document it finds.
    const updated = try people.upsertOne(io, ctx, filter, changes);
    try testing.expectEqual(@as(u64, 1), updated.matched);
    try testing.expectEqual(@as(u64, 1), updated.modified);
    try testing.expectEqual(@as(?bson.ObjectId, null), updated.upserted_id);
    const later = (try people.findOne(io, ctx, .{ .id = id }, .{}, arena.allocator())).?;
    try testing.expectEqual(@as(?i32, 2), later.visits);
    try testing.expectEqual(@as(usize, 2), later.labels.?.len);
    try testing.expectEqual(@as(usize, 1), later.tags.len);
    try testing.expectEqual(@as(u64, 1), try people.count(io, ctx, .{}));
}

test "the server copies one item of in or all of an upsert filter into the document it inserts" {
    try e2e.onZio(upsertInAndAll);
}

/// What mongod makes of `in`, `nin` and `all` in the filter of an upsert
/// that inserts, pinned here through the raw contract, `odm.Client`: why
/// upsertOne refuses them in its filter at compile time. One item of `in`,
/// and one of `all`, the server copies into the document as an equality;
/// on a list field that is the item where the list goes, which the model
/// cannot read. `in` of two items it copies nothing of, `all` of two items
/// it refuses (code 54). `in` of `null` writes a null. An empty `in`
/// matches nothing, and the server then copies none of the filter's
/// equalities. `nin` copies nothing.
fn upsertInAndAll(io: Io) !void {
    const database = "odm_upsert_in";
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    try admin.dropDatabase(io, database);
    defer admin.dropDatabaseAtEnd(io, database);
    var driver: mongo.OdmDriver = .init(testing.allocator);
    // The client of the upserts, as odm's collections reach a driver.
    var client = try driver.driver().open(io, &.{ .uri = e2e.servers.plain });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);
    const raw: Raw = .{ .client = client, .database = database };
    // The model reads what they inserted through a session.
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try open(&registry, io, database);
    var session = try registry.tenant(io, "doc");
    defer session.deinit(io);
    const people = session.collection(Person);
    const ctx = within(io, .fromSeconds(10));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // One item of in on a field of one value: the field equals it, and the
    // model reads it.
    const one_in = try raw.upsert(io, .{ .email = "in@example.com", .status = .{ .@"$in" = .{"blocked"} } });
    {
        const doc = try stored(&admin, io, database, one_in);
        defer doc.deinit();
        try testing.expectEqualStrings("blocked", (try doc.raw().get("status")).?.string);
    }
    try testing.expectEqual(Person.Status.blocked, (try people.findOne(io, ctx, .{ .id = one_in }, .{}, arena.allocator())).?.status);

    // One item of all, or of in, on a list: the item goes where the list
    // goes, and the model cannot read the document.
    const one_all = try raw.upsert(io, .{ .email = "all@example.com", .tags = .{ .@"$all" = .{"a"} } });
    const in_list = try raw.upsert(io, .{ .email = "in-list@example.com", .tags = .{ .@"$in" = .{"a"} } });
    for ([_]bson.ObjectId{ one_all, in_list }) |id| {
        {
            const doc = try stored(&admin, io, database, id);
            defer doc.deinit();
            try testing.expectEqualStrings("a", (try doc.raw().get("tags")).?.string);
        }
        try expectUnreadable(people, &session, io, id, "tags");
    }

    // Two items of all: the server cannot tell which one the list holds,
    // and inserts nothing.
    var d: odm.Diagnostics = .{};
    try testing.expectError(error.WriteFailed, raw.upsertWith(io, .{ .email = "all2@example.com", .tags = .{ .@"$all" = .{ "a", "b" } } }, &d));
    try testing.expectEqual(@as(?i32, 54), d.code);
    try testing.expectEqual(@as(u64, 0), try people.count(io, ctx, .{ .email = "all2@example.com" }));

    // Two items of in: it copies nothing of them; nin neither.
    const two_in = try raw.upsert(io, .{ .email = "in2@example.com", .status = .{ .@"$in" = .{ "active", "blocked" } } });
    const nin = try raw.upsert(io, .{ .email = "nin@example.com", .status = .{ .@"$nin" = .{"blocked"} } });
    for ([_]bson.ObjectId{ two_in, nin }, [_][]const u8{ "in2@example.com", "nin@example.com" }) |id, email| {
        const doc = try stored(&admin, io, database, id);
        defer doc.deinit();
        try testing.expectEqual(@as(?bson.Value, null), try doc.raw().get("status"));
        try testing.expectEqualStrings(email, (try doc.raw().get("email")).?.string);
    }

    // in of null on an optional: the server writes the null.
    const in_null = try raw.upsert(io, .{ .email = "null@example.com", .nickname = .{ .@"$in" = .{null} } });
    {
        const doc = try stored(&admin, io, database, in_null);
        defer doc.deinit();
        try testing.expect((try doc.raw().get("nickname")).? == .null);
    }

    // An empty in matches nothing, and the document that the server
    // inserts gets none of the filter's equalities: no email.
    const none: []const []const u8 = &.{};
    const empty = try raw.upsert(io, .{ .email = "empty@example.com", .tags = .{ .@"$in" = none } });
    {
        const doc = try stored(&admin, io, database, empty);
        defer doc.deinit();
        try testing.expectEqual(@as(?bson.Value, null), try doc.raw().get("email"));
        try testing.expectEqualStrings("Pin", (try doc.raw().getPath("address.city")).?.string);
    }
    try expectUnreadable(people, &session, io, empty, "email");
}

/// The upserts of the pin above, as odm's collections send them: one
/// update of "people" with `upsert`, and `$set` of the address.
const Raw = struct {
    client: odm.Client,
    database: []const u8,

    /// The id of the document that the upsert of `filter` inserted.
    fn upsert(r: Raw, io: Io, filter: anytype) !bson.ObjectId {
        var d: odm.Diagnostics = .{};
        return r.upsertWith(io, filter, &d) catch |err| {
            std.debug.print("  upsert: {t}: {s}\n", .{ err, d.message() });
            return err;
        };
    }

    fn upsertWith(r: Raw, io: Io, filter: anytype, d: *odm.Diagnostics) !bson.ObjectId {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const conditions = try bson.encode(a, filter, .{});
        const changes = try bson.encode(a, .{ .@"$set" = .{ .address = .{ .city = "Pin" } } }, .{});
        const result = try r.client.update(io, within(io, .fromSeconds(10)), &.{
            .ns = .{ .database = r.database, .collection = "people" },
            .filter = conditions.raw(),
            .update = changes.raw(),
            .mode = .one,
            .upsert = true,
        }, .{ .allocator = a, .diagnostics = d });
        try testing.expectEqual(@as(u64, 0), result.matched);
        return (result.upserted_id orelse return error.TestNothingInserted).object_id;
    }
};

/// The model cannot read the document of `id`: `DecodeFailed` at `path`.
fn expectUnreadable(people: odm.Collection(Person), session: *const odm.Session, io: Io, id: bson.ObjectId, path: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.DecodeFailed, people.findOne(io, within(io, .fromSeconds(10)), .{ .id = id }, .{}, arena.allocator()));
    try testing.expectEqualStrings(path, session.diagnostics().path());
}
