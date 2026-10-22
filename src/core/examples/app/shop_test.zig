//! The tests of the shop: OrdersModule with a store of users that the test
//! fills itself, and the graph of the whole shop.

const std = @import("std");
const zefir = @import("zefir");
const users = @import("users.zig");
const orders = @import("orders.zig");

const testing = std.testing;

/// A root of the test: the real OrdersModule, and through it the real
/// UsersModule, but App does not build the users' store. The test passes a
/// store of its own, a value of `.values`, which takes its place.
const OrdersTest = struct {
    pub const module: zefir.app.Module = .{
        .imports = &.{orders.OrdersModule},
        .overrides = &.{users.UsersDb},
        .values = &.{ *users.UsersDb, *const zefir.log.Logger },
    };
};

test "an order of a user who exists, and of one who does not" {
    const io = testing.io;
    var users_db: users.UsersDb = .init(testing.allocator);
    defer users_db.deinit();
    try users_db.start(io);
    const ann = try users_db.store.insert(io, .{ .text = "Ann" });

    // The records of the services go to a buffer, not to stdout.
    var buffer: [1024]u8 = undefined;
    var records: std.Io.Writer = .fixed(&buffer);
    const logger: zefir.log.Logger = try .init(testing.allocator, io, .{ .format = .text, .output = .{ .writer = &records } });
    defer logger.deinit();

    var app = try zefir.App(OrdersTest).init(testing.allocator, io, .{ &users_db, &logger }, .{});
    defer app.deinit();
    // Opens the store of the orders; the store of the users is the test's.
    try app.start();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // app.get is for tests: name the type, and the editor completes its
    // fields and methods.
    const service: *orders.OrderService = app.get(orders.OrderService);
    const order = try service.place(io, arena, ann, "Green tea");
    try testing.expectEqual(ann, order.user_id);
    try testing.expectEqualStrings("Green tea", (try service.find(io, arena, order.id)).item);
    try testing.expectError(error.UserNotFound, service.place(io, arena, ann + 1, "Coffee"));
}

test "the graph of the shop" {
    // Zig checks only the code that a build reaches: naming the type of the
    // shop's App checks its whole graph, and starts nothing.
    _ = zefir.App(@import("app_module.zig").AppModule);
}
