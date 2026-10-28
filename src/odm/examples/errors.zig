//! The errors of odm against mongod: what each says, whether the call may
//! have run on the server, and whether it is worth making again. The
//! customers of the tenant acme have unique e-mails, some sign up twice,
//! and another program leaves a document that the model cannot read. Each
//! run starts from an empty collection.
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
const v = @import("validator");
const zio = @import("zio");
const bson = @import("mongo-bson");

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        password: ?confy.Secret = null,
    } = .{},
};

const Customer = struct {
    id: ?bson.ObjectId = null,
    email: []const u8,
    name: []const u8,

    pub const odm_schema: odm.Schema(Customer) = .{
        .collection = "customers",
        .id = .id,
        .indexes = &.{.{ .keys = &.{.{ .email = .asc }}, .unique = true }},
    };
    pub const field_rules = .{ .email = v.email };
};

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
    try registry.registerConnection(io, "main", .{
        .uri = config.mongo.uri,
        .password = if (config.mongo.password) |password| password.expose() else null,
    });
    try registry.connect(io, within(io, .fromSeconds(10)), "main");
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), .{ .tenant = "acme", .connection = .{ .existing = "main" }, .database = "acme", .version = 1 });

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ctx = within(io, .fromSeconds(10));
    var acme = try registry.tenant(io, "acme");
    defer acme.deinit(io);
    const customers = acme.collection(Customer);
    _ = try customers.deleteMany(io, ctx, .{});
    try customers.ensureIndexes(io, ctx);
    _ = try customers.insertOne(io, ctx, .{ .email = "ann@example.com", .name = "Ann" });
    const d = acme.diagnostics();

    // DuplicateKey: the unique index refused the e-mail. The write reached
    // the server, so it may have run: here it did not, as the index
    // refused it, but odm cannot tell that from the error alone.
    if (customers.insertOne(io, ctx, .{ .email = "ann@example.com", .name = "Ann B." })) |_| {
        app.info("Signed up again", .{});
    } else |err| report(app, "A second sign-up", err, d);

    // In insertMany the documents before the refused one went in, and the
    // ones after it did not: the index says which.
    const newcomers = [_]Customer{
        .{ .email = "bob@example.com", .name = "Bob" },
        .{ .email = "ann@example.com", .name = "Ann" },
        .{ .email = "cleo@example.com", .name = "Cleo" },
    };
    if (customers.insertMany(io, ctx, &newcomers, arena)) |_| {
        app.info("All signed up", .{});
    } else |err| {
        report(app, "An import", err, d);
        app.info("Refused", .{ .index = d.index.?, .customers = try customers.count(io, ctx, .{}) });
    }

    // ValidationFailed: the rules of the model; nothing was sent.
    if (customers.insertOne(io, ctx, .{ .email = "dan", .name = "Dan" })) |_| {
        app.info("Signed up", .{});
    } else |err| report(app, "A sign-up", err, d);

    // DecodeFailed: another program wrote a customer without a name. The
    // cursor reports it, and goes on with the next document.
    _ = try acme.runCommand(io, ctx, .{ .insert = "customers", .documents = .{.{ .email = "eve@example.com" }} }, arena);
    var all = try customers.find(io, ctx, .{}, .{ .sort = .{ .email = .asc } });
    defer all.deinit(io);
    while (true) {
        const customer = all.next(io, ctx, arena) catch |err| {
            const cd = all.diagnostics();
            app.warn("A document failed", .{ .reason = err, .outcome = odm.outcome(err), .path = cd.path(), .cause = cd.cause.? });
            continue;
        } orelse break;
        app.info("Customer", .{ .email = customer.email, .name = customer.name });
    }

    // CommandFailed: the server answered ok: 0, with its code.
    if (acme.runCommand(io, ctx, .{ .frobnicate = 1 }, arena)) |_| {
        app.info("Frobnicated", .{});
    } else |err| report(app, "A command", err, d);

    // InvalidArgument: an update built at run time with no change.
    if (customers.updateOne(io, ctx, .{ .email = "ann@example.com" }, odm.Update(Customer).init(arena))) |_| {
        app.info("Updated", .{});
    } else |err| report(app, "An update", err, d);

    // DeadlineExceeded: no time left before sending.
    if (customers.count(io, within(io, .zero), .{})) |_| {
        app.info("Counted", .{});
    } else |err| report(app, "A count", err, d);

    // TenantNotFound, from the registry.
    if (registry.tenant(io, "initech")) |found| {
        var session = found;
        session.deinit(io);
    } else |err| app.warn("No session", .{ .reason = err, .outcome = odm.outcome(err), .retry = worthRetry(err) });

    // Unavailable: a server that is not there, as a connection finds it.
    try registry.registerConnection(io, "away", .{ .uri = "mongodb://127.0.0.1:1" });
    if (registry.connect(io, within(io, .fromSeconds(5)), "away")) |_| {
        app.info("Connected", .{});
    } else |err| {
        const stats = try registry.connectionStats(io, "away");
        app.warn("Cannot connect", .{ .reason = err, .retry = worthRetry(err), .state = stats.state, .details = if (stats.last_failure) |*failure| failure.message() else "" });
    }
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Whether a call that failed with `err` is worth making again after a
/// pause: it did not reach the server, and what stopped it may pass. The
/// others that did not reach it fail the same way again until the call,
/// its context, the tenant or the settings change.
fn worthRetry(err: odm.Error) bool {
    if (odm.outcome(err) != .not_sent) return false;
    return switch (err) {
        error.Unavailable, error.PoolExhausted => true,
        else => false,
    };
}

/// Logs `err` of `what`, its details, and whether the call may have run.
fn report(app: log.Logger, comptime what: []const u8, err: odm.Error, d: *const odm.Diagnostics) void {
    app.warn(what ++ " failed", .{
        .reason = err,
        .outcome = odm.outcome(err),
        .retry = worthRetry(err),
        .code = d.code orelse 0,
        .details = d.message(),
    });
}
