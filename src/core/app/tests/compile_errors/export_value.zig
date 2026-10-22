//! Must not compile: an exported value of the root.
const core = @import("core");
const common = @import("common.zig");

const X = struct { config: *const common.Config };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X}, .exports = &.{common.Config}, .values = &.{*const common.Config} };
};

test {
    _ = core.App(Root);
}
