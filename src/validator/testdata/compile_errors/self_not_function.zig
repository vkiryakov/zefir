const v = @import("validator");

const Bad = struct {
    x: u32,
    pub const validateSelf = 5;
};

test {
    comptime v.assertRules(Bad);
}
