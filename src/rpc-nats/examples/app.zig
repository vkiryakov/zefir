//! The users service of the guide of rpc under zefir.App, on NATS: a module
//! declares the connection to NATS, the transport of rpc on it, the
//! repository and the handler, the server and a client; App builds them in
//! the order of their dependencies, connects to NATS, starts the server,
//! and stops it all in the reverse order. A real client lives in another
//! service, with a connection of its own; here both share one.
//!
//! Settings, from the environment:
//!
//!   APP_NATS_URL   the NATS server; nats://127.0.0.1:4222 by default

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const nats = @import("nats");
const rpc = @import("rpc");
const rpc_nats = @import("rpc-nats");
const zio = @import("zio");
const api = @import("users-api");
const users = @import("users-service");

/// App, the NATS client and the transport log through std.log; this sends
/// their records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    nats: struct {
        url: []const u8 = "nats://127.0.0.1:4222",
    } = .{},
};

/// What App builds: the repository and the handler of the users service,
/// and the connection, the transport, the server and a client, which
/// factories make.
pub const AppModule = struct {
    pub const module: core.app.Module = .{
        .providers = &.{users.UserRepository},
        .handlers = &.{users.UserHandler},
        .factories = &.{ Nats, Servers },
        .values = &.{*const Config},
    };

    pub const Nats = struct {
        /// The connection to NATS: App connects it (`start`) before the
        /// beans that take it, watches it (`wait`), and drains it
        /// (`shutdown`) after them.
        pub fn natsClient(gpa: std.mem.Allocator, io: std.Io, config: *const Config) !nats.Client {
            return .init(gpa, io, .{ .servers = &.{config.nats.url}, .name = "user-service" });
        }

        /// The transport of rpc on that connection. Its start, drain and
        /// close belong to the server: App only builds and frees it.
        pub fn bus(gpa: std.mem.Allocator, client: *nats.Client) !rpc_nats.Transport {
            return .init(gpa, client, .{});
        }
    };

    pub const Servers = struct {
        /// The server of the handlers of the module, on the transport.
        pub fn rpcServer(gpa: std.mem.Allocator, transport: *rpc_nats.Transport, handlers: core.app.Handlers(AppModule)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{ .transport = transport.serverTransport() });
        }

        /// A client of the service, as another service has one.
        pub fn usersClient(gpa: std.mem.Allocator, transport: *rpc_nats.Transport) !rpc.Client {
            return .init(gpa, .{}, .{ .transport = transport.clientTransport() });
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
    // The logger outlives the runtime, so it takes `init.io`, through
    // which the tasks of the runtime may log too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app_log = logger.scoped("app");

    // One runtime for the program: App, the NATS client, the transport and
    // the server run their tasks on it.
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    // Builds the beans, connects to NATS and starts the server: it takes
    // calls once start returns. App's own deinit comes before the
    // runtime's.
    var app = try core.App(AppModule).init(init.gpa, io, .{&config}, .{});
    defer app.deinit();
    try app.start();

    const client: *rpc.Client = app.get(rpc.Client);
    var created = try client.call(io, .root, api.UserApi.createUser, .{ .name = "Ada Lovelace", .email = "ada@example.com" }, .{});
    defer created.deinit();
    switch (created.outcome) {
        .ok => |user| app_log.info("User created", .{ .id = user.id, .name = user.name }),
        .failure => |failure| app_log.warn("Call failed", .{ .code = failure.code, .app_code = failure.app_code }),
    }

    // What a signal does in a service: App asks the server to stop, shuts
    // it down, then drains the connection, all within its
    // shutdown_timeout, and wait returns.
    app.requestStop();
    try app.wait();
    app_log.info("Stopped", .{ .state = app.state() });
}
