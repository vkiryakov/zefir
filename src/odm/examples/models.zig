//! Models, without a server: the users, the visits and the products of a
//! shop, and what odm writes of them. A model is a plain struct with two
//! declarations: `odm_schema`, its collection, id, BSON names and indexes,
//! and `field_rules`, the rules of zefir-validator. The program hands odm
//! `odm.testing.FakeDriver`, a driver that runs no query and keeps a
//! journal of what odm sent it, and prints those documents as Extended
//! JSON, the text MongoDB's tools show them in.

const std = @import("std");
const core = @import("core");
const odm = @import("odm");
const v = @import("validator");
const bson = @import("mongo-bson");

/// A user of the shop, in the collection "users".
pub const User = struct {
    /// null: odm makes an ObjectId when it inserts the user.
    id: ?bson.ObjectId = null,
    email: []const u8,
    name: []const u8,
    /// A field with a default may stay out of an insert, and a document
    /// without it reads as the default.
    age: u32 = 0,
    status: Status = .active,
    /// An optional is null by default, and odm never writes a null: a user
    /// without a nickname has no field "nickname" at all.
    nickname: ?[]const u8 = null,
    /// A struct is a document inside the document.
    address: Address,
    profile: ?Profile = null,
    tags: []const []const u8 = &.{},
    created_at: bson.DateTime,

    pub const Status = enum { active, blocked };
    pub const Address = struct { city: []const u8, country: []const u8 };
    pub const Profile = struct { bio: []const u8, site: ?[]const u8 = null };

    pub const odm_schema: odm.Schema(User) = .{
        .collection = "users",
        // The field that is _id in the database.
        .id = .id,
        // The BSON names of top-level fields, where they are not the Zig
        // ones.
        .names = .{ .created_at = "createdAt" },
        .indexes = &.{
            .{ .keys = &.{.{ .email = .asc }}, .unique = true },
            // Unique on an optional needs sparse: the users without a
            // nickname stay out of the index, instead of colliding there.
            .{ .keys = &.{.{ .nickname = .asc }}, .unique = true, .sparse = true },
            // A compound index: its keys in their order.
            .{ .keys = &.{ .{ .status = .asc }, .{ .created_at = .desc } } },
        },
    };

    pub const field_rules = .{
        .email = .{ v.email, v.maxLength(254) },
        .name = .{ v.minLength(1), v.maxLength(100) },
        .age = v.range(0, 150),
    };
};

/// A visit to a page, whose id odm always makes: its insert takes an
/// `odm.Insert(Visit)`, the struct without the field `id`.
pub const Visit = struct {
    id: bson.ObjectId,
    user: bson.ObjectId,
    page: []const u8,
    at: bson.DateTime,

    pub const odm_schema: odm.Schema(Visit) = .{
        .collection = "visits",
        .id = .id,
        // A TTL index: the server deletes a visit 30 days after `at`.
        .indexes = &.{.{ .keys = &.{.{ .at = .asc }}, .expire_after_seconds = 30 * 24 * 3600 }},
    };
};

/// A product, whose id the shop gives: its code.
pub const Product = struct {
    id: []const u8,
    title: []const u8,
    price_cents: u32,

    pub const odm_schema: odm.Schema(Product) = .{ .collection = "products", .id = .id };
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;

    // A driver that runs no query, and a registry with one tenant on it,
    // "acme", whose database is "acme".
    var fake: odm.testing.FakeDriver = .init(init.gpa);
    defer fake.deinit();
    var registry: odm.Registry = .init(init.gpa, io, fake.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "main", .{ .uri = "fake://shop" });
    try registry.provisionTenant(io, .root, .{ .tenant = "acme", .connection = .{ .existing = "main" }, .database = "acme", .version = 1 });
    var acme = try registry.tenant(io, "acme");
    defer acme.deinit(io);
    // No deadline: the fake answers at once. A request of a service has
    // one, as the quick start shows.
    const ctx: core.Context = .root;
    const joined: bson.DateTime = .{ .milliseconds = 1_760_000_000_000 };
    const lisbon: User.Address = .{ .city = "Lisbon", .country = "PT" };

    // The indexes of the schema, created by one call: as the service
    // starts, and again for each new tenant.
    const users = acme.collection(User);
    try users.ensureIndexes(io, ctx);
    for (lastCall(&fake, io).create_indexes.indexes) |index| {
        try out.print("index {s}: {f}{s}{s}\n", .{ index.name, index.keys, if (index.unique) " unique" else "", if (index.sparse) " sparse" else "" });
    }
    try acme.collection(Visit).ensureIndexes(io, ctx);
    const ttl = lastCall(&fake, io).create_indexes.indexes[0];
    try out.print("index {s}: {f} expires after {d} s\n", .{ ttl.name, ttl.keys, ttl.expire_after_seconds.? });

    // An insert: odm makes the id, writes it as _id, and leaves the
    // optionals that are null out.
    const ann = try users.insertOne(io, ctx, .{ .email = "ann@example.com", .name = "Ann", .address = lisbon, .created_at = joined });
    try out.print("ann's id: {f}\n", .{ann.id});
    try out.print("inserted: {f}\n", .{lastCall(&fake, io).insert.documents[0]});
    // The same with the optionals there.
    _ = try users.insertOne(io, ctx, .{
        .email = "bob@example.com",
        .name = "Bob",
        .age = 17,
        .nickname = "bobby",
        .address = .{ .city = "Lyon", .country = "FR" },
        .profile = .{ .bio = "Tea and trains" },
        .tags = &.{"student"},
        .created_at = joined,
    });
    try out.print("inserted: {f}\n", .{lastCall(&fake, io).insert.documents[0]});

    // A Visit is inserted without an id: odm.Insert(Visit) has none, and
    // odm makes one every time.
    const visit = try acme.collection(Visit).insertOne(io, ctx, .{ .user = ann.id, .page = "/tea", .at = joined });
    try out.print("visit {f}: {f}\n", .{ visit.id, lastCall(&fake, io).insert.documents[0] });
    // A Product brings its own id.
    const tea = try acme.collection(Product).insertOne(io, ctx, .{ .id = "tea-01", .title = "Green tea", .price_cents = 450 });
    try out.print("product {s}: {f}\n", .{ tea.id, lastCall(&fake, io).insert.documents[0] });

    // The rules of the model come first: a document that breaks one is
    // ValidationFailed, the session's diagnostics say which rule and where,
    // and nothing goes out.
    const sent = fake.journal(io).len;
    if (users.insertOne(io, ctx, .{ .email = "ann at example", .name = "Ann", .address = lisbon, .created_at = joined })) |_| {
        try out.print("inserted a bad e-mail\n", .{});
    } else |err| {
        const d = acme.diagnostics();
        try out.print("refused: {t}, {s}: {s} ({s}); sent {d} more\n", .{ err, d.path(), d.message(), d.violation.?.code, fake.journal(io).len - sent });
    }

    // Reading: a document that another program wrote, without age and
    // profile, with a nickname that is null. The fake answers the next find
    // with it.
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const theirs = try bson.encode(arena.allocator(), .{
        ._id = ann.id,
        .email = "cy@example.com",
        .name = "Cy",
        .nickname = null,
        .address = .{ .city = "Porto", .country = "PT" },
        .createdAt = joined,
    }, .{});
    try fake.reply("fake://shop", .{ .documents = &.{theirs.raw()} });
    const cy = (try users.findOne(io, ctx, .{ .email = "cy@example.com" }, .{}, arena.allocator())).?;
    try out.print("read: {s}, age {d}, {t}, nickname {?s}, profile {s}\n", .{ cy.name, cy.age, cy.status, cy.nickname, if (cy.profile == null) "null" else "set" });
    try out.flush();
}

/// The latest call that odm sent the fake.
fn lastCall(fake: *odm.testing.FakeDriver, io: std.Io) odm.testing.FakeDriver.Call {
    const journal = fake.journal(io);
    return journal[journal.len - 1].call;
}
