const v = @import("validator");

const Bad = struct {
    x: struct {
        n: u32,
        pub fn validateSelf() ?v.Violation {
            return null;
        }
    },
};

test {
    comptime v.assertRules(Bad);
}
