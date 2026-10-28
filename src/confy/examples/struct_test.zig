//! The tests of the chapters of README.md on the configuration struct, its
//! field types, validation and secrets: each holds the struct a section
//! shows, loads it, and checks what the section says of it.

const std = @import("std");
const confy = @import("confy");
const cases = @import("cases.zig");
const fixture = @import("fixture.zig");

const testing = std.testing;

test "a required field that no source sets is a problem that says where to set it" {
    const Config = struct {
        db: struct {
            url: []const u8,
        },
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", "{}" }});
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try fixture.expectLoadProblems(Config, .{
        .io = testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .sources = &.{ .json("config.json"), .osEnv() },
    }, cases.problems.required.text);
}

test "a default is used when no source sets the field" {
    const Config = struct {
        http: struct {
            port: u16 = 8080,
            timeout_s: u32 = 30,
        },
    };

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .sources = &.{} });
    try testing.expectEqual(8080, config.http.port);
    try testing.expectEqual(30, config.http.timeout_s);
}

test "an optional field is null when no source sets it, and null brings its default back" {
    const Config = struct {
        db: struct {
            replica_url: ?[]const u8,
        },
        timeout_s: ?u32 = 30,
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", "{ \"timeout_s\": null }" }});

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} });
    defer confy.free(testing.allocator, config);
    try testing.expectEqual(@as(?[]const u8, null), config.db.replica_url);
    try testing.expectEqual(@as(?u32, 30), config.timeout_s);
}

test "a nested struct is a JSON object, an INI section and a prefix of variable names" {
    const Config = struct {
        db: struct {
            url: []const u8,
            pool: struct {
                size: u8 = 4,
                max_idle: u8 = 2,
            },
        },
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "config.json", "{ \"db\": { \"url\": \"pg://h/app\", \"pool\": { \"size\": 8 } } }" },
        .{ "section.ini", "[db]\nurl = pg://h/app\n\n[db.pool]\nsize = 8\n" },
        .{ "dotted.ini", "[db]\nurl = pg://h/app\npool.size = 8\n" },
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_DB_URL", "pg://h/app");
    try environ.put("APP_DB_POOL_SIZE", "8");

    const every_way = [_]confy.ConfigSource{ .json("config.json"), .ini("section.ini"), .ini("dotted.ini"), .osEnv() };
    for (every_way) |source| {
        var config: Config = undefined;
        try confy.load(testing.allocator, &config, .{
            .io = testing.io,
            .environ = &environ,
            .env_prefix = "APP_",
            .dir = tmp.dir,
            .sources = &.{source},
        });
        defer confy.free(testing.allocator, config);
        try testing.expectEqualStrings("pg://h/app", config.db.url);
        try testing.expectEqual(8, config.db.pool.size);
        try testing.expectEqual(2, config.db.pool.max_idle);
    }
}

test "named struct types work the same way" {
    const Pool = struct { size: u8 = 4, max_idle: u8 = 2 };
    const Db = struct { url: []const u8, pool: Pool = .{} };
    const Config = struct { db: Db };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_DB_URL", "pg://h/app");

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} });
    defer confy.free(testing.allocator, config);
    try testing.expectEqualStrings("pg://h/app", config.db.url);
    try testing.expectEqual(4, config.db.pool.size);
    try testing.expectEqual(2, config.db.pool.max_idle);
}

test "the default of a struct field fills the keys that no source sets" {
    const Pool = struct { size: u8 = 4, max_idle: u8 = 2 };
    const Config = struct {
        // A source that sets only db.pool.size keeps max_idle = 8 from here.
        db: struct { pool: Pool = .{ .size = 16, .max_idle = 8 } },
    };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const options: confy.Options = .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} };

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, options);
    try testing.expectEqual(16, config.db.pool.size);
    try testing.expectEqual(8, config.db.pool.max_idle);

    try environ.put("APP_DB_POOL_SIZE", "32");
    try confy.load(testing.allocator, &config, options);
    try testing.expectEqual(32, config.db.pool.size);
    try testing.expectEqual(8, config.db.pool.max_idle);
}

test "an optional section is null until a source sets one of its fields" {
    const Config = struct {
        tls: ?struct {
            cert: []const u8,
            key: []const u8,
        },
    };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const options: confy.Options = .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} };

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, options);
    try testing.expect(config.tls == null);

    try environ.put("APP_TLS_CERT", "cert.pem");
    try fixture.expectLoadProblems(Config, options,
        \\1 configuration problem:
        \\  tls.key: missing (set APP_TLS_KEY)
    );

    try environ.put("APP_TLS_KEY", "key.pem");
    try confy.load(testing.allocator, &config, options);
    defer confy.free(testing.allocator, config);
    const tls = config.tls orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("cert.pem", tls.cert);
    try testing.expectEqualStrings("key.pem", tls.key);
}

test "a list is a JSON array, or comma-separated text, and a later source replaces it" {
    const Config = struct {
        http: struct {
            allowed_origins: []const []const u8 = &.{},
        },
        ports: []const u16 = &.{ 80, 443 },
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", "{ \"http\": { \"allowed_origins\": [\"https://a.com\", \"https://b.com\"] } }" }});
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var from_json: Config = undefined;
    try confy.load(testing.allocator, &from_json, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} });
    defer confy.free(testing.allocator, from_json);
    try testing.expectEqual(2, from_json.http.allowed_origins.len);
    try testing.expectEqualStrings("https://b.com", from_json.http.allowed_origins[1]);
    try testing.expectEqualSlices(u16, &.{ 80, 443 }, from_json.ports);

    try environ.put("APP_HTTP_ALLOWED_ORIGINS", "https://a.com, https://b.com");
    try environ.put("APP_PORTS", "8080");
    var from_environment: Config = undefined;
    try confy.load(testing.allocator, &from_environment, .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} });
    defer confy.free(testing.allocator, from_environment);
    try testing.expectEqual(2, from_environment.http.allowed_origins.len);
    try testing.expectEqualStrings("https://b.com", from_environment.http.allowed_origins[1]);
    try testing.expectEqualSlices(u16, &.{8080}, from_environment.ports);
}

test "a list of structs comes from JSON only" {
    const Config = struct {
        upstreams: []const struct {
            host: []const u8,
            weight: u8 = 1,
        } = &.{},
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{.{ "config.json", "{ \"upstreams\": [{ \"host\": \"a\", \"weight\": 3 }, { \"host\": \"b\" }] }" }});

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("config.json")} });
    defer confy.free(testing.allocator, config);
    try testing.expectEqual(2, config.upstreams.len);
    try testing.expectEqual(3, config.upstreams[0].weight);
    try testing.expectEqual(1, config.upstreams[1].weight);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_UPSTREAMS", "a, b");
    try fixture.expectLoadProblems(Config, .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} },
        \\1 configuration problem:
        \\  environment: APP_UPSTREAMS: invalid (expected a list)
    );
}

test "an enum is one of its tag names, in the same case" {
    const Config = struct {
        log_level: enum { debug, info, warn, err } = .info,
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "warn.json", "{ \"log_level\": \"warn\" }" },
        .{ "upper.json", "{ \"log_level\": \"WARN\" }" },
        .{ "warning.json", "{ \"log_level\": \"warning\" }" },
    });

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("warn.json")} });
    try testing.expectEqual(.warn, config.log_level);
    try fixture.expectLoadProblems(Config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("upper.json")} },
        \\1 configuration problem:
        \\  upper.json:1: log_level: invalid (expected one of: debug, info, warn, err)
    );
    try fixture.expectLoadProblems(Config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("warning.json")} },
        \\1 configuration problem:
        \\  warning.json:1: log_level: invalid (expected one of: debug, info, warn, err)
    );
}

test "integers must fit their type, and JSON takes strings for numbers, bools and enums" {
    const Config = struct {
        port: u16 = 8080,
        retries: u8 = 3,
        debug: bool = false,
        log_level: enum { debug, info, warn, err } = .info,
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "strings.json", "{ \"port\": \"8080\", \"debug\": \"yes\", \"log_level\": \"warn\" }" },
        .{ "range.json", "{ \"port\": 70000, \"retries\": -1 }" },
    });

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("strings.json")} });
    try testing.expectEqual(8080, config.port);
    try testing.expect(config.debug);
    try testing.expectEqual(.warn, config.log_level);
    try fixture.expectLoadProblems(Config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("range.json")} },
        \\2 configuration problems:
        \\  range.json:1: port: invalid (expected an integer 0..65535)
        \\  range.json:1: retries: invalid (expected an integer 0..255)
    );
}

test "a u128 above 2^127-1 comes from a JSON string, not a JSON number" {
    const Config = struct { id: u128 };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "string.json", "{ \"id\": \"340282366920938463463374607431768211455\" }" },
        .{ "number.json", "{ \"id\": 340282366920938463463374607431768211455 }" },
    });

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("string.json")} });
    try testing.expectEqual(std.math.maxInt(u128), config.id);
    try fixture.expectLoadProblems(Config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.json("number.json")} },
        \\1 configuration problem:
        \\  number.json:1: id: invalid (expected an integer 0..340282366920938463463374607431768211455)
    );
}

test "validate() checks the rules that span several fields" {
    const Config = struct {
        db: struct {
            pool: struct { size: u8 = 4, max_idle: u8 = 2 },
        },

        pub fn validate(config: @This()) !void {
            if (config.db.pool.max_idle > config.db.pool.size) return error.MaxIdleAbovePoolSize;
        }
    };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const options: confy.Options = .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} };

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, options);

    try environ.put("APP_DB_POOL_MAX_IDLE", "8");
    try fixture.expectLoadProblems(Config, options, cases.problems.validate.text);
}

test "a private validate is never called" {
    const Config = struct {
        port: u16 = 8080,

        fn validate(_: @This()) !void {
            return error.NeverCalled;
        }
    };

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .sources = &.{} });
    try testing.expectEqual(8080, config.port);
    try testing.expectError(error.NeverCalled, Config.validate(config));
}

test "a secret loads like a string and prints as [REDACTED]" {
    const Config = struct {
        db: struct {
            password: confy.Secret,
            api_token: ?confy.Secret = null,
        },
    };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_DB_PASSWORD", "change-me");

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} });
    defer confy.free(testing.allocator, config);
    try testing.expectEqualStrings("change-me", config.db.password.expose());
    try testing.expect(config.db.api_token == null);

    const printed = try std.fmt.allocPrint(testing.allocator, "{f} {any}", .{ config.db.password, config });
    defer testing.allocator.free(printed);
    try testing.expect(std.mem.startsWith(u8, printed, "[REDACTED] "));
    try testing.expect(std.mem.find(u8, printed, "change-me") == null);
}
