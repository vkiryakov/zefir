//! Must not compile: a factory whose struct param has nothing for App to
//! inject. The factory writes its options itself.
const std = @import("std");
const core = @import("core");

const Cache = struct {
    gpa: std.mem.Allocator,
    size: usize,

    pub const Options = struct { size: usize = 64 };
};

const Tools = struct {
    pub fn cache(gpa: std.mem.Allocator, options: Cache.Options) Cache {
        return .{ .gpa = gpa, .size = options.size };
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .factories = &.{Tools} };
};

test {
    _ = core.App(Root);
}
