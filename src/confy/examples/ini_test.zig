//! The tests of ini.md: the struct of its "At a glance", the INI files it
//! shows, the values of its tables and the problems of its broken file.

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

test "the INI file of At a glance gives the values of its table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.ini", @embedFile("testdata/ini/glance/config.ini") }});

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .sources = &.{.ini("config.ini")},
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
    try testing.expectEqualStrings("change;me#now", config.db.password.expose());
    try testing.expectEqual(@as(?[]const u8, null), config.db.replica_url);
    try testing.expectEqual(8, config.db.pool.size);
    try testing.expectEqual(4, config.db.pool.max_idle);
}

test "every problem of the broken INI file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.ini", @embedFile("testdata/ini/problems/config.ini") }});

    try fixture.expectLoadProblems(Config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .sources = &.{.ini("config.ini")},
    }, cases.problems.ini.text);
}

test "a section, a dotted key and a dotted section name reach the same field" {
    const Sections = struct {
        http: struct { port: u16 = 80 },
        db: struct { pool: struct { size: u8 = 4, max_idle: u8 = 2 } },
    };
    const files = [_][]const u8{
        "[db.pool]\nsize = 8\n",
        "[db]\npool.size = 8\n",
        "db.pool.size = 8\n",
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (files) |file| {
        try fixture.write(tmp.dir, &.{.{ "config.ini", file }});
        var config: Sections = undefined;
        try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} });
        try testing.expectEqual(8, config.db.pool.size);
    }

    // A section opened again and a dotted key fill the same struct.
    try fixture.write(tmp.dir, &.{.{ "config.ini", "[db]\npool.size = 8\n\n[http]\nport = 8080\n\n[db.pool]\nmax_idle = 4\n" }});
    var config: Sections = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} });
    try testing.expectEqual(8, config.db.pool.size);
    try testing.expectEqual(4, config.db.pool.max_idle);
    try testing.expectEqual(8080, config.http.port);
}

test "quotes are optional, and there are no escapes" {
    const Texts = struct { name: []const u8 };
    const rows = [_][2][]const u8{
        .{ "name = zefir", "zefir" },
        .{ "name = \"zefir\"", "zefir" },
        .{ "name = 'zefir'", "zefir" },
        .{ "name = \"> \"", "> " },
        .{ "name = \"C:\\temp\"", "C:\\temp" },
        .{ "name = \"zefir'", "\"zefir'" },
        .{ "name = zefir demo", "zefir demo" },
        .{ "name = pg://h/app?sslmode=require", "pg://h/app?sslmode=require" },
        .{ "name =", "" },
        .{ "name = change;me#now", "change;me#now" },
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (rows) |row| {
        const text = try std.mem.concat(testing.allocator, u8, &.{ row[0], "\n" });
        defer testing.allocator.free(text);
        try fixture.write(tmp.dir, &.{.{ "config.ini", text }});

        var config: Texts = undefined;
        try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} });
        defer confy.free(testing.allocator, config);
        testing.expectEqualStrings(row[1], config.name) catch |err| {
            std.debug.print("the line was {s}\n", .{row[0]});
            return err;
        };
    }
}

test "a key that matches no field is a problem, with a suggestion" {
    const Port = struct { port: u16 = 80 };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.ini", "Port = 1\nprot = 1\nbad key = 1\n" }});

    try fixture.expectLoadProblems(Port, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} },
        \\3 configuration problems:
        \\  config.ini:3: syntax error (expected a key like port or pool.size before '=')
        \\  config.ini:1: Port: unknown key (did you mean "port"?)
        \\  config.ini:2: prot: unknown key (did you mean "port"?)
    );
}
