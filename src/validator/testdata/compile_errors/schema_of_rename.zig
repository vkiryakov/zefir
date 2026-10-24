const v = @import("validator");

test {
    _ = v.schemaOf(v.rename("userName"), []const u8);
}
