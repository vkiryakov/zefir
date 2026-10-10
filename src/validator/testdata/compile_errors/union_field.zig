const v = @import("validator");

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

const Choice = union(enum) { item: Item, none: void };

const Bad = struct {
    x: Choice,
};

test {
    comptime v.assertRules(Bad);
}
