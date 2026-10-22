//! The tenants of odm.Registry on mongod. Mode A: two tenants of one
//! connection of mongo-plain, each in a database of its own. Mode B: a
//! tenant on a connection and a user of its own on mongo-auth, in the same
//! registry as mode A. Provisioning by events on a live server, the rights
//! of a login that keep a tenant out of the database it is bound to, and
//! the indexes of a model.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const bson = @import("mongo-bson");
const odm = @import("odm");
const mongo = @import("mongo");
const e2e = @import("root.zig");
const within = e2e.within;

/// A document of a tenant: who wrote it, and a number.
const Note = struct {
    id: ?bson.ObjectId = null,
    owner: []const u8,
    n: i32 = 0,

    pub const odm_schema: odm.Schema(Note) = .{ .collection = "notes", .id = .id };
};

/// A model with a unique index.
const Member = struct {
    id: ?bson.ObjectId = null,
    email: []const u8,
    name: []const u8,

    pub const odm_schema: odm.Schema(Member) = .{
        .collection = "members",
        .id = .id,
        .indexes = &.{.{ .keys = &.{.{ .email = .asc }}, .unique = true }},
    };
};

/// A provisioning of `tenant_id` on the known connection `id`.
fn existing(tenant_id: []const u8, id: []const u8, database: []const u8, version: u64) odm.Provision {
    return .{ .tenant = tenant_id, .connection = .{ .existing = id }, .database = database, .version = version };
}

/// Writes `count` notes of `owner` through a session of `tenant_id`.
fn writeNotes(registry: *odm.Registry, io: Io, tenant_id: []const u8, owner: []const u8, count: usize) !void {
    var session = try registry.tenant(io, tenant_id);
    defer session.deinit(io);
    const notes = session.collection(Note);
    for (0..count) |i| _ = try notes.insertOne(io, within(io, .fromSeconds(10)), .{ .owner = owner, .n = @intCast(i) });
}

/// How many notes the tenant `tenant_id` sees; each must be of `owner`.
fn ownNotes(registry: *odm.Registry, io: Io, tenant_id: []const u8, owner: []const u8) !usize {
    var session = try registry.tenant(io, tenant_id);
    defer session.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ctx = within(io, .fromSeconds(10));
    var cursor = try session.collection(Note).find(io, ctx, .{}, .{});
    defer cursor.deinit(io);
    var count: usize = 0;
    while (try cursor.next(io, ctx, arena.allocator())) |note| : (count += 1) try testing.expectEqualStrings(owner, note.owner);
    return count;
}

/// The database of a session of `tenant_id` is `database`.
fn expectDatabase(registry: *odm.Registry, io: Io, tenant_id: []const u8, database: []const u8) !void {
    var session = try registry.tenant(io, tenant_id);
    defer session.deinit(io);
    try testing.expectEqualStrings(database, session.database());
}

/// The documents of `collection` in `database`, counted on the server past
/// odm.
fn countOnServer(admin: *e2e.Admin, io: Io, database: []const u8, collection: []const u8) !u64 {
    return admin.collection(database, collection).countDocuments(io, e2e.op(io), .{}, .{ .allocator = testing.allocator });
}

test "mode A: two tenants on one connection see their own documents" {
    try e2e.onZio(modeA);
}

fn modeA(io: Io) !void {
    const databases = [_][]const u8{ "odm_a1", "odm_a2" };
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    for (databases) |name| try admin.dropDatabase(io, name);
    defer for (databases) |name| admin.dropDatabaseAtEnd(io, name);

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "shared", .{ .uri = e2e.servers.plain });
    try registry.connect(io, within(io, .fromSeconds(10)), "shared");
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("a1", "shared", "odm_a1", 1));
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("a2", "shared", "odm_a2", 1));

    try writeNotes(&registry, io, "a1", "a1", 2);
    try writeNotes(&registry, io, "a2", "a2", 3);
    try testing.expectEqual(@as(usize, 2), try ownNotes(&registry, io, "a1", "a1"));
    try testing.expectEqual(@as(usize, 3), try ownNotes(&registry, io, "a2", "a2"));
    // On the server, each database holds the notes of its tenant only.
    try testing.expectEqual(@as(u64, 2), try countOnServer(&admin, io, "odm_a1", "notes"));
    try testing.expectEqual(@as(u64, 3), try countOnServer(&admin, io, "odm_a2", "notes"));

    const stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 1), stats.connections.active);
    try testing.expectEqual(@as(usize, 2), stats.tenants);
    try testing.expectEqual(@as(usize, 0), stats.leases);
    try testing.expectEqual(@as(usize, 2), (try registry.connectionStats(io, "shared")).tenants);
}

test "mode B: a tenant on its own connection and user, beside mode A" {
    try e2e.onZio(modeB);
}

/// The work of one tenant in a task of its own: 20 notes written and read
/// back. The first error stays in `failure`.
fn busyTenant(registry: *odm.Registry, io: Io, tenant_id: []const u8, failure: *?anyerror) Io.Cancelable!void {
    writeAndRead(registry, io, tenant_id) catch |err| {
        failure.* = err;
    };
}

fn writeAndRead(registry: *odm.Registry, io: Io, tenant_id: []const u8) !void {
    try writeNotes(registry, io, tenant_id, tenant_id, 20);
    try testing.expectEqual(@as(usize, 20), try ownNotes(registry, io, tenant_id, tenant_id));
}

fn modeB(io: Io) !void {
    var plain: e2e.Admin = undefined;
    try plain.openPlain(io);
    defer plain.close();
    var auth: e2e.Admin = undefined;
    try auth.openAuth(io);
    defer auth.close();
    try plain.dropDatabase(io, "odm_a1");
    defer plain.dropDatabaseAtEnd(io, "odm_a1");
    try auth.dropDatabase(io, "odm_b");
    defer auth.dropDatabaseAtEnd(io, "odm_b");
    try auth.freshUser(io, "odm_b", "odm_b", "odm-b-pass", .{.{ .role = "readWrite", .db = "odm_b" }});
    defer auth.dropUserAtEnd(io, "odm_b", "odm_b");

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    // Mode A: a connection of the service, shared by its tenants.
    try registry.registerConnection(io, "shared", .{ .uri = e2e.servers.plain });
    try registry.connect(io, within(io, .fromSeconds(10)), "shared");
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("a1", "shared", "odm_a1", 1));
    // Mode B: the provisioning registers and connects the tenant's own.
    var d: odm.Diagnostics = .{};
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), .{
        .tenant = "b",
        .connection = .{ .new = .{ .id = "b", .uri = "mongodb://odm_b@127.0.0.1:27118/odm_b", .password = "odm-b-pass" } },
        .database = "odm_b",
        .version = 1,
        .diagnostics = &d,
    });
    try testing.expectEqualStrings("", d.message());

    // Both at once, each in a task of its own.
    var failures: [2]?anyerror = .{ null, null };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, busyTenant, .{ &registry, io, "a1", &failures[0] });
    try group.concurrent(io, busyTenant, .{ &registry, io, "b", &failures[1] });
    try group.await(io);
    for (failures) |failure| if (failure) |err| return err;

    try testing.expectEqual(@as(u64, 20), try countOnServer(&plain, io, "odm_a1", "notes"));
    try testing.expectEqual(@as(u64, 20), try countOnServer(&auth, io, "odm_b", "notes"));
    const stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 2), stats.connections.active);
    try testing.expectEqual(@as(usize, 2), stats.tenants);
    try testing.expectEqual(@as(usize, 0), stats.leases);
    const own = try registry.connectionStats(io, "b");
    try testing.expectEqual(odm.ConnectionState.active, own.state);
    try testing.expectEqual(@as(usize, 1), own.tenants);
    try testing.expectEqual(@as(usize, 1), (try registry.connectionStats(io, "shared")).tenants);
}

test "provisioning on a live server" {
    try e2e.onZio(provisioning);
}

fn provisioning(io: Io) !void {
    const plain_databases = [_][]const u8{ "odm_prov_1", "odm_prov_2" };
    const own_uri = "mongodb://odm_prov@127.0.0.1:27118/odm_prov";
    const wrong = "odm-wrong-secret";
    var plain: e2e.Admin = undefined;
    try plain.openPlain(io);
    defer plain.close();
    var auth: e2e.Admin = undefined;
    try auth.openAuth(io);
    defer auth.close();
    for (plain_databases) |name| try plain.dropDatabase(io, name);
    defer for (plain_databases) |name| plain.dropDatabaseAtEnd(io, name);
    try auth.dropDatabase(io, "odm_prov");
    defer auth.dropDatabaseAtEnd(io, "odm_prov");
    try auth.freshUser(io, "odm_prov", "odm_prov", "odm-prov-pass", .{.{ .role = "readWrite", .db = "odm_prov" }});
    defer auth.dropUserAtEnd(io, "odm_prov", "odm_prov");

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    // Registered without the network: the first provisioning connects it.
    try registry.registerConnection(io, "shared", .{ .uri = e2e.servers.plain });
    var d: odm.Diagnostics = .{};

    // A new tenant.
    var first = existing("p", "shared", "odm_prov_1", 2);
    first.diagnostics = &d;
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), first);
    try testing.expectEqual(odm.ConnectionState.active, (try registry.connectionStats(io, "shared")).state);
    try expectDatabase(&registry, io, "p", "odm_prov_1");
    try writeNotes(&registry, io, "p", "p", 1);

    // The same event again changes nothing.
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), first);
    try testing.expectEqualStrings("", d.message());
    try expectDatabase(&registry, io, "p", "odm_prov_1");
    try testing.expectEqual(@as(usize, 1), registry.stats(io).tenants);

    // An older event changes nothing either.
    var older = existing("p", "shared", "odm_prov_2", 1);
    older.diagnostics = &d;
    try testing.expectError(error.StaleVersion, registry.provisionTenant(io, within(io, .fromSeconds(10)), older));
    try testing.expectEqualStrings("odm: version 1 is older than the tenant's version 2", d.message());
    try expectDatabase(&registry, io, "p", "odm_prov_1");

    // A newer one with another database: the sessions after it go there.
    var newer = existing("p", "shared", "odm_prov_2", 3);
    newer.diagnostics = &d;
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), newer);
    try expectDatabase(&registry, io, "p", "odm_prov_2");
    try testing.expectEqual(@as(usize, 0), try ownNotes(&registry, io, "p", "p"));

    // The same version with other settings.
    var conflict = existing("p", "shared", "odm_prov_1", 3);
    conflict.diagnostics = &d;
    try testing.expectError(error.ProvisioningConflict, registry.provisionTenant(io, within(io, .fromSeconds(10)), conflict));
    try testing.expectEqualStrings("odm: version 3 is the tenant's version, with other settings", d.message());
    try expectDatabase(&registry, io, "p", "odm_prov_2");

    // A login of its own with a wrong password: the server refuses it, and
    // the connection that the provisioning made goes again.
    const refused: odm.Provision = .{
        .tenant = "p",
        .connection = .{ .new = .{ .id = "own", .uri = own_uri, .password = wrong } },
        .database = "odm_prov",
        .version = 4,
        .diagnostics = &d,
    };
    try testing.expectError(error.AuthenticationFailed, registry.provisionTenant(io, within(io, .fromSeconds(10)), refused));
    try testing.expect(d.message().len > 0);
    try testing.expect(std.mem.indexOf(u8, d.message(), wrong) == null);
    try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "own"));
    try expectDatabase(&registry, io, "p", "odm_prov_2");

    // A server that is not there: the error comes within the deadline of
    // the context, and the connection goes again.
    var away = refused;
    away.connection = .{ .new = .{ .id = "away", .uri = "mongodb://127.0.0.1:1" } };
    const began = Io.Clock.awake.now(io);
    const result = registry.provisionTenant(io, within(io, .fromSeconds(2)), away);
    const took = began.durationTo(Io.Clock.awake.now(io));
    if (result) |_| return error.TestUnexpectedResult else |err| switch (err) {
        error.Unavailable, error.DeadlineExceeded => {},
        else => return err,
    }
    try testing.expect(took.toMilliseconds() <= 3000);
    try testing.expect(d.message().len > 0);
    try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "away"));
    try expectDatabase(&registry, io, "p", "odm_prov_2");

    // The event with the right password: the tenant moves to its login.
    var retry = refused;
    retry.connection = .{ .new = .{ .id = "own", .uri = own_uri, .password = "odm-prov-pass" } };
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), retry);
    try testing.expectEqualStrings("", d.message());
    try expectDatabase(&registry, io, "p", "odm_prov");
    try writeNotes(&registry, io, "p", "p", 2);
    try testing.expectEqual(@as(usize, 2), try ownNotes(&registry, io, "p", "p"));
    try testing.expectEqual(@as(u64, 2), try countOnServer(&auth, io, "odm_prov", "notes"));

    const stats = registry.stats(io);
    try testing.expectEqual(@as(usize, 2), stats.connections.active);
    try testing.expectEqual(@as(usize, 1), stats.tenants);
    try testing.expectEqual(@as(usize, 0), stats.leases);
    try testing.expectEqual(@as(usize, 0), (try registry.connectionStats(io, "shared")).tenants);
    try testing.expectEqual(@as(usize, 1), (try registry.connectionStats(io, "own")).tenants);
}

test "rights isolate tenants" {
    try e2e.onZio(rights);
}

fn rights(io: Io) !void {
    const databases = [_][]const u8{ "odm_iso_a", "odm_iso_b" };
    var auth: e2e.Admin = undefined;
    try auth.openAuth(io);
    defer auth.close();
    for (databases) |name| try auth.dropDatabase(io, name);
    defer for (databases) |name| auth.dropDatabaseAtEnd(io, name);
    try auth.freshUser(io, "odm_iso_a", "odm_iso", "odm-iso-pass", .{.{ .role = "readWrite", .db = "odm_iso_a" }});
    defer auth.dropUserAtEnd(io, "odm_iso_a", "odm_iso");

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    // The login is good, so the provisioning succeeds; its rights end at
    // odm_iso_a.
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), .{
        .tenant = "iso",
        .connection = .{ .new = .{ .id = "iso", .uri = "mongodb://odm_iso@127.0.0.1:27118/odm_iso_a", .password = "odm-iso-pass" } },
        .database = "odm_iso_b",
        .version = 1,
    });
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("iso-a", "iso", "odm_iso_a", 1));
    try writeNotes(&registry, io, "iso-a", "iso-a", 1);

    var session = try registry.tenant(io, "iso");
    defer session.deinit(io);
    const notes = session.collection(Note);
    const ctx = within(io, .fromSeconds(10));
    try testing.expectError(error.CommandFailed, notes.insertOne(io, ctx, .{ .owner = "iso" }));
    try testing.expectEqual(@as(?i32, 13), session.diagnostics().code);
    try testing.expectError(error.CommandFailed, notes.count(io, ctx, .{}));
    try testing.expectEqual(@as(?i32, 13), session.diagnostics().code);
    try testing.expectError(error.CommandFailed, notes.find(io, ctx, .{}, .{}));
    try testing.expectEqual(@as(?i32, 13), session.diagnostics().code);
    try testing.expectError(error.CommandFailed, notes.deleteMany(io, ctx, .{}));
    try testing.expectEqual(@as(?i32, 13), session.diagnostics().code);

    // Nothing reached odm_iso_b; odm_iso_a holds the note of iso-a.
    try testing.expectEqual(@as(u64, 0), try countOnServer(&auth, io, "odm_iso_b", "notes"));
    try testing.expectEqual(@as(u64, 1), try countOnServer(&auth, io, "odm_iso_a", "notes"));
}

test "ensureIndexes twice, then DuplicateKey" {
    try e2e.onZio(indexes);
}

fn indexes(io: Io) !void {
    var admin: e2e.Admin = undefined;
    try admin.openPlain(io);
    defer admin.close();
    try admin.dropDatabase(io, "odm_idx");
    defer admin.dropDatabaseAtEnd(io, "odm_idx");

    var driver: mongo.OdmDriver = .init(testing.allocator);
    var registry: odm.Registry = .init(testing.allocator, io, driver.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "shared", .{ .uri = e2e.servers.plain });
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), existing("idx", "shared", "odm_idx", 1));
    var session = try registry.tenant(io, "idx");
    defer session.deinit(io);
    const members = session.collection(Member);
    const ctx = within(io, .fromSeconds(10));

    // The same indexes again are no error.
    try members.ensureIndexes(io, ctx);
    try members.ensureIndexes(io, ctx);
    _ = try members.insertOne(io, ctx, .{ .email = "ann@example.com", .name = "Ann" });
    try testing.expectError(error.DuplicateKey, members.insertOne(io, ctx, .{ .email = "ann@example.com", .name = "Ann again" }));
    try testing.expectEqual(@as(?i32, 11000), session.diagnostics().code);
    try testing.expectEqual(@as(?usize, 0), session.diagnostics().index);
    try testing.expect(std.mem.indexOf(u8, session.diagnostics().message(), "email_1") != null);

    // In a list, the documents before the duplicate go in, those after it
    // do not.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = [_]Member{
        .{ .email = "bob@example.com", .name = "Bob" },
        .{ .email = "ann@example.com", .name = "Ann" },
        .{ .email = "cy@example.com", .name = "Cy" },
    };
    try testing.expectError(error.DuplicateKey, members.insertMany(io, ctx, &list, arena.allocator()));
    try testing.expectEqual(@as(?i32, 11000), session.diagnostics().code);
    try testing.expectEqual(@as(?usize, 1), session.diagnostics().index);

    // The next call starts its diagnostics afresh.
    try testing.expectEqual(@as(u64, 2), try members.count(io, ctx, .{}));
    try testing.expectEqual(@as(?i32, null), session.diagnostics().code);
    try testing.expectEqual(@as(?usize, null), session.diagnostics().index);
    try testing.expectEqualStrings("", session.diagnostics().message());
    try testing.expectEqual(@as(u64, 0), try members.count(io, ctx, .{ .email = "cy@example.com" }));
}
