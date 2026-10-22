//! Must not compile: an overridden controller. A test answers through the
//! controller's real code; it overrides what the controller takes.
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{common.UsersModule}, .overrides = &.{common.UsersController} };
};

test {
    _ = core.App(Root);
}
