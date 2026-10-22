//! The root module of the shop: the two servers and what they take, and
//! the ready objects that `main` hands to App.

const std = @import("std");
const zefir = @import("zefir");
const http = zefir.http;
const rpc = zefir.rpc;
const log = zefir.log;
const Config = @import("Config.zig");
const users = @import("users.zig");
const orders = @import("orders.zig");
const HealthController = @import("health.zig").HealthController;

pub const AppModule = struct {
    pub const module: zefir.app.Module = .{
        .imports = &.{ users.UsersModule, orders.OrdersModule },
        .providers = &.{ShopErrors},
        .factories = &.{ Bus, Servers },
        .controllers = &.{HealthController},
        // Ready objects from main: App hands them out, and never starts or
        // destroys them.
        .values = &.{ *const Config, *const log.Logger },
    };

    /// Each pub fn of a factories struct is a bean: its params are its
    /// dependencies, its return type is the bean's type.
    pub const Bus = struct {
        /// The transport of rpc, in memory, so that the shop runs alone.
        /// Its start and stop belong to the rpc server: App only builds it
        /// and frees it.
        pub fn memory(gpa: std.mem.Allocator) !rpc.testing.MemoryTransport {
            return .init(gpa, .{});
        }
    };

    pub const Servers = struct {
        /// Controllers(AppModule) is a tuple of pointers to the controllers
        /// of AppModule and of every module it imports.
        pub fn httpServer(
            gpa: std.mem.Allocator,
            config: *const Config,
            errors: *ShopErrors,
            controllers: zefir.app.Controllers(AppModule),
        ) !http.Server {
            return .init(gpa, .{ .controllers = controllers, .error_handler = errors }, .{
                .listen = .{ .port = config.port }, // the server makes its own http.native.Backend
                .prefix = "/api",
                .request_timeout = .fromSeconds(10),
            });
        }

        /// Handlers(AppModule), the handlers of AppModule and of every module
        /// it imports: here UsersHandler.
        pub fn rpcServer(gpa: std.mem.Allocator, bus: *rpc.testing.MemoryTransport, handlers: zefir.app.Handlers(AppModule)) !rpc.Server {
            return .init(gpa, .{ .handlers = handlers }, .{ .transport = bus.serverTransport() });
        }
    };
};

/// What the errors of the shop answer over HTTP: 404 for a user or an order
/// that is not there, the statuses of zefir-http for its own errors. A
/// provider without fields, which the factory of the server takes.
pub const ShopErrors = struct {
    pub fn mapError(err: anyerror) http.ErrorResponse(http.Problem) {
        return switch (err) {
            error.UserNotFound => notFound("users.not_found", "User not found"),
            error.OrderNotFound => notFound("orders.not_found", "Order not found"),
            else => .fallback(err, .{ .title = http.defaultTitle(err), .status = http.defaultStatus(err), .code = http.defaultCode(err) }),
        };
    }

    fn notFound(code: []const u8, title: []const u8) http.ErrorResponse(http.Problem) {
        return .{ .status = 404, .body = .{ .title = title, .status = 404, .code = code } };
    }
};
