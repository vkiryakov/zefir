//! Must not compile: three providers that take each other in a ring.
const core = @import("core");

const X = struct { y: *Y };
const Y = struct { z: *Z };
const Z = struct { x: *X };

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{ X, Y, Z } };
};

test {
    _ = core.App(Root);
}
