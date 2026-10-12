const v = @import("validator");

const Bad = struct {
    x: u32,
    pub fn validate(self: *const Bad) ?v.Violation {
        if (self.x == 0) return v.fail(Bad, .x, "orders.zero", "must not be zero");
        return null;
    }
};

test {
    comptime v.assertRules(Bad);
}
