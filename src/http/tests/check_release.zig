//! Built in ReleaseSafe by `zig build test-http`, with a ReleaseSafe copy
//! of zefir-http: outside Debug the server does not check a route's
//! declarations, so a route of a controller with `pub const openapi` that
//! reads a query it does not declare and answers a status it does not
//! declare gets its response as it is.
const std = @import("std");
const http = @import("http");

const ListQuery = struct { page: u32 = 1 };
const OtherQuery = struct { q: ?[]const u8 = null };

const ItemsV1Controller = struct {
    pub const openapi = .{};

    pub const http_routes = http.routes(.{
        .prefix = "/v1/items",
        .methods = .{ .list = http.get("", .{ .query = ListQuery }) },
    });

    /// Neither the query nor the status is declared: in Debug, a 500.
    pub fn list(_: *ItemsV1Controller, ctx: *http.Context) !void {
        const query = try ctx.query(OtherQuery);
        try ctx.response.status(202).text(query.q orelse "-");
    }
};

test "outside Debug a mismatch with the route's declarations does not change the response" {
    const io = std.testing.io;
    var items: ItemsV1Controller = .{};
    var backend: http.testing.Backend = .init(std.testing.allocator);
    defer backend.deinit();
    var server = try http.Server.init(std.testing.allocator, .{ .backend = backend.backend(), .controllers = .{&items} });
    defer server.deinit(io);
    try server.start(io);

    var res = try backend.request(io, .{ .method = .GET, .target = "/v1/items?q=milk" });
    defer res.deinit();
    try std.testing.expectEqual(202, res.status);
    try std.testing.expectEqualStrings("milk", res.body);
}
