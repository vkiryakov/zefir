//! Must not compile: a bean that takes mutable a value declared const.
const core = @import("core");
const common = @import("common.zig");

const X = struct { config: *common.Config };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X}, .values = &.{*const common.Config} };
};

test {
    _ = core.App(Root);
}
