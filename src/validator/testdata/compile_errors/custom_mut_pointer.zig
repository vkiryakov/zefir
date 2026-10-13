const v = @import("validator");

const Item = struct { qty: u32 };

fn f(item: *Item) bool {
    return item.qty > 0;
}

const Bad = struct {
    x: Item,
    pub const field_rules = .{ .x = v.custom("users.ok", "must be ok", f) };
};

test {
    comptime v.assertRules(Bad);
}
