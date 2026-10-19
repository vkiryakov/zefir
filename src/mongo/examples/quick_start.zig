//! The quick start of the guide: the customers of a shop, in the
//! collection "users" of the database "shop". It connects, makes the
//! e-mail of a customer unique, signs customers up, finds the adults among
//! them, gives one a birthday, lets one go, and counts the adults again.
//! Each run starts from an empty collection.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one
//!
//! In tests/mongo, `zig build example-quick_start` runs it against the
//! servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const zio = @import("zio");
const bson = mongo.bson;

/// The client logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        /// Kept out of the URI, and out of every log.
        password: ?confy.Secret = null,
    } = .{},
};

/// A customer, as the collection keeps it.
const User = struct {
    /// null: the insert makes an ObjectId.
    _id: ?bson.ObjectId = null,
    email: []const u8,
    name: []const u8,
    age: i32,
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

    // One runtime for the program, with an executor per CPU core: the
    // client and the tasks that call it run on its `io`.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // One client for the whole program, which any task may call. init
    // checks the options and does no I/O; connect opens the first
    // connection and says why when it cannot. From then on the client
    // stays where it is.
    var client: mongo.Client = try .init(init.gpa, io, .{
        .uri = config.mongo.uri,
        .password = if (config.mongo.password) |password| password.expose() else null,
    });
    defer client.deinit();
    var diagnostics: mongo.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)), &diagnostics) catch |err| {
        app.err("Cannot connect", .{ .reason = err, .details = diagnostics.message() });
        return err;
    };
    defer client.close(io);
    app.info("Connected", .{});

    // Where inserts take the _id of a document that has none: one source
    // for the application.
    var ids: bson.ObjectId.Generator = .init(io);
    const db: mongo.Database = .init(&client, "shop", &ids);
    try run(io, init.gpa, db, app);

    const stats = client.stats();
    app.info("Done", .{ .connections = stats.connections, .in_use = stats.in_use, .open_cursors = stats.open_cursors });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// The application: it sees the database, not the client.
fn run(io: std.Io, gpa: std.mem.Allocator, db: mongo.Database, app: log.Logger) !void {
    // The memory of the results, all freed at the end.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Five seconds for all of it: each call has what is left of them.
    const op: mongo.OperationContext = .of(within(io, .fromSeconds(5)));
    const users = db.collection("users");

    // Start afresh, and make the e-mail of a customer unique.
    try users.drop(io, op, .{ .allocator = arena });
    const indexes = try users.createIndexes(io, op, &.{.{ .keys = bson.literal(.{ .email = 1 }), .unique = true }}, .{ .allocator = arena });
    app.info("Index made", .{ .name = indexes[0] });

    // A customer; the insert makes the _id, and says which.
    const ann = try users.insertOne(io, op, User{ .email = "ann@example.com", .name = "Ann", .age = 30 }, .{ .allocator = arena });
    app.info("Signed up", .{ .name = "Ann", ._id = ann.inserted_id.object_id });
    // Three more, in one command.
    const more = [_]User{
        .{ .email = "bob@example.com", .name = "Bob", .age = 17 },
        .{ .email = "cleo@example.com", .name = "Cleo", .age = 41 },
        .{ .email = "dan@example.com", .name = "Dan", .age = 25 },
    };
    const signed = try users.insertMany(io, op, &more, .{ .allocator = arena });
    app.info("Signed up", .{ .inserted = signed.inserted });

    // The adults, the oldest first. The cursor brings the documents batch
    // by batch; each one is read into a User.
    var adults = try users.find(io, op, .{ .age = .{ .@"$gte" = 18 } }, .{ .allocator = arena, .sort = bson.literal(.{ .age = -1 }) });
    defer adults.deinit(io);
    while (try adults.next(io, op)) |doc| {
        const user = try bson.decode(User, arena, doc, .{});
        app.info("Adult", .{ .name = user.name, .age = user.age });
    }

    // Bob has a birthday.
    const birthday = try users.updateOne(io, op, .{ .email = "bob@example.com" }, .{ .@"$inc" = .{ .age = 1 } }, .{ .allocator = arena });
    app.info("Birthday", .{ .matched = birthday.matched, .modified = birthday.modified });
    // Dan leaves the shop.
    const left = try users.deleteOne(io, op, .{ .email = "dan@example.com" }, .{ .allocator = arena });
    app.info("Left", .{ .deleted = left.deleted });
    const count = try users.countDocuments(io, op, .{ .age = .{ .@"$gte" = 18 } }, .{ .allocator = arena });
    app.info("Adults now", .{ .count = count });
}
