//! Must not compile: a module that imports itself.
const core = @import("core");

const A = struct {
    pub const module: core.app.Module = .{ .imports = &.{A} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{A} };
};

test {
    _ = core.App(Root);
}
