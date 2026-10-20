<h1 align="center">
  <img src="logo.png" alt="Zefir" width="400">
</h1>

<p align="center">
  <strong>A modular framework for building services in Zig.</strong><br>
  Web servers, web services and APIs, built from modules you pick: typed configuration, request deadlines, cancellation, tracing, structured logging, validation, a NATS client, RPC and an HTTP server today; an async MongoDB driver with an ODM next.
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
- **Not limited to what ships.** Where a module meets the outside world, it goes through an interface, a pointer to your object and its function pointers, as `std.Io` does, and an implementation of your own takes the place of zefir's: a transport of rpc (`rpc.ClientTransport` and `rpc.ServerTransport`, which every `rpc.Server` and `rpc.Client` is given: zefir ships NATS, and [your own](src/rpc-nats/examples/writing-a-transport.md) lives in a package of its own), `rpc_nats.Conn` for another NATS library, and the `std.Io.Writer` that zefir-log writes to (`.output = .{ .writer = … }`). Middleware, authenticators and credentials providers of your own join the calls of rpc the same way.
- **Your types are the contract.** Declare a struct, and confy fills it and checks every value against its field's type. It reports every problem at once, each pointing at the file and line, or the variable, it came from.
- **No dependencies.** Pure Zig on top of the standard library; nothing else to fetch or audit.
- **Tested on Linux, macOS and Windows.** CI runs the tests of every module on all three.

## Modules

Take any module on its own, or all the finished ones at once through the umbrella module `zefir`.

| Module                             | What it does                                                                                               | Status                                                  |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| **Core & Foundation**              |                                                                                                            |                                                         |
| `zefir-core`                       | Execution context: deadlines, cancellation, W3C trace context; application container and lifecycle planned | ✅ Done · [docs](src/core/examples/README.md)            |
| `zefir-confy`                      | Typed configuration: JSON, INI, `.env` files, environment variables, secrets                               | ✅ Done · [docs](src/confy/examples/README.md)           |
| `zefir-log`                        | Structured logging: JSON Lines, levels, context, redaction                                                 | ✅ Done · [docs](src/log/examples/README.md)             |
| `zefir-validator`                  | Typed schemas, validation rules, API field names, input normalization (trim, case), error reporting        | ✅ Done · [docs](src/validator/examples/README.md)       |
| `zefir-events`                     | Typed in-process event bus                                                                                 | 📋 Planned                                               |
| `zefir-retry`                      | Retry policies, backoff, jitter, circuit breaker                                                           | 📋 Planned                                               |
| **Networking & Communication**     |                                                                                                            |                                                         |
| `zefir-http`                       | HTTP server: REST APIs, routes checked at compile time, middleware, static files, SSE                      | ✅ Done · [docs](src/http/examples/README.md)            |
| `zefir-rpc`                        | Typed RPC with pluggable transports: NATS now, HTTP (Connect) and TCP later                                | ✅ Done · [docs](src/rpc/examples/README.md)             |
| `zefir-rpc-nats`                   | NATS transport for `zefir-rpc`: request-reply, ADR-32 errors, NATS micro discovery                         | ✅ Done · [docs](src/rpc-nats/examples/README.md)        |
| `zefir-graphql`                    | GraphQL queries, mutations, subscriptions, resolvers                                                       | 📋 Planned                                               |
| `zefir-messaging`                  | Pub/sub, message queues, consumers, backpressure                                                           | 📋 Planned                                               |
| `zefir-nats`                       | Native async NATS client on `std.Io`: publish/subscribe, request/reply, reconnect                          | ✅ Done · [docs](src/nats/examples/README.md)            |
| `zefir-zmq`                        | ZeroMQ / ZMTP integration                                                                                  | 📋 Planned                                               |
| `zefir-grpc`                       | gRPC interoperability                                                                                      | 📋 Planned                                               |
| **Database & Persistence**         |                                                                                                            |                                                         |
| `zefir-mongo`                      | Async MongoDB driver on `std.Io`: standalone mongod, SCRAM, pooling, BSON, collections; no TLS yet         | ✅ Done · [docs](src/mongo/examples/README.md)           |
| `zefir-odm`                        | MongoDB ODM (Object Data Mapper): typed schemas, models, CRUD, aggregation                                 | 📋 Planned                                               |
| `zefir-cache`                      | L1/L2 caching, TTL, Redis, invalidation, synchronization                                                   | 📋 Planned                                               |
| **Security**                       |                                                                                                            |                                                         |
| `zefir-security`                   | Authentication, authorization, JWT, MFA/TOTP, WebAuthn, TLS integration, CORS, rate limiting               | 📋 Planned                                               |
| **Observability & Diagnostics**    |                                                                                                            |                                                         |
| `zefir-observability`              | Metrics, distributed tracing, OpenTelemetry integration                                                    | 📋 Planned                                               |
| `zefir-diagnostics`                | Runtime diagnostics: tasks, threads, IO, memory, stack monitoring where supported                          | 📋 Planned                                               |
| `zefir-console`                    | Live terminal UI for runtime diagnostics, inspired by Tokio Console                                        | 📋 Planned                                               |
| `zefir-otel`                       | OpenTelemetry exporters                                                                                    | 📋 Planned                                               |
| `zefir-health`                     | Liveness, readiness, startup health checks                                                                 | 📋 Planned                                               |
| **Background Processing**          |                                                                                                            |                                                         |
| `zefir-scheduler`                  | Scheduled jobs, cron expressions, timers                                                                   | 📋 Planned                                               |
| **Developer Experience & Tooling** |                                                                                                            |                                                         |
| `zefir-openapi`                    | OpenAPI generation from Zig types                                                                          | 📋 Planned                                               |
| `zefir-cli`                        | Project scaffolding, code generation                                                                       | 📋 Planned                                               |
| `zefir-test`                       | Testing helpers, mocks, fixtures                                                                           | 📋 Planned                                               |

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

## nats in a minute

> [!NOTE]
> The example needs zio in your `build.zig.zon` and `build.zig`; the [guide's Installation](src/nats/examples/README.md#installation) shows both.

Connect to a NATS server, subscribe to a subject, publish to it and take the message. The client runs on any `std.Io` with real concurrency; [zio](https://github.com/lalinsky/zio) is the one for services:

```zig
const std = @import("std");
const nats = @import("nats");
const zio = @import("zio");

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var client: nats.Client = try .init(init.gpa, rt.io(), .{ .servers = &.{"nats://127.0.0.1:4222"} });
    defer client.deinit();
    try client.connect();

    const orders = try client.subscribe("orders.>", .{});
    defer orders.deinit();
    try client.flush(.{});

    try client.publish("orders.created", "{\"id\":1001}");

    var msg = (try orders.next(.{})) orelse return;
    defer msg.deinit();
    std.log.info("{s}: {s}", .{ msg.subject, msg.payload });
}
```

```text
$ docker run --rm -d -p 4222:4222 nats:2.15.0-alpine
$ zig build run -Doptimize=ReleaseSafe
info: orders.created: {"id":1001}
```

A Debug build also shows the client's own `debug(nats)` records: connecting, connected, closing.

`flush` waits until the server has the subscription, and `publish` returns once a copy of the message is in the client's queue. Every queue has a limit, a dropped connection comes back with its subscriptions, all requests share one reply subscription, and `drain()` stops a service without losing the work it took. **[Read the nats guide →](src/nats/examples/README.md)**

## rpc in a minute

Describe a service as a contract, implement it in a handler, serve it and call it. Here both sides run in one program, over the memory transport:

```zig
const std = @import("std");
const log = @import("log");
const rpc = @import("rpc");

// The contract: shared by the server and its clients, usually in a package of its own.
const User = struct { id: u64, name: []const u8 };
const GetUserRequest = struct { id: u64 };
const UserApi = rpc.Contract(.{
    .name = "users",
    .version = 1,
    .methods = .{ .getUser = rpc.method(GetUserRequest, User) },
    .errors = .{
        .UserNotFound = .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
    },
});

// The handler: a method for each method of the contract.
const Users = struct {
    pub const rpc_handler = rpc.implement(UserApi, .{});

    pub fn getUser(_: *Users, _: *rpc.Context, req: GetUserRequest) error{UserNotFound}!User {
        if (req.id != 42) return error.UserNotFound;
        return .{ .id = 42, .name = "Ada" };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const logger: log.Logger = try .init(gpa, io, .{ .format = .text });
    defer logger.deinit();

    // The memory transport keeps both sides in this process; on NATS, rpc_nats.Transport.
    var memory: rpc.testing.MemoryTransport = try .init(gpa, .{});
    defer memory.deinit(io);
    var users: Users = .{};
    var server = try rpc.Server.init(gpa, .{ .transport = memory.serverTransport(), .handlers = .{&users} });
    defer server.deinit(io);
    try server.start(io);

    var client = try rpc.Client.init(gpa, .{ .transport = memory.clientTransport() });
    defer client.deinit();
    for ([_]u64{ 42, 7 }) |id| {
        var result = try client.call(io, .root, UserApi.getUser, .{ .id = id }, .{});
        defer result.deinit();
        switch (result.outcome) {
            .ok => |user| logger.info("User found", .{ .id = user.id, .name = user.name }),
            .failure => |failure| logger.warn("No user", .{ .id = id, .app_code = failure.app_code }),
        }
    }
}
```

```text
$ zig build run
2026-10-16T09:51:59.484Z INFO  User found id=42 name=Ada
2026-10-16T09:51:59.485Z WARN  No user id=7 app_code=users.not_found
```

The compiler checks the handler against the contract and the request of every call against the method's type, and a failure of the service, such as `users.not_found`, comes as a value, not an error. On NATS, `rpc_nats.Transport` on a connection to the broker takes the place of the memory transport, and the contract, the handler and the calls stay the same. Validation with zefir-validator on both sides, middleware, authentication, deadlines that travel into nested calls, access logs and a graceful stop are in the guide. **[Read the rpc guide →](src/rpc/examples/README.md)**

## http in a minute

Declare a controller with its routes, give it to a server, and send it requests. Here the server runs on the backend in memory, which needs no network:

```zig
const std = @import("std");
const http = @import("http");
const v = @import("validator");

const Todo = struct { id: u64, title: []const u8 };

// The body of POST: the title is trimmed, then checked.
const NewTodo = struct {
    title: []const u8,

    pub const field_rules = .{ .title = .{ v.trim, v.notBlank, v.maxLength(200) } };
};

// A controller: the routes it declares, and a method for each.
const TodosV1Controller = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    todos: std.ArrayList(Todo) = .empty,

    pub const http_routes = http.routes(.{
        .prefix = "/v1/todos",
        .methods = .{
            .list = http.get("", .{}),
            .create = http.post("", .{}),
        },
    });

    pub fn list(self: *TodosV1Controller, ctx: *http.Context) !http.Json([]const Todo) {
        try self.mutex.lock(ctx.io());
        defer self.mutex.unlock(ctx.io());
        return .{ .value = try ctx.allocator().dupe(Todo, self.todos.items) };
    }

    pub fn create(self: *TodosV1Controller, ctx: *http.Context) !http.Json(Todo) {
        // Parsed, trimmed and checked: a body that does not fit never gets here.
        const body = try ctx.json(NewTodo);
        try self.mutex.lock(ctx.io());
        defer self.mutex.unlock(ctx.io());
        const todo: Todo = .{ .id = self.todos.items.len + 1, .title = try self.gpa.dupe(u8, body.title) };
        try self.todos.append(self.gpa, todo);
        return .{ .value = todo, .status = 201 };
    }

    fn deinit(self: *TodosV1Controller) void {
        for (self.todos.items) |todo| self.gpa.free(todo.title);
        self.todos.deinit(self.gpa);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // The backend in memory serves the server without a network; on the
    // network, http.native.Backend takes its place.
    var backend: http.testing.Backend = .init(gpa);
    defer backend.deinit();
    var todos: TodosV1Controller = .{ .gpa = gpa };
    defer todos.deinit();
    var server = try http.Server.init(gpa, .{ .backend = backend.backend(), .prefix = "/api", .controllers = .{&todos} });
    defer server.deinit(io);
    try server.start(io);

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    for ([_]struct { std.http.Method, []const u8 }{
        .{ .POST, "{\"title\":\"  Buy milk  \"}" },
        .{ .POST, "{\"title\":\"   \"}" },
        .{ .GET, "" },
    }) |request| {
        const method, const body = request;
        var res = try backend.request(io, .{
            .method = method,
            .target = "/api/v1/todos",
            .headers = &.{.{ "content-type", "application/json" }},
            .body = body,
        });
        defer res.deinit();
        try out.print("{t} /api/v1/todos{s}{s}\n", .{ method, if (body.len > 0) " " else "", body });
        try out.print("→ {d} {s} {s}\n", .{ res.status, res.header("content-type").?, res.body });
    }
    try out.flush();
}
```

```text
$ zig build run
POST /api/v1/todos {"title":"  Buy milk  "}
→ 201 application/json {"id":1,"title":"Buy milk"}
POST /api/v1/todos {"title":"   "}
→ 422 application/problem+json {"type":"about:blank","title":"Unprocessable Content","status":422,"code":"validation_failed","errors":[{"code":"validation.not_blank","message":"must not be blank","field":"title"}]}
GET /api/v1/todos
→ 200 application/json [{"id":1,"title":"Buy milk"}]
```

The compiler checks the routes and the handlers when it builds the server, `ctx.json(NewTodo)` reads the body by the `field_rules` of the DTO, trims the title and checks it, and a body that does not fit is a 422 that names every field. On the network, `http.native.Backend` on zio takes the place of the backend in memory, and the controller stays the same. Middleware of your own, one error handler for every error, static files, streamed responses, server-sent events and a graceful stop are in the guide. **[Read the http guide →](src/http/examples/README.md)**

On a shared GitHub runner, 4 vCPUs of an AMD EPYC 7763, a server on zio with four executors, loaded by clients in the same process, answers plain text at about 11 800 requests per second over one connection kept alive and 122 000 over 64, JSON out at 11 700 and 120 000, a JSON body in and JSON out at 11 800 and 116 000; the [guide's benchmark](src/http/examples/README.md#benchmark) shows the whole run, the spread across runs, and why one connection is faster on one executor.

## Installation

Requires **Zig 0.17.0**. Add the dependency to your `build.zig.zon`. This is the `dev` branch, the next version in progress, so the command fetches its latest commit:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#dev
```

`--save` pins the commit it fetched, so your build doesn't change when `dev` moves on. For the latest release, **v0.8.0**, fetch `#v0.8.0` instead; other versions are on the [releases page](https://github.com/vkiryakov/zefir/releases), and a commit hash works too.

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
# check formatting, as CI does
zig fmt --check build.zig build.zig.zon src tests examples \
  --exclude tests/nats/zig-pkg --exclude tests/rpc-nats/zig-pkg \
  --exclude tests/http/zig-pkg --exclude tests/mongo/zig-pkg \
  --exclude examples/rpc-custom-transport/zig-pkg --exclude examples/rpc-custom-transport/consumer/zig-pkg
```

CI tests a pull request only on the modules it affects. A change under `src/<module>/` runs the tests of that module, of every module that depends on it and of `zefir`; a change to `build.zig`, `build.zig.zon`, `src/zefir.zig` or `.github/` runs them all, and documentation outside `src/` runs none, except this README: its "rpc in a minute" and "http in a minute" are programs that the tests of rpc and of http check. Every push to `dev` and `main` tests all modules. The module graph for this is in `.github/scripts/affected-modules.sh`: a new module goes there as well as into `build.zig`.

The end-to-end tests of nats run against real NATS servers in Docker, described by `docker-compose.yml` at the repository root. The tests are a package of their own in `tests/nats`, so zio, the runtime they use, never reaches zefir's users:

```sh
docker compose up -d --wait   # start the servers, from the repository root
cd tests/nats
zig build e2e                 # start the servers if needed, run the tests, then the examples
zig build example-pub_sub     # run one example of src/nats/examples and show what it prints
zig build stress              # the stress tests, in Debug and in ReleaseSafe
zig build bench               # the benchmark, built with ReleaseFast
zig build check               # build all of the above without running it; no servers needed
zig build down                # stop the servers
```

`zig build down` also resets the servers when a run dies half way, say while a test holds one of them paused. Whenever CI tests nats, it builds this package on Linux, macOS and Windows and runs the end-to-end tests on Linux; a change to `tests/nats/` counts as a change to nats.

The end-to-end tests of rpc-nats, with the examples of its guide, are a package of the same kind in `tests/rpc-nats`, against servers of the same `docker-compose.yml`:

```sh
cd tests/rpc-nats
zig build e2e      # start the servers if needed, run the tests, then the examples, checking what they print against the guide
zig build check    # build the tests and the examples without running them; no servers needed
zig build down     # stop the servers
```

CI treats it as nats: whenever it tests rpc-nats, it builds the package on the three systems and runs it on Linux; a change to `tests/rpc-nats/` counts as a change to rpc-nats, and one to `docker-compose.yml` as a change to both.

The end-to-end tests of http, with the service of its guide, are a package of the same kind in `tests/http`, on zio, and need no servers:

```sh
cd tests/http
zig build e2e        # the end-to-end tests, then the service of the guide with its curl commands, checked against the guide
zig build examples   # only the service of the guide and its check (Linux and macOS)
zig build check      # build all of it without running it
```

Whenever CI tests http, it builds the package and runs its end-to-end tests on the three systems; a change to `tests/http/` counts as a change to http.

The end-to-end tests of mongo, with the programs of its guide, are a package of the same kind in `tests/mongo`, against the mongod servers of the profile `mongo` of the same `docker-compose.yml`:

```sh
cd tests/mongo
zig build e2e        # start the servers, run the tests, then the programs of the guide, checking their runs against the guide
zig build stress     # the stress tests, in Debug and in ReleaseSafe
zig build check      # build all of it without running it; no servers needed
zig build down       # stop the servers
```

`MONGO_VERSION` picks the image, 9.0.4 by default: `MONGO_VERSION=7.0.45 zig build e2e`. Whenever CI tests mongo, it builds the package on the three systems and runs its end-to-end tests on Linux against 7.0, 8.0 and 9.0; a change to `tests/mongo/` or to `docker-compose.yml` counts as a change to mongo.

`examples/rpc-custom-transport` is a transport of rpc in a package of its own, the proof that one can be written outside zefir. Its `consumer/` builds it as an application does, against the zefir of this checkout, and CI runs it whenever it tests rpc; a change to the package counts as a change to rpc:

```sh
cd examples/rpc-custom-transport/consumer
zig build test     # the conformance suite of rpc on the transport, its own tests, rpc.Server and rpc.Client over it
```

Branches:

- `dev` — the default branch and the next version in progress: its `.version` in `build.zig.zon` is that version with `-dev`, such as `0.2.0-dev`. Every change lands here first, through a squash-merged pull request.
- `feature/<name>` — new functionality; `chore/<name>` — docs, CI, tooling and other maintenance. Both are created from `dev` and merged back into it; a big feature goes in as several smaller pull requests.
- `main` — releases only. A release is a pull request from `dev`, merged with a merge commit and tagged `vX.Y.Z`.
- `hotfix/<name>` — an urgent fix for the latest release: created from `main`, merged into it as a patch release such as `v0.1.1`, and then brought to `dev` as well.

## License

[MIT](LICENSE)
