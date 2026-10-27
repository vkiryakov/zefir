//! The tests of README.md, the overview of the guide: the test it shows in
//! Testing, the load it shows in Loading, and the problems of the files it
//! shows in Problems and diagnostics. `Config` is the struct of minute.zig,
//! the program of "confy in a minute".

const std = @import("std");
const confy = @import("confy");
const cases = @import("cases.zig");
const fixture = @import("fixture.zig");

const Config = struct {
    log_level: enum { debug, info, warn, err } = .info,
    http: struct {
        port: u16,
        timeout_s: u32 = 30,
    },
    db: struct {
        url: []const u8,
        password: confy.Secret,
    },
};

test "a port out of range is reported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "config.json",
        .data = "{ \"http\": { \"port\": 70000 } }",
    });

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("APP_DB_URL", "postgres://localhost/test");
    try environ.put("APP_DB_PASSWORD", "test");

    var diag: confy.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    var config: Config = undefined;
    try std.testing.expectError(error.InvalidConfig, confy.load(std.testing.allocator, &config, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .diagnostics = &diag,
        .sources = &.{ .json("config.json"), .osEnv() },
    }));
    try std.testing.expectEqual(1, diag.problems.items.len);
    const problem = diag.problems.items[0];
    try std.testing.expectEqual(.invalid, problem.kind);
    try std.testing.expectEqualStrings("http.port", problem.path);
    try std.testing.expectEqualStrings("expected an integer 0..65535", problem.detail);
}

test "load fills the struct, and free releases it" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("APP_HTTP_PORT", "8080");
    try environ.put("APP_DB_URL", "postgres://localhost:5432/app");
    try environ.put("APP_DB_PASSWORD", "change-me");

    var config: Config = undefined;
    try confy.load(std.testing.allocator, &config, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    defer confy.free(std.testing.allocator, config);

    try std.testing.expectEqual(8080, config.http.port);
    try std.testing.expectEqual(30, config.http.timeout_s);
    try std.testing.expectEqualStrings("postgres://localhost:5432/app", config.db.url);
    try std.testing.expectEqualStrings("change-me", config.db.password.expose());
}

test "load leaves the struct untouched when it fails" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("APP_HTTP_PORT", "90000");

    var config: Config = undefined;
    config.http.port = 1;
    try std.testing.expectError(error.InvalidConfig, confy.load(std.testing.allocator, &config, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    }));
    try std.testing.expectEqual(1, config.http.port);
}

test "every problem of the files is reported at once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "config.json", @embedFile("testdata/problems/config.json") },
        .{ ".env", @embedFile("testdata/problems/.env") },
    });

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    try fixture.expectLoadProblems(Config, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .sources = &.{ .json("config.json"), .env(".env"), .osEnv() },
    }, cases.problems.broken_files.text);
}

test "the files of confy in a minute give the values of its first run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "config.json", @embedFile("testdata/minute/config.json") },
        .{ ".env", @embedFile("testdata/minute/.env") },
    });

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    var config: Config = undefined;
    try confy.load(std.testing.allocator, &config, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .sources = &.{ .json("config.json"), .env(".env"), .osEnv() },
    });
    defer confy.free(std.testing.allocator, config);

    try std.testing.expectEqual(.info, config.log_level);
    try std.testing.expectEqual(8080, config.http.port);
    try std.testing.expectEqual(30, config.http.timeout_s);
    try std.testing.expectEqualStrings("postgres://localhost:5432/app", config.db.url);
    try std.testing.expectEqualStrings("change-me", config.db.password.expose());
}
