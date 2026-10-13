const v = @import("validator");

const Inner = struct {
    n: u32,
    pub fn validate(self: *const Inner) ?v.Violation {
        _ = self;
        return null;
    }
};

const Bad = struct {
    x: *const Inner,
};

test {
    comptime v.assertRules(Bad);
}
