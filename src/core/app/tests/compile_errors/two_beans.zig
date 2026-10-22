//! Must not compile: two factory results of one type. App injects by type,
//! so a type is one bean.
const core = @import("core");
const common = @import("common.zig");

const Dbs = struct {
    pub fn usersDb() common.Database {
        return .{ .name = "users" };
    }
    pub fn analyticsDb() common.Database {
        return .{ .name = "analytics" };
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .factories = &.{Dbs} };
};

test {
    _ = core.App(Root);
}
