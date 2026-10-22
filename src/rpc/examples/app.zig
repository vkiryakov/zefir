//! The users service under zefir.App, on the memory transport: a module
//! declares the repository, the handler, the transport, the server and a
//! client; App builds them in the order of their dependencies, starts the
//! server, and stops it. Its setting comes from the environment through
//! confy:
//!
//!   APP_SHUTDOWN_GRACE_MS   how long the calls in flight may still run
//!                           after the stop begins; 1000 by default

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const rpc = @import("rpc");
const api = @import("users-api");
const UserHandler = @import("UserHandler.zig");
const UserRepository = @import("UserRepository.zig");

/// App writes the start and the stop of every bean to std.log, with the
/// scope zefir_app; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    shutdown: struct {
        /// How long the calls in flight may still run after the stop begins.
        grace_ms: u32 = 1000,
    } = .{},
};

/// What App builds: the repository, the handler, and the transport, the
/// server and a client, which factories make.
pub const AppModule = struct {
    pub const module: core.app.Module = .{
        .providers = &.{UserRepository},
        .handlers = &.{UserHandler},
        .factories = &.{ Bus, Servers },
        .values = &.{*const Config},
    };

    pub const Bus = struct {
        /// The transport, a bean of its own: the server takes its server
        /// side, the client its client side. App builds and frees it; its
        /// start and its close belong to the server.
        pub fn memory(gpa: std.mem.Allocator) !rpc.testing.MemoryTransport {
            return .init(gpa, .{});
        }
    };

    pub const Servers = struct {
        /// The server: App passes the handlers of the module, and the
        /// config and the transport, by their types.
        pub fn rpcServer(
            gpa: std.mem.Allocator,
            config: *const Config,
            bus: *rpc.testing.MemoryTransport,
            handlers: core.app.Handlers(AppModule),
        ) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{
                .transport = bus.serverTransport(),
                .shutdown_grace = .fromMilliseconds(config.shutdown.grace_ms),
            });
        }

        /// A client of the service, as another service has one.
        pub fn usersClient(gpa: std.mem.Allocator, bus: *rpc.testing.MemoryTransport) !rpc.Client {
            return .init(gpa, .{}, .{ .transport = bus.clientTransport() });
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
    const io = init.io;
    const logger: log.Logger = try .init(init.gpa, io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app_log = logger.scoped("app");

    // Builds the beans, then starts the server: it takes calls once start
    // returns.
    var app = try core.App(AppModule).init(init.gpa, io, .{&config}, .{});
    defer app.deinit();
    try app.start();
    app_log.info("Serving", .{ .state = app.state() });

    const client: *rpc.Client = app.get(rpc.Client);
    var created = try client.call(io, .root, api.UserApi.createUser, .{ .name = "Ada Lovelace", .email = "ada@example.com" }, .{});
    defer created.deinit();
    switch (created.outcome) {
        .ok => |user| app_log.info("User created", .{ .id = user.id, .name = user.name }),
        .failure => |failure| app_log.warn("Call failed", .{ .code = failure.code, .app_code = failure.app_code }),
    }

    // What a signal does in a service: App asks the server to stop, then
    // shuts it down within its shutdown_timeout, and wait returns.
    app_log.info("Stopping", .{ .grace_ms = config.shutdown.grace_ms });
    app.requestStop();
    try app.wait();
    app_log.info("Stopped", .{ .state = app.state() });
}
