const v = @import("validator");

const Bad = struct {
    x: struct {
        start: u32,
        end: u32,
        pub fn validateSelf(self: *const @This()) ?v.Violation {
            if (self.end < self.start) return v.fail(@This(), .end, "orders.End", "must not be before start");
            return null;
        }
    },
};

test {
    comptime v.assertRules(Bad);
}
