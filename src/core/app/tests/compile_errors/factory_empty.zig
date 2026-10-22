//! Must not compile: a factories struct without a pub fn.
const core = @import("core");

const Tools = struct {
    fn helper() void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .factories = &.{Tools} };
};

test {
    _ = core.App(Root);
}
