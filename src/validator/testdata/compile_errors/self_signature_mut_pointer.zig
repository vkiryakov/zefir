const v = @import("validator");

const Bad = struct {
    x: u32,
    pub fn validateSelf(self: *Bad) ?v.Violation {
        _ = self;
        return null;
    }
};

test {
    comptime v.assertRules(Bad);
}
