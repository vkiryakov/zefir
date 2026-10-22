# redis

> [!WARNING]
> **No TLS yet: use it only in a network you trust.** zefir-redis speaks
> plain TCP. The password goes to the server as it is, in the HELLO of
> every new connection, and so does every command and every value: whoever
> can read the traffic reads them all. Until the client has TLS, keep
> Redis and its services in a closed network, give each service a user of
> its own with a long random password, and across a network you do not
> trust, use a tunnel: WireGuard, SSH or a service mesh.

**A Redis client for Zig services.**

## Installation

Add Zefir to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#dev
```

zefir-redis is on the `dev` branch until the next release. The command
fetches the latest commit of `dev`; `--save` pins that commit. The latest
release, v0.9.0, came before zefir-redis, so `#v0.9.0` does not have it.

A service runs on [zio](https://github.com/lalinsky/zio). zio has no
release for Zig 0.17 yet, so pin the commit Zefir is tested with:

```sh
zig fetch --save git+https://github.com/lalinsky/zio#d15034f1a4d9ddaa42829aae8f7e02d37cd1093a
```

Then import the modules in `build.zig`. The programs of this guide also
use Zefir's confy for settings, log for records and core for deadlines:

```zig
// build.zig
const zefir = b.dependency("zefir", .{ .target = target, .optimize = optimize });
const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "shop",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "redis", .module = zefir.module("zefir-redis") },
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "confy", .module = zefir.module("zefir-confy") },
            .{ .name = "log", .module = zefir.module("zefir-log") },
            .{ .name = "core", .module = zefir.module("zefir-core") },
        },
    }),
});
b.installArtifact(exe);
b.step("run", "Run the service").dependOn(&b.addRunArtifact(exe).step);
```

> [!TIP]
> zefir-redis is also part of the umbrella module: with
> `zefir.module("zefir")` imported as `zefir`, it is
> `@import("zefir").redis`. It imports only zefir-core; zio comes from
> your build.

You need a server to talk to. With Docker:

```sh
docker run --rm -p 6379:6379 redis:8.10.2
```

Valkey works the same way, `docker run --rm -p 6379:6379
valkey/valkey:9.1.2`: the programs of this guide run against Redis 7.2,
Redis 8.10 and Valkey 9.1, and print the same.

## Quick start

The sessions, the page views and the profiles of the shop. The program
connects, signs a customer in with a session that expires, counts the
views of the home page with a pipeline, keeps the customer's profile in a
hash, and signs the customer out:

```zig
//! The quick start of the guide: the sessions, the page views and the
//! profiles of a coffee shop. It connects, signs a customer in with a
//! session that expires, counts the views of the home page with a
//! pipeline, keeps the customer's profile in a hash, and signs the
//! customer out. Each run starts afresh: it deletes its keys first.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-quick_start` runs it against the
//! servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

/// The client logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        /// Kept out of the URL, and out of every log.
        password: ?confy.Secret = null,
    } = .{},
};

/// A customer's profile, as the hash user:<id> keeps it: a field of the
/// hash for each field of the struct.
const Profile = struct {
    name: []const u8,
    age: u8,
    plan: enum { free, pro } = .free,
    visits: i64 = 0,
};

pub fn main(init: std.process.Init) !void {
    var config: Config = undefined;
    confy.loadOrExit(init.arena.allocator(), &config, .{
        .io = init.io,
        .environ = init.environ_map,
        .env_prefix = "APP_",
        .sources = &.{.osEnv()},
    });
    // The logger outlives the runtime, so it takes `init.io`, through which
    // the tasks of the runtime may log too.
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");

    // One runtime for the program, with an executor per CPU core: the
    // client and the tasks that call it run on its `io`.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // One client for the whole program, which any task may call. init
    // checks the options and does no I/O; connect opens the first
    // connection and says why when it cannot. From then on the client
    // stays where it is.
    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    var diagnostics: redis.Diagnostics = .{};
    client.connect(io, within(io, .fromSeconds(10)), &diagnostics) catch |err| {
        app.err("Cannot connect", .{ .reason = err, .details = diagnostics.message() });
        return err;
    };
    defer client.close(io);
    app.info("Connected", .{});

    try run(io, init.gpa, &client, app);

    const stats = client.stats();
    app.info("Done", .{ .connections = stats.connections, .in_use = stats.in_use });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// The application: it sees the client.
fn run(io: std.Io, gpa: std.mem.Allocator, client: *redis.Client, app: log.Logger) !void {
    // The memory of the replies, all freed at the end.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Five seconds for all of it: each call has what is left of them.
    const op: redis.OperationContext = .of(within(io, .fromSeconds(5)));

    // Start afresh.
    _ = try client.run(io, op, cmd.del(&.{ "session:7f3a9c", "views:/home", "motd", "user:42" }), .{});

    // A session: its token names the customer, for half an hour.
    try client.run(io, op, cmd.set("session:7f3a9c", "42", .{ .ttl = .fromSeconds(30 * 60) }), .{});
    const user = try client.run(io, op, cmd.get([]const u8, "session:7f3a9c"), .{ .allocator = arena });
    app.info("Signed in", .{ .session = "7f3a9c", .user = user });
    switch (try client.run(io, op, cmd.ttl("session:7f3a9c"), .{})) {
        .expires_in => |left| app.info("Session expires", .{ .in_minutes = @divFloor(left.toMilliseconds() + 59_999, 60_000) }),
        .persistent, .missing => app.warn("Session without a time to live", .{}),
    }

    // The home page, viewed three times: each view counts itself, keeps
    // the counter for a day, and reads the message of the day, in one
    // exchange.
    try client.run(io, op, cmd.set("motd", "Fresh beans from Ethiopia", .{}), .{});
    for (0..3) |_| {
        const r = try client.pipeline(io, op, .{
            cmd.incr("views:/home"),
            cmd.expire("views:/home", .fromSeconds(24 * 60 * 60)),
            cmd.get([]const u8, "motd"),
        }, .{ .allocator = arena });
        app.info("Home page", .{ .views = try r[0], .ttl_set = try r[1], .motd = try r[2] });
    }

    // The profile: a hash with a field for each field of Profile.
    try client.run(io, op, cmd.hset("user:42", Profile{ .name = "Ann", .age = 30, .plan = .pro }), .{});
    const visits = try client.run(io, op, cmd.hincrby("user:42", "visits", 1), .{});
    app.info("Visit", .{ .user = 42, .visits = visits });
    const profile = (try client.run(io, op, cmd.hgetall(Profile, "user:42"), .{ .allocator = arena })) orelse
        return error.ProfileGone;
    app.info("Profile", .{ .name = profile.name, .age = profile.age, .plan = profile.plan, .visits = profile.visits });

    // Signing out ends the session.
    const deleted = try client.run(io, op, cmd.del(&.{"session:7f3a9c"}), .{});
    const gone = try client.run(io, op, cmd.get([]const u8, "session:7f3a9c"), .{ .allocator = arena });
    app.info("Signed out", .{ .deleted = deleted, .session = gone });
}
```

Start a server as in [Installation](#installation), then the program:

```text
$ zig build run
2026-10-22T05:28:00.991Z INFO  [app] Connected
2026-10-22T05:28:01.016Z INFO  [app] Signed in session=7f3a9c user=42
2026-10-22T05:28:01.017Z INFO  [app] Session expires in_minutes=30
2026-10-22T05:28:01.024Z INFO  [app] Home page views=1 ttl_set=true motd="Fresh beans from Ethiopia"
2026-10-22T05:28:01.041Z INFO  [app] Home page views=2 ttl_set=true motd="Fresh beans from Ethiopia"
2026-10-22T05:28:01.048Z INFO  [app] Home page views=3 ttl_set=true motd="Fresh beans from Ethiopia"
2026-10-22T05:28:01.091Z INFO  [app] Visit user=42 visits=1
2026-10-22T05:28:01.092Z INFO  [app] Profile name=Ann age=30 plan=pro visits=1
2026-10-22T05:28:01.110Z INFO  [app] Signed out deleted=1 session=null
2026-10-22T05:28:01.110Z INFO  [app] Done connections=1 in_use=0
```

What happens, from the top:

- **Settings.** `confy.loadOrExit` fills `Config` from the environment:
  `APP_REDIS_URL` is `redis.url`, and `APP_REDIS_PASSWORD` is
  `redis.password`. The password is a `confy.Secret`, which no log prints:
  it stays out of the URL, and `expose()` hands it to the client.
- **Logs.** The client writes its warnings to `std.log.scoped(.redis)`;
  `std_options` with `log.stdLogFn` and `logger.installStdLog()` send them
  to zefir-log, see [Logs](#logs).
- **The runtime.** Everything runs on the `std.Io` of zio, `rt.io()`,
  with an executor per CPU core. The logger takes `init.io`, so that any
  thread may log.
- **The client.** `init` checks the options and the URL, and does no I/O.
  `connect` opens the first connection under its deadline: a server that
  is not there, a wrong password or a server of the wrong kind shows here,
  at the start, with the reason in `diagnostics`. From then on the client
  must stay where it is. `close` ends its work and `deinit` frees it;
  [Connecting](#connecting) has the rest.
- **A command is a value.** `cmd.set(…)` builds the command, and
  `client.run` sends it and returns its reply, in the type that the
  command names: `void` for SET, `?[]const u8` for
  `cmd.get([]const u8, …)`, null when the key is not there. [Commands and
  replies](#commands-and-replies) has the rules.
- **One context for the work.** `.of(ctx)` makes the
  `redis.OperationContext` of a call from a `core.Context`: here five
  seconds for all the calls of `run`, each with what is left of them.
- **Memory.** A reply that holds strings comes from the arena of
  `.allocator`, and goes with it at the end; numbers and `void` need none.
- **A time to live.** SET with `.ttl` makes the session expire in half an
  hour, and `cmd.ttl` reads what is left of it, as a `redis.Ttl`:
  `.expires_in`, `.persistent` for a key without one, `.missing` for a
  key that is not there.
- **A pipeline.** The three commands of a view go in one write and come
  back in one read: one round trip, see [Pipelines](#pipelines).
- **A hash.** HSET writes a field for each field of a `Profile`, and
  HGETALL reads them back into one; HINCRBY counts a field up on the
  server.
- **The end.** `stats` shows one connection, idle: the calls went one
  after another, and the pool kept the connection that `connect` opened.

## Connecting

### The URL

```text
redis://[[user]:password@]host[:port][/database]
```

One host, a name, an IPv4 address or an IPv6 one in brackets, and the
port 6379 unless the URL names one. The database is a number, 0 unless the
path names one, and whether the server has it, `SELECT` finds out at
`connect`. The user and the password are percent-encoded: `@` is `%40` and
`:` is `%3A`, so `redis://app:p%40ss@cache` is the user `app` with the
password `p@ss`, and `redis://:secret@cache` the password of the user
`default`. Better still, keep the password out of the URL and give it in
`Options.password`, from a `confy.Secret`.

`init` refuses what v0.1 cannot do, with a text that says what to do
instead: `rediss://`, which wants TLS, and options after `?`, which live
in `redis.Client.Options`, are `Unsupported`, and so are UNIX sockets and
other schemes; a password both in the URL and in the options, and a user
without a password, are `InvalidArgument`.

### The options

`redis.Client.Options` holds the rest; only `url` has no default:

| Field | Default | What it does |
|---|---|---|
| `url` | none, required | the server, as above |
| `password` | null | the password of the user of the URL, or of `default`, when the URL has none |
| `client_name` | null | the name of the client's connections in `CLIENT LIST`: printable ASCII without spaces |
| `max_connections` | 32 | how many connections the pool keeps at most; subscribers come on top |
| `timeout` | 5 s | the deadline of a call whose context has none; for a blocking command, the margin after its own timeout; null: no deadline |
| `connect_timeout` | 5 s | DNS, TCP and the handshake of a new connection; the deadline of the call may cut it shorter |
| `start_timeout` | 10 s | the deadline of `start`, see [Under zefir.App](#under-zefirapp) |
| `close_timeout` | 5 s | how long `close` lets the calls in flight finish |
| `max_reply_bytes` | 64 MiB | the largest reply, in bytes on the wire; a larger one is `ReplyTooLarge` |
| `diagnostics` | null | why `init` refused the options; it never shows the password |

`init` keeps copies of the strings, so they may go once the client is
made; `deinit` wipes its copy of the password.

### Users and passwords

A server may have users, its ACL: each with a password, and the commands
and keys it may use, such as `user app on >app-pass ~* +@all`. The client
authenticates every connection it opens in the HELLO that opens it, as the
user of the URL, or as `default` when the URL names none, and sends no
password when it has none. A user that may not run a command, or touch its
keys, gets `ServerError` with the code `NOPERM`.

In production the password comes from wherever the service keeps its
secrets: confy reads it from the environment, as here, or from a `.env`
file, and holds it as a `confy.Secret`, so that a log of the settings
shows `[REDACTED]`.

### What can go wrong at the start

`connect.zig` connects with the password of the settings, then tries a
wrong password, a server that is not there, and URLs that the client
refuses; last come `start` and `shutdown`, see [Under
zefir.App](#under-zefirapp):

```zig
//! Connecting, and what the client says when the start goes wrong. It
//! connects with the password of the settings; then it tries a wrong
//! password, a server that is not there, and URLs that the client refuses.
//! Last come `start` and `shutdown`, the methods that zefir.App calls:
//! `start` with a wrong password logs why it failed.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server, and the user unless it is default,
//!                        such as redis://app@127.0.0.1:6379
//!   APP_REDIS_PASSWORD   the user's password
//!
//! In tests/redis, `zig build example-connect` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");

/// The client logs through std.log; this sends its records to the logger.
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
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
        .sources = &.{.osEnv()},
    });
    const logger: log.Logger = try .init(init.gpa, init.io, .{ .format = .text });
    defer logger.deinit();
    logger.installStdLog();
    const app = logger.scoped("app");
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    // The user of the URL, with the password of the settings: the client
    // authenticates every connection it opens with them, and names its
    // connections "shop" in CLIENT LIST.
    try connect(io, init.gpa, app, .{ .url = config.redis.url, .password = config.redis.password.expose(), .client_name = "shop" });
    // The same user with another password.
    try connect(io, init.gpa, app, .{ .url = config.redis.url, .password = "not-the-password" });
    // A server that is not there: nothing listens on port 1.
    try connect(io, init.gpa, app, .{ .url = "redis://127.0.0.1:1" });

    // URLs copied from elsewhere: init refuses what the client cannot do,
    // rather than skip it.
    for ([_][]const u8{
        "rediss://cache.example.com:6380",
        "redis://cache.example.com:6379/0?protocol=3",
        "redis://app@cache.example.com:6379",
    }) |url| {
        var refused: redis.Diagnostics = .{};
        var client = redis.Client.init(init.gpa, io, .{ .url = url, .diagnostics = &refused }) catch |err| {
            app.warn("Refused", .{ .reason = err, .details = refused.message() });
            continue;
        };
        client.deinit();
    }

    // What zefir.App calls. start is connect under a deadline of
    // Options.start_timeout, 10 s, and logs why it failed, as under App no
    // caller sees the diagnostics.
    var refused: redis.Client = try .init(init.gpa, io, .{ .url = config.redis.url, .password = "not-the-password" });
    defer refused.deinit();
    refused.start(io) catch |err| app.warn("Not started", .{ .reason = err });
    // shutdown is close by the deadline of App's stop.
    var client: redis.Client = try .init(init.gpa, io, .{ .url = config.redis.url, .password = config.redis.password.expose() });
    defer client.deinit();
    try client.start(io);
    app.info("Started", .{ .connections = client.stats().connections });
    try client.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake }));
    app.info("Stopped", .{ .connections = client.stats().connections });
}

/// Connects a client of `options`, and logs how it went.
fn connect(io: std.Io, gpa: std.mem.Allocator, app: log.Logger, options: redis.Client.Options) !void {
    var client: redis.Client = try .init(gpa, io, options);
    defer client.deinit();
    const ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(10)));
    var diagnostics: redis.Diagnostics = .{};
    client.connect(io, ctx, &diagnostics) catch |err| {
        app.warn("Cannot connect", .{ .reason = err, .outcome = redis.outcome(err), .details = diagnostics.message() });
        return;
    };
    defer client.close(io);
    app.info("Connected", .{});
}
```

It needs a server with a password. This one listens on 6380, next to the
server of the other programs, and its user `default` has the password
`change-me`:

```sh
docker run --rm -p 6380:6379 redis:8.10.2 --requirepass change-me
```

```text
$ APP_REDIS_URL=redis://127.0.0.1:6380 APP_REDIS_PASSWORD=change-me zig build run
2026-10-22T05:28:03.493Z INFO  [app] Connected
2026-10-22T05:28:03.515Z WARN  [redis] 127.0.0.1:6380 refused the connection: AuthenticationFailed: WRONGPASS invalid username-password pair or user is disabled.
2026-10-22T05:28:03.515Z WARN  [app] Cannot connect reason=AuthenticationFailed outcome=not_sent details="WRONGPASS invalid username-password pair or user is disabled."
2026-10-22T05:28:03.515Z WARN  [app] Cannot connect reason=Unavailable outcome=not_sent details="cannot connect to 127.0.0.1:1: ConnectionRefused"
2026-10-22T05:28:03.515Z WARN  [app] Refused reason=Unsupported details="TLS is not supported in v0.1; use a trusted network"
2026-10-22T05:28:03.515Z WARN  [app] Refused reason=Unsupported details="v0.1 takes no options in the URL; set them in redis.Client.Options"
2026-10-22T05:28:03.515Z WARN  [app] Refused reason=InvalidArgument details="the URL names a user but no password: add it percent-encoded, redis://user:password@host, or pass Options.password"
2026-10-22T05:28:03.531Z WARN  [redis] 127.0.0.1:6380 refused the connection: AuthenticationFailed: WRONGPASS invalid username-password pair or user is disabled.
2026-10-22T05:28:03.531Z WARN  [redis] start failed: error.AuthenticationFailed: WRONGPASS invalid username-password pair or user is disabled.
2026-10-22T05:28:03.531Z WARN  [app] Not started reason=AuthenticationFailed
2026-10-22T05:28:03.617Z INFO  [app] Started connections=1
2026-10-22T05:28:03.618Z INFO  [app] Stopped connections=0
```

- **Connected,** with the password of the settings.
- **A wrong password** is `AuthenticationFailed`, with the server's
  `WRONGPASS`, and `not_sent`: nothing ran. The client logs the refusal
  too, as a warning with the address of the server, never with the
  password. In a running service a refused user also clears the pool, as
  the server would refuse every connection alike.
- **A server that is not there** is `Unavailable`, and so is one that does
  not answer within `connect_timeout`. A server of another kind is refused
  here too: a cluster node, a Sentinel, Redis before 7.2 or Valkey before
  8 is `Unsupported`, with what it is, such as "the server at db:6379 is
  Redis 6.2.24; v0.1 needs Redis 7.2 or later".
- **URLs** that ask for what v0.1 cannot do stop at `init`, with what to
  do instead.
- `connect` may be called again after a failure; until it succeeds, a call
  is `Unavailable`: "connect() has not succeeded". Once the client is
  connected, `connect` does nothing.

### The composition root

`main` of [the quick start](#quick-start) builds the parts of a service in
the order their lives need, and its `defer`s take them down in the reverse
one:

1. the settings, then the logger, on `init.io`;
2. the zio runtime, whose `io` the client and every task take;
3. the client: `init`, then `connect` under a deadline;
   `defer client.deinit()` comes before `defer client.close(io)`, so that
   `close` runs first;
4. the code of the application, which gets `*redis.Client`.

The client must not move once connected: keep it in a `var` of `main`, or
in a struct that stays where it is, and hand out `&client`. In safe builds
a call on a moved copy panics, and so does a call with another `std.Io`
than the one of `init`.

## Pipelines

Every call is a round trip: the command goes to the server, and the call
waits for its reply. Across a network a round trip takes far longer than
Redis takes to run a command, so a service that sends ten commands one
after another mostly waits. A *pipeline* sends them all in one write and
reads their replies in order: one round trip for the ten.

```mermaid
sequenceDiagram
    participant S as your service
    participant R as Redis
    Note over S,R: one by one: three round trips
    S->>R: INCR views:/home
    R-->>S: 42
    S->>R: EXPIRE views:/home
    R-->>S: 1
    S->>R: GET motd
    R-->>S: "Fresh beans…"
    Note over S,R: a pipeline: one round trip
    S->>R: INCR, EXPIRE, GET
    R-->>S: 43, 1, "Fresh beans…"
```

`client.pipeline(io, op, commands, options)` takes either:

- **a tuple of commands** of any types, as [the quick start](#quick-start)
  does: the result is a tuple with a `redis.CommandError!T` for each
  command in its order, `T` the type of its reply, so `try r[0]` gives the
  first;
- **many commands of one type**, a slice of them or a pointer to their
  array, such as the thousand keys of an import: the result is a slice of
  `redis.CommandError!T`, from `options.allocator`, which the call then
  needs.

The rules:

- One connection of the pool carries the whole pipeline. On the server,
  the commands of other clients may run between its commands: a pipeline
  is no transaction, see [Transactions and WATCH](#transactions-and-watch).
- An error of one command, `ServerError` or `UnexpectedReply`, is the
  value in its place, and the other commands go on.
  `diagnostics.command` is the index of the first command with an error.
- Every command is checked before anything goes out: one that breaks a
  rule of the client, such as an empty list, fails the whole pipeline with
  `InvalidArgument`, and nothing is sent. So does a pipeline of no
  commands.
- An error of the exchange itself, a connection that broke or a deadline
  that passed, is the error of the call, and an unknown part of the
  commands ran: `diagnostics.answered` says how many replies came. Those
  commands surely ran; the others may have.
- The server holds the replies of a pipeline in memory until it sends
  them: keep a pipeline to about 10 000 commands, and send more in several.
- A blocking command holds the commands after it; give a pipeline one at
  most, and last, see [Blocking commands](#blocking-commands-and-the-reliable-queue).

The tests show each case, against a server that the test scripts (see
[Tests without Redis](#tests-without-redis)):

```zig
//! Pipelines against `redis.testing.FakeServer`: commands of several types
//! in a tuple, with the error of one in its place while the others go on;
//! many commands of one type in a slice; and a pipeline whose connection
//! breaks in the middle, which says how many of its commands surely ran.
//! Each test starts a server and a client of it, as profiles_test.zig does.

const std = @import("std");
const redis = @import("redis");
const cmd = redis.cmd;
const testing = std.testing;
const FakeServer = redis.testing.FakeServer;

test "an error of one command is the value in its place, and the commands after it go on" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "INCR", "views:/home" }, .{ .integer = 41 }),
        .expect(.{ "LPUSH", "motd", "Closed on Monday" }, .{ .err = "WRONGTYPE Operation against a key holding the wrong kind of value" }),
        .expect(.{ "GET", "motd" }, .{ .string = "Fresh beans from Ethiopia" }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Three commands in one exchange; motd is a string, not a list.
    var d: redis.Diagnostics = .{};
    const r = try client.pipeline(io, .of(.root), .{
        cmd.incr("views:/home"),
        cmd.lpush("motd", .{"Closed on Monday"}),
        cmd.get([]const u8, "motd"),
    }, .{ .allocator = arena.allocator(), .diagnostics = &d });
    try testing.expectEqual(41, try r[0]);
    try testing.expectError(error.ServerError, r[1]);
    try testing.expectEqualStrings("Fresh beans from Ethiopia", (try r[2]).?);
    // The diagnostics hold the first error: the command's index, and the
    // server's code.
    try testing.expectEqual(1, d.command.?);
    try testing.expect(d.isCode("WRONGTYPE"));
    try server.finish(io);
}

test "many commands of one type go as a slice, and their results come in a slice from .allocator" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "SET", "price:espresso", "2.5", "PX", "600000" }, .ok),
        .expect(.{ "SET", "price:latte", "3.2", "PX", "600000" }, .ok),
        .expect(.{ "SET", "price:mocha", "3.8", "PX", "600000" }, .ok),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The prices of the menu, each kept for ten minutes.
    const menu = [_]redis.KeyValue{
        .{ .key = "price:espresso", .value = "2.5" },
        .{ .key = "price:latte", .value = "3.2" },
        .{ .key = "price:mocha", .value = "3.8" },
    };
    var commands: [menu.len]cmd.Set([]const u8) = undefined;
    for (&commands, menu) |*c, price| c.* = cmd.set(price.key, price.value, .{ .ttl = .fromSeconds(600) });
    const done = try client.pipeline(io, .of(.root), &commands, .{ .allocator = arena.allocator() });
    try testing.expectEqual(menu.len, done.len);
    for (done) |each| try each;
    try server.finish(io);
}

test "a connection that breaks in the middle of a pipeline is ConnectionLost, and answered says how many commands surely ran" {
    const io = testing.io;
    // The server answers two INCRs, reads the third and goes away.
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "INCR", "stock:coffee" }, .{ .integer = 1 }),
        .expect(.{ "INCR", "stock:coffee" }, .{ .integer = 2 }),
        .expect(.{ "INCR", "stock:coffee" }, .close_connection),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The client logs the clear of its pool that a broken connection
    // causes, as a warning: this test expects it, so it stays out of the
    // test's output.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    const restock: [4]cmd.Incr = @splat(cmd.incr("stock:coffee"));
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.ConnectionLost, client.pipeline(io, .of(.root), &restock, .{ .allocator = arena.allocator(), .diagnostics = &d }));
    // Two replies came: those two INCRs ran. The other two may have run,
    // or not: the pipeline must not go again as a whole.
    try testing.expectEqual(2, d.answered.?);
    try testing.expectEqual(redis.Outcome.may_have_executed, redis.outcome(error.ConnectionLost));
    try server.finish(io);
}
```

## Deadlines and cancellation

A call takes a `redis.OperationContext`, whose `ctx` is the
`core.Context` of the work it belongs to: a deadline, a cancellation token
and a trace. `.of(ctx)` makes one.

- **The deadline.** A call's deadline is its context's, else `timeout` of
  the options from the start of the call, 5 s by default; `.timeout =
  null` leaves a call without a deadline of its context with none at all.
  The deadline bounds the whole call: the line of the pool, the opening of
  a connection, the write and the reply. With less than 1 ms left before
  sending, or less than the shortest round trip that the client has seen
  to the server, the call is `DeadlineExceeded`, and nothing goes out.
  Once the command went out, the deadline is `Timeout`, and that
  connection closes: its reply may still come, and no later call must read
  it.
- **The token** is no alarm. The client checks it before the call and
  before it sends: `Cancelled`. It never checks it after the reply: the
  reply of `LPOP`, `GETDEL`, `BLMOVE` or `XREADGROUP` has taken its data
  off the server already, and to drop it would lose the data. The reply
  comes back, and the next call sees the token.
- **The task.** Canceling the task that waits, with the cancelation of
  `io`, ends the wait at once: `Cancelled` before sending, `Interrupted`
  after, and that connection closes. The task stays canceled, so that its
  next cancelation point sees it too.
- **The line of the pool.** A call that waits for a connection leaves the
  line at its deadline: `PoolExhausted`, and nothing went out.
- **A blocking command** takes the timeout it sends the server from the
  deadline, see [Blocking commands](#blocking-commands-and-the-reliable-queue).

One deadline covers all the calls made under it: in the handler of a
request, every call takes what is left of the request's time. Tests
against a server whose replies wait as long as the test says show each
case:

```zig
//! Deadlines and cancellation, against `redis.testing.FakeServer`, whose
//! replies wait as long as a test says: what each call returns, whether
//! its command went out, and what a blocking command gave the server as its
//! timeout. Each test starts a server and a client of it, as
//! profiles_test.zig does.

const std = @import("std");
const core = @import("core");
const redis = @import("redis");
const cmd = redis.cmd;
const testing = std.testing;
const FakeServer = redis.testing.FakeServer;

/// A context whose deadline is `ms` milliseconds away.
fn within(io: std.Io, ms: i64) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromMilliseconds(ms)));
}

/// What the server answers LLEN with, two seconds late.
const three: FakeServer.Reply = .{ .integer = 3 };

test "a reply that comes after the deadline is Timeout: the command went out, and its connection closed" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "LLEN", "orders:paid" }, .{ .delayed = .{ .after = .fromSeconds(2), .reply = &three } }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);

    var d: redis.Diagnostics = .{};
    try testing.expectError(error.Timeout, client.run(io, .of(within(io, 200)), cmd.llen("orders:paid"), .{ .diagnostics = &d }));
    try testing.expectEqualStrings("the deadline passed before the reply came", d.message());
    // The command went out, so the server may have run it.
    try testing.expectEqual(redis.Outcome.may_have_executed, redis.outcome(error.Timeout));
    try testing.expectEqual(1, server.received(io));
    // Its reply may still come: the connection closed rather than go back
    // to the pool with it.
    try testing.expectEqual(0, client.stats().connections);
}

test "a deadline that has passed, or a canceled token, stops a call before anything goes out" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);

    try testing.expectError(error.DeadlineExceeded, client.run(io, .of(within(io, 0)), cmd.llen("orders:paid"), .{}));
    // The caller went away: whoever owns the token canceled it.
    var token: core.CancellationToken = .init;
    token.cancel();
    try testing.expectError(error.Cancelled, client.run(io, .of(core.Context.root.withCancellation(&token)), cmd.llen("orders:paid"), .{}));
    // Neither went out, so both are safe to make again.
    try testing.expectEqual(0, server.received(io));
    try testing.expectEqual(redis.Outcome.not_sent, redis.outcome(error.DeadlineExceeded));
    try testing.expectEqual(redis.Outcome.not_sent, redis.outcome(error.Cancelled));
}

/// Cancels `token` as the command comes, and answers it: the caller's
/// token is canceled while its call is out, as when the caller goes away
/// in the middle.
const CancelOnArrival = struct {
    token: *core.CancellationToken,

    pub fn answer(h: *CancelOnArrival, _: std.Io, _: std.mem.Allocator, _: *const FakeServer.Request) FakeServer.Handler.Error!FakeServer.Reply {
        h.token.cancel();
        return .{ .string = "order:1001" };
    }
};

test "a token canceled while the command is out does not drop its reply: LPOP has taken the order off the server" {
    const io = testing.io;
    var token: core.CancellationToken = .init;
    var canceler: CancelOnArrival = .{ .token = &token };
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&canceler) });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const op: redis.OperationContext = .of(core.Context.root.withCancellation(&token));
    const order = try client.run(io, op, cmd.lpop([]const u8, "orders:paid"), .{ .allocator = arena.allocator() });
    try testing.expectEqualStrings("order:1001", order.?);
    // The next call sees the token before it sends.
    try testing.expectError(error.Cancelled, client.run(io, op, cmd.lpop([]const u8, "orders:paid"), .{ .allocator = arena.allocator() }));
    try testing.expectEqual(1, server.received(io));
}

/// LLEN orders:paid, without a deadline of the context: the 5 s of
/// `Options.timeout`.
fn countPaid(io: std.Io, client: *redis.Client) redis.Error!u64 {
    return client.run(io, .of(.root), cmd.llen("orders:paid"), .{});
}

test "a task canceled while its command waits for the reply is Interrupted, and the connection closes" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{
        .expect(.{ "LLEN", "orders:paid" }, .{ .delayed = .{ .after = .fromSeconds(2), .reply = &three } }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);

    var call = try io.concurrent(countPaid, .{ io, &client });
    // Wait until the command is out, for 5 s at most.
    const give_up: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(5));
    while (server.received(io) == 0) {
        if (give_up.isExpired(std.Io.Clock.awake.now(io))) return error.TestTimedOut;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.Interrupted, call.cancel(io));
    try testing.expectEqual(redis.Outcome.may_have_executed, redis.outcome(error.Interrupted));
    try testing.expectEqual(0, client.stats().connections);
}

/// Answers every command with null, as BLMOVE of an empty list answers
/// once its timeout is over.
const Empty = struct {
    pub fn answer(_: *Empty, _: std.Io, _: std.mem.Allocator, _: *const FakeServer.Request) FakeServer.Handler.Error!FakeServer.Reply {
        return .nil;
    }
};

test "a blocking command gives the server what the deadline leaves beyond 150 ms, or its own timeout when that is shorter" {
    const io = testing.io;
    var empty: Empty = .{};
    var server: FakeServer = try .startWith(testing.allocator, io, .{ .handler = .init(&empty) });
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A second for the call; the command would wait for an order forever.
    const start = std.Io.Clock.awake.now(io);
    const order = try client.run(io, .of(within(io, 1000)), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .forever), .{ .allocator = arena.allocator() });
    try testing.expect(order == null);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    // BLMOVE orders:paid orders:packing LEFT RIGHT <seconds>: the deadline
    // less 150 ms, so 0.85 s at most, and less only by the time that passed
    // before the command went out.
    const sent = (try server.entry(io, 0)).args;
    try testing.expectEqualStrings("BLMOVE", sent[0]);
    const timeout_ms: i64 = @intFromFloat(@round(try std.fmt.parseFloat(f64, sent[5]) * 1000));
    try testing.expect(timeout_ms <= 850);
    try testing.expect(timeout_ms + elapsed + 1 >= 850);

    // Its own timeout, when the deadline leaves more: 300 ms.
    _ = try client.run(io, .of(within(io, 1000)), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .{ .at_most = .fromMilliseconds(300) }), .{ .allocator = arena.allocator() });
    try testing.expectEqualStrings("0.3", (try server.entry(io, 1)).args[5]);
}

test "a blocking command with 150 ms or less left of its deadline is DeadlineExceeded, and nothing goes out" {
    const io = testing.io;
    var server: FakeServer = try .start(testing.allocator, io, &.{});
    defer server.stop(io);
    var client: redis.Client = try .init(testing.allocator, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var d: redis.Diagnostics = .{};
    try testing.expectError(error.DeadlineExceeded, client.run(io, .of(within(io, 100)), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .forever), .{ .allocator = arena.allocator(), .diagnostics = &d }));
    // The text says why, and names the command that does not block.
    try testing.expect(std.mem.startsWith(u8, d.message(), "a blocking command needs more than 150 ms left of the deadline"));
    try testing.expect(std.mem.endsWith(u8, d.message(), "for a shorter wait, use redis.cmd.lmove"));
    try testing.expectEqual(0, server.received(io));
}
```

## Tests without Redis

`redis.testing.FakeServer` runs the tests of your code without a Redis
server, on the real client: it listens on loopback, plays a script, and
your code talks to it through a `redis.Client`, as to any Redis.

- **`FakeServer.start(gpa, io, steps)`** listens on 127.0.0.1, on a port
  that the system picks, and serves in tasks of its own; `url()` gives
  `redis://127.0.0.1:<port>`, for `Options.url`, and `stop(io)` ends it.
- **A step** `.expect(.{ "HGETALL", "user:42" }, reply)` waits for that
  command, its name in any case and its arguments byte for byte, and
  answers it with `reply`; `.send(reply)` sends a reply without a request,
  right after the step before it, on its connection: a message to a
  subscriber. The steps run in the order the commands come, on all the
  connections together.
- **A reply** is data: `.ok`, `.nil`, `.integer`, `.string`, `.double`,
  `.boolean`, `.array`, `.set`, `.pairs` for a map, `.push`, `.err` with
  its code first; `.map(…)` of strings, as HGETALL answers, and
  `.subscribed(channels)` and `.message(channel, payload)` for a
  subscriber. Or it is what a server does: `.delayed` answers after a
  pause, `.close_connection` reads the command and closes without a reply,
  `.refuse_connections` closes every connection and refuses new ones until
  `acceptConnections(io)`, a server that went away; `.malformed` breaks
  RESP3, and `.raw` sends bytes as they are.
- **The handshake** the server answers itself: HELLO, CLIENT SETINFO,
  SELECT, and PING, which goes to the journal. `startWith(gpa, io,
  .{ .hello = .{ .password = "…" } })` makes it want a password, and
  `.hello` can make it say that it is another server; `.handler`, a type
  of yours with `pub fn answer(self, io, arena, request)
  FakeServer.Handler.Error!FakeServer.Reply`, answers the commands that the
  steps do not expect, for tests whose commands come in no set order, as
  in [the deadlines](#deadlines-and-cancellation).
- **`finish(io)`** fails when a step has not run, or a command came that
  no step expected, and says which. Such a command gets an error from the
  server: `-ERR zefir FakeServer: unexpected command …`.
- **The journal** gives `received(io)`, the number of commands that came;
  `entry(io, i)`, command number `i`, its `args` and the number of the
  `connection` it came on; and `count(io, name)`, the commands of one name.
  With it a test checks what your code sent, and that it sent nothing
  twice.

The profiles of the shop's customers, as an application keeps them:

```zig
//! The profiles of the shop's customers, as the application keeps them: a
//! hash `user:<id>` for each customer, whose fields are those of
//! `Profile`. It sees a `*redis.Client` only, so the same code runs against
//! Redis and, in profiles_test.zig, against `redis.testing.FakeServer`.

const std = @import("std");
const redis = @import("redis");
const cmd = redis.cmd;
const Profiles = @This();

client: *redis.Client,

pub const Profile = struct {
    name: []const u8,
    age: u8,
    plan: enum { free, pro } = .free,
    /// How many times the customer came, as `visit` counts them.
    visits: i64 = 0,
};

pub fn init(client: *redis.Client) Profiles {
    return .{ .client = client };
}

/// Keeps `profile` as the profile of the customer `id`: a field of the
/// hash for each field of the struct.
pub fn save(profiles: Profiles, io: std.Io, op: redis.OperationContext, id: u64, profile: Profile) redis.Error!void {
    var buffer: [32]u8 = undefined;
    try profiles.client.run(io, op, cmd.hset(key(&buffer, id), profile), .{});
}

/// The profile of the customer `id`, its strings in `arena`; null when the
/// customer has none.
pub fn byId(profiles: Profiles, io: std.Io, op: redis.OperationContext, arena: std.mem.Allocator, id: u64) redis.Error!?Profile {
    var buffer: [32]u8 = undefined;
    return profiles.client.run(io, op, cmd.hgetall(Profile, key(&buffer, id)), .{ .allocator = arena });
}

/// Counts a visit of the customer `id`, and returns how many there were.
pub fn visit(profiles: Profiles, io: std.Io, op: redis.OperationContext, id: u64) redis.Error!i64 {
    var buffer: [32]u8 = undefined;
    return profiles.client.run(io, op, cmd.hincrby(key(&buffer, id), "visits", 1), .{});
}

/// "user:<id>", in `buffer`: "user:" and the 20 digits of the largest u64
/// fit.
fn key(buffer: *[32]u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "user:{d}", .{id}) catch unreachable;
}
```

And their tests:

```zig
//! Tests of the profiles of the shop without Redis. Each runs `Profiles`
//! on a real `redis.Client`, connected to `redis.testing.FakeServer`: a
//! server on loopback that plays a script, the commands it expects and
//! what it answers them, and keeps a journal of what came.

const std = @import("std");
const redis = @import("redis");
const Profiles = @import("Profiles.zig");
const testing = std.testing;
const FakeServer = redis.testing.FakeServer;

test "a profile is read from its hash" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The script: HGETALL user:42, answered with the fields of a hash.
    var server: FakeServer = try .start(gpa, io, &.{
        .expect(.{ "HGETALL", "user:42" }, .map(&.{ .{ "name", "Ann" }, .{ "age", "30" }, .{ "plan", "pro" } })),
    });
    defer server.stop(io);
    // A client of it, as of any Redis.
    var client: redis.Client = try .init(gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const profiles: Profiles = .init(&client);
    const ann = (try profiles.byId(io, .of(.root), arena.allocator(), 42)).?;
    try testing.expectEqualStrings("Ann", ann.name);
    try testing.expectEqual(30, ann.age);
    try testing.expectEqual(.pro, ann.plan);
    // A field that the hash lacks takes its default.
    try testing.expectEqual(0, ann.visits);
    try server.finish(io); // the script ran to its end, and nothing else came
}

test "a customer without a profile has none: HGETALL of a key that is not there answers an empty map" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server: FakeServer = try .start(gpa, io, &.{
        .expect(.{ "HGETALL", "user:7" }, .{ .pairs = &.{} }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const profiles: Profiles = .init(&client);
    try testing.expect(try profiles.byId(io, .of(.root), arena.allocator(), 7) == null);
    try server.finish(io);
}

test "a profile is saved as a field of the hash for each field of the struct, and a visit counts in its field" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The fields go in the order of the struct, the enum as its name; the
    // server answers HSET with how many fields were new.
    var server: FakeServer = try .start(gpa, io, &.{
        .expect(.{ "HSET", "user:42", "name", "Ann", "age", "30", "plan", "pro", "visits", "0" }, .{ .integer = 4 }),
        .expect(.{ "HINCRBY", "user:42", "visits", "1" }, .{ .integer = 1 }),
    });
    defer server.stop(io);
    var client: redis.Client = try .init(gpa, io, .{ .url = server.url() });
    defer client.deinit();
    try client.connect(io, .root, null);
    defer client.close(io);

    const profiles: Profiles = .init(&client);
    try profiles.save(io, .of(.root), 42, .{ .name = "Ann", .age = 30, .plan = .pro });
    try testing.expectEqual(1, try profiles.visit(io, .of(.root), 42));
    // The journal: what came, in order, byte for byte.
    try testing.expectEqual(2, server.received(io));
    try testing.expectEqualStrings("HINCRBY", (try server.entry(io, 1)).args[0]);
    try server.finish(io);
}
```

- The client is real and talks to the server over loopback, so the
  deadlines, the cancellation and the errors in a test are those of
  production.
- The server comes before the client, and `defer client.deinit()` before
  `defer client.close(io)`, so that their `defer`s close the client first
  and stop the server last.
- The build of zefir runs these tests, and those of
  [pipelines](#pipelines) and of [deadlines](#deadlines-and-cancellation),
  in `zig build test-redis`.
