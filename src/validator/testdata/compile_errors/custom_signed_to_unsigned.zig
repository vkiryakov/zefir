const v = @import("validator");

fn f(x: u64) bool {
    return x > 0;
}

const Bad = struct {
    x: i32,
    pub const field_rules = .{ .x = v.custom("users.ok", "must be ok", f) };
};

test {
    comptime v.assertRules(Bad);
}
