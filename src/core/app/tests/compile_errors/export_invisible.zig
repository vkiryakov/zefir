//! Must not compile: an export of a bean the module does not see.
const core = @import("core");
const common = @import("common.zig");

const Reports = struct {
    pub const module: core.app.Module = .{ .exports = &.{common.UserService} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{ common.UsersModule, Reports } };
};

test {
    _ = core.App(Root);
}
