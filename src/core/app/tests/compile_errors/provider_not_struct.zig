//! Must not compile: a provider that is no struct.
const core = @import("core");

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{u32} };
};

test {
    _ = core.App(Root);
}
