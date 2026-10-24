//! The errors of the collection API, against mongod: what each says, and
//! whether the call is safe to make again. The shop's customers have
//! unique e-mails, and some of them sign up twice. Each run starts from an
//! empty collection.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server; mongodb://127.0.0.1:27017 by default
//!   APP_MONGO_PASSWORD   the password of the user that the URI names, if
//!                        it names one
//!
//! In tests/mongo, `zig build example-errors` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const zio = @import("zio");
const bson = @import("mongo-bson");

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8 = "mongodb://127.0.0.1:27017",
        password: ?confy.Secret = null,
    } = .{},
};

const User = struct {
    _id: ?bson.ObjectId = null,
    email: []const u8,
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

    var client: mongo.Client = try .init(init.gpa, io, .{
        .uri = config.mongo.uri,
        .password = if (config.mongo.password) |password| password.expose() else null,
    });
    defer client.deinit();
    const ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(10)));
    try client.connect(io, ctx, null);
    defer client.close(io);
    var ids: bson.ObjectId.Generator = .init(io);
    const db: mongo.Database = .init(&client, "shop", &ids);

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const op: mongo.OperationContext = .of(ctx);
    const users = db.collection("users");
    try users.drop(io, op, .{ .allocator = arena });
    _ = try users.createIndexes(io, op, &.{.{ .keys = bson.literal(.{ .email = 1 }), .unique = true }}, .{ .allocator = arena });
    _ = try users.insertOne(io, op, User{ .email = "ann@example.com" }, .{ .allocator = arena });

    var d: mongo.Diagnostics = .{};

    // WriteFailed: the write ran to its end, and the server refused a
    // document. Its error is in the diagnostics: 11000, a duplicate key.
    if (users.insertOne(io, op, User{ .email = "ann@example.com" }, .{ .allocator = arena, .diagnostics = &d })) |_| {
        app.info("Signed up again", .{});
    } else |err| report(app, "A second sign-up", err, &d);

    // An unordered insertMany goes on past a refused document: partial
    // holds what was written and which documents were refused.
    const newcomers = [_]User{
        .{ .email = "bob@example.com" },
        .{ .email = "ann@example.com" },
        .{ .email = "cleo@example.com" },
        .{ .email = "bob@example.com" },
        .{ .email = "dan@example.com" },
    };
    var partial: mongo.Collection.InsertManyResult = .{};
    if (users.insertMany(io, op, &newcomers, .{ .allocator = arena, .ordered = false, .partial = &partial, .diagnostics = &d })) |_| {
        app.info("All signed up", .{});
    } else |err| {
        report(app, "An import", err, &d);
        app.info("Imported", .{ .inserted = partial.inserted, .answered = partial.answered });
        for (partial.write_errors) |refused| app.info("Refused", .{ .index = refused.index, .code = refused.code });
    }

    // CommandFailed: the server answered ok: 0. The whole reply can come
    // too, for what the diagnostics do not keep.
    var reply: ?bson.OwnedDocument = null;
    if (db.runCommand(io, op, .{ .frobnicate = 1 }, .{ .allocator = arena, .diagnostics = &d, .failure_reply = &reply })) |_| {
        app.info("Frobnicated", .{});
    } else |err| {
        report(app, "A command", err, &d);
        app.info("Its reply", .{ .code_name = (try reply.?.raw().get("codeName")).?.string });
    }

    // InvalidArgument: the client stops a call against its rules, before
    // anything goes out. An update starts with an update operator, such as
    // $set; a document without one replaces, with replaceOne.
    if (users.updateOne(io, op, .{ .email = "ann@example.com" }, .{ .email = "ann@example.org" }, .{ .allocator = arena, .diagnostics = &d })) |_| {
        app.info("Updated", .{});
    } else |err| report(app, "An update", err, &d);
    if (db.collection("users$").countDocuments(io, op, .{}, .{ .allocator = arena, .diagnostics = &d })) |_| {
        app.info("Counted", .{});
    } else |err| report(app, "A count", err, &d);
}

/// Logs `err` of `what`, its details, and whether the call may have run.
fn report(app: log.Logger, comptime what: []const u8, err: mongo.Error, d: *const mongo.Diagnostics) void {
    app.warn(what ++ " failed", .{
        .reason = err,
        .outcome = mongo.outcome(err),
        .code = if (d.server) |server| server.code else 0,
        .details = d.message(),
    });
}
