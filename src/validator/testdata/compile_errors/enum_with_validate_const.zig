const v = @import("validator");

const Level = enum {
    low,
    high,
    pub const validate = true;
};

const Bad = struct {
    x: Level,
};

test {
    comptime v.assertRules(Bad);
}
