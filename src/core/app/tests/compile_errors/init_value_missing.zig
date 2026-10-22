//! Must not compile: App.init misses a declared value.
const std = @import("std");
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{
        .providers = &.{common.Uses},
        .values = &.{ *common.Recorder, *const common.Config, *const common.Logger },
    };
};

test {
    var rec: common.Recorder = .{};
    const config: common.Config = .{};
    var app = try core.App(Root).init(std.testing.allocator, std.testing.io, .{ &rec, &config }, .{});
    defer app.deinit();
}
