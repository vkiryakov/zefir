//! Must not compile: two rpc servers that both take the handler of
//! OrdersModule: Handlers(AppModule) reaches OrdersModule.
const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const OrdersHandler = struct {
    pub const rpc_handler = .{ .api = "orders.v1" };
};

const OrdersModule = struct {
    pub const module: core.app.Module = .{ .handlers = &.{OrdersHandler} };
};

/// The internal rpc server: a type of its own, since App injects by type.
const InternalRpc = struct { server: common.Server };

const AppModule = struct {
    pub const module: core.app.Module = .{
        .imports = &.{OrdersModule},
        .factories = &.{Servers},
        .values = &.{*const common.Config},
    };

    pub const Servers = struct {
        pub fn rpcServer(gpa: std.mem.Allocator, config: *const common.Config, handlers: core.app.Handlers(AppModule)) !common.Server {
            _ = gpa;
            _ = config;
            return .init(handlers);
        }
        pub fn internalRpc(gpa: std.mem.Allocator, config: *const common.Config, handlers: core.app.Handlers(OrdersModule)) !InternalRpc {
            _ = gpa;
            _ = config;
            return .{ .server = .init(handlers) };
        }
    };
};

test {
    _ = core.App(AppModule);
}
