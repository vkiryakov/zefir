const v = @import("validator");

const Choice = union(enum) { a: u32, b: u32 };

test {
    _ = v.fieldNamed(Choice, "a");
}
