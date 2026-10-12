const v = @import("validator");

fn f() bool {
    return true;
}

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.custom("users.ok", "must be ok", f) };
};

test {
    comptime v.assertRules(Bad);
}
