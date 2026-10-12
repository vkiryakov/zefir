const v = @import("validator");

const Bad = struct {
    address: struct {
        city: []const u8,
        geo: struct {
            lat: f64,
            pub const field_rules = .{ .lta = v.positive };
        },
    },
};

test {
    comptime v.assertRules(Bad);
}
