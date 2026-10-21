//! Must not compile: an import that is no module.
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{common.Config} };
};

test {
    _ = core.App(Root);
}
