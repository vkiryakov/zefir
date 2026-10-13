const v = @import("validator");

const Item = struct { id: u32, name: []const u8 };
const Bad = struct {
    x: []const Item,
    pub const field_rules = .{ .x = .{ v.maxItems(10), v.uniqueBy(.idd) } };
};

test {
    comptime v.assertRules(Bad);
}
