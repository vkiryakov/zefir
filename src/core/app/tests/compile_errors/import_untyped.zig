//! Must not compile: an import whose module is an anonymous literal.
const core = @import("core");

const X = struct { port: u16 };

const A = struct {
    pub const module = .{ .providers = &.{X} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{A} };
};

test {
    _ = core.App(Root);
}
