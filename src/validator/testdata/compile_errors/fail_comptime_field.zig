const v = @import("validator");

const Bad = struct {
    comptime version: u32 = 1,
    start: u32,
    end: u32,
    pub fn validateSelf(self: *const Bad) ?v.Violation {
        if (self.end < self.start) return v.fail(Bad, .version, "config.bad_version", "is not supported");
        return null;
    }
};

test {
    comptime v.assertRules(Bad);
}
