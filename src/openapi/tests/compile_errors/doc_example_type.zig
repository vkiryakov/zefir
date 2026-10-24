//! Must not compile: an example that is not a value of its type.
const zefir = @import("zefir");

const CreateTodoRequest = struct {
    title: []const u8,

    pub const openapi: zefir.openapi.Doc(@This()) = .{
        .example = .{ .title = 42 },
    };
};

test {
    _ = CreateTodoRequest.openapi;
}
