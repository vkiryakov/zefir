const v = @import("validator");

const Inner = struct {
    name: []const u8,
    pub const field_rules = .{ .nmae = v.notEmpty };
};

const Middle = struct {
    inners: []const ?Inner,
};

const Bad = struct {
    x: [2]Middle,
};

test {
    comptime v.assertRules(Bad);
}
