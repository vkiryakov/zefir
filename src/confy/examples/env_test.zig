//! The tests of env.md: the test it shows in Testing, the values of its
//! "At a glance" table and the problems of its Required fields. `Config`
//! is the struct of environment.zig, the program of the page.

const std = @import("std");
const confy = @import("confy");
const cases = @import("cases.zig");
const fixture = @import("fixture.zig");

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

test "the port comes from the environment" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("APP_HTTP_PORT", "9090");

    var config: Config = undefined;
    try confy.load(std.testing.allocator, &config, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    defer confy.free(std.testing.allocator, config);

    try std.testing.expectEqual(9090, config.http.port);
}

/// Loads `Config` from the variables `vars`, as the program does.
fn loadWith(vars: []const [2][]const u8) !Config {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    for (vars) |pair| try environ.put(pair[0], pair[1]);

    var config: Config = undefined;
    try confy.load(std.testing.allocator, &config, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    return config;
}

test "each variable of the At a glance table sets one field" {
    const defaults = try loadWith(&.{});
    defer confy.free(std.testing.allocator, defaults);
    try std.testing.expectEqualStrings("zefir-demo", defaults.name);
    try std.testing.expect(!defaults.debug);
    try std.testing.expectEqual(.info, defaults.log_level);
    try std.testing.expectEqual(8080, defaults.http.port);
    try std.testing.expectEqual(30, defaults.http.timeout_s);
    try std.testing.expectEqual(1, defaults.http.allowed_origins.len);
    try std.testing.expectEqualStrings("http://localhost:3000", defaults.http.allowed_origins[0]);
    try std.testing.expectEqualStrings("postgres://localhost:5432/app", defaults.db.url);
    try std.testing.expect(defaults.db.password == null);
    try std.testing.expectEqual(4, defaults.db.pool.size);
    try std.testing.expectEqual(2, defaults.db.pool.max_idle);

    const port = try loadWith(&.{.{ "APP_HTTP_PORT", "9090" }});
    defer confy.free(std.testing.allocator, port);
    try std.testing.expectEqual(9090, port.http.port);

    const level = try loadWith(&.{ .{ "APP_LOG_LEVEL", "warn" }, .{ "APP_DEBUG", "1" } });
    defer confy.free(std.testing.allocator, level);
    try std.testing.expectEqual(.warn, level.log_level);
    try std.testing.expect(level.debug);

    const origins = try loadWith(&.{.{ "APP_HTTP_ALLOWED_ORIGINS", "https://a.com,https://b.com" }});
    defer confy.free(std.testing.allocator, origins);
    try std.testing.expectEqual(2, origins.http.allowed_origins.len);
    try std.testing.expectEqualStrings("https://a.com", origins.http.allowed_origins[0]);
    try std.testing.expectEqualStrings("https://b.com", origins.http.allowed_origins[1]);

    const password = try loadWith(&.{.{ "APP_DB_PASSWORD", "change-me" }});
    defer confy.free(std.testing.allocator, password);
    const secret = password.db.password orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("change-me", secret.expose());
    const printed = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{secret});
    defer std.testing.allocator.free(printed);
    try std.testing.expectEqualStrings("[REDACTED]", printed);

    const pool = try loadWith(&.{.{ "APP_DB_POOL_SIZE", "16" }});
    defer confy.free(std.testing.allocator, pool);
    try std.testing.expectEqual(16, pool.db.pool.size);
    try std.testing.expectEqual(2, pool.db.pool.max_idle);

    const empty = try loadWith(&.{.{ "APP_NAME", "" }});
    defer confy.free(std.testing.allocator, empty);
    try std.testing.expectEqualStrings("", empty.name);
}

test "a required field names the variable to set, and the files when there are any" {
    const Named = struct { name: []const u8 };
    const Database = struct { db: struct { url: []const u8 } };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", "{}" }});
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    try fixture.expectLoadProblems(Named, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    }, cases.problems.env_name.text);
    try fixture.expectLoadProblems(Database, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .sources = &.{ .json("config.json"), .env(".env"), .osEnv() },
    }, cases.problems.env_files.text);
}

test "a value that does not fit names the variable" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("APP_HTTP_PORT", "");

    try fixture.expectLoadProblems(Config, .{
        .io = std.testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    },
        \\1 configuration problem:
        \\  environment: APP_HTTP_PORT: invalid (expected an integer 0..65535)
    );
}
