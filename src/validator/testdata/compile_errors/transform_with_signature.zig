const v = @import("validator");

fn splitComma(text: []const u8) []const u8 {
    return text;
}

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{ .x = v.transformWith(splitComma) };
};

test {
    comptime v.assertRules(Bad);
}
