const v = @import("validator");

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

const Choice = union(enum) { item: Item, none: void };

test {
    var path_buf: [64]u8 = undefined;
    const choice: Choice = .{ .none = {} };
    _ = v.check(&choice, &path_buf);
}
