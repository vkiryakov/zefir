//! Tests of the tenants of odm.Registry on odm.testing.FakeDriver: bindings
//! by provisioning, `tenant()` and its sessions, the removal of a tenant,
//! the versions of a tenant and the queue of its provisionings.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const core = @import("core");
const odm = @import("../root.zig");
const support = @import("support.zig");
const FakeDriver = odm.testing.FakeDriver;
const Registry = odm.Registry;
const Outcome = support.Outcome;
const eventually = support.eventually;

/// Registers and connects "shared-1", of fake://shared.
fn shared(registry: *Registry, io: Io) !void {
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://shared" });
    try registry.connect(io, .root, "shared-1");
}

/// A provisioning on the known connection `id`.
fn existing(tenant_id: []const u8, id: []const u8, database: []const u8, version: u64) odm.Provision {
    return .{ .tenant = tenant_id, .connection = .{ .existing = id }, .database = database, .version = version };
}

fn replaceTask(o: *Outcome, r: *Registry, io: Io, id: []const u8, uri: []const u8) void {
    o.set(r.replaceConnection(io, .root, id, .{ .uri = uri }));
}

test "bind" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try shared(&registry, io);

    // The registry keeps copies of the tenant id and the database name.
    var tenant_id = "acme".*;
    var database = "acme_db".*;
    var d: odm.Diagnostics = .{};
    try registry.provisionTenant(io, .root, .{ .tenant = &tenant_id, .connection = .{ .existing = "shared-1" }, .database = &database, .version = 1, .diagnostics = &d });
    try testing.expectEqualStrings("", d.message());
    tenant_id = "xxxx".*;
    database = "xxxxxxx".*;
    {
        var session = try registry.tenant(io, "acme");
        defer session.deinit(io);
        try testing.expectEqualStrings("acme_db", session.database());
        try testing.expectEqualStrings("", session.diagnostics().message());
        const s = registry.stats(io);
        try testing.expectEqual(@as(usize, 1), s.tenants);
        try testing.expectEqual(@as(usize, 1), s.leases);
        try testing.expectEqual(@as(usize, 1), (try registry.connectionStats(io, "shared-1")).tenants);
    }
    try testing.expectEqual(@as(usize, 0), registry.stats(io).leases);
    // The connection was active: nothing more went to the network.
    try testing.expectEqual(@as(usize, 1), fake.counts(io).connected);

    // A registered connection is connected first.
    try registry.registerConnection(io, "lazy", .{ .uri = "fake://lazy" });
    try registry.provisionTenant(io, .root, existing("globex", "lazy", "globex", 1));
    try testing.expectEqual(odm.ConnectionState.active, (try registry.connectionStats(io, "lazy")).state);
    try testing.expectEqual(@as(usize, 2), fake.counts(io).connected);

    // An unknown connection binds nothing.
    var unknown = existing("initech", "nope", "initech", 1);
    unknown.diagnostics = &d;
    try testing.expectError(error.ConnectionNotFound, registry.provisionTenant(io, .root, unknown));
    try testing.expectEqualStrings("odm: no connection has this id", d.message());
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "initech"));
    try testing.expectEqual(@as(usize, 2), registry.stats(io).tenants);
}

test "unknown tenant" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "acme"));
    try shared(&registry, io);
    try registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme", 1));

    try testing.expectError(error.TenantNotFound, registry.tenant(io, "globex"));
    // No other tenant stands in, whatever the id.
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "ACME"));
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "acme "));
    // Ids that no tenant can have.
    try testing.expectError(error.TenantNotFound, registry.tenant(io, ""));
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "a b"));
    try testing.expectError(error.TenantNotFound, registry.tenant(io, &@as([129]u8, @splat('a'))));
    try testing.expectEqual(@as(usize, 0), registry.stats(io).leases);
}

test "bad names are refused before any I/O" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "lazy", .{ .uri = "fake://lazy" });

    var d: odm.Diagnostics = .{};
    const cases = [_]struct { request: odm.Provision, text: []const u8 }{
        .{ .request = existing(&@as([129]u8, @splat('a')), "lazy", "acme", 1), .text = "odm: the tenant id is longer than 128 bytes" },
        .{ .request = existing("a\x7f", "lazy", "acme", 1), .text = "odm: the tenant id holds a byte outside visible ASCII, 0x21 to 0x7E" },
        .{ .request = existing("acme", "lazy", "Admin", 1), .text = "odm: the database name is a system one: admin, local or config" },
        .{ .request = existing("acme", "lazy", "CONFIG", 1), .text = "odm: the database name is a system one: admin, local or config" },
        .{ .request = existing("acme", "lazy", "a.b", 1), .text = "odm: the database name holds one of / \\ . \" $, a space or NUL" },
        .{ .request = existing("acme", "lazy", &@as([62]u8, @splat('a')) ++ "я", 1), .text = "odm: the database name is longer than 63 bytes" },
        .{ .request = existing("acme", "lazy", "\xff", 1), .text = "odm: the database name is not UTF-8" },
        .{
            .request = .{ .tenant = "acme", .connection = .{ .new = .{ .id = "big/1", .uri = "fake://big" } }, .database = "acme", .version = 1 },
            .text = "odm: the connection id holds a byte other than A-Z a-z 0-9 _ - . :",
        },
    };
    for (cases) |case| {
        var request = case.request;
        request.diagnostics = &d;
        try testing.expectError(error.InvalidArgument, registry.provisionTenant(io, .root, request));
        try testing.expectEqualStrings(case.text, d.message());
    }
    // Nothing reached the driver: no client was opened, no connect made.
    try testing.expectEqual(@as(usize, 1), fake.counts(io).opened);
    try testing.expectEqual(@as(usize, 0), fake.journal(io).len);
    try testing.expectEqual(odm.ConnectionState.registered, (try registry.connectionStats(io, "lazy")).state);
    try testing.expectEqual(@as(usize, 0), registry.stats(io).tenants);
}

test "shared connection" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try shared(&registry, io);

    try registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme", 1));
    try registry.provisionTenant(io, .root, existing("globex", "shared-1", "globex", 1));
    var acme = try registry.tenant(io, "acme");
    defer acme.deinit(io);
    var globex = try registry.tenant(io, "globex");
    defer globex.deinit(io);
    try testing.expectEqualStrings("acme", acme.database());
    try testing.expectEqualStrings("globex", globex.database());
    // One client, two databases.
    try testing.expect(acme.generation == globex.generation);
    try testing.expectEqual(@as(usize, 1), fake.counts(io).opened);
    const s = try registry.connectionStats(io, "shared-1");
    try testing.expectEqual(@as(usize, 2), s.tenants);
    try testing.expectEqual(@as(usize, 2), s.leases);
    try testing.expectEqual(@as(usize, 2), registry.stats(io).tenants);
}

test "separate connections" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try shared(&registry, io);

    // Both kinds at once: a tenant on the shared connection, two on their own.
    try registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme", 1));
    try registry.provisionTenant(io, .root, .{
        .tenant = "big",
        .connection = .{ .new = .{ .id = "big-1", .uri = "fake://big", .password = "secret" } },
        .database = "big",
        .version = 1,
    });
    try registry.provisionTenant(io, .root, .{
        .tenant = "huge",
        .connection = .{ .new = .{ .id = "huge-1", .uri = "fake://huge" } },
        .database = "huge",
        .version = 1,
    });
    var acme = try registry.tenant(io, "acme");
    defer acme.deinit(io);
    var big = try registry.tenant(io, "big");
    defer big.deinit(io);
    var huge = try registry.tenant(io, "huge");
    defer huge.deinit(io);
    try testing.expectEqualStrings("big", big.database());
    try testing.expectEqualStrings("huge", huge.database());
    try testing.expect(acme.generation != big.generation);
    try testing.expect(big.generation != huge.generation);
    // Each new connection was registered and connected.
    const own = try registry.connectionStats(io, "big-1");
    try testing.expectEqual(odm.ConnectionState.active, own.state);
    try testing.expectEqual(@as(u64, 1), own.generation);
    try testing.expectEqual(@as(usize, 1), own.tenants);
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 3), counts.opened);
    try testing.expectEqual(@as(usize, 3), counts.connected);
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 3), s.connections.active);
    try testing.expectEqual(@as(usize, 3), s.tenants);
    try testing.expectEqual(@as(usize, 3), s.leases);
}

test "a failed .new rolls back" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try fake.plan("fake://locked", .{ .connects = &.{error.AuthenticationFailed} });
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var d: odm.Diagnostics = .{};
    const request: odm.Provision = .{
        .tenant = "big",
        .connection = .{ .new = .{ .id = "big-1", .uri = "fake://locked", .password = "secret" } },
        .database = "big",
        .version = 1,
        .diagnostics = &d,
    };
    try testing.expectError(error.AuthenticationFailed, registry.provisionTenant(io, .root, request));
    try testing.expectEqualStrings("the plan of the fake fails this connect with AuthenticationFailed", d.message());
    // The connection that the call made is gone, its client closed and freed.
    try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "big-1"));
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "big"));
    var counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 1), counts.opened);
    try testing.expectEqual(counts.opened, counts.closed);
    try testing.expectEqual(counts.opened, counts.freed);
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 0), s.connections.failed);
    try testing.expectEqual(@as(usize, 0), s.connections.removing);
    try testing.expectEqual(@as(usize, 0), s.tenants);

    // The same event again, once the server takes the login, succeeds.
    try fake.plan("fake://locked", .{});
    try registry.provisionTenant(io, .root, request);
    try testing.expectEqualStrings("", d.message());
    try testing.expectEqual(odm.ConnectionState.active, (try registry.connectionStats(io, "big-1")).state);
    {
        var big = try registry.tenant(io, "big");
        defer big.deinit(io);
    }
    counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 2), counts.opened);
    try testing.expectEqual(@as(usize, 1), counts.freed);
}

test "remove tenant" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try shared(&registry, io);
    try registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme", 1));

    var before = try registry.tenant(io, "acme");
    // Given back in the middle of the test; a failed check before that
    // gives it back here, so that the registry's deinit finds no lease.
    var held = true;
    defer if (held) before.deinit(io);
    try registry.removeTenant(io, "acme");
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "acme"));
    try testing.expectEqual(@as(usize, 0), registry.stats(io).tenants);
    // A session taken before works until its deinit: its database and its
    // lease of a live client stay.
    try testing.expectEqualStrings("acme", before.database());
    try testing.expectEqual(@as(usize, 1), registry.stats(io).leases);
    try before.generation.client.ping(io, .root, null);
    before.deinit(io);
    held = false;
    try testing.expectEqual(@as(usize, 0), registry.stats(io).leases);
    // The connection stays.
    const s = try registry.connectionStats(io, "shared-1");
    try testing.expectEqual(odm.ConnectionState.active, s.state);
    try testing.expectEqual(@as(usize, 0), s.tenants);
    try testing.expectEqual(@as(usize, 0), fake.counts(io).closed);

    try testing.expectError(error.TenantNotFound, registry.removeTenant(io, "acme"));
    try testing.expectError(error.TenantNotFound, registry.removeTenant(io, "globex"));
    // The tenant may come again.
    try registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme", 1));
    var again = try registry.tenant(io, "acme");
    defer again.deinit(io);
}

/// Whether the connection "shared-1" has its generation `n`, with one old
/// generation draining.
const Replaced = struct { r: *Registry, n: u64 };

fn isReplaced(e: Replaced, io: Io) bool {
    const s = e.r.connectionStats(io, "shared-1") catch return false;
    return s.generation == e.n and s.draining == 1;
}

test "a session keeps its generation" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try shared(&registry, io);
    try registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme", 1));

    var group: Io.Group = .init;
    defer group.cancel(io);
    // Both are given back in the middle of the test. A failed check before
    // that gives them back here, before the group's cancel: the
    // replacement drains until they are, and the registry's deinit must
    // find no lease.
    var first = try registry.tenant(io, "acme");
    var first_held = true;
    defer if (first_held) first.deinit(io);
    var second = try registry.tenant(io, "acme");
    var second_held = true;
    defer if (second_held) second.deinit(io);
    var replace: Outcome = .{};
    try group.concurrent(io, replaceTask, .{ &replace, &registry, io, "shared-1", "fake://b" });
    // The new generation is published; the old one drains, held by both
    // sessions.
    try eventually(io, Replaced{ .r = &registry, .n = 2 }, isReplaced);
    try testing.expectEqual(@as(usize, 1), registry.stats(io).draining);
    {
        var fresh = try registry.tenant(io, "acme");
        defer fresh.deinit(io);
        try testing.expectEqual(@as(u64, 2), fresh.generation.number);
        try testing.expectEqual(@as(u64, 1), first.generation.number);
        try testing.expectEqual(@as(usize, 3), registry.stats(io).leases);
    }

    // Giving a lease back makes no I/O.
    const calls = fake.journal(io).len;
    first.deinit(io);
    first_held = false;
    try testing.expectEqual(calls, fake.journal(io).len);
    try testing.expectEqual(@as(usize, 0), fake.counts(io).close_calls);
    try io.sleep(.fromMilliseconds(30), .awake);
    try testing.expect(!replace.done.load(.acquire));
    // The last one lets the replacement close the old generation and return.
    second.deinit(io);
    second_held = false;
    try try replace.wait(io);
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 1), counts.close_calls);
    try testing.expectEqual(@as(usize, 1), counts.freed);
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 0), s.draining);
    try testing.expectEqual(@as(usize, 0), s.leases);
    try testing.expectEqual(@as(usize, 0), s.forced);
}

/// The session of `tenant_id` is on `database`.
fn expectDatabase(r: *Registry, io: Io, tenant_id: []const u8, database: []const u8) !void {
    var session = try r.tenant(io, tenant_id);
    defer session.deinit(io);
    try testing.expectEqualStrings(database, session.database());
}

test "the versions of a tenant" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try shared(&registry, io);
    try registry.registerConnection(io, "other-1", .{ .uri = "fake://other" });
    try registry.connect(io, .root, "other-1");

    // No binding: any version is applied.
    try registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme_v2", 2));
    var old = try registry.tenant(io, "acme");
    defer old.deinit(io);

    // Older: nothing changes, and the text names both versions.
    var d: odm.Diagnostics = .{};
    var stale = existing("acme", "other-1", "acme_v1", 1);
    stale.diagnostics = &d;
    try testing.expectError(error.StaleVersion, registry.provisionTenant(io, .root, stale));
    try testing.expectEqualStrings("odm: version 1 is older than the tenant's version 2", d.message());
    try expectDatabase(&registry, io, "acme", "acme_v2");

    // The same version with the same settings: the event again, nothing to
    // do, nothing opened or connected.
    const calls = fake.journal(io).len;
    const counts = fake.counts(io);
    var repeat = existing("acme", "shared-1", "acme_v2", 2);
    repeat.diagnostics = &d;
    try registry.provisionTenant(io, .root, repeat);
    try testing.expectEqualStrings("", d.message());
    try testing.expectEqual(calls, fake.journal(io).len);
    try testing.expectEqual(counts, fake.counts(io));

    // The same version with other settings: a conflict, whatever differs.
    const conflicts = [_]odm.Provision{
        existing("acme", "shared-1", "acme_other", 2),
        existing("acme", "other-1", "acme_v2", 2),
        // The same connection, named as a new one.
        .{ .tenant = "acme", .connection = .{ .new = .{ .id = "shared-1", .uri = "fake://shared" } }, .database = "acme_v2", .version = 2 },
    };
    for (conflicts) |request| {
        var conflict = request;
        conflict.diagnostics = &d;
        try testing.expectError(error.ProvisioningConflict, registry.provisionTenant(io, .root, conflict));
        try testing.expectEqualStrings("odm: version 2 is the tenant's version, with other settings", d.message());
    }
    try testing.expectEqual(counts, fake.counts(io));
    try expectDatabase(&registry, io, "acme", "acme_v2");

    // Newer: applied, whatever the settings. New sessions get the new
    // database and connection; the old session keeps its own.
    try registry.provisionTenant(io, .root, existing("acme", "other-1", "acme_v3", 3));
    var fresh = try registry.tenant(io, "acme");
    defer fresh.deinit(io);
    try testing.expectEqualStrings("acme_v3", fresh.database());
    try testing.expectEqualStrings("acme_v2", old.database());
    try testing.expect(fresh.generation != old.generation);
    try testing.expectEqual(@as(usize, 0), (try registry.connectionStats(io, "shared-1")).tenants);
    try testing.expectEqual(@as(usize, 1), (try registry.connectionStats(io, "other-1")).tenants);
    try testing.expectEqual(@as(usize, 1), registry.stats(io).tenants);
}

test "a new connection with a known id" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    const big: odm.NewConnection = .{ .id = "big-1", .uri = "fake://big", .password = "a" };
    try registry.provisionTenant(io, .root, .{ .tenant = "acme", .connection = .{ .new = big }, .database = "acme", .version = 1 });
    // The same settings: the connection is taken as it is, as .existing.
    try registry.provisionTenant(io, .root, .{ .tenant = "globex", .connection = .{ .new = big }, .database = "globex", .version = 1 });
    try testing.expectEqual(@as(usize, 1), fake.counts(io).opened);
    try testing.expectEqual(@as(usize, 2), (try registry.connectionStats(io, "big-1")).tenants);

    // Other settings: a conflict, since changing them is replaceConnection's.
    var d: odm.Diagnostics = .{};
    var other = big;
    other.password = "b";
    try testing.expectError(error.ProvisioningConflict, registry.provisionTenant(io, .root, .{ .tenant = "initech", .connection = .{ .new = other }, .database = "initech", .version = 1, .diagnostics = &d }));
    try testing.expectEqualStrings("odm: connection big-1 exists with other settings: change them with replaceConnection", d.message());
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "initech"));
    try testing.expectEqual(@as(usize, 1), fake.counts(io).opened);

    // A connection that registerConnection made counts the same way; a
    // registered one is connected first.
    try registry.registerConnection(io, "lazy", .{ .uri = "fake://lazy" });
    try registry.provisionTenant(io, .root, .{ .tenant = "hooli", .connection = .{ .new = .{ .id = "lazy", .uri = "fake://lazy" } }, .database = "hooli", .version = 1 });
    try testing.expectEqual(odm.ConnectionState.active, (try registry.connectionStats(io, "lazy")).state);
    try testing.expectEqual(@as(usize, 2), fake.counts(io).opened);

    // A failed connect of a connection that this call did not make keeps
    // it, for a connect to come again.
    try fake.plan("fake://locked", .{ .connects = &.{error.AuthenticationFailed} });
    try registry.registerConnection(io, "locked", .{ .uri = "fake://locked" });
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.AuthenticationFailed, registry.provisionTenant(io, .root, .{ .tenant = "pied", .connection = .{ .new = .{ .id = "locked", .uri = "fake://locked" } }, .database = "pied", .version = 1 }));
    try testing.expectEqual(odm.ConnectionState.failed, (try registry.connectionStats(io, "locked")).state);
}

/// A count of clients that the fake must have opened.
const Opened = struct { fake: *FakeDriver, n: usize };

fn isOpened(e: Opened, io: Io) bool {
    return e.fake.counts(io).opened >= e.n;
}

test "a .new waits for the replacement of its connection in progress, then finds its settings" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    const before: odm.NewConnection = .{ .id = "big-1", .uri = "fake://big", .password = "a" };
    try registry.provisionTenant(io, .root, .{ .tenant = "big", .connection = .{ .new = before }, .database = "big", .version = 1 });
    // The connection moves to a new password, and its new client takes a
    // while to connect.
    try fake.plan("fake://big", .{ .connect_delay = .fromMilliseconds(500) });
    var group: Io.Group = .init;
    defer group.cancel(io);
    var replace: Outcome = .{};
    try group.concurrent(io, replaceTaskWith, .{ &replace, &registry, io, "big-1", odm.ConnectionConfig{ .uri = "fake://big", .password = "b" } });
    // The replacement holds the turn once it has opened its client.
    try eventually(io, Opened{ .fake = &fake, .n = 2 }, isOpened);
    // The event of the tenant that brings the same change: its settings
    // are those of the replacement, which the connection has once it is
    // done.
    var after = before;
    after.password = "b";
    try registry.provisionTenant(io, .root, .{ .tenant = "big", .connection = .{ .new = after }, .database = "big_v2", .version = 2 });
    try try replace.wait(io);
    try expectDatabase(&registry, io, "big", "big_v2");
    const s = try registry.connectionStats(io, "big-1");
    try testing.expectEqual(@as(u64, 2), s.generation);
    try testing.expectEqual(@as(usize, 1), s.tenants);
    try testing.expectEqual(@as(usize, 2), fake.counts(io).opened);
}

fn replaceTaskWith(o: *Outcome, r: *Registry, io: Io, id: []const u8, config: odm.ConnectionConfig) void {
    o.set(r.replaceConnection(io, .root, id, config));
}

fn provisionCanceled(c: *support.Canceled, r: *Registry, io: Io, request: odm.Provision) void {
    c.set(io, r.provisionTenant(io, .root, request));
}

test "a .new canceled in its connect rolls back: no connection, no tenant" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    // The rollback frees the connection and the binding in the canceled
    // task. On macOS std drops a cancelation that comes during the stack
    // trace that std.testing.allocator takes at a free, so the registry's
    // memory comes from an allocator that takes none.
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
    {
        var registry: Registry = .init(gpa.allocator(), io, fake.driver(), .{});
        defer registry.deinit(io);
        // Only the cancelation ends this connect.
        try fake.plan("fake://big", .{ .connect_delay = .fromSeconds(60) });
        {
            var provision: support.Canceled = .{};
            var task = try io.concurrent(provisionCanceled, .{ &provision, &registry, io, odm.Provision{
                .tenant = "big",
                .connection = .{ .new = .{ .id = "big-1", .uri = "fake://big" } },
                .database = "big",
                .version = 1,
            } });
            defer task.cancel(io);
            // The connect of the new client is out.
            try eventually(io, support.Journaled{ .fake = &fake, .n = 1 }, support.isJournaled);
            task.cancel(io);
            try testing.expectError(error.Cancelled, provision.result);
            try testing.expect(provision.after);
        }
        try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "big-1"));
        try testing.expectError(error.TenantNotFound, registry.tenant(io, "big"));
        const counts = fake.counts(io);
        try testing.expectEqual(@as(usize, 1), counts.opened);
        try testing.expectEqual(@as(usize, 1), counts.closed);
        try testing.expectEqual(@as(usize, 1), counts.freed);
        const s = registry.stats(io);
        try testing.expectEqual(Registry.Stats.Connections{ .registered = 0, .connecting = 0, .active = 0, .failed = 0, .removing = 0 }, s.connections);
        try testing.expectEqual(@as(usize, 0), s.tenants);
        try testing.expectEqual(@as(usize, 0), s.leases);
        // The tenant's queue is free: the same event again goes through.
        try fake.plan("fake://big", .{});
        try registry.provisionTenant(io, .root, .{ .tenant = "big", .connection = .{ .new = .{ .id = "big-1", .uri = "fake://big" } }, .database = "big", .version = 1 });
        try expectDatabase(&registry, io, "big", "big");
    }
    try testing.expectEqual(@as(usize, 0), gpa.deinit());
}

test "remove connection with a tenant bound" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);
    try shared(&registry, io);
    try registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme", 1));

    try testing.expectError(error.ConnectionInUse, registry.removeConnection(io, "shared-1"));
    try expectDatabase(&registry, io, "acme", "acme");
    try registry.removeTenant(io, "acme");
    try registry.removeConnection(io, "shared-1");
    try testing.expectError(error.ConnectionNotFound, registry.connectionStats(io, "shared-1"));
    try testing.expectEqual(@as(usize, 1), fake.counts(io).freed);
    try testing.expectError(error.ConnectionNotFound, registry.provisionTenant(io, .root, existing("acme", "shared-1", "acme", 2)));
}

fn provisionTask(o: *Outcome, r: *Registry, io: Io, ctx: core.Context, request: odm.Provision) void {
    o.set(r.provisionTenant(io, ctx, request));
}

fn slowConnecting(r: *Registry, io: Io) bool {
    const s = r.connectionStats(io, "slow") catch return false;
    return s.state == .connecting;
}

test "provisionings of one tenant take turns" {
    const io = testing.io;
    var fake: FakeDriver = .init(testing.allocator);
    defer fake.deinit();
    var registry: Registry = .init(testing.allocator, io, fake.driver(), .{});
    defer registry.deinit(io);

    try fake.plan("fake://slow", .{ .connect_delay = .fromMilliseconds(300) });
    try registry.registerConnection(io, "slow", .{ .uri = "fake://slow" });
    var group: Io.Group = .init;
    defer group.cancel(io);
    var first: Outcome = .{};
    try group.concurrent(io, provisionTask, .{ &first, &registry, io, core.Context.root, existing("acme", "slow", "acme_v1", 1) });
    try eventually(io, &registry, slowConnecting);
    // The second waits until the first is done, then goes on.
    var second: Outcome = .{};
    try group.concurrent(io, provisionTask, .{ &second, &registry, io, core.Context.root, existing("acme", "slow", "acme_v2", 2) });

    // A deadline passes while a third waits for its turn.
    var d: odm.Diagnostics = .{};
    var third = existing("acme", "slow", "acme_v3", 3);
    third.diagnostics = &d;
    const start = Io.Clock.awake.now(io);
    const soon = core.Context.root.withDeadline(.after(start, .fromMilliseconds(50)));
    try testing.expectError(error.DeadlineExceeded, registry.provisionTenant(io, soon, third));
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 50 * std.time.ns_per_ms);
    try testing.expectEqualStrings("odm: the deadline passed while the call waited for another provisioning of the tenant", d.message());
    // And so does the cancelation of its task.
    var fourth: Outcome = .{};
    var task = try io.concurrent(provisionTask, .{ &fourth, &registry, io, core.Context.root, existing("acme", "slow", "acme_v4", 4) });
    try io.sleep(.fromMilliseconds(10), .awake);
    task.cancel(io);
    try testing.expectError(error.Cancelled, fourth.result);
    // A canceled token ends the wait too.
    var token: core.CancellationToken = .init;
    token.cancel();
    var fifth = existing("acme", "slow", "acme_v5", 5);
    fifth.diagnostics = &d;
    try testing.expectError(error.Cancelled, registry.provisionTenant(io, core.Context.root.withCancellation(&token), fifth));
    try testing.expectEqualStrings("odm: the token was canceled while the call waited for another provisioning of the tenant", d.message());
    try testing.expect(!second.done.load(.acquire));

    try try first.wait(io);
    try try second.wait(io);
    try expectDatabase(&registry, io, "acme", "acme_v2");
    // One connect: the second found the connection active.
    var connects: usize = 0;
    for (fake.journal(io)) |entry| {
        if (entry.call == .connect) connects += 1;
    }
    try testing.expectEqual(@as(usize, 1), connects);
}
