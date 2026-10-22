//! Must not compile: texts of the values of an enum, which v1 does not
//! have.
const zefir = @import("zefir");

const Priority = enum {
    low,
    normal,
    high,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .values = .{ .low = "Some day.", .high = "Today." },
    };
};

test {
    _ = Priority.openapi;
}
