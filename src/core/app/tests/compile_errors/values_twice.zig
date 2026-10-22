//! Must not compile: two values of one type.
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{ .values = &.{ *const common.Config, *common.Config } };
};

test {
    _ = core.App(Root);
}
