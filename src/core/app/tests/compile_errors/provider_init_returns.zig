//! Must not compile: a provider whose init returns a pointer.
const core = @import("core");

const X = struct {
    n: u32,

    pub fn init() *X {
        return undefined;
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X} };
};

test {
    _ = core.App(Root);
}
