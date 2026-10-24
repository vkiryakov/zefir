//! Must not compile: a body for 204 in .responses, a status that goes
//! without one, as 205 and 304 do.
const std = @import("std");
const http = @import("http");

const Item = struct { id: u64 };

const ItemsV1Controller = struct {
    pub const http_routes = http.routes(.{
        .prefix = "/v1/items",
        .methods = .{ .sync = http.put("/sync", .{ .responses = .{ .ok = .{}, .no_content = .{ .json = Item } } }) },
    });

    pub fn sync(_: *ItemsV1Controller, _: *http.Context) !http.Json(Item) {
        return .{ .value = .{ .id = 1 } };
    }
};

test {
    var items: ItemsV1Controller = .{};
    const backend: http.Backend = undefined;
    var server = try http.Server.init(std.testing.allocator, .{ .controllers = .{&items} }, .{ .listen = .{ .backend = backend } });
    defer server.deinit(std.testing.io);
}
