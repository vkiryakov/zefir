//! The users service of the guide of rpc, on NATS: the same handler and
//! repository, served by `rpc.Server` on `rpc_nats.Transport`, and a client
//! that calls it through the broker. A real client lives in another
//! service, with a connection of its own; here both share one.
//!
//! Settings, from the environment:
//!
//!   APP_NATS_URL        the NATS server; nats://127.0.0.1:4222 by default
//!   APP_SERVE_SECONDS   how long it goes on serving after its calls, for
//!                       the NATS CLI; 0 by default

const std = @import("std");
const confy = @import("confy");
const log = @import("log");
const nats = @import("nats");
const rpc = @import("rpc");
const rpc_nats = @import("rpc-nats");
const zio = @import("zio");
const api = @import("users-api");
const users = @import("users-service");

/// The NATS client and the transport log through std.log; this sends their
/// records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    nats: struct {
        url: []const u8 = "nats://127.0.0.1:4222",
    } = .{},
    serve_seconds: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    // The logger outlives the runtime, so it takes `init.io`, through
    // which the tasks of the runtime may log too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    // One runtime for the whole program: the NATS client, the transport and
    // the server run their tasks on it.
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const gpa = init.gpa;

    // The connection to NATS, which the program owns, and the transport on
    // it, which carries the calls of the server and of the clients alike.
    // Each stays where it is from here on.
    var nc: nats.Client = try .init(gpa, io, .{ .servers = &.{config.nats.url}, .name = "user-service" });
    defer nc.deinit();
    try nc.connect();
    var bus: rpc_nats.Transport = try .init(gpa, &nc, .{});
    defer bus.deinit(io); // after the server's deinit, before the connection's

    var repo: users.UserRepository = .init(gpa);
    defer repo.deinit();
    var handler: users.UserHandler = .{ .repo = &repo };
    var server = try rpc.Server.init(gpa, .{
        .handlers = .{&handler},
    }, .{
        .transport = bus.serverTransport(),
    });
    defer server.deinit(io);
    // Subscribes to users.v1.createUser and the other methods; returns once
    // the broker has the subscriptions.
    try server.start(io);
    app.info("Serving", .{ .service = "users", .version = 1 });

    var client = try rpc.Client.init(gpa, .{}, .{ .transport = bus.clientTransport() });
    defer client.deinit();

    var created = try client.call(io, .root, api.UserApi.createUser, .{ .name = "Ada Lovelace", .email = "ada@example.com" }, .{});
    defer created.deinit();
    switch (created.outcome) {
        .ok => |user| app.info("User created", .{ .id = user.id, .name = user.name }),
        .failure => |failure| app.warn("Call failed", .{ .code = failure.code, .app_code = failure.app_code }),
    }
    var missing = try client.call(io, .root, api.UserApi.getUser, .{ .id = 42 }, .{});
    defer missing.deinit();
    switch (missing.outcome) {
        .ok => |user| app.info("User found", .{ .id = user.id, .name = user.name }),
        .failure => |failure| app.warn("Call failed", .{ .code = failure.code, .app_code = failure.app_code }),
    }
    // A method that no server serves: on NATS no one takes the request.
    var other = client.call(io, .root, OtherApi.ping, .{}, .{});
    if (other) |*result| result.deinit() else |err| app.warn("Call not taken", .{ .route = "billing.v1.ping", .reason = err });

    if (config.serve_seconds > 0) {
        app.info("Serving on", .{ .seconds = config.serve_seconds });
        try io.sleep(.fromSeconds(config.serve_seconds), .awake);
    }
}

/// A contract that nobody serves here.
const OtherApi = rpc.Contract(.{
    .name = "billing",
    .version = 1,
    .methods = .{ .ping = rpc.method(struct {}, void) },
});
