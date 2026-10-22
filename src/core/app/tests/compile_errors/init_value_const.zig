//! Must not compile: App.init gets a const pointer for a value declared mutable.
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
    const logger: common.Logger = .{};
    var app = try core.App(Root).init(std.testing.allocator, std.testing.io, .{ @as(*const common.Recorder, &rec), &config, &logger }, .{});
    defer app.deinit();
}
