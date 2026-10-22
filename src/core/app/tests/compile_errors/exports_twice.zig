//! Must not compile: a bean exported twice.
const core = @import("core");

const X = struct { n: u32 = 0 };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X}, .exports = &.{ X, X } };
};

test {
    _ = core.App(Root);
}
