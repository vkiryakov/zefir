//! A request that a golden application gets in the tests, and the status
//! it answers with. Each application lists requests that reach every
//! operation of its document: valid input, invalid input, and the errors
//! that a request can cause.
const std = @import("std");

pub const Request = struct {
    method: std.http.Method,
    /// With the server's prefix and the query: "/api/v1/todos/1?page=2".
    target: []const u8,
    headers: []const [2][]const u8 = &.{},
    body: []const u8 = "",
    /// The status the application answers with.
    status: u16,
};
