//! Must not compile: a bean that takes the value in the place of an
//! export of an overridden module, but does not import that module.
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

const Repo = struct { db: *common.Database };

const UsersModule = struct {
    pub const module: core.app.Module = .{ .imports = &.{InfraModule}, .providers = &.{Repo} };
};

const Peek = struct { db: *common.Database };

const Reports = struct {
    pub const module: core.app.Module = .{ .providers = &.{Peek} };
};

const Root = struct {
    pub const module: core.app.Module = .{
        .imports = &.{ UsersModule, Reports },
        .overrides = &.{InfraModule},
        .values = &.{*common.Database},
    };
};

test {
    _ = core.App(Root);
}
