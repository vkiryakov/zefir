//! Must not compile: a pub constant in a factories struct.
const core = @import("core");

const X = struct { n: u32 };

const Tools = struct {
    pub const retries = 3;

    pub fn x() X {
        return .{ .n = retries };
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .factories = &.{Tools} };
};

test {
    _ = core.App(Root);
}
