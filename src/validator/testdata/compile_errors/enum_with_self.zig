const v = @import("validator");

const Level = enum {
    low,
    high,

    pub fn validateSelf(_: *const Level) ?v.Violation {
        return null;
    }
};

const Bad = struct {
    x: Level,
};

test {
    comptime v.assertRules(Bad);
}
