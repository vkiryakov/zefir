const v = @import("validator");

const Open = enum(u8) { a, b, _ };

const Bad = struct {
    x: Open,
    pub const field_rules = .{ .x = v.equals(@as(Open, @fromBackingInt(7))) };
};

test {
    comptime v.assertRules(Bad);
}
