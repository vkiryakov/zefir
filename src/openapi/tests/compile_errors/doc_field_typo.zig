//! Must not compile: the texts of a field that the type does not have.
const zefir = @import("zefir");

const CreateTodoRequest = struct {
    title: []const u8,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .fields = .{ .titel = .{ .description = "What to do." } },
    };
};

test {
    _ = CreateTodoRequest.openapi;
}
