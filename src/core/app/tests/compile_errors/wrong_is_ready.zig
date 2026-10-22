//! Must not compile: a bean whose isReady can fail.
const std = @import("std");
const core = @import("core");

const Job = struct {
    pub fn isReady(_: *const Job) !bool {
        return true;
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Job} };
};

test {
    _ = core.App(Root);
}
