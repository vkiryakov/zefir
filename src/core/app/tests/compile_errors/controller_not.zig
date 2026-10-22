//! Must not compile: a controller that declares no routes.
const core = @import("core");

const Plain = struct { port: u16 = 0 };

const Root = struct {
    pub const module: core.app.Module = .{ .controllers = &.{Plain} };
};

test {
    _ = core.App(Root);
}
