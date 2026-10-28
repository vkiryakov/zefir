//! New credentials on the fly. The connection of the tenant acme changes
//! its user twice while four tasks serve requests through it, and none
//! of them fails. The program plays two parts: the secrets system of the
//! service, which makes and drops the users of mongod through zefir-mongo,
//! and the service, which replaces its connection through odm. Then it
//! repeats the last rotation, which changes nothing, and tries a password
//! that the server does not know yet, which the registry refuses and rolls
//! back. Each run makes users of its own, and drops them at the end.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_SERVER     the host and port of mongod, which checks logins;
//!                        127.0.0.1:27017 by default
//!   APP_ADMIN_URI        a user who may make users, for the secrets
//!                        system, such as mongodb://admin@127.0.0.1:27017
//!   APP_ADMIN_PASSWORD   that user's password

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
    mongo: struct {
        server: []const u8 = "127.0.0.1:27017",
    } = .{},
    admin: struct {
        uri: []const u8,
        password: confy.Secret,
    },
};

/// A note of the shop, which the requests write and count.
const Note = struct {
    id: ?bson.ObjectId = null,
    text: []const u8,

    pub const odm_schema: odm.Schema(Note) = .{ .collection = "notes", .id = .id };
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

    // The secrets system, with a user who may make users. The users of an
    // earlier run go first.
    var secrets: Secrets = .{
        .client = try .init(init.gpa, io, .{ .uri = config.admin.uri, .password = config.admin.password.expose() }),
        .ids = .init(io),
        .server = config.mongo.server,
        .gpa = init.gpa,
    };
    defer secrets.client.deinit();
    try secrets.client.connect(io, within(io, .fromSeconds(10)), null);
    defer secrets.client.close(io);
    try secrets.dropUser(io, "shop_a");
    try secrets.dropUser(io, "shop_b");

    // The service: its connection logs in as shop_a.
    var a: Credentials = undefined;
    var b: Credentials = undefined;
    try secrets.newUser(io, "shop_a", &a);
    var driver: mongo.OdmDriver = .init(init.gpa);
    var registry: odm.Registry = .init(init.gpa, io, driver.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "main", a.config());
    try registry.connect(io, within(io, .fromSeconds(10)), "main");
    try registry.provisionTenant(io, within(io, .fromSeconds(10)), .{ .tenant = "acme", .connection = .{ .existing = "main" }, .database = "acme", .version = 1 });
    {
        var acme = try registry.tenant(io, "acme");
        defer acme.deinit(io);
        _ = try acme.collection(Note).deleteMany(io, within(io, .fromSeconds(5)), .{});
    }

    // Four tasks serve requests while the credentials change.
    var calls: Calls = .{};
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);
    for (0..4) |_| try tasks.concurrent(io, serve, .{ &registry, io, &calls });

    // A rotation: a second user, the connection moves to it, and the
    // first user goes once the call returned. Then back, to shop_a with a
    // new password.
    try rotate(&registry, io, &secrets, app, "shop_a", "shop_b", &b);
    try rotate(&registry, io, &secrets, app, "shop_b", "shop_a", &a);
    try tasks.await(io);
    app.info("Requests during the rotations", .{ .made = calls.made.load(.monotonic), .failed = calls.failed.load(.monotonic) });

    // The same rotation again, as a queue may deliver its event twice: the
    // settings of the current generation, so nothing changes.
    try registry.replaceConnection(io, within(io, .fromSeconds(10)), "main", a.config());
    app.info("The same rotation again", .{ .generation = (try registry.connectionStats(io, "main")).generation });

    // A new password that the server does not know yet: the new generation
    // cannot log in, and the connection keeps the one it has.
    var d: odm.Diagnostics = .{};
    var early = a.config();
    early.password = "not-set-on-the-server";
    early.diagnostics = &d;
    if (registry.replaceConnection(io, within(io, .fromSeconds(10)), "main", early)) |_| {
        app.info("Rotated", .{});
    } else |err| {
        app.warn("Not rotated", .{ .reason = err, .details = d.message(), .generation = (try registry.connectionStats(io, "main")).generation });
    }

    // The service stops, and the secrets system drops its users.
    try registry.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake }));
    try secrets.dropUser(io, "shop_a");
    const stats = registry.stats(io);
    app.info("Done", .{ .leases = stats.leases, .forced = stats.forced });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Moves the connection "main" from the user `from` to a new user `to`,
/// whose credentials go to `next`, and drops `from` once the old
/// generation of the connection is closed.
fn rotate(registry: *odm.Registry, io: std.Io, secrets: *Secrets, app: log.Logger, from: []const u8, to: []const u8, next: *Credentials) !void {
    try secrets.newUser(io, to, next);
    // It returns once the leases of the old generation came back, or
    // drain_timeout passed, and the old generation is closed.
    try registry.replaceConnection(io, within(io, .fromSeconds(40)), "main", next.config());
    try secrets.dropUser(io, from);
    app.info("Rotated", .{ .user = to, .generation = (try registry.connectionStats(io, "main")).generation });
}

/// How the requests went.
const Calls = struct {
    made: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
};

/// A task of the service: 50 requests of the tenant, 10 ms apart.
fn serve(registry: *odm.Registry, io: std.Io, calls: *Calls) void {
    for (0..50) |_| {
        request(registry, io) catch {
            _ = calls.failed.fetchAdd(1, .monotonic);
        };
        _ = calls.made.fetchAdd(1, .monotonic);
        io.sleep(.fromMilliseconds(10), .awake) catch return;
    }
}

/// One request: a session of its own, as a handler takes one, and two
/// calls through it.
fn request(registry: *odm.Registry, io: std.Io) !void {
    var acme = try registry.tenant(io, "acme");
    defer acme.deinit(io);
    const notes = acme.collection(Note);
    const ctx = within(io, .fromSeconds(5));
    _ = try notes.insertOne(io, ctx, .{ .text = "hello" });
    _ = try notes.count(io, ctx, .{});
}

/// The URI and the password of a user of the connection.
const Credentials = struct {
    uri_buffer: [128]u8,
    uri_len: usize,
    password: [32]u8,

    fn config(c: *const Credentials) odm.ConnectionConfig {
        return .{ .uri = c.uri_buffer[0..c.uri_len], .password = &c.password };
    }
};

/// The secrets system of the service, as this program plays it: a client
/// of zefir-mongo, as a user who may make and drop the users of the
/// database "acme".
const Secrets = struct {
    client: mongo.Client,
    ids: bson.ObjectId.Generator,
    server: []const u8,
    gpa: std.mem.Allocator,

    /// A new user `name` of the database "acme", which it may read and
    /// write, with a random password; its credentials go to `out`.
    fn newUser(s: *Secrets, io: std.Io, name: []const u8, out: *Credentials) !void {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        out.password = std.fmt.bytesToHex(bytes, .lower);
        out.uri_len = (try std.fmt.bufPrint(&out.uri_buffer, "mongodb://{s}@{s}/acme", .{ name, s.server })).len;
        try s.command(io, .{ .createUser = name, .pwd = @as([]const u8, &out.password), .roles = .{.{ .role = "readWrite", .db = "acme" }} });
    }

    /// Drops the user `name` of "acme"; one that is not there is no error.
    fn dropUser(s: *Secrets, io: std.Io, name: []const u8) !void {
        s.command(io, .{ .dropUser = name }) catch |err| switch (err) {
            error.UserNotFound => {},
            else => return err,
        };
    }

    fn command(s: *Secrets, io: std.Io, body: anytype) !void {
        const db: mongo.Database = .init(&s.client, "acme", &s.ids);
        var d: mongo.Diagnostics = .{};
        const reply = db.runCommand(io, .of(within(io, .fromSeconds(10))), body, .{ .allocator = s.gpa, .diagnostics = &d }) catch |err| {
            // 11: UserNotFound.
            if (err == error.CommandFailed and d.server != null and d.server.?.code == 11) return error.UserNotFound;
            return err;
        };
        reply.deinit();
    }
};
