//! Must not compile: a bean that takes a private bean of a module it imports.
const core = @import("core");
const common = @import("common.zig");

const Peek = struct { repo: *common.UserRepository };

const Reports = struct {
    pub const module: core.app.Module = .{ .imports = &.{common.UsersModule}, .providers = &.{Peek} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{ common.UsersModule, Reports } };
};

test {
    _ = core.App(Root);
}
