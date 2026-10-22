//! Must not compile: an overridden bean that a bean takes, and no value in
//! its place.
const core = @import("core");
const common = @import("common.zig");

const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{common.UsersModule}, .overrides = &.{common.UserRepository} };
};

test {
    _ = core.App(Root);
}
