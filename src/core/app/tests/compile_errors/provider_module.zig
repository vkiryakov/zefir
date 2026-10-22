//! Must not compile: a module listed as a provider.
const core = @import("core");

const A = struct {
    pub const module: core.app.Module = .{};
};
const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{A} };
};

test {
    _ = core.App(Root);
}
