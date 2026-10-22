//! Must not compile: a test root overrides UsersModule, whose controllers
//! its server factory takes. App builds nothing of an overridden module.
const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{
        .imports = &.{common.UsersModule},
        .overrides = &.{common.UsersModule},
        .factories = &.{Servers},
        .values = &.{*const common.Config},
    };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, config: *const common.Config, controllers: core.app.Controllers(common.UsersModule)) !common.Server {
            _ = gpa;
            _ = config;
            return .init(controllers);
        }
    };
};

test {
    _ = core.App(Root);
}
