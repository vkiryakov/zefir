//! Must not compile: a bean that takes an export of a module its module
//! does not import.
const core = @import("core");
const common = @import("common.zig");

const Peek = struct { users: *common.UserService };

const Reports = struct {
    pub const module: core.app.Module = .{ .providers = &.{Peek} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{ common.UsersModule, Reports } };
};

test {
    _ = core.App(Root);
}
