//! Must not compile: App.init gets one pointer instead of a tuple.
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
    var app = try core.App(Root).init(std.testing.allocator, std.testing.io, &rec, .{});
    defer app.deinit();
}
