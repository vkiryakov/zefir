const v = @import("validator");

fn isEven(n: u32) bool {
    return n % 2 == 0;
}

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = .{ v.positive, isEven } };
};

test {
    comptime v.assertRules(Bad);
}
