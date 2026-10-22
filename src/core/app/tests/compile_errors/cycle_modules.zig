//! Must not compile: modules that import each other in a ring.
const core = @import("core");

const A = struct {
    pub const module: core.app.Module = .{ .imports = &.{B} };
};
const B = struct {
    pub const module: core.app.Module = .{ .imports = &.{C} };
};
const C = struct {
    pub const module: core.app.Module = .{ .imports = &.{A} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{A} };
};

test {
    _ = core.App(Root);
}
