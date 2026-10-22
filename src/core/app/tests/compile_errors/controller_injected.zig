//! Must not compile: a provider that takes a controller.
const core = @import("core");
const common = @import("common.zig");

const Peek = struct { ctl: *common.UsersController };

const Reports = struct {
    pub const module: core.app.Module = .{ .imports = &.{common.UsersModule}, .providers = &.{Peek} };
};
const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{ common.UsersModule, Reports } };
};

test {
    _ = core.App(Root);
}
