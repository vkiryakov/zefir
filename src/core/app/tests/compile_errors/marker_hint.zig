//! Must not compile: a transport of rpc without the marker: its start takes a third param.
const std = @import("std");
const core = @import("core");

const Transport = struct {
    pub fn start(_: *Transport, _: std.Io, _: u8) !void {}
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Transport} };
};

test {
    _ = core.App(Root);
}
