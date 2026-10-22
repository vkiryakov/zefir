//! Must not compile: a provider with a field of a type App cannot provide.
const core = @import("core");

const Counter = struct { count: u32 };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Counter} };
};

test {
    _ = core.App(Root);
}
