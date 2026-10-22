//! Must not compile: a provider that takes itself.
const core = @import("core");

const X = struct { next: *X };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X} };
};

test {
    _ = core.App(Root);
}
