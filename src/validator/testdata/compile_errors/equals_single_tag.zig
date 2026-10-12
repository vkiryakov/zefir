const v = @import("validator");

const Only = enum { only };

const Bad = struct {
    x: Only,
    pub const field_rules = .{ .x = v.equals(.only) };
};

test {
    comptime v.assertRules(Bad);
}
