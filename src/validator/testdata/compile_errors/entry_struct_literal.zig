const v = @import("validator");

const Address = struct {
    city: []const u8,
};

const Bad = struct {
    x: Address,
    pub const field_rules = .{ .x = .{ .city = v.notEmpty } };
};

test {
    comptime v.assertRules(Bad);
}
