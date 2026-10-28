//! The tests of several_sources.md: how its layers combine, the values of
//! its complete example and of each change to it, the problems across its
//! sources, and its recipes. `Config` is the struct of several_sources.zig,
//! the program of the page.

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

const base_json = @embedFile("testdata/several_sources/sources/base.json");
const production_ini = @embedFile("testdata/several_sources/sources/production.ini");
const dot_env = @embedFile("testdata/several_sources/sources/.env");

test "objects merge key by key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "config/base.json", @embedFile("testdata/merge/config/base.json") },
        .{ "config/production.ini", @embedFile("testdata/merge/config/production.ini") },
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_NAME", "zefir-demo");
    try environ.put("APP_HTTP_PORT", "8080");
    try environ.put("APP_DB_PASSWORD", "change-me");

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{
        .io = testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .sources = &.{
            .json("config/base.json"),
            .ini("config/production.ini"),
            .env(".env"),
            .env(".env.local"),
            .osEnv(),
        },
    });
    defer confy.free(testing.allocator, config);

    try testing.expectEqualStrings("postgres://localhost:5432/app", config.db.url);
    try testing.expectEqual(16, config.db.pool.size);
}

/// The sources of the program, which outlive every load: a container-level
/// constant, made when the test compiles.
const program_sources = [_]confy.ConfigSource{
    .json("base.json"),
    .ini("production.ini"),
    .env(".env"),
    .env(".env.local"),
    .osEnv(),
};

/// The files of the complete example, written into a temporary directory,
/// and the variables of a run.
const Layers = struct {
    tmp: testing.TmpDir,
    environ: std.process.Environ.Map,

    fn init(files: []const [2][]const u8) !Layers {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try fixture.write(tmp.dir, files);
        return .{ .tmp = tmp, .environ = .init(testing.allocator) };
    }

    fn deinit(layers: *Layers) void {
        layers.environ.deinit();
        layers.tmp.cleanup();
    }

    /// The options of the program: its sources, in its directory.
    fn options(layers: *Layers) confy.Options {
        return .{
            .io = testing.io,
            .environ = &layers.environ,
            .env_prefix = "APP_",
            .dir = layers.tmp.dir,
            .sources = &program_sources,
        };
    }

    fn load(layers: *Layers) !Config {
        var config: Config = undefined;
        try confy.load(testing.allocator, &config, layers.options());
        return config;
    }
};

const example_files = [_][2][]const u8{
    .{ "base.json", base_json },
    .{ "production.ini", production_ini },
    .{ ".env", dot_env },
};

test "the complete example gives the values of its table" {
    var layers: Layers = try .init(&example_files);
    defer layers.deinit();
    const config = try layers.load();
    defer confy.free(testing.allocator, config);

    try testing.expectEqualStrings("zefir-demo", config.name);
    try testing.expect(!config.debug);
    try testing.expectEqual(.warn, config.log_level);
    try testing.expectEqual(8443, config.http.port);
    try testing.expectEqual(10, config.http.timeout_s);
    try testing.expectEqual(2, config.http.allowed_origins.len);
    try testing.expectEqualStrings("https://app.example.com", config.http.allowed_origins[0]);
    try testing.expectEqualStrings("https://admin.example.com", config.http.allowed_origins[1]);
    try testing.expectEqualStrings("postgres://db.internal:5432/app", config.db.url);
    try testing.expectEqualStrings("change-me", config.db.password.expose());
    try testing.expectEqualDeep(@as(?[]const u8, "postgres://replica.internal:5432/app"), config.db.replica_url);
    try testing.expectEqual(16, config.db.pool.size);
    try testing.expectEqual(2, config.db.pool.max_idle);
}

test "each change of the play table gives its value" {
    {
        var layers: Layers = try .init(&example_files);
        defer layers.deinit();
        try layers.environ.put("APP_HTTP_PORT", "9090");
        try layers.environ.put("APP_LOG_LEVEL", "debug");
        try layers.environ.put("APP_HTTP_ALLOWED_ORIGINS", "https://a.com,https://b.com");
        const config = try layers.load();
        defer confy.free(testing.allocator, config);
        try testing.expectEqual(9090, config.http.port);
        try testing.expectEqual(.debug, config.log_level);
        try testing.expectEqual(2, config.http.allowed_origins.len);
        try testing.expectEqualStrings("https://a.com", config.http.allowed_origins[0]);
    }
    {
        var layers: Layers = try .init(&(example_files ++ [_][2][]const u8{.{ ".env.local", "APP_HTTP_PORT=7000\n" }}));
        defer layers.deinit();
        const local = try layers.load();
        defer confy.free(testing.allocator, local);
        try testing.expectEqual(7000, local.http.port);

        try layers.environ.put("APP_HTTP_PORT", "9090");
        const both = try layers.load();
        defer confy.free(testing.allocator, both);
        try testing.expectEqual(9090, both.http.port);
    }
    {
        const without_password = try fixture.edit(dot_env, "APP_DB_PASSWORD=change-me", "");
        defer testing.allocator.free(without_password);
        var layers: Layers = try .init(&.{ example_files[0], example_files[1], .{ ".env", without_password } });
        defer layers.deinit();
        try fixture.expectLoadProblems(Config, layers.options(),
            \\1 configuration problem:
            \\  db.password: missing (set APP_DB_PASSWORD, or "db.password" in a config file)
        );
    }
    {
        const with_debug = try fixture.edit(base_json, "\"name\": \"zefir-demo\",", "\"name\": \"zefir-demo\", \"debug\": true,");
        defer testing.allocator.free(with_debug);
        var layers: Layers = try .init(&.{ .{ "base.json", with_debug }, example_files[1], example_files[2] });
        defer layers.deinit();
        const config = try layers.load();
        defer confy.free(testing.allocator, config);
        try testing.expect(config.debug);
    }
}

test "a value is checked only in the layer that wins" {
    const bad_port = try fixture.edit(base_json, "\"port\": 8080", "\"port\": 70000");
    defer testing.allocator.free(bad_port);
    var layers: Layers = try .init(&.{ .{ "base.json", bad_port }, example_files[1], example_files[2] });
    defer layers.deinit();
    const config = try layers.load();
    defer confy.free(testing.allocator, config);
    try testing.expectEqual(8443, config.http.port);
}

test "problems from every source are reported together" {
    const base = try fixture.edit(base_json, "\"log_level\"", "\"log_levl\"");
    defer testing.allocator.free(base);
    const production = try fixture.edit(production_ini, "pool.size = 16", "pool.size = 300");
    defer testing.allocator.free(production);
    const env = try fixture.edit(dot_env, "APP_HTTP_PORT=8443", "APP_HTTP_PORT=http");
    defer testing.allocator.free(env);

    var layers: Layers = try .init(&.{ .{ "base.json", base }, .{ "production.ini", production }, .{ ".env", env } });
    defer layers.deinit();
    try fixture.expectLoadProblems(Config, layers.options(), cases.problems.across_sources.text);
}

test "a JSON null takes out what an earlier source set" {
    const Port = struct { port: u16 = 5432 };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "config.ini", "port = 6000\n" },
        .{ "override.json", "{ \"port\": null }" },
    });

    var config: Port = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.ini("config.ini")} });
    try testing.expectEqual(6000, config.port);
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{ .ini("config.ini"), .json("override.json") } });
    try testing.expectEqual(5432, config.port);
}

test "a missing JSON or INI file is a problem, a missing .env file is skipped" {
    const Port = struct { port: u16 = 5432 };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var config: Port = undefined;
    try confy.load(testing.allocator, &config, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{.env(".env")} });
    try fixture.expectLoadProblems(Port, .{ .io = testing.io, .dir = tmp.dir, .sources = &.{ .json("config/base.json"), .ini("config/staging.ini") } },
        \\2 configuration problems:
        \\  config/base.json: cannot read file (file not found)
        \\  config/staging.ini: cannot read file (file not found)
    );
}

test "personal overrides in .env.local win over .env" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture.write(tmp.dir, &.{
        .{ "config.json", base_json },
        .{ ".env", dot_env },
        .{ ".env.local", "APP_HTTP_PORT=7000\n" },
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    var config: Config = undefined;
    try confy.load(testing.allocator, &config, .{
        .io = testing.io,
        .environ = &environ,
        .env_prefix = "APP_",
        .dir = tmp.dir,
        .sources = &.{ .json("config.json"), .env(".env"), .env(".env.local"), .osEnv() },
    });
    defer confy.free(testing.allocator, config);
    try testing.expectEqual(7000, config.http.port);
}

/// The recipe of an optional file, as `main` would run it. Only built: it
/// reads the working directory, and exits when the configuration is wrong.
fn loadWithOptionalFile(init: std.process.Init) !Config {
    var config: Config = undefined;
    const arena = init.arena.allocator();

    var sources: std.ArrayList(confy.ConfigSource) = .empty;
    try sources.append(arena, .json("config/base.json"));
    if (std.Io.Dir.cwd().access(init.io, "config/local.json", .{})) {
        try sources.append(arena, .json("config/local.json"));
    } else |_| {}
    try sources.append(arena, .osEnv());

    confy.loadOrExit(arena, &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = sources.items,
    });
    return config;
}

/// The recipe of a file per environment, as `main` would run it. Only
/// built, as the one above.
fn loadForEnvironment(init: std.process.Init) !Config {
    var config: Config = undefined;
    const arena = init.arena.allocator();

    // APP_ENV names the environment; confy reads it as any setting.
    const Environment = struct { env: enum { development, staging, production } = .development };
    var environment: Environment = undefined;
    confy.loadOrExit(arena, &environment, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    const env_file = try std.fmt.allocPrint(arena, "config/{t}.ini", .{environment.env});

    confy.loadOrExit(arena, &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{ .json("config/base.json"), .ini(env_file), .env(".env"), .osEnv() },
    });
    return config;
}

test "the recipes build" {
    _ = &loadWithOptionalFile;
    _ = &loadForEnvironment;
}

test "a typo in APP_ENV is a problem of the first load" {
    const Environment = struct { env: enum { development, staging, production } = .development };

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("APP_ENV", "stagign");

    try fixture.expectLoadProblems(Environment, .{ .io = testing.io, .environ = &environ, .env_prefix = "APP_", .sources = &.{.osEnv()} },
        \\1 configuration problem:
        \\  environment: APP_ENV: invalid (expected one of: development, staging, production)
    );
}
