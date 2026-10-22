//! Must not compile: a value of the root that no bean takes.
const core = @import("core");
const common = @import("common.zig");

const X = struct { rec: *common.Recorder };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X}, .values = &.{ *common.Recorder, *const common.Config } };
};

test {
    _ = core.App(Root);
}
