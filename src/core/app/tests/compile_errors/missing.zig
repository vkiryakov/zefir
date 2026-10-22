//! Must not compile: a dependency nothing the module sees provides.
const core = @import("core");

const Cache = struct { hits: u32 };
const X = struct { cache: *Cache };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{X} };
};

test {
    _ = core.App(Root);
}
