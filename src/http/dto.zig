//! Typed responses (design section 8): `http.Json(T)`, what a handler
//! returns to answer with a JSON value.
const std = @import("std");

/// A JSON response of a handler, 200 unless it says otherwise:
/// `return .{ .value = .from(todo) };`, or with a status of its own,
/// `return .{ .value = .from(todo), .status = 201 };`.
pub fn Json(comptime T: type) type {
    return struct {
        value: T,
        status: u16 = 200,

        /// The type of the value.
        pub const Value = T;
        pub const zefir_http_json = {};
    };
}

test "Json: 200 unless the handler gives a status" {
    const Todo = struct { id: u64 };
    const ok: Json(Todo) = .{ .value = .{ .id = 1 } };
    try std.testing.expectEqual(200, ok.status);
    const created: Json(Todo) = .{ .value = .{ .id = 2 }, .status = 201 };
    try std.testing.expectEqual(201, created.status);
    try std.testing.expect(Json(Todo).Value == Todo);
}
