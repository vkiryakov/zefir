const v = @import("validator");

fn f(x: u32, y: u32) bool {
    return x > y;
}

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.custom("users.ok", "must be ok", f) };
};

test {
    comptime v.assertRules(Bad);
}
