//! Must not compile: a factory that returns nothing.
const core = @import("core");

const Tools = struct {
    pub fn setup() void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .factories = &.{Tools} };
};

test {
    _ = core.App(Root);
}
