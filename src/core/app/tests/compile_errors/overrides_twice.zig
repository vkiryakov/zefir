//! Must not compile: an override listed twice.
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{
        .imports = &.{common.UsersModule},
        .overrides = &.{ common.UserRepository, common.UserRepository },
        .values = &.{*common.UserRepository},
    };
};

test {
    _ = core.App(Root);
}
