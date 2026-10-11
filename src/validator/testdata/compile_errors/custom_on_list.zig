const v = @import("validator");

fn isOk(x: u32) bool {
    return x > 0;
}

const Bad = struct {
    x: []const u32,
    pub const field_rules = .{ .x = v.custom("users.ok", "must be ok", isOk) };
};

test {
    comptime v.assertRules(Bad);
}
