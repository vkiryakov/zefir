const v = @import("validator");

pub const quantity = .{ v.positive, v.max(1000) }; // a tuple
pub const sku: v.Rule = v.notEmpty; // one rule
