const v = @import("validator");

fn isFree(x: u32) bool {
    return x > 0;
}

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.custom("users.ok", isFree) };
};

test {
    comptime v.assertRules(Bad);
}
