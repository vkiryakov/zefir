//! Must compile: every type a claim may have, alone, as ?T and as
//! []const T, with names from claim_names and v.rename and a rule.
const jwt = @import("jwt");
const v = @import("validator");

const Level = enum { low, high };

const Item = struct {
    sku: []const u8,
    count: u32 = 1,
};

const Claims = struct {
    flag: bool,
    small: i8,
    count: u32,
    total: u64,
    delta: i64,
    ratio: f32,
    value: f64,
    level: Level,
    name: []const u8,
    item: Item,

    maybe_flag: ?bool = null,
    maybe_count: ?u32 = null,
    maybe_value: ?f64 = null,
    maybe_level: ?Level = null,
    maybe_name: ?[]const u8 = null,
    maybe_item: ?Item = null,

    flags: []const bool = &.{},
    counts: []const u32 = &.{},
    values: []const f64 = &.{},
    levels: []const Level = &.{},
    names: []const []const u8 = &.{},
    items: []const Item = &.{},
    maybe_counts: []const ?u32 = &.{},
    matrix: []const []const i64 = &.{},

    is_root: bool = false,
    user_name: []const u8 = "",

    pub const claim_names = .{ .is_root = "http://example.com/is_root" };
    pub const field_rules = .{
        .user_name = v.rename("userName"),
        .names = v.maxItems(16),
    };
};

test {
    comptime jwt.assertClaims(Claims);
}
