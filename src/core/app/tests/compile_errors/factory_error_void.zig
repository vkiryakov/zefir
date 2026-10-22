//! Must not compile: a factory that returns an error union of void.
const core = @import("core");

const Tools = struct {
    pub fn connect() error{Down}!void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .factories = &.{Tools} };
};

test {
    _ = core.App(Root);
}
