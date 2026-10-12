const v = @import("validator");

fn f(x: []const u32) bool {
    return x.len > 0;
}

const Bad = struct {
    x: []const u32,
    pub const field_rules = .{ .x = v.each(v.custom("users.ok", "must be ok", f)) };
};

test {
    comptime v.assertRules(Bad);
}
