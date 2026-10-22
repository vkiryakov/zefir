//! Must not compile: an init that takes a private bean of another module by
//! value. A struct param of a bean's type is that bean, never a struct of
//! dependencies.
const core = @import("core");
const common = @import("common.zig");

const Peek = struct {
    repo: common.UserRepository,

    pub fn init(repo: common.UserRepository) Peek {
        return .{ .repo = repo };
    }
};

const Reports = struct {
    pub const module: core.app.Module = .{ .imports = &.{common.UsersModule}, .providers = &.{Peek} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{ common.UsersModule, Reports } };
};

test {
    _ = core.App(Root);
}
