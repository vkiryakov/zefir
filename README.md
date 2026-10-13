<h1 align="center">
  <img src="logo.png" alt="Zefir" width="400">
</h1>

<p align="center">
  <strong>A modular framework for building services in Zig.</strong><br>
  Web servers, web services and APIs, built from modules you pick: typed configuration, request deadlines, cancellation, tracing, structured logging and validation today; RPC, an ORM and an HTTP server next.
</p>

<p align="center">
  <a href="https://github.com/vkiryakov/zefir/actions/workflows/ci.yml"><img src="https://github.com/vkiryakov/zefir/actions/workflows/ci.yml/badge.svg?branch=dev" alt="CI"></a>
  <a href="https://github.com/vkiryakov/zefir/releases/latest"><img src="https://img.shields.io/github/v/release/vkiryakov/zefir?label=release" alt="Latest release"></a>
  <a href="https://ziglang.org/download/"><img src="https://img.shields.io/badge/Zig-0.17.0-f7a41d?logo=zig&logoColor=white" alt="Zig 0.17.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

## Why Zefir exists

I'm writing a large application in Zig, and I'm building it on Zefir, the framework I make for it along the way. Every module is here because that application needed it, and some of them already run in its production code.

Life is too short to write in a boring language, and I think Zig is a really cool one.

Zig is still young. Each release reshapes the language and its standard library, and many Zig projects don't survive that: they start with enthusiasm and are abandoned a release or two later. It's not that I think I'm smarter than their authors; in fact, I borrowed plenty of ideas from existing projects. I just don't want my production code to depend on code that may be abandoned, or that catches up with a new Zig months late. So I'm building the whole stack myself and keeping it on the current Zig.

Maybe that's a bad idea. But building it gives me more joy than I can put into words: I write this code for myself, and I'm having a lot of fun doing it. Zefir is in active development, and new modules arrive as the application needs them.

Every module stands on its own: take only the ones you need, with your own types as the schema and errors that say exactly what's wrong and where.

Zefir is shaped by my needs first, and it's open to everyone. If it fits the way you work, use it. Found a bug? Open an [issue](https://github.com/vkiryakov/zefir/issues). Ideas and questions are welcome in [Discussions](https://github.com/vkiryakov/zefir/discussions), and so are pull requests.

## Highlights

- **Built for services.** Zefir is growing into the layers every web service needs: configuration, deadlines and tracing, validation, RPC, logging, database access and HTTP.
- **Take only what you use.** Every module is its own import, and the umbrella `zefir` module brings them all together.
- **Your types are the contract.** Declare a struct, and confy fills it and checks every value against its field's type. It reports every problem at once, each pointing at the file and line, or the variable, it came from.
- **No dependencies.** Pure Zig on top of the standard library; nothing else to fetch or audit.
- **Tested on Linux, macOS and Windows.** CI runs the tests of every module on all three.

## Modules

| Module             | Import name       | What it does                                                         | Status                                            |
| ------------------ | ----------------- | -------------------------------------------------------------------- | ------------------------------------------------- |
| **confy**          | `zefir-confy`     | Typed configuration from JSON, INI, `.env` files and the environment | ✅ Done · [docs](src/confy/examples/README.md)     |
| **core**           | `zefir-core`      | Execution context: deadlines, cancellation and W3C trace context     | ✅ Done · [docs](src/core/examples/README.md)      |
| **log**            | `zefir-log`       | Structured logging: JSON Lines, redaction, live levels, alerts       | ✅ Done · [docs](src/log/examples/README.md)       |
| **validator**      | `zefir-validator` | Declarative validation rules for struct fields                       | ✅ Done · [docs](src/validator/examples/README.md) |
| nats               | `zefir-nats`      | Core NATS client: publish/subscribe, request/reply, reconnect        | 🚧 In progress                                     |
| rpc                | `zefir-rpc`       | RPC                                                                  | 📋 Planned                                         |
| orm                | `zefir-orm`       | ORM                                                                  | 📋 Planned                                         |
| http               | —                 | HTTP server                                                          | 📋 Planned                                         |
| _all of the above_ | `zefir`           | Umbrella module                                                      |                                                   |

> [!NOTE]
> Zefir is in early development. Until 1.0, any minor release may change the API.

## confy in a minute

Declare the configuration and load it at the start of `main`:

```zig
const std = @import("std");
const confy = @import("confy");

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

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{ .json("config.json"), .env(".env"), .osEnv() },
    });

    std.log.info("listening on port {d}, database {s}", .{ config.http.port, config.db.url });
}
```

With `http.port` and `db.url` in `config.json`, and `APP_DB_PASSWORD` in `.env`:

```text
$ zig build run
info: listening on port 8080, database postgres://localhost:5432/app

$ APP_HTTP_PORT=9090 zig build run
info: listening on port 9090, database postgres://localhost:5432/app

$ APP_HTTP_PORT=90000 zig build run
error(confy): 1 configuration problem:
  environment: APP_HTTP_PORT: invalid (expected an integer 0..65535)
```

The environment overrides the files, a bad value stops the program before it does anything, and `confy.Secret` prints as `[REDACTED]`. **[Read the confy guide →](src/confy/examples/README.md)**

## core in a minute

Give a request a deadline and a cancellation token, pass the context down by value, and check it before work:

```zig
const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init) !void {
    // The request owns the token; contexts only point to it.
    var token: core.CancellationToken = .init;
    const ctx = core.Context.root
        .withDeadline(.after(std.Io.Clock.awake.now(init.io), .fromMilliseconds(500)))
        .withCancellation(&token);

    const name = try findUser(ctx, init.io, 42);
    std.log.info("user 42 is {s}", .{name});
}

fn findUser(ctx: core.Context, io: std.Io, id: u64) ![]const u8 {
    try ctx.check(std.Io.Clock.awake.now(io)); // error.Cancelled or error.DeadlineExceeded
    return if (id == 42) "Ada" else error.UserNotFound;
}
```

Cancel the token when the client goes away, and every check below fails with `error.Cancelled`; once the deadline passes, they fail with `error.DeadlineExceeded`. `core.w3c` reads and writes the W3C `traceparent` and `tracestate` headers, and nothing in core allocates, reads a clock or does I/O. **[Read the core guide →](src/core/examples/README.md)**

## log in a minute

Create the logger at the start of `main`, then log constant messages with named fields:

```zig
const std = @import("std");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    const logger: log.Logger = try .init(init.gpa, init.io, .{
        .service = .{ .name = "user-service", .version = "1.0.0" },
    });
    defer logger.deinit();

    const users = logger.scoped("users");
    users.info("User created", .{ .user_id = 42, .email = "ada@example.com", .password = "hunter2" });
}
```

```json
{"timestamp":"2026-10-12T09:41:07.415Z","level":"info","message":"User created","service.name":"user-service","service.version":"1.0.0","scope":"users","user_id":42,"email":"ada@example.com","password":"[REDACTED]"}
```

Every record is one line of JSON on stdout, ready for a log collector. The fields are checked when the program compiles, secrets come out as `[REDACTED]`, levels change while the service runs, and a queued mode keeps stdout off the request path. **[Read the log guide →](src/log/examples/README.md)**

## Installation

Requires **Zig 0.17.0**. Add the dependency to your `build.zig.zon`; the latest release is **v0.4.0**:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#v0.4.0
```

Other versions are on the [releases page](https://github.com/vkiryakov/zefir/releases); a commit hash works too.

Then import the modules you need in your `build.zig`:

```zig
const zefir = b.dependency("zefir", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            // a single module...
            .{ .name = "confy", .module = zefir.module("zefir-confy") },
            // ...or everything at once
            .{ .name = "zefir", .module = zefir.module("zefir") },
        },
    }),
});
```

And use them in code:

```zig
const confy = @import("confy");
const zefir = @import("zefir"); // zefir.confy, zefir.core, ...
```

## Development

```sh
zig build test --summary all                                                     # run all tests
zig build test-log --summary all                                                 # run one module's tests: test-core, test-log, …
zig fmt --check build.zig build.zig.zon src tests --exclude tests/nats/zig-pkg   # check formatting
```

CI tests a pull request only on the modules it affects. A change under `src/<module>/` runs the tests of that module, of every module that depends on it and of `zefir`; a change to `build.zig`, `build.zig.zon`, `src/zefir.zig` or `.github/` runs them all, and documentation outside `src/` runs none. Every push to `dev` and `main` tests all modules. The module graph for this is in `.github/scripts/affected-modules.sh`: a new module goes there as well as into `build.zig`.

The end-to-end tests of nats run against real NATS servers in Docker, described by `docker-compose.yml` at the repository root. The tests are a package of their own in `tests/nats`, so zio, the runtime they use, never reaches zefir's users:

```sh
docker compose up -d --wait   # start the servers, from the repository root
cd tests/nats
zig build e2e                 # start the servers if needed, then run the tests
zig build down                # stop the servers
```

`zig build down` also resets the servers when a run dies half way, say while a test holds one of them paused. CI runs these tests whenever it tests nats; a change to `tests/nats/` or `docker-compose.yml` counts as a change to nats.

Branches:

- `dev` — the default branch and the next version in progress: its `.version` in `build.zig.zon` is that version with `-dev`, such as `0.2.0-dev`. Every change lands here first, through a squash-merged pull request.
- `feature/<name>` — new functionality; `chore/<name>` — docs, CI, tooling and other maintenance. Both are created from `dev` and merged back into it; a big feature goes in as several smaller pull requests.
- `main` — releases only. A release is a pull request from `dev`, merged with a merge commit and tagged `vX.Y.Z`.
- `hotfix/<name>` — an urgent fix for the latest release: created from `main`, merged into it as a patch release such as `v0.1.1`, and then brought to `dev` as well.

## License

[MIT](LICENSE)
