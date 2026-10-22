//! Must not compile: a bean whose deinit takes it by value, as log.Logger does.
const std = @import("std");
const core = @import("core");

const Job = struct {
    pub fn deinit(_: Job) void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Job} };
};

test {
    _ = core.App(Root);
}
