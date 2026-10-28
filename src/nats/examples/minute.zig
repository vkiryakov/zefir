const std = @import("std");
const confy = @import("confy");
const nats = @import("nats");
const zio = @import("zio");

/// The client logs through std.log; this leaves out its debug records.
pub const std_options: std.Options = .{ .log_level = .info };

const Config = struct {
    nats: struct {
        url: []const u8 = "nats://127.0.0.1:4222",
    } = .{},
};

pub fn main(init: std.process.Init) !void {
    // APP_NATS_URL sets the server; without it, the default stays.
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });

    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var client: nats.Client = try .init(init.gpa, rt.io(), .{ .servers = &.{config.nats.url} });
    defer client.deinit();
    try client.connect();

    const orders = try client.subscribe("orders.>", .{});
    defer orders.deinit();
    try client.flush(.{});

    try client.publish("orders.created", "{\"id\":1001}");

    var msg = (try orders.next(.{})) orelse return;
    defer msg.deinit();
    std.log.info("{s}: {s}", .{ msg.subject, msg.payload });
}
