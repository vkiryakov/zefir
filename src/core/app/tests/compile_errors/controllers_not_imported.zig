//! Must not compile: the admin's server takes the controllers of
//! AdminModule, but the root forgot to import it, so no module of the
//! application reaches AdminModule.
const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const AdminController = struct {
    pub const http_routes = .{"GET /admin/stats"};
};

const AdminModule = struct {
    pub const module: core.app.Module = .{ .controllers = &.{AdminController} };
};

const AppModule = struct {
    pub const module: core.app.Module = .{ .factories = &.{Servers}, .values = &.{*const common.Config} };

    pub const Servers = struct {
        pub fn adminHttp(gpa: std.mem.Allocator, config: *const common.Config, controllers: core.app.Controllers(AdminModule)) !common.Server {
            _ = gpa;
            _ = config;
            return .init(controllers);
        }
    };
};

test {
    _ = core.App(AppModule);
}
