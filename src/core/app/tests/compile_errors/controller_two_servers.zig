//! Must not compile: the layout "before" of design §5.8. The public server
//! takes Controllers(AppModule), which reaches AdminModule: the admin's
//! controller would be served on the public port as well.
const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const AdminController = struct {
    pub const http_routes = .{"GET /admin/stats"};
};

const AdminModule = struct {
    pub const module: core.app.Module = .{ .controllers = &.{AdminController} };
};

/// The admin's server: a type of its own, since App injects by type.
const AdminHttp = struct { server: common.Server };

const HealthController = struct {
    pub const http_routes = .{"GET /readyz"};
};

const AppModule = struct {
    pub const module: core.app.Module = .{
        .imports = &.{ common.UsersModule, AdminModule },
        .factories = &.{Servers},
        .controllers = &.{HealthController},
        .values = &.{*const common.Config},
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, config: *const common.Config, controllers: core.app.Controllers(AppModule)) !common.Server {
            _ = gpa;
            _ = config;
            return .init(controllers);
        }
        pub fn adminHttp(gpa: std.mem.Allocator, config: *const common.Config, controllers: core.app.Controllers(AdminModule)) !AdminHttp {
            _ = gpa;
            _ = config;
            return .{ .server = .init(controllers) };
        }
    };
};

test {
    _ = core.App(AppModule);
}
