//! The tests of json.md: the struct of its "At a glance" and the structs of
//! its sections, the JSON files it shows, the values of its tables and the
//! problems of its broken files.

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
    upstreams: []const struct { host: []const u8, weight: u8 = 1 } = &.{},
};

test "the JSON file of At a glance gives the values of its table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", @embedFile("testdata/json/glance/config.json") }});

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .sources = &.{.json("config.json")},
    });
    defer confy.free(testing.allocator, config);

    try testing.expectEqualStrings("zefir-demo", config.name);
    try testing.expect(!config.debug);
    try testing.expectEqual(.debug, config.log_level);
    try testing.expectEqual(8080, config.http.port);
    try testing.expectEqual(2.5, config.http.timeout_s);
    try testing.expectEqual(2, config.http.allowed_origins.len);
    try testing.expectEqualStrings("https://app.example.com", config.http.allowed_origins[0]);
    try testing.expectEqualStrings("https://admin.example.com", config.http.allowed_origins[1]);
    try testing.expectEqualStrings("postgres://db.internal:5432/app", config.db.url);
    try testing.expectEqualStrings("change-me", config.db.password.expose());
    try testing.expectEqual(@as(?[]const u8, null), config.db.replica_url);
    try testing.expectEqual(8, config.db.pool.size);
    try testing.expectEqual(2, config.db.pool.max_idle);
    try testing.expectEqual(2, config.upstreams.len);
    try testing.expectEqualStrings("10.0.0.1:9000", config.upstreams[0].host);
    try testing.expectEqual(3, config.upstreams[0].weight);
    try testing.expectEqualStrings("10.0.0.2:9000", config.upstreams[1].host);
    try testing.expectEqual(1, config.upstreams[1].weight);
}

/// Loads `T` from the JSON `text`; a problem fails the test.
fn loadJson(comptime T: type, text: []const u8) !T {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", text }});

    var config: T = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} });
    return config;
}

/// Loads `T` from the JSON `text`, which must give the problems `expected`.
fn expectJsonProblems(comptime T: type, text: []const u8, expected: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", text }});
    try fixture.expectLoadProblems(T, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} }, expected);
}

test "integers must fit their type" {
    const Integers = struct { port: u16 = 0, offset: i8 = 0, max: u64 = 0 };

    try testing.expectEqual(8080, (try loadJson(Integers, "{ \"port\": 8080 }")).port);
    try testing.expectEqual(8080, (try loadJson(Integers, "{ \"port\": \"8080\" }")).port);
    try testing.expectEqual(-3, (try loadJson(Integers, "{ \"offset\": -3 }")).offset);
    try testing.expectEqual(std.math.maxInt(u64), (try loadJson(Integers, "{ \"max\": 18446744073709551615 }")).max);
    for ([_][]const u8{ "{ \"port\": 70000 }", "{ \"port\": -1 }", "{ \"port\": 80.5 }" }) |text| {
        try expectJsonProblems(Integers, text,
            \\1 configuration problem:
            \\  config.json:1: port: invalid (expected an integer 0..65535)
        );
    }
}

test "a list takes an array, and a problem in an item names it by index" {
    const Ports = struct {
        ports: []const u16 = &.{80},
    };

    const rows = [_]struct { []const u8, []const u16 }{
        .{ "{ \"ports\": [80, 443] }", &.{ 80, 443 } },
        .{ "{ \"ports\": [] }", &.{} },
        .{ "{ \"ports\": [80, \"443\"] }", &.{ 80, 443 } },
        .{ "{ \"ports\": \"80, 443\" }", &.{ 80, 443 } },
        .{ "{}", &.{80} },
    };
    for (rows) |row| {
        const config = try loadJson(Ports, row[0]);
        defer confy.free(testing.allocator, config);
        try testing.expectEqualSlices(u16, row[1], config.ports);
    }
    try expectJsonProblems(Ports, "{ \"ports\": [80, 70000] }",
        \\1 configuration problem:
        \\  config.json:1: ports[1]: invalid (expected an integer 0..65535)
    );
    try expectJsonProblems(Ports, "{ \"ports\": 80 }",
        \\1 configuration problem:
        \\  config.json:1: ports: invalid (expected a list)
    );
}

test "a nested object can be partial: missing keys take their defaults" {
    const Database = struct {
        db: struct {
            url: []const u8,
            pool: struct { size: u8 = 4, max_idle: u8 = 2 },
        },
    };

    const partial = try loadJson(Database, "{ \"db\": { \"url\": \"pg://h/app\" } }");
    defer confy.free(testing.allocator, partial);
    try testing.expectEqual(4, partial.db.pool.size);
    try testing.expectEqual(2, partial.db.pool.max_idle);

    const size = try loadJson(Database, "{ \"db\": { \"url\": \"pg://h/app\", \"pool\": { \"size\": 8 } } }");
    defer confy.free(testing.allocator, size);
    try testing.expectEqual(8, size.db.pool.size);
    try testing.expectEqual(2, size.db.pool.max_idle);

    try expectJsonProblems(Database, "{ \"db\": { \"pool\": { \"size\": 8 } } }",
        \\1 configuration problem:
        \\  db.url: missing (set "db.url" in a config file)
    );
    try expectJsonProblems(Database, "{ \"db\": \"pg://h/app\" }",
        \\1 configuration problem:
        \\  config.json:1: db: invalid (expected a section with fields)
    );
}

test "only JSON fills a list of structs, with their defaults" {
    const Upstreams = struct {
        upstreams: []const struct {
            host: []const u8,
            weight: u8 = 1,
        } = &.{},
    };

    const config = try loadJson(Upstreams,
        \\{
        \\  "upstreams": [
        \\    { "host": "10.0.0.1:9000", "weight": 3 },
        \\    { "host": "10.0.0.2:9000" }
        \\  ]
        \\}
    );
    defer confy.free(testing.allocator, config);
    try testing.expectEqual(2, config.upstreams.len);
    try testing.expectEqual(3, config.upstreams[0].weight);
    try testing.expectEqual(1, config.upstreams[1].weight);

    try expectJsonProblems(Upstreams, "{ \"upstreams\": [{ \"host\": \"a\" }, { \"host\": \"b\", \"weight\": 300 }] }",
        \\1 configuration problem:
        \\  config.json:1: upstreams[1].weight: invalid (expected an integer 0..255)
    );
    try expectJsonProblems(Upstreams, "{ \"upstreams\": [{ \"host\": \"a\", \"wieght\": 3 }] }",
        \\1 configuration problem:
        \\  config.json:1: upstreams[0].wieght: unknown key (did you mean "weight"?)
    );
    try expectJsonProblems(Upstreams, "{ \"upstreams\": [{ \"weight\": 3 }] }",
        \\1 configuration problem:
        \\  upstreams[0].host: missing (set "upstreams[0].host" in a config file)
    );
}

test "every problem of the broken JSON file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", @embedFile("testdata/json/problems/config.json") }});

    try fixture.expectLoadProblems(Config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .sources = &.{.json("config.json")},
    }, cases.problems.json.text);
}

test "a file that is not valid JSON is skipped as a whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", @embedFile("testdata/json/syntax/config.json") }});

    try fixture.expectLoadProblems(Config, .{
        .io = testing.io,
        .dir = tmp.dir,
        .sources = &.{.json("config.json")},
    }, cases.problems.json_syntax.text);
}
