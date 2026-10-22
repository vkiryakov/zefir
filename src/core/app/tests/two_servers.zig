//! Two servers of one kind in one App, laid out as design §5.8 says: each
//! server takes the controllers (or handlers) of a module of its own, and
//! no module of one server reaches the other's. The second server of a
//! kind is a wrapper type, since App injects by type (design §5.5).
const std = @import("std");
const zapp = @import("../../app.zig");
const mocks = @import("mocks.zig");
const shop = @import("shop.zig");

const http = mocks.http;
const rpc = mocks.rpc;
const Recorder = mocks.Recorder;

/// Everything open on the public port.
pub const PublicModule = struct {
    pub const module: zapp.Module = .{
        .imports = &.{ shop.UsersModule, shop.OrdersModule },
        // The health controller of the shop's root moves here.
        .controllers = &.{shop.HealthController},
    };
};

pub const AdminModule = struct {
    pub const module: zapp.Module = .{
        // ShopDb only: AdminModule reaches neither UsersModule nor OrdersModule.
        .imports = &.{shop.InfraModule},
        // A health of its own: the type HealthController is the public server's.
        .controllers = &.{ AdminController, AdminHealthController },
    };
};

pub const AdminController = struct {
    db: *shop.ShopDb,

    pub const http_routes = .{"GET /admin/stats"};
};

pub const AdminHealthController = struct {
    status: *const zapp.Status,

    pub const http_routes = .{"GET /admin/readyz"};
};

/// The admin's HTTP server: a type of its own, which passes the lifecycle on.
pub const AdminHttp = struct {
    server: http.Server,

    pub fn start(a: *AdminHttp, io: std.Io) !void {
        return a.server.start(io);
    }
    pub fn wait(a: *AdminHttp, io: std.Io) !void {
        return a.server.wait(io);
    }
    pub fn requestStop(a: *AdminHttp, io: std.Io) void {
        a.server.requestStop(io);
    }
    pub fn shutdown(a: *AdminHttp, io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
        return a.server.shutdown(io, deadline);
    }
    pub fn isReady(a: *const AdminHttp) bool {
        return a.server.isReady();
    }
    pub fn deinit(a: *AdminHttp) void {
        a.server.deinit();
    }
};

pub const AppModule = struct {
    pub const module: zapp.Module = .{
        .imports = &.{ shop.InfraModule, PublicModule, AdminModule },
        .factories = &.{Servers},
        .values = &.{ *Recorder, *const mocks.Config, *const mocks.Logger },
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, rec: *Recorder, controllers: zapp.Controllers(PublicModule)) !http.Server {
            return .init(gpa, rec, .{ .controllers = controllers });
        }
        pub fn adminHttp(gpa: std.mem.Allocator, rec: *Recorder, controllers: zapp.Controllers(AdminModule)) !AdminHttp {
            return .{ .server = try .init(gpa, rec, .{ .controllers = controllers }) };
        }
        /// One rpc server: the handlers of every module are its own.
        pub fn rpcServer(gpa: std.mem.Allocator, rec: *Recorder, transport: *mocks.rpc_nats.Transport, handlers: zapp.Handlers(AppModule)) !rpc.Server {
            _ = transport;
            return .init(gpa, rec, .{ .handlers = handlers });
        }
    };
};

/// The statistics of the shop over an internal rpc server.
pub const InternalModule = struct {
    pub const module: zapp.Module = .{
        // AnalyticsDb only: InternalModule does not reach OrdersModule.
        .imports = &.{shop.InfraModule},
        .handlers = &.{StatsHandler},
    };
};

pub const StatsHandler = struct {
    analytics: *shop.AnalyticsDb,

    pub const rpc_handler = .{ .api = "stats.v1" };
};

/// The internal rpc server: a type of its own, which passes the lifecycle on.
pub const InternalRpc = struct {
    server: rpc.Server,

    pub fn start(r: *InternalRpc, io: std.Io) !void {
        return r.server.start(io);
    }
    pub fn wait(r: *InternalRpc, io: std.Io) !void {
        return r.server.wait(io);
    }
    pub fn requestStop(r: *InternalRpc, io: std.Io) void {
        r.server.requestStop(io);
    }
    pub fn shutdown(r: *InternalRpc, io: std.Io, deadline: std.Io.Clock.Timestamp) !void {
        return r.server.shutdown(io, deadline);
    }
    pub fn isReady(r: *const InternalRpc) bool {
        return r.server.isReady();
    }
    pub fn deinit(r: *InternalRpc) void {
        r.server.deinit();
    }
};

/// Two rpc servers: the orders' and the internal one, each with the
/// handlers of its own module.
pub const RpcModule = struct {
    pub const module: zapp.Module = .{
        .imports = &.{ shop.InfraModule, shop.OrdersModule, InternalModule },
        .factories = &.{RpcServers},
        .values = &.{ *Recorder, *const mocks.Config, *const mocks.Logger },
    };

    pub const RpcServers = struct {
        pub fn rpcServer(gpa: std.mem.Allocator, rec: *Recorder, transport: *mocks.rpc_nats.Transport, handlers: zapp.Handlers(shop.OrdersModule)) !rpc.Server {
            _ = transport;
            return .init(gpa, rec, .{ .handlers = handlers });
        }
        pub fn internalRpc(gpa: std.mem.Allocator, rec: *Recorder, handlers: zapp.Handlers(InternalModule)) !InternalRpc {
            return .{ .server = try .init(gpa, rec, .{ .handlers = handlers }) };
        }
    };
};
