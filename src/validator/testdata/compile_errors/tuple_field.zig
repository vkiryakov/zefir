const v = @import("validator");

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

const Bad = struct {
    x: struct { u32, Item },
};

test {
    comptime v.assertRules(Bad);
}
