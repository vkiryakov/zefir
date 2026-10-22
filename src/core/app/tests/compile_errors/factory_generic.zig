//! Must not compile: a factory with an anytype param.
const core = @import("core");

const X = struct { n: u32 };

const Tools = struct {
    pub fn make(n: anytype) X {
        return .{ .n = n };
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .factories = &.{Tools} };
};

test {
    _ = core.App(Root);
}
