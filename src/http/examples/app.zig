//! The health check of the todo service under zefir.App, on the backend in
//! memory: a module declares the backend, the controller and the factory
//! of the server; App builds them in the order of their dependencies,
//! starts the server, and stops it. Its setting comes from the environment
//! through confy:
//!
//!   APP_PREFIX   before the routes of the controllers, `/api` by default

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const http = @import("http");
const HealthController = @import("HealthController.zig");

/// App writes each start and stop of a bean to the log, at info: this run
/// prints warnings only.
pub const std_options: std.Options = .{ .log_level = .warn };

const Config = struct {
    prefix: []const u8 = "/api",
};

/// What App builds: the backend, the controller, and the server, which a
/// factory makes of them.
pub const AppModule = struct {
    pub const module: core.app.Module = .{
        .providers = &.{http.testing.Backend},
        .controllers = &.{HealthController},
        .factories = &.{Servers},
        .values = &.{*const Config},
    };

    pub const Servers = struct {
        /// The server: App passes the controllers of the module, and the
        /// backend and the config, by their types.
        pub fn httpServer(
            gpa: std.mem.Allocator,
            config: *const Config,
            backend: *http.testing.Backend,
            controllers: core.app.Controllers(AppModule),
        ) !http.Server {
            return .init(gpa, .{ .controllers = controllers }, .{
                .listen = .{ .backend = backend.backend() },
                .prefix = config.prefix,
            });
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

    // Builds the backend, the controller and the server, and starts the
    // server: it takes requests once start returns.
    var app = try core.App(AppModule).init(init.gpa, io, .{&config}, .{});
    defer app.deinit();
    try app.start();

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    try out.print("the app is {t}\n", .{app.state()});

    const target = try std.fmt.allocPrint(init.arena.allocator(), "{s}/health", .{config.prefix});
    var res = try app.get(http.testing.Backend).request(io, .{ .method = .GET, .target = target });
    defer res.deinit();
    try out.print("GET {s}\n→ {d} {s}\n", .{ target, res.status, res.body });

    // What a signal does in a service: App asks every server to stop, then
    // shuts each down within its shutdown_timeout, and wait returns.
    app.requestStop();
    try app.wait();
    try out.print("the app is {t}\n", .{app.state()});
    try out.flush();
}
