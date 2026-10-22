//! Must not compile: a root that overrides itself.
const core = @import("core");

const Root = struct {
    pub const module: core.app.Module = .{ .overrides = &.{Root} };
};

test {
    _ = core.App(Root);
}
