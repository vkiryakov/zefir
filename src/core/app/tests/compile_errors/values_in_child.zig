//! Must not compile: values declared by a module that is not the root.
const core = @import("core");
const common = @import("common.zig");

const A = struct {
    pub const module: core.app.Module = .{ .values = &.{*const common.Config} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{A} };
};

test {
    _ = core.App(Root);
}
