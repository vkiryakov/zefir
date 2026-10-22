//! Must not compile: a bean that takes App's status mutable.
const core = @import("core");

const X = struct { status: *core.app.Status };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X} };
};

test {
    _ = core.App(Root);
}
