//! Must not compile: a key of the texts of a field written wrong.
const zefir = @import("zefir");
const v = zefir.validator;

const TodoIdPath = struct {
    id: u64,

    pub const field_rules = .{ .id = v.positive };

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .fields = .{ .id = .{ .descripton = "The id of the todo." } },
    };
};

test {
    _ = TodoIdPath.openapi;
}
