//! Must not compile: a provider and the factory of its dependency that
//! take each other.
const core = @import("core");
const common = @import("common.zig");

const Repo = struct { db: *common.Database };

const Factories = struct {
    pub fn database(repo: *Repo) common.Database {
        _ = repo;
        return .{};
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Repo}, .factories = &.{Factories} };
};

test {
    _ = core.App(Root);
}
