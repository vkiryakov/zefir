//! Must not compile: an init whose struct param has nothing for App to
//! inject. Those are options: a factory builds the type and passes them.
const std = @import("std");
const core = @import("core");

const Cache = struct {
    gpa: std.mem.Allocator,
    size: usize,

    pub const Options = struct { size: usize = 64 };

    pub fn init(gpa: std.mem.Allocator, options: Options) Cache {
        return .{ .gpa = gpa, .size = options.size };
    }
};

const Root = struct {
    pub const module: core.app.Module = .{ .providers = &.{Cache} };
};

test {
    _ = core.App(Root);
}
