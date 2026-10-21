//! Must not compile: an exported module.
const core = @import("core");

const A = struct {
    pub const module: core.app.Module = .{};
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{A}, .exports = &.{A} };
};

test {
    _ = core.App(Root);
}
