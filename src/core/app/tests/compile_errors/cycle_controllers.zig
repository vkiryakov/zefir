//! Must not compile: a server that takes the controllers, one of which
//! takes the server.
const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const Ctl = struct {
    server: *common.Server,

    pub const http_routes = .{"GET /"};
};

const Root = struct {
    pub const module: core.app.Module = .{ .controllers = &.{Ctl}, .factories = &.{Servers}, .values = &.{*const common.Config} };

    pub const Servers = struct {
        pub fn http(gpa: std.mem.Allocator, config: *const common.Config, controllers: core.app.Controllers(Root)) !common.Server {
            _ = gpa;
            _ = config;
            return .init(controllers);
        }
    };
};

test {
    _ = core.App(Root);
}
