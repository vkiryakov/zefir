//! Must not compile: a handler that declares no rpc_handler.
const core = @import("core");

const Plain = struct { port: u16 = 0 };

const Root = struct {
    pub const module: core.app.Module = .{ .handlers = &.{Plain} };
};

test {
    _ = core.App(Root);
}
