//! Must not compile: a value of the root of the type of a bean.
const core = @import("core");
const common = @import("common.zig");

const InfraModule = struct {
    pub const module: core.app.Module = .{ .factories = &.{Factories}, .exports = &.{common.Database} };

    pub const Factories = struct {
        pub fn database() common.Database {
            return .{ .name = "shop" };
        }
    };
};

const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{InfraModule}, .values = &.{*const common.Database} };
};

test {
    _ = core.App(Root);
}
