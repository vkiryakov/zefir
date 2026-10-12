const v = @import("validator");

fn f(x: u32) bool {
    return x > 0;
}

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.custom("users.ok", &@as([513]u8, @splat('m')), f) };
};

test {
    comptime v.assertRules(Bad);
}
