const v = @import("validator");

const Bad = struct {
    start: u32,
    end: u32,
    pub inline fn validateSelf(self: *const Bad) ?v.Violation {
        if (self.end < self.start) return v.fail(Bad, .end, "rpc.end_before_start", "must not be before start");
        return null;
    }
};

test {
    comptime v.assertRules(Bad);
}
