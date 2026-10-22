//! Must not compile: get of the type of a value of the root. The value is
//! the caller's already; get gives beans only.
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{common.Uses}, .values = &.{ *common.Recorder, *const common.Config, *const common.Logger } };
};

test {
    var app: core.App(Root) = undefined;
    _ = app.get(common.Config);
}
