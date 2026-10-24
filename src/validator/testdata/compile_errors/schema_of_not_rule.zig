const v = @import("validator");

test {
    _ = v.schemaOf("notEmpty", []const u8);
}
