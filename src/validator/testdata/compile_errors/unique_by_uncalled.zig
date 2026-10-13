const v = @import("validator");

const Item = struct { id: u32 };
const Bad = struct {
    x: []const Item,
    pub const field_rules = .{ .x = v.uniqueBy };
};

test {
    comptime v.assertRules(Bad);
}
