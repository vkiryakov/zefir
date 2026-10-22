//! Must not compile: the root is no struct at all.
const core = @import("core");

test {
    _ = core.App(u32);
}
