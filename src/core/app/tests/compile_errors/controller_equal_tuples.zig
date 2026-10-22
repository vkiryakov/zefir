//! Must not compile: two servers whose tuples are of two modules but equal.
//! Root declares no controllers, so Controllers(Root) holds what
//! Controllers(UsersModule) holds: the same controller at both servers.
const core = @import("core");
const common = @import("common.zig");

/// The second server: a type of its own, since App injects by type.
const AdminHttp = struct { server: common.Server };

const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{common.UsersModule}, .factories = &.{Servers} };

    pub const Servers = struct {
        pub fn httpServer(controllers: core.app.Controllers(common.UsersModule)) common.Server {
            return .init(controllers);
        }
        pub fn adminHttp(controllers: core.app.Controllers(Root)) AdminHttp {
            return .{ .server = .init(controllers) };
        }
    };
};

test {
    _ = core.App(Root);
}
