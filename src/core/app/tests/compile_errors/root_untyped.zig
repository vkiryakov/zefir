//! Must not compile: the root's module is an anonymous literal, not a
//! zefir.app.Module.
const core = @import("core");

const X = struct { port: u16 };

const Root = struct {
    pub const module = .{ .providers = &.{X} };
};

test {
    _ = core.App(Root);
}
