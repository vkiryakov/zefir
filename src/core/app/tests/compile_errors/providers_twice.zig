//! Must not compile: a provider listed twice.
const core = @import("core");
const common = @import("common.zig");

const X = struct { rec: *common.Recorder };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{ X, X }, .values = &.{*common.Recorder} };
};

test {
    _ = core.App(Root);
}
