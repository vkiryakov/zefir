//! Must not compile: a bean whose start takes no io.
const std = @import("std");
const core = @import("core");

const Job = struct {
    pub fn start(_: *Job) !void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Job} };
};

test {
    _ = core.App(Root);
}
