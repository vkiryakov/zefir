//! Must not compile: a bean whose requestStop can fail.
const std = @import("std");
const core = @import("core");

const Job = struct {
    pub fn requestStop(_: *Job, _: std.Io) !void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Job} };
};

test {
    _ = core.App(Root);
}
