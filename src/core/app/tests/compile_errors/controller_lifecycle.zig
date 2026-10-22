//! Must not compile: a controller with a method of the bean contract.
const core = @import("core");

const Ctl = struct {
    pub const http_routes = .{"GET /"};

    pub fn deinit(_: *Ctl) void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .controllers = &.{Ctl} };
};

test {
    _ = core.App(Root);
}
