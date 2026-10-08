# Environment variables

The environment of the running process is how deployments configure a program:
containers, CI jobs and service managers all set variables. List `.osEnv()`
last, and every variable overrides whatever the files say.

```zig
.environ = init.environ_map,
.env_prefix = "APP_",
.sources = &.{.osEnv()},
```

## Contents

- [At a glance](#at-a-glance)
- [Options](#options)
- [Variable names](#variable-names)
- [Values](#values)
- [Required fields](#required-fields)
- [Setting variables](#setting-variables)
- [Combining with files](#combining-with-files)
- [Testing](#testing)
- [Problems](#problems)
- [Limits](#limits)

## At a glance

A struct where every field has a default runs without any variables, and each
variable overrides one field:

**`main.zig`**

```zig
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
```

| You run                                                      | You get                                         |
| ------------------------------------------------------------ | ----------------------------------------------- |
| `./app`                                                      | every field at its default                      |
| `APP_HTTP_PORT=9090 ./app`                                   | `http.port = 9090`                              |
| `APP_LOG_LEVEL=warn APP_DEBUG=1 ./app`                       | `log_level = .warn`, `debug = true`             |
| `APP_HTTP_ALLOWED_ORIGINS=https://a.com,https://b.com ./app` | two origins; the default list is replaced       |
| `APP_DB_PASSWORD=change-me ./app`                            | `db.password` is set; it prints as `[redacted]` |
| `APP_DB_POOL_SIZE=16 ./app`                                  | `db.pool.size = 16`, `max_idle` stays 2         |

## Options

| Option        | Meaning                                               |
| ------------- | ----------------------------------------------------- |
| `.environ`    | the variables to read; in `main`, `init.environ_map`  |
| `.env_prefix` | put in front of every variable name, such as `"APP_"` |

`.osEnv()` reads from `.environ`, so the two go together. Without `.environ`,
`load` stops the program with
`confy: the .osEnv() source needs Options.environ`.

> [!WARNING]
> Always set a prefix. The environment is shared with the shell and every other
> program: without a prefix, a field named `path`, `home`, `user` or `lang` reads
> `PATH`, `HOME`, `USER` or `LANG`, and `debug` reads whatever `DEBUG` some tool
> left behind.

## Variable names

A variable is named after the field's path: `env_prefix`, then the field names
upper-cased and joined with `_`:

| Field                  | Variable                   |
| ---------------------- | -------------------------- |
| `name`                 | `APP_NAME`                 |
| `http.port`            | `APP_HTTP_PORT`            |
| `http.allowed_origins` | `APP_HTTP_ALLOWED_ORIGINS` |
| `db.password`          | `APP_DB_PASSWORD`          |
| `db.pool.max_idle`     | `APP_DB_POOL_MAX_IDLE`     |

- confy looks up exactly these names. Every other variable is ignored,
  misspelled ones included.
- The prefix is put in front as is: `"APP_"`, not `"APP"`.
- On Linux and macOS names are case-sensitive: `app_http_port` is not
  `APP_HTTP_PORT`. On Windows, as in the system itself, case doesn't matter.
- Two fields that would get the same name, like `db_port` and `db.port`, are a
  compile error.

## Values

Every value is text, which confy parses into the field's type:

| Field type     | You set                                      | You get                                                      |
| -------------- | -------------------------------------------- | ------------------------------------------------------------ |
| `[]const u8`   | `APP_NAME=zefir`                             | `"zefir"`                                                    |
| `[]const u8`   | `APP_NAME=`                                  | `""`                                                         |
| `u16`          | `APP_HTTP_PORT=9090`                         | `9090`                                                       |
| `u16`          | `APP_HTTP_PORT=http`                         | problem: `invalid (expected an integer 0..65535)`            |
| `u16`          | `APP_HTTP_PORT=`                             | problem: `invalid (expected an integer 0..65535)`            |
| `f32`          | `APP_HTTP_TIMEOUT_S=2.5`                     | `2.5`                                                        |
| `bool`         | `APP_DEBUG=true`, `yes`, `on`, `1`, any case | `true`                                                       |
| `bool`         | `APP_DEBUG=false`, `no`, `off`, `0`          | `false`                                                      |
| `enum`         | `APP_LOG_LEVEL=warn`                         | `.warn`                                                      |
| `enum`         | `APP_LOG_LEVEL=WARN`                         | problem: `invalid (expected one of: debug, info, warn, err)` |
| `confy.Secret` | `APP_DB_PASSWORD=change-me`                  | a secret                                                     |
| `[]const T`    | `APP_PORTS=80,443` or `APP_PORTS=80, 443`    | `{ 80, 443 }`                                                |
| `[]const T`    | `APP_PORTS=`                                 | `{}`: an empty list                                          |
| `?T`           | variable not set                             | `null`, or the default                                       |

The value is used as it is: the shell has already removed any quotes. An item
of a list can't contain a comma, and a list of structs can't come from a
variable; put it in a [JSON](json.md#lists-of-objects) file.

> [!NOTE]
> A variable set to an empty value is still set: `APP_NAME=` makes `name` an
> empty string, it doesn't bring the default back. Unset the variable instead.

## Required fields

A field without a default must come from some source. When none sets it, the
problem names the variable to set:

```text
error(confy): 1 configuration problem:
  name: missing (set APP_NAME)
```

When files are listed too, the hint names both places:

```text
db.url: missing (set APP_DB_URL, or "db.url" in a config file)
```

## Setting variables

### Shell

```sh
APP_HTTP_PORT=9090 ./app        # for one run
export APP_HTTP_PORT=9090       # for the rest of the session
```

### Docker Compose

```yaml
services:
  app:
    image: app
    environment:
      APP_HTTP_PORT: "9090"
      APP_LOG_LEVEL: warn
      APP_DEBUG: "false"
```

Quote numbers and booleans in YAML, so they reach the program as written.

### Kubernetes

```yaml
containers:
  - name: app
    image: app
    env:
      - name: APP_HTTP_PORT
        value: "9090"
      - name: APP_DB_PASSWORD
        valueFrom:
          secretKeyRef:
            name: app-secrets
            key: db-password
```

### systemd

```ini
[Service]
Environment=APP_HTTP_PORT=9090 APP_LOG_LEVEL=warn
EnvironmentFile=/etc/app/app.env
```

## Combining with files

List `.osEnv()` after the files, so the deployment has the last word:

```zig
.sources = &.{ .json("config.json"), .env(".env"), .osEnv() },
```

A variable then overrides the same field from any file, and a field the
environment doesn't mention keeps the value from the files. See
[several_sources.md](several_sources.md).

## Testing

`.environ` takes any `std.process.Environ.Map`, so a test passes exactly the
variables it wants instead of the real environment:

```zig
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
```

## Problems

```sh
APP_DEBUG=maybe APP_HTTP_PORT=http ./app
```

```text
error(confy): 2 configuration problems:
  environment: APP_DEBUG: invalid (expected true or false)
  environment: APP_HTTP_PORT: invalid (expected an integer 0..65535)
```

A problem with a value from the environment starts with `environment:` and
names the variable, not the field. Problems never contain the value itself.

## Limits

- Lists can't contain commas in their items, and lists of structs need JSON.
- No `null`: unset the variable instead.
- Misspelled variables are ignored, not reported.

See also: [JSON](json.md) · [INI](ini.md) · [.env](dotenv.md) ·
[Several sources](several_sources.md) · [Overview](README.md)
