const v = @import("validator");

const Item = struct {
    name: []const u8,
    pub const field_rules = .{ .name = v.notEmpty };
};

fn handle(request: *const Item) ?v.Violation {
    var path_buf: [64]u8 = undefined;
    return v.check(&request, &path_buf);
}

test {
    _ = handle(&.{ .name = "" });
}
