//! Must not compile: a value declared as a type, not as a pointer.
const core = @import("core");

const Root = struct {
    pub const module: core.app.Module = .{ .values = &.{u16} };
};

test {
    _ = core.App(Root);
}
