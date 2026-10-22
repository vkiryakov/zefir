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
    var big = try registry.tenant(io, "big");
    big.deinit(io);
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
    try registry.removeTenant(io, "acme");
    try testing.expectError(error.TenantNotFound, registry.tenant(io, "acme"));
    try testing.expectEqual(@as(usize, 0), registry.stats(io).tenants);
    // A session taken before works until its deinit: its database and its
    // lease of a live client stay.
    try testing.expectEqualStrings("acme", before.database());
    try testing.expectEqual(@as(usize, 1), registry.stats(io).leases);
    try before.generation.client.ping(io, .root, null);
    before.deinit(io);
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
    again.deinit(io);
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

    var first = try registry.tenant(io, "acme");
    var second = try registry.tenant(io, "acme");
    var group: Io.Group = .init;
    defer group.cancel(io);
    var replace: Outcome = .{};
    try group.concurrent(io, replaceTask, .{ &replace, &registry, io, "shared-1", "fake://b" });
    // The new generation is published; the old one drains, held by both
    // sessions.
    try eventually(io, Replaced{ .r = &registry, .n = 2 }, isReplaced);
    try testing.expectEqual(@as(usize, 1), registry.stats(io).draining);
    var fresh = try registry.tenant(io, "acme");
    try testing.expectEqual(@as(u64, 2), fresh.generation.number);
    try testing.expectEqual(@as(u64, 1), first.generation.number);
    try testing.expectEqual(@as(usize, 3), registry.stats(io).leases);
    fresh.deinit(io);

    // Giving a lease back makes no I/O.
    const calls = fake.journal(io).len;
    first.deinit(io);
    try testing.expectEqual(calls, fake.journal(io).len);
    try testing.expectEqual(@as(usize, 0), fake.counts(io).close_calls);
    try io.sleep(.fromMilliseconds(30), .awake);
    try testing.expect(!replace.done.load(.acquire));
    // The last one lets the replacement close the old generation and return.
    second.deinit(io);
    try try replace.wait(io);
    const counts = fake.counts(io);
    try testing.expectEqual(@as(usize, 1), counts.close_calls);
    try testing.expectEqual(@as(usize, 1), counts.freed);
    const s = registry.stats(io);
    try testing.expectEqual(@as(usize, 0), s.draining);
    try testing.expectEqual(@as(usize, 0), s.leases);
    try testing.expectEqual(@as(usize, 0), s.forced);
}
