const v = @import("validator");

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

test {
    var path_buf: [64]u8 = undefined;
    _ = v.check(Item{ .name = "" }, &path_buf);
}
