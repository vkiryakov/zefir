//! Must not compile: a struct inside a struct of dependencies is an
//! ordinary dependency, and nothing provides this one.
const core = @import("core");

const Inner = struct { port: u16 };

const Report = struct {
    inner: Inner,

    pub fn init(deps: struct { inner: Inner }) Report {
        return .{ .inner = deps.inner };
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Report} };
};

test {
    _ = core.App(Root);
}
