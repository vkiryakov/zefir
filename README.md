<h1 align="center">
  <img src="logo.png" alt="Zefir" width="400">
</h1>

<p align="center">
  <strong>A modular framework for building services in Zig.</strong><br>
  Web servers, web services and APIs, built from modules you pick: typed configuration, request deadlines, cancellation, tracing, structured logging, validation, a NATS client, RPC, an HTTP server with OpenAPI documents built from its types, an async MongoDB driver and a typed ODM over it, a Redis client, JSON Web Tokens and an application container today.
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
- **One container for the whole service.** [`zefir.App`](src/core/examples/app/README.md) builds a service out of its modules: it gives every part what it asks for by type, starts the servers and clients in order, watches them, and stops them all within one deadline when `main` asks it to, on SIGTERM for instance. A dependency that nothing provides is a compile error.
- **Take only what you use.** Every module is its own import, and the umbrella `zefir` module brings them all together.
- **Not limited to what ships.** Where a module meets the outside world, it goes through an interface, a pointer to your object and its function pointers, as `std.Io` does, and an implementation of your own takes the place of zefir's: a transport of rpc (`rpc.ClientTransport` and `rpc.ServerTransport`, which every `rpc.Server` and `rpc.Client` is given: zefir ships NATS, and [your own](src/rpc-nats/examples/writing-a-transport.md) lives in a package of its own), `rpc_nats.Conn` for another NATS library, and the `std.Io.Writer` that zefir-log writes to (`.output = .{ .writer = … }`). Middleware, authenticators and credentials providers of your own join the calls of rpc the same way.
- **Your types are the contract.** Declare a struct, and confy fills it and checks every value against its field's type. It reports every problem at once, each pointing at the file and line, or the variable, it came from.
- **No dependencies.** Pure Zig on top of the standard library; nothing else to fetch or audit.
- **Tested on Linux, macOS and Windows.** CI runs the tests of every module on all three.

## Modules

Take any module on its own, or all the finished ones at once through the umbrella module `zefir`.

| Module                             | What it does                                                                                                                                                                                                                  | Status                                                                                                                                                           |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Core & Foundation**              |                                                                                                                                                                                                                               |                                                                                                                                                                  |
| `zefir-core`                       | Execution context: deadlines, cancellation, W3C trace context; [`zefir.App`][app-guide]: the application container with DI and lifecycle                                                                                      | ✅ Done · [docs](src/core/examples/README.md)                                                                                                                     |
| `zefir-confy`                      | Typed configuration: JSON, INI, `.env` files, environment variables, secrets                                                                                                                                                  | ✅ Done · [docs](src/confy/examples/README.md)                                                                                                                    |
| `zefir-log`                        | Structured logging: JSON Lines, levels, context, redaction                                                                                                                                                                    | ✅ Done · [docs](src/log/examples/README.md)                                                                                                                      |
| `zefir-validator`                  | Typed schemas, validation rules, API field names, input normalization (trim, case), error reporting                                                                                                                           | ✅ Done · [docs](src/validator/examples/README.md)                                                                                                                |
| `zefir-events`                     | Typed in-process event bus                                                                                                                                                                                                    | 📋 Planned                                                                                                                                                        |
| `zefir-retry`                      | Retry policies, backoff, jitter, circuit breaker                                                                                                                                                                              | 📋 Planned                                                                                                                                                        |
| **Networking & Communication**     |                                                                                                                                                                                                                               |                                                                                                                                                                  |
| `zefir-http`                       | HTTP server: REST APIs, routes checked at compile time, middleware, static files, SSE                                                                                                                                         | 🟡 Partial (no TLS, HTTP/2, WebSocket, file uploads or compression) · [docs](src/http/examples/README.md)                                                         |
| `zefir-rpc`                        | Typed RPC with pluggable transports: NATS now, HTTP (Connect) and TCP later                                                                                                                                                   | 🟡 Partial (NATS transport only: no HTTP or TCP yet) · [docs](src/rpc/examples/README.md)                                                                         |
| `zefir-rpc-nats`                   | NATS transport for `zefir-rpc`: request-reply, ADR-32 errors, NATS micro discovery                                                                                                                                            | 🟡 Partial (no TLS; user and password only) · [docs](src/rpc-nats/examples/README.md)                                                                             |
| `zefir-graphql`                    | GraphQL queries, mutations, subscriptions, resolvers                                                                                                                                                                          | 📋 Planned                                                                                                                                                        |
| `zefir-messaging`                  | Pub/sub, message queues, consumers, backpressure                                                                                                                                                                              | 📋 Planned                                                                                                                                                        |
| `zefir-nats`                       | Native async NATS client on `std.Io`: publish/subscribe, request/reply, reconnect                                                                                                                                             | 🟡 Partial (core NATS only: no JetStream, KV, object store or TLS) · [docs](src/nats/examples/README.md)                                                          |
| `zefir-zmq`                        | ZeroMQ / ZMTP integration                                                                                                                                                                                                     | 📋 Planned                                                                                                                                                        |
| `zefir-grpc`                       | gRPC interoperability                                                                                                                                                                                                         | 📋 Planned                                                                                                                                                        |
| **Database & Persistence**         |                                                                                                                                                                                                                               |                                                                                                                                                                  |
| `zefir-mongo`                      | Async MongoDB driver on `std.Io`: standalone mongod, SCRAM, pooling, BSON, collections; no TLS yet                                                                                                                            | 🟡 Partial (standalone mongod only: no replica set, sharded cluster or TLS) · [docs](src/mongo/examples/README.md)                                                |
| `zefir-mongo-bson`                 | BSON, the format of MongoDB's documents: Zig values to BSON and back, raw documents, Extended JSON; shared by `zefir-mongo` and `zefir-odm`                                                                                   | ✅ Done · [docs](src/mongo/examples/README.md)                                                                                                                    |
| `zefir-redis`                      | Redis and Valkey client on `std.Io`: one standalone server, RESP3, connection pooling, typed replies, pipelines, WATCH transactions, Lua scripts, streams with consumer groups, pub/sub; no TLS yet, so trusted networks only | 🟡 Partial (one standalone server only: no Sentinel, Cluster or TLS) · [docs](src/redis/examples/README.md)                                                       |
| `zefir-odm`                        | Typed ODM for MongoDB: models as structs, queries checked at compile time, tenants on shared and own servers, connections replaced on the fly, any driver that passes its conformance suite                                   | ✅ Done · [docs](src/odm/examples/README.md)                                                                                                                      |
| `zefir-cache`                      | L1/L2 caching, TTL, Redis, invalidation, synchronization                                                                                                                                                                      | 📋 Planned                                                                                                                                                        |
| **Security**                       |                                                                                                                                                                                                                               |                                                                                                                                                                  |
| `zefir-security`                   | Authentication, authorization, JWT, MFA/TOTP, WebAuthn, TLS integration, CORS, rate limiting                                                                                                                                  | 🟡 Partial (JWT only, as security.jwt: no authentication, authorization, MFA, WebAuthn, TLS, CORS or rate limiting yet) · [docs](src/security/examples/README.md) |
| **Observability & Diagnostics**    |                                                                                                                                                                                                                               |                                                                                                                                                                  |
| `zefir-observability`              | Metrics, distributed tracing, OpenTelemetry integration                                                                                                                                                                       | 📋 Planned                                                                                                                                                        |
| `zefir-diagnostics`                | Runtime diagnostics: tasks, threads, IO, memory, stack monitoring where supported                                                                                                                                             | 📋 Planned                                                                                                                                                        |
| `zefir-console`                    | Live terminal UI for runtime diagnostics, inspired by Tokio Console                                                                                                                                                           | 📋 Planned                                                                                                                                                        |
| `zefir-otel`                       | OpenTelemetry exporters                                                                                                                                                                                                       | 📋 Planned                                                                                                                                                        |
| `zefir-health`                     | Liveness, readiness, startup health checks                                                                                                                                                                                    | 📋 Planned                                                                                                                                                        |
| **Background Processing**          |                                                                                                                                                                                                                               |                                                                                                                                                                  |
| `zefir-scheduler`                  | Scheduled jobs, cron expressions, timers                                                                                                                                                                                      | 🚧 In progress                                                                                                                                                    |
| **Developer Experience & Tooling** |                                                                                                                                                                                                                               |                                                                                                                                                                  |
| `zefir-openapi`                    | OpenAPI 3.1 and 3.2 documents of zefir-http services, built by the compiler from their routes, DTOs, errors and middleware                                                                                                    | ✅ Done · [docs](src/openapi/examples/README.md)                                                                                                                  |
| `zefir-cli`                        | Project scaffolding, code generation                                                                                                                                                                                          | 📋 Planned                                                                                                                                                        |
| `zefir-test`                       | Testing helpers, mocks, fixtures                                                                                                                                                                                              | 📋 Planned                                                                                                                                                        |

[app-guide]: src/core/examples/app/README.md

> [!NOTE]
> Zefir is in early development. Until 1.0, any minor release may change the API.

## confy in a minute

A service that listens on a port and talks to a database. Its defaults go in `config.json`, next to `build.zig`:

```json
{
  "http": { "port": 8080 },
  "db": { "url": "postgres://localhost:5432/app" }
}
```

The password goes in `.env`, which stays out of version control:

```sh
APP_DB_PASSWORD=change-me
```

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

    std.log.info("listening on port {d}, database {s}, password {f}", .{ config.http.port, config.db.url, config.db.password });
}
```

```text
$ zig build run
info: listening on port 8080, database postgres://localhost:5432/app, password [REDACTED]
```

The environment comes last, so it overrides the files:

```text
$ APP_HTTP_PORT=9090 zig build run
info: listening on port 9090, database postgres://localhost:5432/app, password [REDACTED]
```

A value that doesn't fit its field stops the program before it does anything:

```text
$ APP_HTTP_PORT=90000 zig build run
error(confy): 1 configuration problem:
  environment: APP_HTTP_PORT: invalid (expected an integer 0..65535)
```

`confy.Secret` prints as `[REDACTED]`, and every problem of the configuration comes at once, each pointing at the file and line, or the variable, it came from. **[Read the confy guide →](src/confy/examples/README.md)**

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

```text
$ zig build run
info: user 42 is Ada
```

Cancel the token when the client goes away, and every check below fails with `error.Cancelled`; once the deadline passes, they fail with `error.DeadlineExceeded`. `core.w3c` reads and writes the W3C `traceparent` and `tracestate` headers, and none of these primitives allocates, reads a clock or does I/O; `zefir.App`, the root of an application, which core also holds, is the one exception. **[Read the core guide →](src/core/examples/README.md)** · **[Read the App guide →](src/core/examples/app/README.md)**

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

```text
$ zig build run
{"timestamp":"2026-10-12T09:41:07.415Z","level":"info","message":"User created","service.name":"user-service","service.version":"1.0.0","scope":"users","user_id":42,"email":"ada@example.com","password":"[REDACTED]"}
```

Every record is one line of JSON on stdout, ready for a log collector. The fields are checked when the program compiles, secrets come out as `[REDACTED]`, levels change while the service runs, and a queued mode keeps stdout off the request path. **[Read the log guide →](src/log/examples/README.md)**

## nats in a minute

> [!NOTE]
> The example needs zio in your `build.zig.zon` and `build.zig`, and confy among its imports; the [guide's Installation](src/nats/examples/README.md#installation) shows them.

Connect to a NATS server, subscribe to a subject, publish to it and take the message. The client runs on [zio](https://github.com/lalinsky/zio), and confy reads the server's address from `APP_NATS_URL`:

```zig
const std = @import("std");
const confy = @import("confy");
const nats = @import("nats");
const zio = @import("zio");

/// The client logs through std.log; this leaves out its debug records.
pub const std_options: std.Options = .{ .log_level = .info };

const Config = struct {
    nats: struct {
        url: []const u8 = "nats://127.0.0.1:4222",
    } = .{},
};

pub fn main(init: std.process.Init) !void {
    // APP_NATS_URL sets the server; without it, the default stays.
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });

    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var client: nats.Client = try .init(init.gpa, rt.io(), .{ .servers = &.{config.nats.url} });
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

Against a server started with `docker run --rm -d -p 4222:4222 nats:2.15.0-alpine`:

```text
$ zig build run
info: orders.created: {"id":1001}
```

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
    var server = try rpc.Server.init(gpa, .{ .handlers = .{&users} }, .{ .transport = memory.serverTransport() });
    defer server.deinit(io);
    try server.start(io);

    var client = try rpc.Client.init(gpa, .{}, .{ .transport = memory.clientTransport() });
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
    // network, .listen = .{ .port = 8080 } takes its place.
    var backend: http.testing.Backend = .init(gpa);
    defer backend.deinit();
    var todos: TodosV1Controller = .{ .gpa = gpa };
    defer todos.deinit();
    var server = try http.Server.init(gpa, .{ .controllers = .{&todos} }, .{
        .listen = .{ .backend = backend.backend() },
        .prefix = "/api",
    });
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

The compiler checks the routes and the handlers when it builds the server, `ctx.json(NewTodo)` reads the body by the `field_rules` of the DTO, trims the title and checks it, and a body that does not fit is a 422 that names every field. On the network, `.listen = .{ .port = 8080 }` puts `http.native.Backend` on zio in the place of the backend in memory, and the controller stays the same. Middleware of your own, one error handler for every error, static files, streamed responses, server-sent events and a graceful stop are in the guide. **[Read the http guide →](src/http/examples/README.md)**

## Installation

Requires **Zig 0.17.0**. Add the dependency to your `build.zig.zon`. This is the `dev` branch, the next version in progress, so the command fetches its latest commit:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#dev
```

`--save` pins the commit it fetched, so your build doesn't change when `dev` moves on. For the latest release, **v0.11.0**, fetch `#v0.11.0` instead; other versions are on the [releases page](https://github.com/vkiryakov/zefir/releases), and a commit hash works too.

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

[CONTRIBUTING.md](CONTRIBUTING.md) tells how to build and test Zefir itself, and how a change reaches a release.

## License

[MIT](LICENSE)
