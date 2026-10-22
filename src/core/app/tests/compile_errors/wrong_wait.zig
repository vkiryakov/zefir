//! Must not compile: a bean whose wait returns a number.
const std = @import("std");
const core = @import("core");

const Job = struct {
    pub fn wait(_: *Job, _: std.Io) u32 {
        return 0;
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Job} };
};

test {
    _ = core.App(Root);
}
