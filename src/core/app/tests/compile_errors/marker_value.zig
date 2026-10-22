//! Must not compile: a marker that says true.
const std = @import("std");
const core = @import("core");

const Transport = struct {
    pub const app_lifecycle = true;

    pub fn start(_: *Transport, _: std.Io, _: u8) !void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Transport} };
};

test {
    _ = core.App(Root);
}
