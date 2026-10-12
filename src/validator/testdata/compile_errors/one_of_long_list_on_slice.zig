const v = @import("validator");

const Bad = struct {
    x: []const []const u8,
    pub const field_rules = .{
        .x = v.oneOf(.{ "value_000", "value_001", "value_002", "value_003", "value_004", "value_005", "value_006", "value_007", "value_008", "value_009" }),
    };
};

test {
    comptime v.assertRules(Bad);
}
