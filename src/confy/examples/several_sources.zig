const std = @import("std");
const confy = @import("confy");

const Config = struct {
    name: []const u8,
    debug: bool = false,
    log_level: enum { debug, info, warn, err } = .info,
    http: struct {
        port: u16,
        timeout_s: f32 = 30,
        allowed_origins: []const []const u8 = &.{},
    },
    db: struct {
        url: []const u8,
        password: confy.Secret,
        replica_url: ?[]const u8,
        pool: struct { size: u8 = 4, max_idle: u8 = 2 },
    },
};

pub fn main(init: std.process.Init) !void {
    const dir = try std.Io.Dir.cwd().openDir(init.io, "sources", .{});
    defer dir.close(init.io);

    var diag: confy.Diagnostics = .init(init.gpa);
    defer diag.deinit();

    var config: Config = undefined;
    confy.load(init.gpa, &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .dir = dir,
        .diagnostics = &diag,
        .sources = &.{
            .json("base.json"),
            .ini("production.ini"),
            .env(".env"),
            .env(".env.local"),
            .osEnv(),
        },
    }) catch |err| switch (err) {
        error.InvalidConfig => {
            std.debug.print("{f}\n", .{&diag}); // a header and one line per problem
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };
    defer confy.free(init.gpa, config);

    std.log.info("{s} listens on port {d}", .{ config.name, config.http.port });
}
