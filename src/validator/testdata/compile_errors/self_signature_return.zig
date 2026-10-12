const v = @import("validator");

const Bad = struct {
    x: u32,
    pub fn validateSelf(self: *const Bad) bool {
        return self.x != 0;
    }
};

test {
    comptime v.assertRules(Bad);
}
