//! Must not compile: a typo in a field of zefir.app.Module, which Zig
//! reports on the line of the module.
const core = @import("core");

const X = struct { port: u16 };

const Root = struct {
    pub const module: core.app.Module = .{ .provders = &.{X} };
};

test {
    _ = core.App(Root);
}
