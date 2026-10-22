//! Must not compile: an exported controller.
const core = @import("core");

const Ctl = struct {
    pub const http_routes = .{"GET /"};
};

const Root = struct {
    pub const module: core.app.Module = .{ .controllers = &.{Ctl}, .exports = &.{Ctl} };
};

test {
    _ = core.App(Root);
}
