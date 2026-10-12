const v = @import("validator");

fn isOk(x: u32) bool {
    return x > 0;
}

const is_ok: *const fn (u32) bool = &isOk;

const Bad = struct {
    x: u32,
    pub const field_rules = .{ .x = v.custom("users.ok", "must be ok", is_ok) };
};

test {
    comptime v.assertRules(Bad);
}
