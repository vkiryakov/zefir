//! The tests of dotenv.md: the struct of its "At a glance", the `.env` files
//! it shows, the values of its tables and the problems of its broken file.

const std = @import("std");
const confy = @import("confy");
const cases = @import("cases.zig");
const fixture = @import("fixture.zig");

const testing = std.testing;

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

test "the .env file of At a glance gives the values of its table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ ".env", @embedFile("testdata/dotenv/glance/.env") }});

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .env_prefix = "APP_",
        .sources = &.{ .env(".env"), .env(".env.local") },
    });
    defer confy.free(testing.allocator, config);

    try testing.expectEqualStrings("zefir-demo", config.name);
    try testing.expect(config.debug);
    try testing.expectEqual(.debug, config.log_level);
    try testing.expectEqual(8080, config.http.port);
    try testing.expectEqual(2.5, config.http.timeout_s);
    try testing.expectEqual(2, config.http.allowed_origins.len);
    try testing.expectEqualStrings("https://app.example.com", config.http.allowed_origins[0]);
    try testing.expectEqualStrings("https://admin.example.com", config.http.allowed_origins[1]);
    try testing.expectEqualStrings("postgres://db.internal:5432/app", config.db.url);
    try testing.expectEqualStrings("change#me", config.db.password.expose());
    try testing.expectEqual(@as(?[]const u8, null), config.db.replica_url);
    try testing.expectEqual(8, config.db.pool.size);
    try testing.expectEqual(2, config.db.pool.max_idle);
}

test "a later .env file wins over an earlier one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ ".env", @embedFile("testdata/dotenv/glance/.env") },
        .{ ".env.local", "APP_HTTP_PORT=9090\n" },
    });

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .env_prefix = "APP_",
        .sources = &.{
            .env(".env"), // shared by the team, without secrets
            .env(".env.local"), // personal overrides, in .gitignore
        },
    });
    defer confy.free(testing.allocator, config);

    try testing.expectEqual(9090, config.http.port);
    try testing.expectEqualStrings("zefir-demo", config.name);
}

test "every problem of the broken .env file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ ".env", @embedFile("testdata/dotenv/problems/.env") }});

    try fixture.expectLoadProblems(Config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .env_prefix = "APP_",
        .sources = &.{.env(".env")},
    }, cases.problems.dotenv.text);
}

test "quotes, escapes and comments give the values of their tables" {
    const Name = struct { name: []const u8 };
    const rows = [_][2][]const u8{
        .{ "NAME=zefir demo", "zefir demo" },
        .{ "NAME=\"zefir demo\"", "zefir demo" },
        .{ "NAME='zefir demo'", "zefir demo" },
        .{ "NAME=\" padded \"", " padded " },
        .{ "NAME=\"a\\tb\"", "a\tb" },
        .{ "NAME='a\\tb'", "a\\tb" },
        .{ "NAME=a\\tb", "a\\tb" },
        .{ "NAME=\"say \\\"hi\\\"\"", "say \"hi\"" },
        .{ "NAME=\"a\\qb\"", "a\\qb" },
        .{ "NAME=${HOME}/data", "${HOME}/data" },
        .{ "NAME=value # note", "value" },
        .{ "NAME=value#tag", "value#tag" },
        .{ "NAME=\"value # note\"", "value # note" },
        .{ "NAME='change#me'", "change#me" },
        .{ "NAME=", "" },
        .{ "export NAME = zefir", "zefir" },
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (rows) |row| {
        const text = try std.mem.concat(testing.allocator, u8, &.{ row[0], "\n" });
        defer testing.allocator.free(text);
        try fixture.write(tmp.dir, &.{.{ ".env", text }});

        var config: Name = undefined;
        try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.env(".env")} });
        defer confy.free(testing.allocator, config);
        testing.expectEqualStrings(row[1], config.name) catch |err| {
            std.debug.print("the line was {s}\n", .{row[0]});
            return err;
        };
    }
}
