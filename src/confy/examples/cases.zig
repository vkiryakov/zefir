//! The examples of the confy guide: README.md and its pages on the
//! sources, dotenv.md, env.md, ini.md, json.md and several_sources.md.
//! build.zig builds and runs the programs, runs the tests and compiles the
//! code that must not compile; readme_test.zig checks that every page shows
//! its files as they are, every run as it printed, every problem and
//! compile error as confy gives it, and no Zig code that is not a part of
//! these files.

/// The pages of the guide.
pub const pages = [_][]const u8{ "README.md", "dotenv.md", "env.md", "ini.md", "json.md", "several_sources.md" };

/// A run of a program: `$ NAME=value ... zig build run`.
pub const Run = struct {
    /// The variables it sets, as the command shows them.
    env: []const [2][]const u8 = &.{},
    /// Its exit code: 1 when confy finds problems in the configuration.
    exit: u8 = 0,
};

/// A program of the guide. It logs with std.log, which writes to stderr,
/// as `loadOrExit` does with the problems it finds.
pub const Program = struct {
    /// The file, without `.zig`.
    name: []const u8,
    /// The page that shows it whole, and each run after it.
    page: []const u8,
    /// The directory under testdata/ that its runs work in, as `zig build
    /// run` works next to build.zig; null when it reads no file.
    dir: ?[]const u8 = null,
    /// The files it reads there, which its page shows whole.
    files: []const []const u8 = &.{},
    runs: []const Run,
};

/// The programs: `zig build test-confy` runs each of them once per run.
pub const programs = [_]Program{
    .{
        .name = "minute",
        .page = "README.md",
        .dir = "minute",
        .files = &.{ "config.json", ".env" },
        .runs = &.{
            .{},
            .{ .env = &.{.{ "APP_HTTP_PORT", "9090" }} },
            .{ .env = &.{.{ "APP_HTTP_PORT", "90000" }}, .exit = 1 },
        },
    },
    .{
        .name = "environment",
        .page = "env.md",
        .runs = &.{
            .{},
            .{ .env = &.{.{ "APP_HTTP_PORT", "9090" }} },
            .{ .env = &.{ .{ "APP_DEBUG", "maybe" }, .{ "APP_HTTP_PORT", "http" } }, .exit = 1 },
        },
    },
    .{
        .name = "several_sources",
        .page = "several_sources.md",
        .dir = "several_sources",
        .files = &.{ "sources/base.json", "sources/production.ini", "sources/.env" },
        .runs = &.{
            .{},
            .{ .env = &.{.{ "APP_HTTP_PORT", "9090" }} },
        },
    },
};

/// The programs that README.md at the root of the repository shows too,
/// with their files and runs: its "confy in a minute".
pub const root_readme = [_][]const u8{"minute"};

/// The tests: each holds the structs and the code of a page, loads the
/// files the page shows, and checks the values and the problems the page
/// says they give.
pub const tests = [_][]const u8{
    "overview_test",
    "struct_test",
    "dotenv_test",
    "env_test",
    "ini_test",
    "json_test",
    "several_sources_test",
};

/// The tests that hold a copy of the `Config` of a program, which
/// readme_test.zig checks against the program's own.
pub const config_copies = [_][2][]const u8{
    .{ "overview_test", "minute" },
    .{ "env_test", "environment" },
    .{ "several_sources_test", "several_sources" },
};

/// A file under testdata/ that a page shows whole, and a test loads.
pub const Fixture = struct {
    page: []const u8,
    path: []const u8,
};

pub const fixtures = [_]Fixture{
    .{ .page = "README.md", .path = "problems/config.json" },
    .{ .page = "README.md", .path = "problems/.env" },
    .{ .page = "dotenv.md", .path = "dotenv/glance/.env" },
    .{ .page = "dotenv.md", .path = "dotenv/problems/.env" },
    .{ .page = "ini.md", .path = "ini/glance/config.ini" },
    .{ .page = "ini.md", .path = "ini/problems/config.ini" },
    .{ .page = "json.md", .path = "json/glance/config.json" },
    .{ .page = "json.md", .path = "json/problems/config.json" },
    .{ .page = "json.md", .path = "json/syntax/config.json" },
    .{ .page = "several_sources.md", .path = "merge/config/base.json" },
    .{ .page = "several_sources.md", .path = "merge/config/production.ini" },
};

/// Code that must not compile: a file of compile_errors/, and the message
/// it fails with. The build compiles each and expects the message; the
/// page shows the message after the code.
pub const CompileError = struct {
    /// The file under compile_errors/, without `.zig`.
    name: []const u8,
    page: []const u8,
    expect: []const u8,
};

pub const compile_errors = [_]CompileError{
    .{
        .name = "unsupported_type",
        .page = "README.md",
        .expect = "confy: fields of type [4]u8 are not supported; use bool, an integer, a float, an enum, []const u8, confy.Secret, a []const slice of these, a struct, or an optional of any of them",
    },
    .{
        .name = "same_variable",
        .page = "README.md",
        .expect = "confy: fields 'db_port' and 'db.port' both map to the environment variable DB_PORT",
    },
};

/// Problems that a page shows: what `{f}` of confy.Diagnostics writes
/// after a load that a test of the page makes.
pub const Problems = struct {
    page: []const u8,
    /// Whether the page shows them as `loadOrExit` logs them, after
    /// `error(confy): `.
    logged: bool = true,
    text: []const u8,
};

pub const problems = struct {
    pub const required: Problems = .{ .page = "README.md", .text =
        \\1 configuration problem:
        \\  db.url: missing (set APP_DB_URL, or "db.url" in a config file)
    };
    pub const validate: Problems = .{ .page = "README.md", .text =
        \\1 configuration problem:
        \\  invalid (validate() returned error.MaxIdleAbovePoolSize)
    };
    pub const broken_files: Problems = .{ .page = "README.md", .text =
        \\4 configuration problems:
        \\  .env:2: APP_LOG_LEVEL: invalid (expected one of: debug, info, warn, err)
        \\  config.json:2: http.port: invalid (expected an integer 0..65535)
        \\  db.url: missing (set APP_DB_URL, or "db.url" in a config file)
        \\  config.json:3: db.ulr: unknown key (did you mean "url"?)
    };
    pub const dotenv: Problems = .{ .page = "dotenv.md", .text =
        \\7 configuration problems:
        \\  .env:4: APP_DB_URL: syntax error (unterminated quote)
        \\  .env:5: APP_NAME: duplicate key (first set on line 1)
        \\  .env:6: syntax error (expected KEY=value)
        \\  .env:3: APP_DEBUG: invalid (expected true or false)
        \\  .env:2: APP_HTTP_PORT: invalid (expected an integer 0..65535)
        \\  db.url: missing (set APP_DB_URL)
        \\  db.password: missing (set APP_DB_PASSWORD)
    };
    pub const env_name: Problems = .{ .page = "env.md", .text =
        \\1 configuration problem:
        \\  name: missing (set APP_NAME)
    };
    pub const env_files: Problems = .{ .page = "env.md", .text =
        \\1 configuration problem:
        \\  db.url: missing (set APP_DB_URL, or "db.url" in a config file)
    };
    pub const ini: Problems = .{ .page = "ini.md", .text =
        \\5 configuration problems:
        \\  config.ini:6: http.port: duplicate key (first set on line 5)
        \\  config.ini:2: log_level: invalid (expected one of: debug, info, warn, err)
        \\  config.ini:5: http.port: invalid (expected an integer 0..65535)
        \\  config.ini:11: db.pool.size: invalid (expected an integer 0..255)
        \\  config.ini:12: db.replica_ur: unknown key (did you mean "replica_url"?)
    };
    pub const json: Problems = .{ .page = "json.md", .text =
        \\5 configuration problems:
        \\  name: missing (set "name" in a config file)
        \\  config.json:3: log_level: invalid (expected one of: debug, info, warn, err)
        \\  config.json:4: http.port: invalid (expected an integer 0..65535)
        \\  config.json:5: db.password: invalid (expected a string)
        \\  config.json:2: nmae: unknown key (did you mean "name"?)
    };
    pub const json_syntax: Problems = .{ .page = "json.md", .text =
        \\5 configuration problems:
        \\  config.json:3: syntax error (invalid JSON)
        \\  name: missing (set "name" in a config file)
        \\  http.port: missing (set "http.port" in a config file)
        \\  db.url: missing (set "db.url" in a config file)
        \\  db.password: missing (set "db.password" in a config file)
    };
    pub const across_sources: Problems = .{ .page = "several_sources.md", .logged = false, .text =
        \\3 configuration problems:
        \\  .env:2: APP_HTTP_PORT: invalid (expected an integer 0..65535)
        \\  production.ini:13: db.pool.size: invalid (expected an integer 0..255)
        \\  base.json:3: log_levl: unknown key (did you mean "log_level"?)
    };
};

/// Every block of problems of the pages.
pub const shown_problems = [_]Problems{
    problems.required,
    problems.validate,
    problems.broken_files,
    problems.dotenv,
    problems.env_name,
    problems.env_files,
    problems.ini,
    problems.json,
    problems.json_syntax,
    problems.across_sources,
};

/// The command a page shows for `run`.
pub fn command(comptime run: Run) []const u8 {
    comptime var line: []const u8 = "$ ";
    inline for (run.env) |pair| line = line ++ pair[0] ++ "=" ++ pair[1] ++ " ";
    return line ++ "zig build run";
}

/// The language of the block that shows the file `path`: json, ini, or sh
/// for a `.env` file.
pub fn language(comptime path: []const u8) []const u8 {
    if (endsWith(path, ".json")) return "json";
    if (endsWith(path, ".ini")) return "ini";
    return "sh";
}

fn endsWith(comptime text: []const u8, comptime suffix: []const u8) bool {
    return text.len >= suffix.len and comptimeEql(text[text.len - suffix.len ..], suffix);
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
