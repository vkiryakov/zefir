//! Must not compile: one module imported twice by the same module.
const core = @import("core");

const A = struct {
    pub const module: core.app.Module = .{};
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{ A, A } };
};

test {
    _ = core.App(Root);
}
