//! Typed responses: `http.Json(T)`, what a handler
//! returns to answer with a JSON value.
const std = @import("std");

/// A JSON response of a handler, 200 unless it says otherwise:
/// `return .{ .value = .from(todo) };`, or with a status of its own,
/// `return .{ .value = .from(todo), .status = 201 };`. The value goes out
/// as `ctx.response.json` writes it: through the transforms of its
/// `field_rules`, with the outside names of its fields.
///
/// The transforms run when the handler returns; the JSON is written as the
/// response goes out, through the response's buffer of 16 KiB: a value
/// that fits goes with `Content-Length`, a larger one chunked, and a long
/// list is never held whole in memory. So what the value points to lives,
/// unchanged, until the response has gone out, as memory of the request's
/// arena (`ctx.allocator()`) does.
pub fn Json(comptime T: type) type {
    return struct {
        value: T,
        status: u16 = 200,

        /// The type of the value.
        pub const Value = T;
        pub const zefir_http_json = {};
    };
}

/// What happens to a field of the input that the DTO does not have: the
/// request is refused (422, `http.unknown_field`) or the field ignored.
pub const UnknownFields = enum { reject, ignore };

test "Json: 200 unless the handler gives a status" {
    const Todo = struct { id: u64 };
    const ok: Json(Todo) = .{ .value = .{ .id = 1 } };
    try std.testing.expectEqual(200, ok.status);
    const created: Json(Todo) = .{ .value = .{ .id = 2 }, .status = 201 };
    try std.testing.expectEqual(201, created.status);
    try std.testing.expect(Json(Todo).Value == Todo);
}
