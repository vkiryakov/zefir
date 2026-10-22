//! Must not compile: a dependency that is a tuple of no controllers.
const core = @import("core");

const X = struct { pair: struct { u8, u8 } };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X} };
};

test {
    _ = core.App(Root);
}
