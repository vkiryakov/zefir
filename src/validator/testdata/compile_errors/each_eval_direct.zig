const v = @import("validator");

test {
    const items = [_]u32{ 1, 2 };
    const rule = comptime v.each(v.positive);
    _ = rule.eval(&items);
}
