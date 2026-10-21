//! Must not compile: an overridden module the root does not reach.
const core = @import("core");

const InfraModule = struct {
    pub const module: core.app.Module = .{};
};

const Root = struct {
    pub const module: core.app.Module = .{ .overrides = &.{InfraModule} };
};

test {
    _ = core.App(Root);
}
