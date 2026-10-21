//! Must not compile: a bean with the shutdown of rpc and http before App, without a deadline.
const std = @import("std");
const core = @import("core");

const Job = struct {
    pub fn shutdown(_: *Job, _: std.Io) !void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Job} };
};

test {
    _ = core.App(Root);
}
