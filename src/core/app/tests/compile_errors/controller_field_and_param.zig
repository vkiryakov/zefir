//! Must not compile: a provider that holds the controllers of UsersModule
//! in a field, and a server factory that takes them as a param.
const core = @import("core");
const common = @import("common.zig");

const Panel = struct { controllers: core.app.Controllers(common.UsersModule) };

const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{common.UsersModule}, .providers = &.{Panel}, .factories = &.{Servers} };

    pub const Servers = struct {
        pub fn httpServer(controllers: core.app.Controllers(Root)) common.Server {
            return .init(controllers);
        }
    };
};

test {
    _ = core.App(Root);
}
