//! The registry under zefir.App, without a server: a module declares the
//! driver, the registry, which a factory makes on it, and the tenants of
//! the service, a bean whose `start` binds them. App builds the beans in
//! the order of their dependencies, starts the tenants, and at the stop
//! shuts the registry down within its deadline, then frees it. The driver
//! is `odm.testing.FakeDriver`, which runs no query; a service declares
//! `mongo.OdmDriver` in its place.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const odm = @import("odm");
const bson = @import("mongo-bson");

/// App and odm log through std.log; this sends their records to the
/// logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

/// The settings of the service; a service reads them with confy, as the
/// quick start does.
const Config = struct {
    /// The connection string of the shared server.
    uri: []const u8,
    /// The tenants that the service knows when it starts.
    tenants: []const []const u8,
};

/// A customer of a tenant.
const Customer = struct {
    id: ?bson.ObjectId = null,
    name: []const u8,

    pub const odm_schema: odm.Schema(Customer) = .{ .collection = "customers", .id = .id };
};

/// The tenants of the service. App builds it by its fields and starts it
/// once the registry is built: the connection of the settings, and a
/// tenant on it for each name, in a database of that name. The events of
/// tenants that come later call `provisionTenant` the same way.
pub const Tenants = struct {
    registry: *odm.Registry,
    config: *const Config,

    pub fn start(tenants: *Tenants, io: std.Io) !void {
        const registry = tenants.registry;
        try registry.registerConnection(io, "main", .{ .uri = tenants.config.uri });
        // The network, under a deadline.
        const ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(10)));
        try registry.connect(io, ctx, "main");
        for (tenants.config.tenants) |name| {
            try registry.provisionTenant(io, ctx, .{ .tenant = name, .connection = .{ .existing = "main" }, .database = name, .version = 1 });
        }
    }
};

/// What App builds: the driver and the tenants, by their `init` and their
/// fields, and the registry, which a factory makes.
pub const AppModule = struct {
    pub const module: core.app.Module = .{
        .providers = &.{ odm.testing.FakeDriver, Tenants },
        .factories = &.{Odm},
        .values = &.{*const Config},
    };

    pub const Odm = struct {
        /// The registry on the driver App built. App shuts it down
        /// (`shutdown`) at the stop, after the beans that take it, and
        /// frees it (`deinit`).
        pub fn registry(gpa: std.mem.Allocator, io: std.Io, driver: *odm.testing.FakeDriver) odm.Registry {
            return .init(gpa, io, driver.driver(), .{});
        }
    };
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const logger: log.Logger = try .init(init.gpa, io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app_log = logger.scoped("app");

    const config: Config = .{ .uri = "fake://shop", .tenants = &.{ "acme", "globex" } };
    var app = try core.App(AppModule).init(init.gpa, io, .{&config}, .{});
    defer app.deinit();
    // Once start returns, the tenants are bound.
    try app.start();
    const registry: *odm.Registry = app.get(odm.Registry);
    app_log.info("Started", .{ .tenants = registry.stats(io).tenants });

    // A request of the tenant acme, as a handler makes it.
    {
        var acme = try registry.tenant(io, "acme");
        defer acme.deinit(io);
        const ann = try acme.collection(Customer).insertOne(io, .root, .{ .name = "Ann" });
        app_log.info("Signed up", .{ .tenant = "acme", .id = ann.id });
    }

    // What a signal does in a service: App shuts the registry down within
    // its shutdown_timeout, and wait returns.
    app.requestStop();
    try app.wait();
    app_log.info("Stopped", .{ .state = app.state() });
}
