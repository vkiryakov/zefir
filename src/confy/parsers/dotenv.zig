const Tree = @import("../tree.zig").Tree;
const ConfyErrors = @import("../errors.zig").ConfyErrors;

pub fn parse(path: []const u8, tree: *Tree) ConfyErrors!void {
    _ = tree;
    _ = path;
}
