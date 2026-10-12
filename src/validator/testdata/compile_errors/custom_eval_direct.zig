const v = @import("validator");

fn isEven(x: u32) bool {
    return x % 2 == 0;
}

test {
    const name: []const u8 = "bob";
    const rule = comptime v.custom("users.even", "must be even", isEven);
    _ = rule.eval(&name);
}
