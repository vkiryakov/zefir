//! The root of the shop: its servers, its health controller and the ready
//! objects `main` hands to App.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const rpc = zefir.rpc;
const rpc_nats = zefir.rpc_nats;
const log = zefir.log;
const Config = @import("Config.zig");
const infra = @import("infra.zig");
const users = @import("users.zig");
const orders = @import("orders.zig");

pub const AppModule = struct {
    pub const module: zefir.app.Module = .{
        .imports = &.{ infra.InfraModule, users.UsersModule, orders.OrdersModule },
        .factories = &.{Servers},
        .controllers = &.{HealthController},
        // Ready objects from main: App hands them out, but never starts or
        // destroys them.
        .values = &.{ *const Config, *const log.Logger },
    };

    pub const Servers = struct {
        /// The HTTP server is a bean of this factory. Controllers(AppModule)
        /// is a tuple of pointers to the controllers of AppModule and of
        /// every module it reaches.
        pub fn httpServer(gpa: std.mem.Allocator, config: *const Config, controllers: zefir.app.Controllers(AppModule)) !http.Server {
            return .init(gpa, .{ .controllers = controllers }, .{
                .listen = .{ .port = config.port }, // the server builds its http.native.Backend
                .prefix = "/api",
                .request_timeout = .fromSeconds(10),
            });
        }

        pub fn rpcServer(gpa: std.mem.Allocator, bus: *rpc_nats.Transport, handlers: zefir.app.Handlers(AppModule)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{ .transport = bus.serverTransport() });
        }
    };
};

pub const HealthController = struct {
    /// A built-in dependency: the state of App, read-only.
    status: *const zefir.app.Status,

    pub const http_routes = http.routes(.{ .methods = .{
        .live = http.get("/livez", .{}),
        .ready = http.get("/readyz", .{}),
    } });

    pub const Health = struct { status: []const u8 };

    pub fn live(_: *HealthController, _: *http.Context) !http.Json(Health) {
        return .{ .value = .{ .status = "ok" } };
    }

    /// 503 until App has started everything, and from the first step of its
    /// stop.
    pub fn ready(self: *HealthController, _: *http.Context) !http.Json(Health) {
        if (!self.status.isReady()) return .{ .value = .{ .status = "not ready" }, .status = 503 };
        return .{ .value = .{ .status = "ok" } };
    }
};
