//! The quick start of the guide: the customers of a shop, for the tenant
//! "acme", in the collection "users" of its database. It connects, makes
//! the e-mail of a customer unique, signs customers up, finds the adults
//! among them, gives one a birthday, lets one go, and counts the adults
//! again. Each run starts from an empty collection.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const odm = @import("odm");
const zio = @import("zio");
const bson = @import("mongo-bson");

/// odm and the driver log through std.log; this sends their records to
/// the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        /// Kept out of the URI, and out of every log.
        password: ?confy.Secret = null,
    } = .{},
};

/// A customer of the shop, as the collection keeps it.
const User = struct {
    /// null: odm makes an ObjectId when it inserts the customer.
    id: ?bson.ObjectId = null,
    email: []const u8,
    name: []const u8,
    age: u32 = 0,

    pub const odm_schema: odm.Schema(User) = .{
        .collection = "users",
        .id = .id,
        .indexes = &.{.{ .keys = &.{.{ .email = .asc }}, .unique = true }},
    };
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    // The logger outlives the runtime, so it takes `init.io`, through which
    // the tasks of the runtime may log too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    // One runtime for the program, with an executor per CPU core. The
    // registry and every call of it run on its `io`.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // The driver and the registry: one of each for the whole program.
    // Neither does I/O yet.
    var driver: mongo.OdmDriver = .init(init.gpa);
    var registry: odm.Registry = .init(init.gpa, io, driver.driver(), .{});
    defer registry.deinit(io);
    // A connection: this server, with this login. Registering it opens a
    // client of the driver without the network; connect opens the first
    // network connection and logs in, under its deadline.
    try registry.registerConnection(io, "main", .{
        .uri = config.mongo.uri,
        .password = if (config.mongo.password) |password| password.expose() else null,
    });
    registry.connect(io, within(io, .fromSeconds(10)), "main") catch |err| {
        const stats = try registry.connectionStats(io, "main");
        app.err("Cannot connect", .{ .reason = err, .details = if (stats.last_failure) |*failure| failure.message() else "" });
        return err;
    };
    app.info("Connected", .{});
    // A tenant: acme, whose database is "acme", on that connection.
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), .{
        .tenant = "acme",
        .connection = .{ .existing = "main" },
        .database = "acme",
        .version = 1,
    });

    try run(io, init.gpa, &registry, app);

    const stats = registry.stats(io);
    app.info("Done", .{ .tenants = stats.tenants, .operations = stats.operations, .leases = stats.leases });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// The application: it asks the registry for its tenant, and sees a
/// collection, not the connection.
fn run(io: std.Io, gpa: std.mem.Allocator, registry: *odm.Registry, app: log.Logger) !void {
    // The memory of the results, all freed at the end.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Five seconds for all of it: each call has what is left of them.
    const ctx = within(io, .fromSeconds(5));

    // A session on the tenant's database, for this task, and the
    // collection of User in it.
    var acme = try registry.tenant(io, "acme");
    defer acme.deinit(io);
    const users = acme.collection(User);

    // Start afresh, and make the e-mail of a customer unique.
    _ = try users.deleteMany(io, ctx, .{});
    try users.ensureIndexes(io, ctx);

    // A customer; odm makes the id, and says which.
    const ann = try users.insertOne(io, ctx, .{ .email = "ann@example.com", .name = "Ann", .age = 30 });
    app.info("Signed up", .{ .name = "Ann", .id = ann.id });
    // Three more, in one request.
    const more = [_]User{
        .{ .email = "bob@example.com", .name = "Bob", .age = 17 },
        .{ .email = "cleo@example.com", .name = "Cleo", .age = 41 },
        .{ .email = "dan@example.com", .name = "Dan", .age = 25 },
    };
    const signed = try users.insertMany(io, ctx, &more, arena);
    app.info("Signed up", .{ .count = signed.ids.len });

    // The adults, the oldest first. The cursor brings them batch by batch,
    // each one decoded into a User in the arena.
    var adults = try users.find(io, ctx, .{ .age = .{ .gte = 18 } }, .{ .sort = .{ .age = .desc } });
    defer adults.deinit(io);
    while (try adults.next(io, ctx, arena)) |user| app.info("Adult", .{ .name = user.name, .age = user.age });

    // Bob has a birthday.
    const birthday = try users.updateOne(io, ctx, .{ .email = "bob@example.com" }, .{ .inc = .{ .age = 1 } });
    app.info("Birthday", .{ .matched = birthday.matched, .modified = birthday.modified });
    // Dan leaves the shop.
    const left = try users.deleteOne(io, ctx, .{ .email = "dan@example.com" });
    app.info("Left", .{ .deleted = left.deleted });
    const count = try users.count(io, ctx, .{ .age = .{ .gte = 18 } });
    app.info("Adults now", .{ .count = count });
}
