//! Must not compile: a controller listed twice.
const core = @import("core");

const Ctl = struct {
    pub const http_routes = .{"GET /"};
};

const Root = struct {
    pub const module: core.app.Module = .{ .controllers = &.{ Ctl, Ctl } };
};

test {
    _ = core.App(Root);
}
