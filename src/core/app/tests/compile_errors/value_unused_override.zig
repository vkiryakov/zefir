//! Must not compile: a value in the place of an overridden export that no
//! bean takes.
const core = @import("core");
const common = @import("common.zig");

const InfraModule = struct {
    pub const module: core.app.Module = .{ .factories = &.{Dbs}, .exports = &.{common.Database} };

    pub const Dbs = struct {
        pub fn database() common.Database {
            return .{ .name = "shop" };
        }
    };
};

const Root = struct {
    pub const module: core.app.Module = .{ .imports = &.{InfraModule}, .overrides = &.{InfraModule}, .values = &.{*common.Database} };
};

test {
    _ = core.App(Root);
}
