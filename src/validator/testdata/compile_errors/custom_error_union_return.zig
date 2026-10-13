const v = @import("validator");

fn f(x: u32) error{Bad}!bool {
    if (x == 0) return error.Bad;
    return true;
}

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.custom("users.ok", "must be ok", f) };
};

test {
    comptime v.assertRules(Bad);
}
