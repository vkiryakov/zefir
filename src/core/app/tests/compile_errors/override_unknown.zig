//! Must not compile: an override that is neither a module nor a bean.
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{ .overrides = &.{common.Config} };
};

test {
    _ = core.App(Root);
}
