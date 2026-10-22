//! Must not compile: a server factory takes the controllers of a module
//! its module does not reach.
const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const Reports = struct {
    pub const module: core.app.Module = .{ .factories = &.{Servers} };

    pub const Servers = struct {
        pub fn http(gpa: std.mem.Allocator, config: *const common.Config, controllers: core.app.Controllers(common.UsersModule)) !common.Server {
            _ = gpa;
            _ = config;
            return .init(controllers);
        }
    };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{ common.UsersModule, Reports }, .values = &.{*const common.Config} };
};

test {
    _ = core.App(Root);
}
