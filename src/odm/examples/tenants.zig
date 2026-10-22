//! Tenants: the shops of three companies in one service. acme and globex
//! share a server and its login, each with a database of its own; big-co
//! has a server and a login of its own. The service hears of its tenants
//! by events with versions, applies them to the registry as they come,
//! late and twice included, and serves the requests of each tenant in its
//! own database, after it checked that the caller may use that tenant.
//! Each run starts from empty collections.
//!
//! Settings, from the environment:
//!
//!   APP_SHARED_URI        the shared server; mongodb://127.0.0.1:27017 by
//!                         default
//!   APP_SHARED_PASSWORD   the password of the user of APP_SHARED_URI, if
//!                         it names one
//!   APP_BIG_URI           the server of big-co and its user, such as
//!                         mongodb://admin@127.0.0.1:27018
//!   APP_BIG_PASSWORD      that user's password
//!   APP_BIG_DATABASE      the database of big-co; bigco by default
//!
//! In tests/odm, `zig build example-tenants` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const odm = @import("odm");
const zio = @import("zio");
const bson = @import("mongo-bson");

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    shared: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        password: ?confy.Secret = null,
    } = .{},
    big: struct {
        uri: []const u8,
        password: ?confy.Secret = null,
        database: []const u8 = "bigco",
    },
};

/// An order of a shop, in the collection "orders" of its tenant.
const Order = struct {
    id: ?bson.ObjectId = null,
    customer: []const u8,
    item: []const u8,
    cents: u32,

    pub const odm_schema: odm.Schema(Order) = .{
        .collection = "orders",
        .id = .id,
        .indexes = &.{.{ .keys = &.{.{ .customer = .asc }} }},
    };
};

/// Who calls: the subject of the request's token and the tenants it may
/// use, as the authentication of the service finds them.
const Caller = struct { name: []const u8, tenants: []const []const u8 };

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    var driver: mongo.OdmDriver = .init(init.gpa);
    var registry: odm.Registry = .init(init.gpa, io, driver.driver(), .{});
    defer registry.deinit(io);
    // The shared server, as the service starts.
    try registry.registerConnection(io, "shared", .{
        .uri = config.shared.uri,
        .password = if (config.shared.password) |password| password.expose() else null,
    });
    try registry.connect(io, within(io, .fromSeconds(10)), "shared");

    // The events of the tenants, as they come: two on the shared
    // connection, each in its own database, and one with a connection of
    // its own, which the provisioning registers and connects.
    apply(&registry, io, app, .{ .tenant = "acme", .connection = .{ .existing = "shared" }, .database = "acme", .version = 1 });
    apply(&registry, io, app, .{ .tenant = "globex", .connection = .{ .existing = "shared" }, .database = "globex", .version = 1 });
    apply(&registry, io, app, .{
        .tenant = "big-co",
        .connection = .{ .new = .{
            .id = "big-co",
            .uri = config.big.uri,
            .password = if (config.big.password) |password| password.expose() else null,
        } },
        .database = config.big.database,
        .version = 1,
    });
    // The same event again, as a queue may deliver it twice: nothing
    // changes. The same version with other settings is a conflict; a newer
    // one applies; an older one that came late changes nothing.
    apply(&registry, io, app, .{ .tenant = "acme", .connection = .{ .existing = "shared" }, .database = "acme", .version = 1 });
    apply(&registry, io, app, .{ .tenant = "acme", .connection = .{ .existing = "shared" }, .database = "acme-eu", .version = 1 });
    apply(&registry, io, app, .{ .tenant = "acme", .connection = .{ .existing = "shared" }, .database = "acme", .version = 2 });
    apply(&registry, io, app, .{ .tenant = "acme", .connection = .{ .existing = "shared" }, .database = "acme", .version = 1 });

    // Each run starts afresh.
    for ([_][]const u8{ "acme", "globex", "big-co" }) |tenant_id| {
        var session = try registry.tenant(io, tenant_id);
        defer session.deinit(io);
        _ = try session.collection(Order).deleteMany(io, within(io, .fromSeconds(5)), .{});
    }

    // Requests. Ann works for acme, Bo for big-co.
    const ann: Caller = .{ .name = "ann", .tenants = &.{"acme"} };
    const bo: Caller = .{ .name = "bo", .tenants = &.{"big-co"} };
    const ops: Caller = .{ .name = "ops", .tenants = &.{ "acme", "globex", "big-co", "initech" } };
    serve(&registry, io, app, ann, "acme", .{ .customer = "cleo", .item = "green tea", .cents = 450 });
    serve(&registry, io, app, ann, "globex", .{ .customer = "cleo", .item = "black tea", .cents = 390 });
    serve(&registry, io, app, bo, "big-co", .{ .customer = "dan", .item = "oolong", .cents = 820 });
    serve(&registry, io, app, ops, "initech", .{ .customer = "eve", .item = "sencha", .cents = 610 });

    // Each tenant sees its own orders only.
    for ([_][]const u8{ "acme", "globex", "big-co" }) |tenant_id| {
        var session = try registry.tenant(io, tenant_id);
        defer session.deinit(io);
        const orders = try session.collection(Order).count(io, within(io, .fromSeconds(5)), .{});
        app.info("Orders", .{ .tenant = tenant_id, .count = orders });
    }

    // globex leaves: new requests do not find it.
    try registry.removeTenant(io, "globex");
    serve(&registry, io, app, ops, "globex", .{ .customer = "cleo", .item = "black tea", .cents = 390 });

    const stats = registry.stats(io);
    app.info("Done", .{ .active = stats.connections.active, .tenants = stats.tenants, .leases = stats.leases });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Applies an event of a tenant to the registry, and makes the indexes of
/// its database, which starts empty. The same event again changes nothing,
/// and so does an older one: the queue of the events may take both as
/// done.
fn apply(registry: *odm.Registry, io: std.Io, app: log.Logger, event: odm.Provision) void {
    var d: odm.Diagnostics = .{};
    var request = event;
    request.diagnostics = &d;
    const ctx = within(io, .fromSeconds(10));
    registry.provisionTenant(io, ctx, request) catch |err| {
        app.warn("Event not applied", .{ .tenant = event.tenant, .version = event.version, .reason = err, .details = d.message() });
        return;
    };
    var session = registry.tenant(io, event.tenant) catch return;
    defer session.deinit(io);
    session.collection(Order).ensureIndexes(io, ctx) catch |err| {
        app.warn("No indexes", .{ .tenant = event.tenant, .reason = err, .details = session.diagnostics().message() });
        return;
    };
    app.info("Event applied", .{ .tenant = event.tenant, .version = event.version });
}

/// Serves a request and logs how it went.
fn serve(registry: *odm.Registry, io: std.Io, app: log.Logger, caller: Caller, tenant_id: []const u8, order: Order) void {
    const id = placeOrder(registry, io, within(io, .fromSeconds(5)), caller, tenant_id, order) catch |err| {
        app.warn("Refused", .{ .tenant = tenant_id, .caller = caller.name, .reason = err });
        return;
    };
    app.info("Order placed", .{ .tenant = tenant_id, .caller = caller.name, .id = id });
}

const PlaceError = odm.Error || error{Forbidden};

/// The handler of `POST /tenants/{tenant}/orders`, with the fields of the
/// request as its parameters. The tenant id comes from the path, which the
/// caller wrote: the handler checks that the caller may use that tenant
/// before it asks the registry, which takes any id it knows.
fn placeOrder(registry: *odm.Registry, io: std.Io, ctx: core.Context, caller: Caller, tenant_id: []const u8, order: Order) PlaceError!bson.ObjectId {
    for (caller.tenants) |allowed| {
        if (std.mem.eql(u8, allowed, tenant_id)) break;
    } else return error.Forbidden;
    var session = try registry.tenant(io, tenant_id);
    defer session.deinit(io);
    const placed = try session.collection(Order).insertOne(io, ctx, order);
    return placed.id;
}
