const std = @import("std");
const confy = @import("confy");

const Config = struct {
    name: []const u8 = "zefir-demo",
    debug: bool = false,
    log_level: enum { debug, info, warn, err } = .info,
    http: struct {
        port: u16 = 8080,
        timeout_s: f32 = 30,
        allowed_origins: []const []const u8 = &.{"http://localhost:3000"},
    },
    db: struct {
        url: []const u8 = "postgres://localhost:5432/app",
        password: ?confy.Secret = null,
        pool: struct { size: u8 = 4, max_idle: u8 = 2 },
    },
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });

    std.log.info("{s} listens on port {d}", .{ config.name, config.http.port });
}
