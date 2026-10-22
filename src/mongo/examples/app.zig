//! The users of the shop under zefir.App: a module declares the client of
//! MongoDB and the database of the users, which factories make, the
//! generator of ObjectIds and the repository of the users; App builds them
//! in the order of their dependencies, starts the client, and closes it at
//! the stop. The program signs a user up, finds them, and stops. Each run
//! starts from an empty collection.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one
//!
//! In tests/mongo, `zig build example-app` runs it against the servers of
//! the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const zio = @import("zio");
const bson = @import("mongo-bson");

/// App and the client log through std.log; this sends their records to
/// the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        /// Kept out of the URI, and out of every log.
        password: ?confy.Secret = null,
    } = .{},
};

/// The database of the users. App gives every dependency by its type, so a
/// database has a type of its own: a second one would be a second struct
/// like this.
pub const UsersDb = struct { db: mongo.Database };

/// The users of the shop, in the collection "users" of their database.
pub const Users = struct {
    collection: mongo.Collection,

    pub const User = struct {
        /// null: the insert makes an ObjectId.
        _id: ?bson.ObjectId = null,
        email: []const u8,
        name: []const u8,
    };

    /// App passes the database it built.
    pub fn init(users_db: *UsersDb) Users {
        return .{ .collection = users_db.db.collection("users") };
    }

    /// Signs `user` up, and returns the `_id` that the insert made.
    pub fn signUp(users: *Users, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, user: User) mongo.Error!bson.ObjectId {
        const inserted = try users.collection.insertOne(io, op, user, .{ .allocator = arena });
        return inserted.inserted_id.object_id;
    }

    /// The user with `email`, or null; its strings live in `arena`.
    pub fn byEmail(users: *Users, io: std.Io, op: mongo.OperationContext, arena: std.mem.Allocator, email: []const u8) (mongo.Error || bson.DecodeError)!?User {
        const doc = try users.collection.findOne(io, op, .{ .email = email }, .{ .allocator = arena }) orelse return null;
        return try bson.decode(User, arena, doc.raw(), .{});
    }
};

/// What App builds: the generator of ObjectIds, whose init takes only io,
/// the users, and the client and the database, which factories make.
pub const AppModule = struct {
    pub const module: core.app.Module = .{
        .providers = &.{ bson.ObjectId.Generator, Users },
        .factories = &.{Mongo},
        .values = &.{*const Config},
    };

    pub const Mongo = struct {
        /// The client: App starts it (`start`, a connect) before the beans
        /// that take it, and closes it (`shutdown`) after them.
        pub fn mongoClient(gpa: std.mem.Allocator, io: std.Io, config: *const Config) !mongo.Client {
            return .init(gpa, io, .{
                .uri = config.mongo.uri,
                .password = if (config.mongo.password) |password| password.expose() else null,
            });
        }

        /// The database "shop", on the client App built.
        pub fn usersDb(client: *mongo.Client, ids: *bson.ObjectId.Generator) UsersDb {
            return .{ .db = .init(client, "shop", ids) };
        }
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
    const app_log = logger.scoped("app");

    // One runtime for the program: App, the client and their tasks run on
    // its `io`.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // Builds the beans, then starts the client: it is connected once start
    // returns. App's own deinit comes before the runtime's.
    var app = try core.App(AppModule).init(init.gpa, io, .{&config}, .{});
    defer app.deinit();
    try app.start();

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const op: mongo.OperationContext = .of(core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(5))));
    const users: *Users = app.get(Users);
    // Start afresh.
    try users.collection.drop(io, op, .{ .allocator = arena });
    const id = try users.signUp(io, op, arena, .{ .email = "ann@example.com", .name = "Ann" });
    app_log.info("Signed up", .{ .name = "Ann", ._id = id });
    const ann = (try users.byEmail(io, op, arena, "ann@example.com")) orelse return error.UserNotFound;
    app_log.info("Found", .{ .name = ann.name, .email = ann.email });

    // What a signal does in a service: App closes the client within its
    // shutdown_timeout, and wait returns.
    app.requestStop();
    try app.wait();
    app_log.info("Stopped", .{ .state = app.state() });
}
