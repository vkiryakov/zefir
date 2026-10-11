const v = @import("validator");

const Bad = struct {
    start: u32,
    end: u32,
    pub fn validateSelf(self: *const Bad) ?v.Violation {
        if (self.end < self.start) return v.fail(Bad, .end, "validation.end_before_start", "must not be before start");
        return null;
    }
};

test {
    comptime v.assertRules(Bad);
}
