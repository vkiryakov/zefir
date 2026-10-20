//! Connecting, and what the client says when the start goes wrong. It
//! connects as the user of the connection string, with the password of
//! the settings; then it tries a wrong password, a server that is not
//! there, and connection strings that the client refuses.
//!
//! Settings, from the environment:
//!
//!   APP_MONGO_URI        the server and the user, such as
//!                        mongodb://admin@127.0.0.1:27017
//!   APP_MONGO_PASSWORD   the user's password
//!
//! In tests/mongo, `zig build example-connect` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const mongo = @import("mongo");
const zio = @import("zio");

/// The client logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    mongo: struct {
        uri: []const u8,
        password: confy.Secret,
    },
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

    // The user of the URI, with the password of the settings: the client
    // authenticates every connection it opens with them.
    try connect(io, init.gpa, app, .{ .uri = config.mongo.uri, .password = config.mongo.password.expose() });
    // The same user with another password.
    try connect(io, init.gpa, app, .{ .uri = config.mongo.uri, .password = "not-the-password" });
    // A server that is not there: nothing listens on port 1.
    try connect(io, init.gpa, app, .{ .uri = "mongodb://127.0.0.1:1" });

    // Connection strings copied from elsewhere: init refuses what the
    // client cannot do, rather than skip it.
    for ([_][]const u8{
        "mongodb://127.0.0.1:27017/?retryWrites=true&w=majority",
        "mongodb://127.0.0.1:27017/?tls=true",
        "mongodb://db1.example.com:27017,db2.example.com:27017/?replicaSet=rs0",
    }) |uri| {
        var refused: mongo.Diagnostics = .{};
        var client = mongo.Client.init(init.gpa, io, .{ .uri = uri, .diagnostics = &refused }) catch |err| {
            app.warn("Refused", .{ .reason = err, .details = refused.message() });
            continue;
        };
        client.deinit();
    }
}

/// Connects a client of `options`, and logs how it went.
fn connect(io: std.Io, gpa: std.mem.Allocator, app: log.Logger, options: mongo.Client.Options) !void {
    var client: mongo.Client = try .init(gpa, io, options);
    defer client.deinit();
    const ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(10)));
    var diagnostics: mongo.Diagnostics = .{};
    client.connect(io, ctx, &diagnostics) catch |err| {
        app.warn("Cannot connect", .{
            .reason = err,
            .outcome = mongo.outcome(err),
            .details = diagnostics.message(),
            // A server that may be overloaded, or gone: a retry later may
            // find it.
            .retryable = if (diagnostics.server) |server| server.labels.contains(.retryable_error) else false,
        });
        return;
    };
    defer client.close(io);
    app.info("Connected", .{});
}
