//! Must not compile: a constraint written in the texts of a field; the
//! document takes it from the field's rules.
const zefir = @import("zefir");

const CreateTodoRequest = struct {
    title: []const u8,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .fields = .{ .title = .{ .description = "What to do.", .maxLength = 200 } },
    };
};

test {
    _ = CreateTodoRequest.openapi;
}
