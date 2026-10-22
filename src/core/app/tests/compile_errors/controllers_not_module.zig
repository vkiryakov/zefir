//! Must not compile: a server factory takes the controllers of Config,
//! which is no module.
const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const AppModule = struct {
    pub const module: core.app.Module = .{ .factories = &.{Servers} };

    pub const Servers = struct {
        pub fn httpServer(gpa: std.mem.Allocator, controllers: core.app.Controllers(common.Config)) !common.Server {
            _ = gpa;
            return .init(controllers);
        }
    };
};

test {
    _ = core.App(AppModule);
}
