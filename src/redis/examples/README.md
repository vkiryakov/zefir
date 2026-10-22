# redis

> [!WARNING]
> **No TLS yet: use it only in a network you trust.** zefir-redis speaks
> plain TCP. The password goes to the server as it is, in the HELLO of
> every new connection, and so does every command and every value: whoever
> can read the traffic reads them all. Until the client has TLS, keep
> Redis and its services in a closed network, give each service a user of
> its own with a long random password, and across a network you do not
> trust, use a tunnel: WireGuard, SSH or a service mesh.

**A Redis client for Zig services.** Redis is a server that keeps data
in memory: every piece of it sits under a *key*, a name such as
`session:7f3a9c`, and a key holds a value of one of a few types, a string,
a hash of fields, a list, a set, a sorted set or a stream. A key may
expire. That makes Redis the place for what a service needs fast and for a
while: sessions, caches, counters, limits on requests, queues of work,
leaderboards and messages between services. [Valkey](https://valkey.io)
is a server of the same kind, which speaks the same protocol. This module
is the client side: it connects to one server, keeps a pool of connections
that every task of the service shares, and sends commands whose replies
it reads straight into Zig types. It is written against `std.Io` only,
and runs on [zio](https://github.com/lalinsky/zio) in production.

> [!IMPORTANT]
> **Not in v0.1 (TODO):**
>
> - **One standalone server only.** Sentinel and Cluster come later, and
>   with them replicas to read from and sharded pub/sub. A client refuses a
>   node of a cluster or a Sentinel when it connects, with `Unsupported` and
>   the mode of the server, so a cloud Redis in cluster mode does not
>   connect.
> - **TLS**, see above, and with it the authentication by tokens that
>   expire, as the clouds' IAM has it: the password stays as `init` got it.
> - **Redis 7.2 or later, or Valkey 8 or later, in RESP3.** A client refuses
>   an older server when it connects, with its version.
> - **Retries.** The client never repeats a command by itself.
>   `redis.outcome` tells which failed calls are safe to make again,
>   [Errors and what is safe to retry](#errors-and-what-is-safe-to-retry)
>   which of them are worth it, and your code decides.
> - **A subscription as it was made.** The channels and the patterns of a
>   subscriber are set when it subscribes; to change them, close it and
>   subscribe again.
> - **No TCP keepalive.** `std.Io.net` has no socket options yet. Instead
>   the client checks a connection that idled 30 s with PING before a call
>   takes it, and a subscriber sends PING after a silence; a blocking
>   command that waits `.forever` without a deadline on a dead connection
>   waits until its task is canceled.
> - **`close` and `shutdown` on Windows.** Under zio on Windows, `close`
>   cannot cut a read that already waits for the server: such a call ends
>   with the server's reply or at its own deadline, and the `next` of a
>   subscriber at its next PING. `close` and `shutdown` wait for it, past
>   `close_timeout` and the deadline of `shutdown`: a blocking command with
>   `.forever` and no deadline keeps them waiting until the server answers.
> - **Modules and caching on the client.** No commands of JSON, Search,
>   Bloom, TimeSeries or vector sets in the catalog, and no
>   `CLIENT TRACKING`; `cmd.raw` with `redis.Value` sends the commands of
>   modules by hand.
> - **A part of the commands.** About 90, see [The catalog](#the-catalog);
>   no functions (`FUNCTION`, `FCALL`), `EVAL_RO` or `SCRIPT LOAD`, one
>   stream per typed read, and no `CLIENT UNBLOCK` for a blocked command of
>   a canceled task. `cmd.raw` sends what the catalog lacks.
> - **One connection shared by many calls**, with their commands pipelined
>   on it: later, if a benchmark shows that it pays. `run` and `pipeline`
>   will not change.
> - **A hook for observers**, such as OpenTelemetry, and metrics beyond
>   `client.stats()`.

From [the quick start](#quick-start): a session that expires, and a
profile in a hash, read back into a struct.

```zig
// A session: its token names the customer, for half an hour.
try client.run(io, op, cmd.set("session:7f3a9c", "42", .{ .ttl = .fromSeconds(30 * 60) }), .{});
const user = try client.run(io, op, cmd.get([]const u8, "session:7f3a9c"), .{ .allocator = arena });
app.info("Signed in", .{ .session = "7f3a9c", .user = user });
```

```zig
// The profile: a hash with a field for each field of Profile.
try client.run(io, op, cmd.hset("user:42", Profile{ .name = "Ann", .age = 30, .plan = .pro }), .{});
const visits = try client.run(io, op, cmd.hincrby("user:42", "visits", 1), .{});
app.info("Visit", .{ .user = 42, .visits = visits });
const profile = (try client.run(io, op, cmd.hgetall(Profile, "user:42"), .{ .allocator = arena })) orelse
    return error.ProfileGone;
```

- **One client for the whole service.** Any task may call it at once; its
  pool of connections serves them, first come first served.
- **A command is a value, and its reply a Zig type.**
  `cmd.get(i64, "views")` knows its command and that its reply is a
  `?i64`; a hash reads
  into a struct of yours, and a reply that does not fit its type is an
  error that leaves the connection fine.
- **About 90 commands** of strings, keys, hashes, lists, sets, sorted sets,
  streams with consumer groups, scripts and pub/sub, and `cmd.raw` for any
  other.
- **Pipelines, transactions with WATCH, Lua scripts by their SHA1,
  subscribers, and blocking commands** whose timeout on the server comes
  from the deadline of the call.
- **Errors that say whether to retry.** Every error is one of 16 names, and
  each tells whether the server may have run the command; the details, the
  server's code and text among them, are in `redis.Diagnostics`.
- **Deadlines of zefir-core.** A call takes a `core.Context`: its deadline
  bounds the call, and its token stops the call before it goes out.
- **Tests without Redis.** `redis.testing.FakeServer` plays a script on
  loopback, and your code talks to it through a real client.
- **No dependencies.** Only the standard library and zefir-core; zio comes
  from your build, not from Zefir.

## Contents

- [How Redis keeps data](#how-redis-keeps-data)
- [How the client works](#how-the-client-works)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Connecting](#connecting)
- [Commands and replies](#commands-and-replies)
- [The catalog](#the-catalog)
- [Pipelines](#pipelines)
- [Transactions and WATCH](#transactions-and-watch)
- [Blocking commands and the reliable queue](#blocking-commands-and-the-reliable-queue)
- [Scripts](#scripts)
- [Streams and consumer groups](#streams-and-consumer-groups)
- [Pub/sub](#pubsub)
- [Errors and what is safe to retry](#errors-and-what-is-safe-to-retry)
- [Deadlines and cancellation](#deadlines-and-cancellation)
- [The pool, closing and statistics](#the-pool-closing-and-statistics)
- [Under zefir.App](#under-zefirapp)
- [Logs](#logs)
- [Tests without Redis](#tests-without-redis)

Programs that `zig build e2e` in `tests/redis` builds and runs against
Redis and Valkey, checking what they print against this guide: [quick start](quick_start.zig) · [connecting](connect.zig) ·
[the best customers](leaders.zig) · [checkout](checkout.zig) · [a limit on
requests](limits.zig) · [shipping](orders.zig) ·
[notifications](notifications.zig) · [errors](errors.zig). Tests that
`zig build test-redis` runs without a server: [pipelines](pipeline_test.zig)
· [deadlines](deadlines_test.zig) · [tests of an
application](profiles_test.zig).

## How Redis keeps data

Picture the coffee shop of this guide. Everything it keeps in Redis is a
key with a value:

```mermaid
flowchart LR
    server[("Redis")] --> db["database 0"]
    db --> session["session:7f3a9c<br/>a string: 42,<br/>expires in 30 minutes"]
    db --> views["views:/home<br/>a string: 3, a counter"]
    db --> user["user:42<br/>a hash: name Ann, age 30,<br/>plan pro, visits 1"]
    db --> paid["orders:paid<br/>a list: ann, cleo"]
    db --> leaders["leaders<br/>a sorted set: cleo 240,<br/>bob 129.5, ann 120.5, dan 15"]
    db --> shipping["shipping<br/>a stream: 1001, 1002, 1003"]
```

- **Keys.** A key is a name, a string of bytes, whose parts are set apart
  by colons by custom: `user:42`. Every command names the keys it works
  on. There is no schema: the first write to a key makes it, with the type
  of that write, and deleting the last value of a list or a hash deletes
  the key.
- **Types.** A *string* holds bytes, text or a number, which INCR counts
  up; a *hash* holds fields and their values, like a struct; a *list*
  holds values in order, a queue; a *set* holds values without order and
  without repeats; a *sorted set* holds members with scores, in the order
  of their scores; a *stream* holds entries that only grow, each with an id
  from the server's clock, and groups of consumers that share them. A
  command of one type on a key of another fails with `WRONGTYPE`.
- **A time to live.** A key may expire: the server deletes it once its
  time is over. Sessions and caches live so, and so do the windows of a
  limit on requests.
- **In memory.** Redis keeps it all in memory, which makes it fast, and
  writes it to disk only when it is set up to. A session or a cache may be
  lost with no harm; the only copy of an order belongs in a database.
- **Databases.** A server has 16 numbered databases, 0 by default; the
  path of the URL picks one, `redis://host:6379/2`.
- **Commands.** A client sends commands, each a list of strings, such as
  `SET session:7f3a9c 42 PX 1800000`. The server runs them one at a time,
  so a command never sees another one half done.

## How the client works

One `redis.Client` talks to one server. The tasks of a service call it at
once, and it keeps a pool of connections for them:

```mermaid
flowchart LR
    subgraph yours["your tasks"]
        a["client.run(…)"]
        b["client.pipeline(…)"]
        c["conn.transaction(…)"]
        d["sub.next(…)"]
    end
    a --> client["redis.Client"]
    b --> client
    c -->|"a redis.Conn holds one"| client
    client --> pool[("the pool: idle connections,<br/>calls waiting in line")]
    pool --> c1(["connection"])
    pool --> c2(["connection"])
    c1 --> server[("Redis")]
    c2 --> server
    d --> own(["the subscriber's own connection"])
    own --> server
```

1. **A call takes a connection:** an idle one from the pool, or a new one
   when none is idle and the pool has room, up to `max_connections` (32),
   two opening at once at most. A call that finds neither waits in line,
   first come first served, until its deadline.
2. **A new connection introduces itself.** Its first command is `HELLO 3`,
   which makes it speak RESP3, the protocol of Redis since 6.0, carries the
   user and the password when there is one, and the name of
   `client_name`. The server answers what it is, and anything but Redis 7.2
   or later or Valkey 8 or later, standalone, is refused. Then
   `CLIENT SETINFO` tells the server the name and the version of the
   client, and `SELECT` picks the database of the URL.
3. **The command goes out and the reply comes back** on that connection,
   in one write and one read; the client reads the reply straight into the
   type that the call named.
4. **The connection goes back to the pool**, unless the exchange broke it.
   One that idled for more than 30 s answers a PING before a call takes it,
   so that a connection that a firewall or the server's `timeout` closed
   during the night fails no call.

Two things take a connection out of the pool for longer: a `redis.Conn`,
from `client.acquire`, holds one for one task, for WATCH and
transactions; and a `redis.Subscriber`, from `client.subscribe`, opens one
of its own, outside the pool. The client has no tasks of its own:
everything happens in the calls of your tasks.

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

Valkey works the same way,
`docker run --rm -p 6379:6379 valkey/valkey:9.1.2`: the programs of this
guide run against Redis 7.2, Redis 8.10 and Valkey 9.1, and print the
same.

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
/// hash for each field of the struct. `visits` is optional, so that HSET
/// of a profile without it leaves it out, and never resets what HINCRBY
/// counted.
const Profile = struct {
    name: []const u8,
    age: u8,
    plan: enum { free, pro } = .free,
    visits: ?i64 = null,
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
2026-10-22T07:52:41.397Z INFO  [app] Connected
2026-10-22T07:52:41.398Z INFO  [app] Signed in session=7f3a9c user=42
2026-10-22T07:52:41.399Z INFO  [app] Session expires in_minutes=30
2026-10-22T07:52:41.400Z INFO  [app] Home page views=1 ttl_set=true motd="Fresh beans from Ethiopia"
2026-10-22T07:52:41.400Z INFO  [app] Home page views=2 ttl_set=true motd="Fresh beans from Ethiopia"
2026-10-22T07:52:41.400Z INFO  [app] Home page views=3 ttl_set=true motd="Fresh beans from Ethiopia"
2026-10-22T07:52:41.401Z INFO  [app] Visit user=42 visits=1
2026-10-22T07:52:41.401Z INFO  [app] Profile name=Ann age=30 plan=pro visits=1
2026-10-22T07:52:41.402Z INFO  [app] Signed out deleted=1 session=null
2026-10-22T07:52:41.402Z INFO  [app] Done connections=1 in_use=0
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
  server. `visits` is optional: HSET of a profile without it leaves it
  out, so it never resets what HINCRBY counted.
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

## Commands and replies

### A command is a value

A function of `redis.cmd` sends nothing. It returns a small value, the
keys and the arguments of the command, whose type knows the command on the
wire and the type of its reply; `client.run` sends it and returns that
reply. So the compiler knows what each call returns:

| Call | Sends | `run` returns |
|---|---|---|
| `cmd.get([]const u8, "motd")` | `GET motd` | `?[]const u8`: null when the key is not there |
| `cmd.get(i64, "views:/home")` | `GET views:/home` | `?i64`: the string the server keeps, read as a number |
| `cmd.set("session:7f3a9c", "42", .{ .ttl = .fromSeconds(1800) })` | `SET session:7f3a9c 42 PX 1800000` | `void` |
| `cmd.incr("views:/home")` | `INCR views:/home` | `i64`: the new count |
| `cmd.hgetall(Profile, "user:42")` | `HGETALL user:42` | `?Profile`: null when there is no hash |

- **Names.** A function is named after its command, in lower case, and a
  form of a command with another reply is a function of its own: `setNx`
  answers whether it wrote. `type` is a keyword of Zig, so TYPE is
  `keyType`.
- **Durations** are `std.Io.Duration`, and go to the server in
  milliseconds. One under 1 ms is `InvalidArgument`: `PEXPIRE key 0` would
  delete the key.
- **Lists.** An empty list where a command takes one or more, the keys of
  `del`, the members of `sadd`, is `InvalidArgument`, and so is NaN for a
  score: the client stops the call before anything goes out.
- **A command holds the slices it was given:** they must live while it
  runs. It holds no state, so it may be built once and run many times; its
  type has a name, `cmd.Set([]const u8)` or `cmd.Incr`, for an array of
  commands in a [pipeline](#pipelines).

### The type of the reply

The type that the call names decides how its reply is read, and one
decoder reads every reply, by these rules:

| Type | Reads | Note |
|---|---|---|
| `void` | any reply but an error | the reply is read and dropped |
| `bool` | a boolean; the integers 1 and 0; the strings "1" and "0" | EXPIRE and SISMEMBER answer integers |
| integers | an integer; a string or a big number with a number in range | GET of a counter gives a string |
| `f32`, `f64` | a double, `inf` and `nan` too; an integer; a string with a number | INCRBYFLOAT answers a string |
| `[]const u8` | a string of any kind; a number, as its text | |
| `?T` | null, or what `T` reads | |
| an exhaustive `enum` | a string that names one of its tags | |
| `[]const T`, `[N]T` | an array or a set, of what `T` reads | |
| a tuple, `struct { A, B }` | an array of exactly that many | a script's table, in [Scripts](#scripts) |
| a struct | a map by the names of its fields, or an array of field and value pairs | a hash, or an entry of a stream |
| `redis.Value` | anything | for replies of any shape |

- **A reply that does not fit** its type is `UnexpectedReply`. The client
  reads the reply to its end, so the connection stays fine, and the
  diagnostics say what came and what the call asked for, without the
  value: "the reply is a bulk string of 25 bytes, and the call asked for
  ?i64".
- **An error of the server** is `ServerError`, whatever the type, with its
  code and its text in the diagnostics.
- **A hash and a struct.** `cmd.hset(key, value)` writes a field of the
  hash for each field of the struct: a number, a bool or an enum as its
  text, and an optional that is null not at all. `cmd.hgetall(T, key)`
  reads them back: a field that the hash lacks takes the default of the
  struct's field, an optional null, and without either the call is
  `UnexpectedReply`; the fields of the hash that the struct lacks are
  skipped; a hash that is not there is null. A nested struct, a slice
  other than a string, a union or a pointer is a compile error, as a hash
  has no nesting; `[]const redis.FieldValue` reads a hash of any fields.
- **`redis.Value`** is a union of what RESP3 sends: null, booleans,
  integers, doubles, big numbers, strings, arrays, sets, maps with their
  pairs in the server's order, and the errors inside an array.
- **Limits.** A reply larger than `max_reply_bytes`, or nested deeper than
  64 levels, is `ReplyTooLarge`, found before anything is allocated, and
  its connection closes. The limit counts bytes on the wire, and memory
  may take more: the elements of an array are allocated as soon as its
  header comes, and each takes 3 bytes on the wire at least, so a slice of
  `T` may take up to `@sizeOf(T) / 3` times `max_reply_bytes` in the arena,
  and `redis.Value`, of 40 bytes, about 13 times.

### Memory

- **Arguments** are borrowed until the call returns: the client writes
  them straight into its connection, large ones without a copy.
- **A reply** that holds strings or slices comes from `options.allocator`,
  an arena: the client takes from it during the call only and frees
  nothing, so the reply lives as long as the arena, often the one of a
  request. A call whose reply needs memory and has no `.allocator` is
  `InvalidArgument` before anything goes out. Numbers, bools, enums and
  `void` need none, hence `.{}`.
- **Borrowed results.** A message of a subscriber lives until its next
  `next`, and so does an item of an iterator: the only results that the
  client keeps for you.

### Commands of your own: cmd.raw

`cmd.raw(T, args)` sends a command that the catalog lacks. `args` is a
tuple of strings, numbers, bools and enums, the name of the command
first, or a slice of strings for a command built at run time, and the
reply reads into `T` by the rules above. [The limit on
requests](#scripts) flushes the scripts of the server with it:

```zig
try client.run(io, op, cmd.raw(void, .{ "SCRIPT", "FLUSH" }), .{});
```

The commands that change the state of their connection do not go
through `raw`, as the calls after them on that connection would inherit
it: `InvalidArgument`, with what to use instead, for these:

| Commands | Why not | Instead |
|---|---|---|
| `HELLO`, `AUTH`, `RESET` | they change the protocol or the user of the connection | the handshake of the client |
| `SELECT` | the later calls would go to another database | the database in the path of the URL |
| `QUIT` | it closes the connection | `close` |
| `MULTI`, `EXEC`, `DISCARD` | they leave the connection in a transaction | `conn.transaction` |
| `WATCH`, `UNWATCH` | they hold keys on the connection | `cmd.watch`, `cmd.unwatch` on a `redis.Conn` |
| `SUBSCRIBE` and its kin | pushes would come on the connection | `client.subscribe` |
| `MONITOR`, `SYNC`, `PSYNC`, `REPLCONF` | the connection stops answering commands | — |
| `CLIENT REPLY`, `CLIENT TRACKING`, `CLIENT CACHING` | they break the count of replies, or send pushes | — |
| `READONLY`, `READWRITE`, `ASKING` | they are commands of a cluster | — |

A blocking command through `raw` gets no timeout from the deadline, see
[the blocking commands](#blocking-commands-and-the-reliable-queue).

## The catalog

About 90 commands, by the type of the data. Each function is named after
its command; the options in braces are a struct with defaults, and `T` is
the type that the reply reads into. [Commands and
replies](#commands-and-replies) has the rules every one follows.

**Strings and counters**

| Function | Command | Returns |
|---|---|---|
| `get(T, key)` | GET | `?T` |
| `set(key, value, .{ .ttl, .keep_ttl })` | SET [PX] [KEEPTTL] | `void` |
| `setNx(key, value, .{ .ttl })`, `setXx(key, value, .{ .ttl, .keep_ttl })` | SET NX, SET XX | `bool`: whether it wrote |
| `getdel(T, key)`, `getex(T, key, .{ .ttl, .persist })` | GETDEL, GETEX | `?T` |
| `mget(T, keys)`, `mset(pairs)` | MGET, MSET | `[]const ?T`, `void` |
| `incr(key)`, `decr(key)`, `incrby(key, by)`, `decrby(key, by)` | INCR… | `i64`: the new value |
| `incrbyfloat(key, by)` | INCRBYFLOAT | `f64` |

**Keys**

| Function | Command | Returns |
|---|---|---|
| `del(keys)`, `unlink(keys)`, `exists(keys)` | DEL, UNLINK, EXISTS | `u64`: how many |
| `expire(key, ttl)`, `persist(key)` | PEXPIRE, PERSIST | `bool`: whether it changed |
| `ttl(key)` | PTTL | `redis.Ttl`: `.expires_in`, `.persistent` or `.missing` |
| `keyType(key)` | TYPE | `redis.KeyType`; `type` is a keyword of Zig |
| `rename(key, new_key)` | RENAME | `void` |
| `scan(.{ .cursor, .match, .count, .type })` | SCAN | `redis.ScanPage([]const u8)`: one page |
| `ping()` | PING | `void` |

**Hashes**

| Function | Command | Returns |
|---|---|---|
| `hset(key, fields)` | HSET | `void`; `fields` is a struct or `[]const redis.FieldValue` |
| `hsetnx(key, field, value)` | HSETNX | `bool` |
| `hget(T, key, field)`, `hmget(T, key, fields)` | HGET, HMGET | `?T`, `[]const ?T` |
| `hgetall(T, key)` | HGETALL | `?T`: a struct, or `[]const redis.FieldValue` |
| `hdel(key, fields)`, `hexists(key, field)`, `hlen(key)` | HDEL, HEXISTS, HLEN | `u64`, `bool`, `u64` |
| `hincrby(key, field, by)`, `hincrbyfloat(key, field, by)` | HINCRBY, HINCRBYFLOAT | `i64`, `f64` |
| `hkeys(key)` | HKEYS | `[]const []const u8` |
| `hscan(key, .{ .cursor, .match, .count })` | HSCAN | `redis.ScanPage(redis.FieldValue)` |

**Lists**

| Function | Command | Returns |
|---|---|---|
| `lpush(key, values)`, `rpush(key, values)` | LPUSH, RPUSH | `u64`: the length |
| `lpop(T, key)`, `rpop(T, key)`, `lindex(T, key, index)` | LPOP, RPOP, LINDEX | `?T` |
| `llen(key)`, `lrange(T, key, start, stop)` | LLEN, LRANGE | `u64`, `[]const T` |
| `ltrim(key, start, stop)`, `lrem(key, count, value)` | LTRIM, LREM | `void`, `u64` |
| `lmove(T, source, destination, from, to)` | LMOVE | `?T` |
| `blpop(T, keys, timeout)`, `brpop(T, keys, timeout)` | BLPOP, BRPOP | `?redis.Popped(T)`: the key and the value |
| `blmove(T, source, destination, from, to, timeout)` | BLMOVE | `?T` |

**Sets**

| Function | Command | Returns |
|---|---|---|
| `sadd(key, members)`, `srem(key, members)` | SADD, SREM | `u64` |
| `sismember(key, member)` | SISMEMBER | `bool` |
| `smembers(T, key)`, `sinter(T, keys)`, `sunion(T, keys)`, `sdiff(T, keys)` | SMEMBERS… | `[]const T` |
| `scard(key)`, `spop(T, key)` | SCARD, SPOP | `u64`, `?T` |
| `sscan(key, .{ .cursor, .match, .count })` | SSCAN | `redis.ScanPage([]const u8)` |

**Sorted sets**

| Function | Command | Returns |
|---|---|---|
| `zadd(key, members, .{ .only, .compare, .changed })` | ZADD [NX\|XX] [GT\|LT] [CH] | `u64`: how many were added |
| `zincrby(key, by, member)`, `zscore(key, member)` | ZINCRBY, ZSCORE | `f64`, `?f64` |
| `zrank(key, member)`, `zrevrank(key, member)` | ZRANK, ZREVRANK | `?u64` |
| `zrem(key, members)`, `zcard(key)`, `zcount(key, min, max)` | ZREM, ZCARD, ZCOUNT | `u64` |
| `zrange(T, key, start, stop, .{ .rev })` | ZRANGE [REV] | `[]const T`; with `T` a `redis.Scored(M)`, the scores too |
| `zrangeByScore(T, key, min, max, .{ .rev, .limit })` | ZRANGE BYSCORE | `[]const T` |
| `zpopmin(T, key)`, `zpopmax(T, key)` | ZPOPMIN, ZPOPMAX | `?redis.Scored(T)` |
| `zremrangebyscore(key, min, max)`, `zremrangebyrank(key, start, stop)` | ZREMRANGEBY… | `u64` |
| `zscan(key, .{ .cursor, .match, .count })` | ZSCAN | `redis.ScanPage(redis.Scored([]const u8))` |

**Streams**

| Function | Command | Returns |
|---|---|---|
| `xadd(key, fields, .{ .id, .max_len, .approximate })` | XADD | `redis.StreamId` |
| `xaddNoMkstream(key, fields, .{…})` | XADD NOMKSTREAM | `?redis.StreamId`: null when the stream is not there |
| `xlen(key)` | XLEN | `u64` |
| `xrange(T, key, .{ .start, .end, .count })`, `xrevrange(…)` | XRANGE, XREVRANGE | `[]const redis.Entry(T)` |
| `xread(T, key, .{ .after, .count, .block })` | XREAD | `[]const redis.Entry(T)` |
| `xgroupCreate(key, group, .{ .start, .mkstream })` | XGROUP CREATE | `void` |
| `xreadgroup(T, key, .{ .group, .consumer, .from, .count, .block, .no_ack })` | XREADGROUP | `[]const redis.Entry(T)` |
| `xack(key, group, ids)` | XACK | `u64` |
| `xpending(key, group)` | XPENDING | `redis.PendingSummary` |
| `xpendingRange(key, group, .{ .count, .start, .end, .consumer, .min_idle })` | XPENDING … | `[]const redis.Pending` |
| `xautoclaim(T, key, .{ .group, .consumer, .min_idle, .start, .count })` | XAUTOCLAIM | `redis.Claimed(T)` |
| `xdel(key, ids)`, `xtrim(key, by, .{ .approximate })` | XDEL, XTRIM | `u64` |

**Scripts, pub/sub and the rest**

| Function | Command | Returns |
|---|---|---|
| `eval(T, source, keys, args)` | EVAL | `T` |
| `evalScript(T, &script, keys, args)` | EVALSHA, EVAL after NOSCRIPT | `T` |
| `publish(channel, message)` | PUBLISH | `u64`: how many subscribers got it |
| `watch(keys)`, `unwatch()` | WATCH, UNWATCH, on a `redis.Conn` only | `void` |
| `raw(T, args)` | as given | `T` |

What the catalog lacks, `cmd.raw` sends: APPEND and the bits, EXPIREAT,
LPOS, SMOVE, ZUNION, XCLAIM and XINFO, FUNCTION and FCALL, HyperLogLog,
geo, the commands of modules, INFO and CONFIG among them.

### The best customers, and the sessions of one

`leaders.zig` keeps the shop's best customers in a sorted set, and signs a
customer out everywhere by walking the keys with SCAN:

```zig
//! The best customers of the shop, in a sorted set: what each spent is
//! their score, the server keeps them in order, and the top comes in one
//! call. Then the sessions of one customer, found by walking the keys with
//! SCAN, end at once: "sign out everywhere". Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-leaders` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        password: ?confy.Secret = null,
    } = .{},
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

    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{"leaders"}), .{});

    // What each customer spent, as a member of the set and its score.
    _ = try client.run(io, op, cmd.zadd("leaders", &.{
        .{ .member = "ann", .score = 120.5 },
        .{ .member = "bob", .score = 87 },
        .{ .member = "cleo", .score = 240 },
        .{ .member = "dan", .score = 15 },
    }, .{}), .{});
    // Bob buys more: his score grows, and the set keeps its order.
    const bob = try client.run(io, op, cmd.zincrby("leaders", 42.5, "bob"), .{});
    app.info("Bob spent", .{ .total = bob });

    // The top three, the highest first, each with its score: a range read
    // into redis.Scored asks the server for the scores too.
    const top = try client.run(io, op, cmd.zrange(redis.Scored([]const u8), "leaders", 0, 2, .{ .rev = true }), .{ .allocator = arena });
    for (top, 1..) |leader, place| app.info("Top", .{ .place = place, .name = leader.member, .spent = leader.score });
    // Dan's place, from the top: ranks start at 0.
    const dan = (try client.run(io, op, cmd.zrevrank("leaders", "dan"), .{})).?;
    app.info("Dan", .{ .place = dan + 1, .of = try client.run(io, op, cmd.zcard("leaders"), .{}) });
    // The customers who spent 100 or more get a free pack.
    const generous = try client.run(io, op, cmd.zrangeByScore([]const u8, "leaders", .{ .inclusive = 100 }, .max, .{}), .{ .allocator = arena });
    app.info("Free pack", .{ .customers = generous });

    // Six sessions, three of them Ann's on her phone, laptop and tablet.
    for ([_][2][]const u8{
        .{ "session:a1", "ann" },  .{ "session:b2", "bob" }, .{ "session:a3", "ann" },
        .{ "session:c4", "cleo" }, .{ "session:a5", "ann" }, .{ "session:d6", "dan" },
    }) |session| try client.run(io, op, cmd.set(session[0], session[1], .{ .ttl = .fromSeconds(30 * 60) }), .{});

    // Ann signs out everywhere. SCAN walks the keys a page at a time, and
    // the iterator gives them one by one; a page is one call, so the
    // server never blocks on a walk of all its keys.
    var sessions = client.iterate(cmd.scan(.{ .match = "session:*", .count = 100 }), .{ .allocator = init.gpa });
    defer sessions.deinit();
    var ended: u64 = 0;
    while (try sessions.next(io, op)) |key| {
        // The key lives until the next call of next.
        const owner = try client.run(io, op, cmd.get([]const u8, key), .{ .allocator = arena }) orelse continue;
        if (std.mem.eql(u8, owner, "ann")) ended += try client.run(io, op, cmd.del(&.{key}), .{});
    }
    app.info("Ann signed out", .{ .sessions = ended });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}
```

```text
$ zig build run
2026-10-22T05:28:06.199Z INFO  [app] Bob spent total=129.5
2026-10-22T05:28:06.201Z INFO  [app] Top place=1 name=cleo spent=240
2026-10-22T05:28:06.201Z INFO  [app] Top place=2 name=bob spent=129.5
2026-10-22T05:28:06.201Z INFO  [app] Top place=3 name=ann spent=120.5
2026-10-22T05:28:06.206Z INFO  [app] Dan place=4 of=4
2026-10-22T05:28:06.209Z INFO  [app] Free pack customers=[ann,bob,cleo]
2026-10-22T05:28:06.339Z INFO  [app] Ann signed out sessions=3
```

- **A sorted set** keeps its members in the order of their scores: ZADD
  adds them, ZINCRBY adds to a score on the server, and ZRANGE gives a
  range of ranks, here the top three, from the highest with `.rev`. Read
  into `redis.Scored([]const u8)`, the range asks for WITHSCORES, and each
  member comes with its score.
- **Ranks** start at 0: ZREVRANK of Dan is 3, as three customers spent
  more.
- **A range of scores** takes its bounds as `redis.ScoreBound`:
  `.{ .inclusive = 100 }`, `.{ .exclusive = 100 }`, and `.min` and `.max`
  for no bound.
- **SCAN** walks the keys a page at a time, from a cursor: a page is one
  call, so neither the server nor the client holds all the keys at once,
  and the commands of other clients run between the pages. `client.iterate`
  gives the keys of the pages one at a time; it holds a page in an arena of
  its own over `.allocator`, frees it in `deinit`, and a key lives until
  the next `next`. SCAN gives every key that was there for the whole walk
  at least once, and may give one twice when the server grows its table
  meanwhile; a page may be empty while the walk goes on.
- **A page that failed** leaves the iterator where it was: the next `next`,
  under a new context, asks for that page again. The iterator itself never
  retries.
- `hscan`, `sscan` and `zscan` walk a hash, a set and a sorted set the same
  way.

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
    try testing.expectEqualStrings("Fresh beans from Ethiopia", (try r[2]) orelse return error.TestUnexpectedResult);
    // The diagnostics hold the first error: the command's index, and the
    // server's code.
    try testing.expectEqual(1, d.command orelse return error.TestUnexpectedResult);
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
    try testing.expectEqual(2, d.answered orelse return error.TestUnexpectedResult);
    try testing.expectEqual(redis.Outcome.may_have_executed, redis.outcome(error.ConnectionLost));
    try server.finish(io);
}
```

## Transactions and WATCH

A *transaction* runs commands as one: MULTI opens it, the commands queue
up, and EXEC runs them all, with no command of another client between
them. It has no rollback: a command that fails as it runs, such as
WRONGTYPE, fails alone, and the others run. Nor does it read: "take a pack
off the stock, if one is left" needs the stock first, and between the read
and EXEC another customer may take the last pack. WATCH gives the
transaction its condition: the server remembers the keys that it names,
and when any of them changes before EXEC, EXEC runs nothing and answers
null.

```mermaid
sequenceDiagram
    participant A as Ann's connection
    participant R as Redis
    participant B as Bob's connection
    A->>R: WATCH stock:coffee, GET stock:coffee
    R-->>A: 1
    B->>R: WATCH stock:coffee, GET stock:coffee
    R-->>B: 1
    A->>R: MULTI, DECR stock:coffee, RPUSH orders:paid ann, EXEC
    R-->>A: 0, 1: the pack is Ann's
    B->>R: MULTI, DECR stock:coffee, RPUSH orders:paid bob, EXEC
    R-->>B: null: the stock changed after WATCH, and nothing ran
```

WATCH belongs to the connection it goes on, so a transaction with WATCH
needs a connection of its own: `client.acquire` gives a `redis.Conn`,
which holds a connection of the pool for one task until `release`.
`conn.run` and `conn.pipeline` work as the client's do, and
`conn.transaction(io, op, commands, options)` runs `commands` between
MULTI and EXEC: it returns their results as a pipeline does, or null when a
watched key changed.

`checkout.zig` sells the last pack of coffee twice over, then packs the
orders:

```zig
//! The checkout of the shop: customers buy packs of coffee while there are
//! some left. A purchase watches the stock and pays in a transaction, which
//! the server runs only if nobody changed the stock since: two customers
//! race for the last pack, first step by step, then as two tasks of a
//! service. Then the packer takes the paid orders off their queue, so that
//! none is lost: BLMOVE moves each into the list of the orders being
//! packed, which keeps it until it is packed. Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-checkout` runs it against the
//! servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        password: ?confy.Secret = null,
    } = .{},
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

    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{ "stock:coffee", "orders:paid", "orders:packing" }), .{});

    // One pack left, and two customers at the checkout at once. Each has a
    // connection of its own, which holds the WATCH of the stock.
    try client.run(io, op, cmd.set("stock:coffee", 1, .{}), .{});
    {
        var ann = try client.acquire(io, op);
        defer ann.release(io);
        var bob = try client.acquire(io, op);
        defer bob.release(io);
        // Both watch the stock, and both see the last pack.
        app.info("Ann sees", .{ .left = try look(io, op, &ann) });
        app.info("Bob sees", .{ .left = try look(io, op, &bob) });
        // Ann pays first: nobody changed the stock since her WATCH, so the
        // server runs her transaction.
        app.info("Ann pays", .{ .bought = try pay(io, op, &ann, "ann") });
        // Bob pays next: the stock changed since his WATCH, so the server
        // runs none of his.
        app.info("Bob pays", .{ .bought = try pay(io, op, &bob, "bob") });
    }

    // The same race in a service: each customer is a task, and buy pays
    // again whenever the stock changed in between. One of the two gets the
    // pack, whichever is first.
    try client.run(io, op, cmd.set("stock:coffee", 1, .{}), .{});
    var cleo = try io.concurrent(buy, .{ io, &client, op, "cleo" });
    defer _ = cleo.cancel(io) catch false;
    var dan = try io.concurrent(buy, .{ io, &client, op, "dan" });
    defer _ = dan.cancel(io) catch false;
    const bought = @as(u8, @intFromBool(try cleo.await(io))) + @intFromBool(try dan.await(io));
    app.info("Two at once", .{ .bought = bought, .sold_out = 2 - bought });

    // The packer takes the paid orders one at a time. BLMOVE waits for one
    // and moves it into orders:packing in the same step: an order that the
    // packer took stays there until it is packed, so a packer that falls
    // over leaves it there rather than lose it. Each wait has 2 s; the
    // server gets 1.85 of them, so that an empty queue answers null before
    // the deadline.
    var done: usize = 0;
    while (try client.run(io, .of(within(io, .fromSeconds(2))), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .forever), .{ .allocator = arena })) |order| {
        // The order is packed: it leaves orders:packing.
        _ = try client.run(io, op, cmd.lrem("orders:packing", 1, order), .{});
        done += 1;
    }
    app.info("Packed", .{ .orders = done, .packing = try client.run(io, op, cmd.llen("orders:packing"), .{}) });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Watches the stock on `conn`, and returns how many packs are left.
fn look(io: std.Io, op: redis.OperationContext, conn: *redis.Conn) !i64 {
    try conn.run(io, op, cmd.watch(&.{"stock:coffee"}), .{});
    return try conn.run(io, op, cmd.get(i64, "stock:coffee"), .{}) orelse 0;
}

/// Takes a pack off the stock and puts the order of `customer` on the
/// queue of paid orders, in one transaction: false when the stock changed
/// since the WATCH of `conn`, and the server ran none of it.
fn pay(io: std.Io, op: redis.OperationContext, conn: *redis.Conn, customer: []const u8) !bool {
    const done = try conn.transaction(io, op, .{
        cmd.decr("stock:coffee"),
        cmd.rpush("orders:paid", .{customer}),
    }, .{}) orelse return false;
    // Each command ran: an error of one would be in its place.
    _ = try done[0];
    _ = try done[1];
    return true;
}

/// Buys a pack for `customer`: watches the stock and pays, again whenever
/// the stock changed in between. False: sold out.
fn buy(io: std.Io, client: *redis.Client, op: redis.OperationContext, customer: []const u8) !bool {
    while (true) {
        var conn = try client.acquire(io, op);
        defer conn.release(io);
        if (try look(io, op, &conn) == 0) {
            // Nothing to buy. UNWATCH, so that release keeps the connection
            // for the pool rather than close it.
            try conn.run(io, op, cmd.unwatch(), .{});
            return false;
        }
        if (try pay(io, op, &conn, customer)) return true;
    }
}
```

```text
$ zig build run
2026-10-22T05:28:08.349Z INFO  [app] Ann sees left=1
2026-10-22T05:28:08.378Z INFO  [app] Bob sees left=1
2026-10-22T05:28:08.381Z INFO  [app] Ann pays bought=true
2026-10-22T05:28:08.384Z INFO  [app] Bob pays bought=false
2026-10-22T05:28:08.440Z INFO  [app] Two at once bought=1 sold_out=1
2026-10-22T05:28:10.346Z INFO  [app] Packed orders=2 packing=0
```

- **WATCH, then read, then the transaction.** `look` watches the stock and
  reads it on the Conn, and `pay` sends DECR and RPUSH in a transaction.
  The server ran Ann's; Bob's came after the stock changed, and got null:
  none of it ran, so Bob paid nothing.
- **A null means: look again.** In a service, `buy` loops: somebody else
  changed the stock in between, and a fresh look decides. In the run, Cleo
  and Dan raced as two tasks: one of them bought the last pack and the
  other found none, whichever came first.
- **`cmd.watch` and `cmd.unwatch` run on a Conn only.** On the client, or
  inside a transaction, they are a compile error that says where they go.
- **`release`** gives the connection back to the pool, unless keys may
  still be under WATCH on it, as after `look` found no pack: then it closes
  the connection, so that no later call gets the WATCH of another, and
  sends no UNWATCH behind your back. To keep the connection, `buy` sends
  UNWATCH itself. EXEC ends a WATCH either way.
- **MULTI goes alone,** and the client waits for its OK before it sends the
  commands and EXEC in one write: when the server refuses MULTI, as it does
  for a user without the right to it, the commands never run outside a
  transaction.
- **A command that the server refuses as it queues it,** one it does not
  know or one the user may not run, makes the server drop the whole
  transaction: `ServerError` with the code EXECABORT, as
  [errors.zig](#errors-and-what-is-safe-to-retry) shows.
- **A transaction without WATCH,** a batch that runs as one, is the same
  `conn.transaction` on a fresh Conn.
- One task at a time calls a Conn, and every Conn is released before the
  client's `deinit`: in safe builds, either mistake panics.

## Blocking commands and the reliable queue

BLPOP, BRPOP, BLMOVE, and XREAD and XREADGROUP with `.block`, wait on the
server until a value comes, or until their timeout is over: then they
answer null. The timeout is a `redis.Block`: `.forever`, or
`.{ .at_most = duration }`. A server takes 0 as forever, so `.forever` is
written out, and a 0 never waits forever by mistake.

**The timeout comes from the deadline.** Under a deadline, the client
sends the server what the deadline leaves, less 150 ms and the shortest
round trip, or the command's own timeout when that is shorter:

| Deadline of the call | Timeout of the command | The server gets | The call waits |
|---|---|---|---|
| R left | `.at_most = t` | the shorter of `t` and R − 150 ms − rtt | until the deadline |
| R left | `.forever` | R − 150 ms − rtt | until the deadline |
| none | `.at_most = t` | `t` | `t`, and `Options.timeout` more |
| none | `.forever` | 0: forever | until the task is canceled or the client closes (on Windows, only until the task is canceled) |

Here rtt is the shortest round trip to the server that the client has
measured, on the HELLO of its latest connections: the least time a reply
takes, 0 until it has opened two.

Why 150 ms: Redis checks the timeouts of the clients it blocks when its
loop of events goes to sleep, and a quiet server sleeps until its next
timer, 100 ms later at most, as it wakes ten times a second by default
(`hz 10`). So the null of a quiet server comes up to 100 ms after the
timeout. Were the timeout all that the deadline leaves, that null would
come after the deadline: `Timeout` instead of null, a closed connection,
and a value that the server gave out in that moment, lost. With the margin
the null comes before the deadline, from a quiet server too. When that
leaves the server less than 1 ms, with less than 151 ms and the round
trip left, the call is `DeadlineExceeded` and nothing goes out; the text
names the command that does not block, `lmove` for `blmove`. The tests of
[deadlines](#deadlines-and-cancellation) show both.

**A read that takes the value can lose it.** BLPOP takes the value off the
server as it answers. When the answer comes after the deadline after all,
from a busy server or across a slow network, the call is `Timeout`, its
connection closes, and the value is gone; so it is when the task is
canceled while it waits. The margin makes this rare, not impossible.

**The reliable queue** loses nothing: BLMOVE moves the value into a second
list, of the work in progress, in the same step, and the worker takes it
off that list once the work is done. The packer of
[the checkout](#transactions-and-watch) works so:

```zig
    while (try client.run(io, .of(within(io, .fromSeconds(2))), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .forever), .{ .allocator = arena })) |order| {
        // The order is packed: it leaves orders:packing.
        _ = try client.run(io, op, cmd.lrem("orders:packing", 1, order), .{});
        done += 1;
    }
```

An order whose answer was lost, or whose packer fell over, stays in
`orders:packing`, and a job of the service can give those back to
`orders:paid` after a while, with LMOVE. In the run above, the queue ended
empty: the last BLMOVE got 1.85 s of its 2, answered null before the
deadline, and its connection went back to the pool. Streams with a group
keep the same promise in their own way, see [Streams and consumer
groups](#streams-and-consumer-groups).

- **A blocking command holds its connection** of the pool while it waits:
  32 tasks in `blpop(… .forever)` take the whole pool, and the other calls
  wait in line. Wait with `.at_most` in a loop, and give many waiting tasks
  a client of their own, with its own `max_connections`.
- **Without TCP keepalive,** `.forever` without a deadline on a connection
  that died waits until its task is canceled: `.at_most` in a loop catches
  that too.
- **Inside a transaction** a blocking command does not block: the server
  answers at once, and its timeout goes as given.
- **In a pipeline** a blocking command holds the commands after it, and
  gets what is left of the deadline as the pipeline goes out: give a
  pipeline one at most, and last.
- **Through `cmd.raw`** a blocking command gets no timeout from the
  deadline: give it a timeout of the server shorter than what is left of
  the deadline by 150 ms and a round trip at least.

## Scripts

A Lua script runs on the server as one command: no other command runs
while it does, so it reads keys, decides and writes, with nothing between,
which a transaction cannot do. `cmd.eval(T, source, keys, args)` sends its
text with each call. A `redis.Script` holds the text and its SHA1,
computed when the program compiles for a script that is a constant, and
`cmd.evalScript(T, &script, keys, args)` sends the SHA1 alone, EVALSHA.
The server keeps its scripts in a cache that a restart, a failover or
SCRIPT FLUSH empties; EVALSHA then answers NOSCRIPT and runs nothing, and
the client sends the text, EVAL, on the same connection. That is no retry:
nothing ran.

`limits.zig` limits the requests of the shop's API with a script:

```zig
//! A limit on the requests of the shop's API: each customer may make five
//! a minute. A Lua script counts them on the server, so that the count and
//! the end of its minute change together, however many requests come at
//! once. The client sends the script by its SHA1, and its text once when
//! the server lacks it: after the server forgot its scripts, the next call
//! goes on. Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-limits` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        password: ?confy.Secret = null,
    } = .{},
};

/// Counts a request in the window KEYS[1], which lasts ARGV[2] ms from its
/// first request: {1, the requests left} while no more than ARGV[1] came,
/// else {0, the milliseconds until the window ends}. Its SHA1 is computed
/// when the program compiles.
const allow: redis.Script = .init(
    \\local count = redis.call('INCR', KEYS[1])
    \\if count == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[2]) end
    \\local limit = tonumber(ARGV[1])
    \\if count > limit then return {0, redis.call('PTTL', KEYS[1])} end
    \\return {1, limit - count}
);

/// The script's answer, a table of two numbers: a tuple.
const Verdict = struct { i64, i64 };

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

    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);

    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{ "rate:ann", "rate:bob" }), .{});

    // Ann makes seven requests in a row: five pass.
    for (0..7) |_| try request(io, op, &client, app, "ann", "rate:ann");
    // Bob's window is his own.
    try request(io, op, &client, app, "bob", "rate:bob");
    // The server forgets its scripts, as after a restart: the next call
    // gets NOSCRIPT for the SHA1, sends the text, and goes on.
    try client.run(io, op, cmd.raw(void, .{ "SCRIPT", "FLUSH" }), .{});
    try request(io, op, &client, app, "bob", "rate:bob");
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// A request of `customer`, whose window is the key `window`: five a
/// minute.
fn request(io: std.Io, op: redis.OperationContext, client: *redis.Client, app: log.Logger, customer: []const u8, window: []const u8) !void {
    const verdict = try client.run(io, op, cmd.evalScript(Verdict, &allow, &.{window}, .{ 5, 60_000 }), .{});
    if (verdict[0] == 1) {
        app.info("Allowed", .{ .customer = customer, .left = verdict[1] });
    } else {
        app.warn("Too many requests", .{ .customer = customer, .retry_in_s = @divFloor(verdict[1] + 999, 1000) });
    }
}
```

```text
$ zig build run
2026-10-22T05:28:13.267Z INFO  [app] Allowed customer=ann left=4
2026-10-22T05:28:13.397Z INFO  [app] Allowed customer=ann left=3
2026-10-22T05:28:13.418Z INFO  [app] Allowed customer=ann left=2
2026-10-22T05:28:13.420Z INFO  [app] Allowed customer=ann left=1
2026-10-22T05:28:13.430Z INFO  [app] Allowed customer=ann left=0
2026-10-22T05:28:13.441Z WARN  [app] Too many requests customer=ann retry_in_s=60
2026-10-22T05:28:13.457Z WARN  [app] Too many requests customer=ann retry_in_s=60
2026-10-22T05:28:13.504Z INFO  [app] Allowed customer=bob left=4
2026-10-22T05:28:13.576Z INFO  [app] Allowed customer=bob left=3
```

- **The script** counts a request with INCR, ends the window with PEXPIRE
  at its first request, and answers a table of two numbers, which reads
  into a tuple. The keys go in `keys`, the other values in `args`: KEYS[1],
  ARGV[1] and ARGV[2] in the script.
- **One command**, so two requests at once cannot both read four and both
  pass as the fifth.
- **After SCRIPT FLUSH** the call went on as before: EVALSHA met NOSCRIPT,
  and EVAL ran the script.
- **What a script answers**, the server converts: a Lua number becomes an
  integer, its fraction dropped; a table an array; `false` null; and
  `{err = …}` an error, a `ServerError` with that code.
- **In a pipeline or a transaction** `evalScript` sends EVAL at once: there
  a NOSCRIPT could not be answered without changing the order of the
  commands.
- **An error in the middle** of a script leaves the writes it made before:
  a `ServerError` may have run, in part.

## Streams and consumer groups

A *stream* is a log of entries that only grows: XADD appends an entry of
a few fields, and the server gives it an id from its clock,
`<milliseconds>-<sequence>`. Anyone may read a stream from any id. A
*consumer group* shares it among workers: each entry goes to one consumer
of the group and stays *pending* for that consumer until it acknowledges
it, with XACK; when a consumer falls over, another can claim its pending
entries.

```mermaid
flowchart LR
    shop["the shop: XADD"] --> stream[("stream shipping:<br/>1001, 1002, 1003")]
    stream -->|"XREADGROUP: 1001, 1002"| kim["courier kim"]
    stream -->|"XREADGROUP: 1003"| lee["courier lee"]
    kim -->|"XACK 1001"| done(["delivered"])
    kim -.->|"falls over: 1002 stays pending"| pending[["pending for kim"]]
    pending -->|"XAUTOCLAIM, later"| lee
    lee -->|"XACK 1003, 1002"| done
```

`orders.zig` ships the shop's orders through a stream:

```zig
//! The shipping of the shop's orders, through a stream: the shop adds an
//! entry to the stream "shipping" for each order to ship, and the couriers
//! of the group "couriers" take them, each entry to one courier, and
//! acknowledge each once it is delivered. A courier that falls over leaves
//! the entries it took pending, and another claims them. Each run starts
//! afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-orders` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        password: ?confy.Secret = null,
    } = .{},
};

/// An order to ship, as an entry of the stream keeps it: a field for each
/// field of the struct.
const Shipment = struct {
    order: u64,
    address: []const u8,
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

    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{"shipping"}), .{});

    // The group of the couriers, made as the service starts; a group that
    // is there already, from the start before, is fine.
    try createGroup(io, op, &client);
    try createGroup(io, op, &client);

    // Three orders to ship. The server gives each entry its id: the time
    // in milliseconds and a sequence number.
    for ([_]Shipment{
        .{ .order = 1001, .address = "12 Bean Street" },
        .{ .order = 1002, .address = "7 Roast Lane" },
        .{ .order = 1003, .address = "3 Crema Court" },
    }) |shipment| {
        const id = try client.run(io, op, cmd.xadd("shipping", shipment, .{ .max_len = 10_000 }), .{});
        app.info("To ship", .{ .order = shipment.order, .id = id });
    }

    // Kim takes two orders: the group gives them to her alone.
    const kim = try client.run(io, op, cmd.xreadgroup(Shipment, "shipping", .{ .group = "couriers", .consumer = "kim", .count = 2 }), .{ .allocator = arena });
    for (kim) |entry| app.info("Kim takes", .{ .order = entry.fields.?.order });
    // She delivers the first, and acknowledges it: it is done.
    _ = try client.run(io, op, cmd.xack("shipping", "couriers", &.{kim[0].id}), .{});
    app.info("Kim delivers", .{ .order = kim[0].fields.?.order });
    // Then she falls over, with the second still hers: pending.

    // Lee takes what nobody has taken yet, and delivers it.
    const lee = try client.run(io, op, cmd.xreadgroup(Shipment, "shipping", .{ .group = "couriers", .consumer = "lee" }), .{ .allocator = arena });
    for (lee) |entry| {
        app.info("Lee takes", .{ .order = entry.fields.?.order });
        _ = try client.run(io, op, cmd.xack("shipping", "couriers", &.{entry.id}), .{});
    }

    // What the group gave out and nobody acknowledged.
    const pending = try client.run(io, op, cmd.xpending("shipping", "couriers"), .{ .allocator = arena });
    for (pending.consumers) |consumer| app.info("Pending", .{ .consumer = consumer.name, .entries = consumer.count });

    // Lee claims the entries that have been pending for long: in a service,
    // minutes; here, 100 ms.
    try io.sleep(.fromMilliseconds(200), .awake);
    const claimed = try client.run(io, op, cmd.xautoclaim(Shipment, "shipping", .{ .group = "couriers", .consumer = "lee", .min_idle = .fromMilliseconds(100) }), .{ .allocator = arena });
    for (claimed.entries) |entry| {
        app.info("Lee claims", .{ .order = entry.fields.?.order });
        _ = try client.run(io, op, cmd.xack("shipping", "couriers", &.{entry.id}), .{});
    }
    const left = try client.run(io, op, cmd.xpending("shipping", "couriers"), .{ .allocator = arena });
    app.info("Pending now", .{ .entries = left.count });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Makes the group "couriers" of the stream "shipping", and the stream if
/// it is not there; a group that is there already is no error.
fn createGroup(io: std.Io, op: redis.OperationContext, client: *redis.Client) !void {
    var d: redis.Diagnostics = .{};
    client.run(io, op, cmd.xgroupCreate("shipping", "couriers", .{ .mkstream = true }), .{ .diagnostics = &d }) catch |err| {
        if (err == error.ServerError and d.isCode("BUSYGROUP")) return;
        return err;
    };
}
```

```text
$ zig build run
2026-10-22T05:28:15.652Z INFO  [app] To ship order=1001 id=1792646895645-0
2026-10-22T05:28:15.676Z INFO  [app] To ship order=1002 id=1792646895669-0
2026-10-22T05:28:15.697Z INFO  [app] To ship order=1003 id=1792646895683-0
2026-10-22T05:28:15.729Z INFO  [app] Kim takes order=1001
2026-10-22T05:28:15.729Z INFO  [app] Kim takes order=1002
2026-10-22T05:28:15.745Z INFO  [app] Kim delivers order=1001
2026-10-22T05:28:15.776Z INFO  [app] Lee takes order=1003
2026-10-22T05:28:15.808Z INFO  [app] Pending consumer=kim entries=1
2026-10-22T05:28:16.011Z INFO  [app] Lee claims order=1002
2026-10-22T05:28:16.019Z INFO  [app] Pending now entries=0
```

- **An entry** reads into a struct of yours by the names of its fields, as
  a hash does: `redis.Entry(Shipment)` holds its `id` and its `fields`.
  `.max_len` keeps the stream to about that many entries.
- **The group.** XGROUP CREATE with `.mkstream` makes the stream too. A
  group that is there already is `ServerError` with the code BUSYGROUP,
  which `createGroup` takes as done, so that every start of the service
  may make it.
- **XREADGROUP** with `.from = .new`, the default, gives the entries that
  the group has not given out yet, each to one consumer;
  `.from = .{ .id = .zero }` gives a consumer its own pending ones again,
  as after its restart; an entry deleted from the stream meanwhile comes
  with `fields == null`.
- **XACK** takes an entry off the pending ones: it is done. Until then the
  group keeps it, so nothing is lost when a consumer falls over.
- **XAUTOCLAIM** hands the entries pending for longer than `.min_idle` to
  another consumer: in a service, minutes. An entry that was deleted while
  it was pending is not claimed: it leaves the group, and its id comes in
  `claimed.deleted`.
- **XREADGROUP with `.block`** waits for new entries, with its timeout
  from the deadline, as [the blocking
  commands](#blocking-commands-and-the-reliable-queue) do. A typed read
  takes one stream; several at once go through `cmd.raw`.

## Pub/sub

Pub/sub sends a message to whoever listens at that moment: PUBLISH puts
it on a channel, and every subscriber of the channel, or of a pattern that
matches its name, gets it. The server keeps no message, so a subscriber
that was not there misses it: work that must not be missed goes in a
stream or a list.

`notifications.zig` has a listener in a task of its own:

```zig
//! The notifications of the shop, with pub/sub: the packer publishes on a
//! channel that an order is ready, the shop publishes its offers on
//! channels of a pattern, and a listener, in a task of its own, hears what
//! it subscribed to. A message reaches only the subscribers that listen at
//! that moment: the server keeps none of them.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-notifications` runs it against the
//! servers of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        password: ?confy.Secret = null,
    } = .{},
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

    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);
    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));

    // The listener: a channel by its name, and channels by a pattern. It
    // has a connection of its own, and subscribe returns once the server
    // confirmed each name. It must stay where it is until its deinit,
    // which comes once the listener is done.
    var sub = try client.subscribe(io, op, .{ .channels = &.{"orders:ready"}, .patterns = &.{"offers:*"} });
    defer sub.deinit();
    app.info("Subscribed", .{ .subscribers = client.stats().subscribers });
    var heard_all: std.Io.Event = .unset;
    var listener = try io.concurrent(listen, .{ io, &sub, app, &heard_all });
    defer listener.cancel(io) catch {};

    // PUBLISH answers how many subscribers got the message.
    var delivered: u64 = 0;
    delivered += try client.run(io, op, cmd.publish("orders:ready", "order 1001 is packed"), .{});
    delivered += try client.run(io, op, cmd.publish("offers:beans", "two packs for the price of one"), .{});
    delivered += try client.run(io, op, cmd.publish("offers:cups", "a cup with every pack"), .{});
    // Nobody listens to this channel: the message goes nowhere.
    const unheard = try client.run(io, op, cmd.publish("news", "open at 8 tomorrow"), .{});

    // Once the listener heard the three, close the subscriber from here:
    // its next in the other task returns null.
    try heard_all.wait(io);
    sub.close(io);
    try listener.await(io);
    app.info("Published", .{ .delivered = delivered, .unheard = unheard, .subscribers = client.stats().subscribers });
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Logs every message of `sub` until it closes, and sets `heard_all` once
/// three came. Keep such a loop quick: a subscriber that falls behind the
/// messages, the server cuts off.
fn listen(io: std.Io, sub: *redis.Subscriber, app: log.Logger, heard_all: *std.Io.Event) redis.Error!void {
    var heard: usize = 0;
    while (try sub.next(io)) |message| {
        // The message lives until the next call of next: copy what must
        // last longer.
        app.info("Heard", .{ .channel = message.channel, .pattern = message.pattern, .payload = message.payload });
        heard += 1;
        if (heard == 3) heard_all.set(io);
    }
    app.info("Subscriber closed", .{ .heard = heard });
}
```

```text
$ zig build run
2026-10-22T05:28:18.076Z INFO  [app] Subscribed subscribers=1
2026-10-22T05:28:18.096Z INFO  [app] Heard channel=orders:ready pattern=null payload="order 1001 is packed"
2026-10-22T05:28:18.115Z INFO  [app] Heard channel=offers:beans pattern=offers:* payload="two packs for the price of one"
2026-10-22T05:28:18.125Z INFO  [app] Heard channel=offers:cups pattern=offers:* payload="a cup with every pack"
2026-10-22T05:28:18.143Z INFO  [app] Subscriber closed heard=3
2026-10-22T05:28:18.143Z INFO  [app] Published delivered=3 unheard=0 subscribers=0
```

- **`client.subscribe`** opens a connection of its own, outside the pool,
  with the handshake of the pool's connections, subscribes to the channels
  and the patterns, and returns once the server has confirmed each, within
  the deadline of `op`. The subscriber must stay where it is, as the client
  must; `stats().subscribers` counts the open ones.
- **`next(io)`** waits for the next message without a deadline: a
  subscriber lives long. The message lives until the next `next`, and
  `pattern` is the pattern it matched, null for a channel subscribed by its
  name.
- **`close(io)`** may come from any task: the `next` that waits in another
  task returns null, and so does every later one, and `close` returns once
  it has, and closes the connection. A message that the listener holds
  meanwhile stays as it came until its next `next`. The client's `close`
  ends every subscriber the same way.
- **`deinit()`** frees the subscriber, and closes it first if nobody has.
  It comes once nothing reads the subscriber: after the task that listens,
  as `listener` above, has been awaited, and before the client's `deinit`.
- **The channels stay as they were made.** To change them, close the
  subscriber and subscribe again.
- **Silence.** After `idle_ping` without a word from the server, 15 s by
  default, the subscriber sends PING, and when nothing comes within as
  long again, `next` is `ConnectionLost`: without TCP keepalive, a dead
  connection would be silent forever.
- **A broken connection** is `ConnectionLost`, and `next` after it is
  `Closed`. Nothing subscribes again by itself, and the messages published
  meanwhile are lost: close the subscriber and subscribe again.
- **A slow subscriber** the server cuts off, once the messages it has not
  read pass `client-output-buffer-limit pubsub`: 32 MiB, or 8 MiB for a
  minute, by default. Keep the loop of `next` quick, and hand the messages
  to a queue of your own.

## Errors and what is safe to retry

Every call fails with one of 16 errors, `redis.Error`, and
`redis.outcome(err)` says whether the server may have run the command:

- `.not_sent`: nothing reached the server, and the call is safe to make
  again;
- `.may_have_executed`: the server may have run it, wholly or in part:
  make it again only if running it twice does no harm.

Safe to make again is not the same as worth making again. A call that is
`.not_sent` goes through only once what stopped it has changed:

- **`Unavailable` and `PoolExhausted`** are worth a retry after a pause:
  the server may be back, or a connection free, by then;
- **`DeadlineExceeded` and `Cancelled`** only with a new context: under the
  same one the call stops again at once;
- **`InvalidArgument`, `Unsupported`, `Closed` and
  `AuthenticationFailed`** fail the same way however often the call goes,
  until the call, the options, the client or the user changes.

| Error | Outcome | When |
|---|---|---|
| `InvalidArgument` | not sent | the call breaks a rule of the client: bad options or URL, an empty list, a duration under 1 ms, NaN, a command of the connection in `raw`, a reply that needs memory without `.allocator`; the database of the URL is not on the server |
| `Unsupported` | not sent | what v0.1 does not do: `rediss://`, options in the URL; a server other than Redis 7.2 or later or Valkey 8 or later, in cluster or Sentinel mode |
| `Closed` | not sent | the client or the subscriber was closed, or the `Conn` lost its connection with an error before |
| `Unavailable` | not sent | no connection: the server is not there, or is full, or refused it; the pool is paused after a clear; `connect` has not succeeded |
| `AuthenticationFailed` | not sent | the server refused the user or the password (WRONGPASS), or wants a password that it did not get (NOAUTH) |
| `PoolExhausted` | not sent | the deadline came while the call waited in line for a connection |
| `DeadlineExceeded` | not sent | less than 1 ms, or than a round trip, was left of the deadline before sending, or less than 151 ms and a round trip for a blocking command; or the deadline passed while a connection opened |
| `Cancelled` | not sent | the token or the task was canceled before sending |
| `ConnectionLost` | may have run | the connection broke after the command started to go out, or `close` cut it; a subscriber lost its connection |
| `Timeout` | may have run | the deadline passed after the command went out |
| `Interrupted` | may have run | the task was canceled while the command was out |
| `ProtocolViolation` | may have run | the reply broke RESP3 |
| `ReplyTooLarge` | may have run | the reply was larger than `max_reply_bytes`, or nested deeper than 64 levels |
| `ServerError` | may have run | the server answered with an error |
| `UnexpectedReply` | may have run | the reply does not fit the type that the call named |
| `OutOfMemory` | may have run | always: where the memory ran out is unknown |

A Zig error carries no data, so the details go to the `redis.Diagnostics`
that a call gets in `.diagnostics`: `message()`, the server's error as it
sent it or the client's own text; `code()`, the first word of the server's
error, such as `WRONGTYPE`, and `isCode(name)` to test it; `phase`, where
the error happened; and for a pipeline or a transaction `command`, the
index of the command it is about, and `answered`, the replies that came
before a break. Every call starts it afresh. A subscriber and an iterator
keep their own, for the errors of their `next`. The client's texts never
hold arguments, values or passwords; a server's text may quote arguments,
as `ERR unknown command` does, so log it where such values may go.

**A `ServerError` that did not run.** `ServerError` is "may have run", as
an error in the middle of a Lua script leaves the writes it made. Some
codes, though, the server gives before it runs a command at all, and with
them even a command that must not run twice is safe to make again:

| Code | What the server says |
|---|---|
| `NOAUTH` | the connection has not authenticated |
| `NOPERM` | the user may not run the command, or touch one of its keys |
| `OOM` | the command would take more memory than `maxmemory` gives the server |
| `MISCONF` | the server cannot save its data to disk, and refuses writes |
| `NOREPLICAS` | fewer replicas are in reach than `min-replicas-to-write` asks |
| `READONLY` | the server is a replica, which takes no writes |
| `MASTERDOWN` | the replica lost its master, and serves no stale data |
| `LOADING` | the server is still loading its data from disk |
| `BUSY` | a script has run too long, and holds the server |
| `EXECABORT` | the server dropped a whole transaction: none of it ran |

These are the server's own refusals. A script gives its error any code it
likes, after the writes it made: an error of `cmd.eval` or
`cmd.evalScript` may have run, whatever its code.

`outcome(error.ServerError)` stays `.may_have_executed` with each of them:
the class belongs to the name of the error, and your code refines it by
the code, with `diagnostics.isCode("EXECABORT")` and the others.

`errors.zig` makes a few calls fail on purpose:

```zig
//! The errors of calls, against a server: what each says, and whether the
//! command may have run. A counter that is a list, a number that is text,
//! calls that break the client's rules, and a transaction that the server
//! drops whole. Each run starts afresh.
//!
//! Settings, from the environment:
//!
//!   APP_REDIS_URL        the server; redis://127.0.0.1:6379 by default
//!   APP_REDIS_PASSWORD   the password of the user of the URL, or of the
//!                        user default, if the server wants one
//!
//! In tests/redis, `zig build example-errors` runs it against the servers
//! of the repository's docker-compose.yml.

const std = @import("std");
const confy = @import("confy");
const core = @import("core");
const log = @import("log");
const redis = @import("redis");
const zio = @import("zio");
const cmd = redis.cmd;

pub const std_options: std.Options = .{ .logFn = log.stdLogFn };

const Config = struct {
    redis: struct {
        url: []const u8 = "redis://127.0.0.1:6379",
        password: ?confy.Secret = null,
    } = .{},
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

    var client: redis.Client = try .init(init.gpa, io, .{
        .url = config.redis.url,
        .password = if (config.redis.password) |password| password.expose() else null,
    });
    defer client.deinit();
    try client.connect(io, within(io, .fromSeconds(10)), null);
    defer client.close(io);

    const op: redis.OperationContext = .of(within(io, .fromSeconds(10)));
    _ = try client.run(io, op, cmd.del(&.{ "motd", "orders:paid", "stock:coffee" }), .{});
    try client.run(io, op, cmd.set("motd", "Fresh beans from Ethiopia", .{}), .{});
    _ = try client.run(io, op, cmd.rpush("orders:paid", .{"ann"}), .{});

    var d: redis.Diagnostics = .{};

    // ServerError: the server refused the command, with its code first. A
    // list is no counter.
    if (client.run(io, op, cmd.incr("orders:paid"), .{ .diagnostics = &d })) |_| {
        app.info("Counted", .{});
    } else |err| report(app, "A count", err, &d);

    // UnexpectedReply: the reply does not fit the type that the call named,
    // a number here. The client read the reply to its end, so the
    // connection goes back to the pool.
    if (client.run(io, op, cmd.get(i64, "motd"), .{ .diagnostics = &d })) |_| {
        app.info("A number", .{});
    } else |err| report(app, "A read", err, &d);

    // InvalidArgument: the client stops a call that breaks its rules before
    // anything goes out: a delete of no keys; a command that would change
    // the connection for the calls after it.
    if (client.run(io, op, cmd.del(&.{}), .{ .diagnostics = &d })) |_| {
        app.info("Deleted", .{});
    } else |err| report(app, "A delete", err, &d);
    if (client.run(io, op, cmd.raw(void, .{ "SELECT", 1 }), .{ .diagnostics = &d })) |_| {
        app.info("Selected", .{});
    } else |err| report(app, "A raw command", err, &d);

    // EXECABORT: the server refused a command of a transaction as it queued
    // it, and dropped the whole transaction. The class of ServerError says
    // that it may have run; its code says that none of it did.
    var conn = try client.acquire(io, op);
    defer conn.release(io);
    if (conn.transaction(io, op, .{
        cmd.set("stock:coffee", 10, .{}),
        cmd.raw(void, .{ "RESTOCK", "coffee" }),
    }, .{ .diagnostics = &d })) |_| {
        app.info("Restocked", .{});
    } else |err| {
        report(app, "A transaction", err, &d);
        if (d.refused()) |refused| app.info("Refused", .{ .command = d.command, .code = refused.code });
        app.info("Dropped whole", .{ .stock_set = try client.run(io, op, cmd.exists(&.{"stock:coffee"}), .{}) });
    }
}

/// A context whose deadline is `budget` away.
fn within(io: std.Io, budget: std.Io.Duration) core.Context {
    return core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget));
}

/// Logs `err` of `what`, the server's code, if a server gave it, the
/// details, and whether the command may have run.
fn report(app: log.Logger, comptime what: []const u8, err: redis.Error, d: *const redis.Diagnostics) void {
    app.warn(what ++ " failed", .{ .reason = err, .outcome = redis.outcome(err), .code = d.code(), .details = d.message() });
}
```

```text
$ zig build run
2026-10-22T05:28:20.285Z WARN  [app] A count failed reason=ServerError outcome=may_have_executed code=WRONGTYPE details="WRONGTYPE Operation against a key holding the wrong kind of value"
2026-10-22T05:28:20.300Z WARN  [app] A read failed reason=UnexpectedReply outcome=may_have_executed code="" details="the reply is a bulk string of 25 bytes, and the call asked for ?i64"
2026-10-22T05:28:20.300Z WARN  [app] A delete failed reason=InvalidArgument outcome=not_sent code="" details="redis.cmd.del: no keys: DEL takes one or more"
2026-10-22T05:28:20.300Z WARN  [app] A raw command failed reason=InvalidArgument outcome=not_sent code="" details="redis.cmd.raw: SELECT would send the later calls on the connection to another database: put the database in the path of the URL"
2026-10-22T05:28:20.407Z WARN  [app] A transaction failed reason=ServerError outcome=may_have_executed code=EXECABORT details="EXECABORT Transaction discarded because of previous errors."
2026-10-22T05:28:20.407Z INFO  [app] Refused command=1 code=ERR
2026-10-22T05:28:20.450Z INFO  [app] Dropped whole stock_set=0
```

- **`ServerError`**: a list is no counter. The code is `WRONGTYPE`, and the
  text is the server's.
- **`UnexpectedReply`**: the reply was a string of 25 bytes, and the call
  asked for a number. The client read the whole reply, so the connection
  went back to the pool, fine.
- **`InvalidArgument`** stopped two calls before anything went out: a
  delete of no keys, and SELECT through `raw`, which would have sent the
  later calls on that connection to another database.
- **EXECABORT**: the server refused RESTOCK, a command it does not know, as
  it queued it, and dropped the whole transaction. The code of the call is
  EXECABORT; `diagnostics.command` is the index of the refused command,
  and `diagnostics.refused()` its own code and text, `ERR` here. The SET
  before it never ran.

## Deadlines and cancellation

A call takes a `redis.OperationContext`, whose `ctx` is the
`core.Context` of the work it belongs to: a deadline, a cancellation token
and a trace. `.of(ctx)` makes one.

- **The deadline.** A call's deadline is its context's, else `timeout` of
  the options from the start of the call, 5 s by default; with
  `.timeout = null`, a call whose context has no deadline has none at all.
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
    try testing.expectEqualStrings("order:1001", order orelse return error.TestUnexpectedResult);
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
    // The call ends with the test, even one that fails before the cancel
    // below; a second cancel only gives the result of the first.
    defer if (call.cancel(io)) |_| {} else |_| {};
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
    try testing.expectEqual(6, sent.len);
    try testing.expectEqualStrings("BLMOVE", sent[0]);
    const seconds = try std.fmt.parseFloat(f64, sent[5]);
    try testing.expect(seconds >= 0 and seconds <= 0.85);
    const timeout_ms: i64 = @intFromFloat(@round(seconds * 1000));
    try testing.expect(timeout_ms + elapsed + 1 >= 850);

    // Its own timeout, when the deadline leaves more: 300 ms.
    _ = try client.run(io, .of(within(io, 1000)), cmd.blmove([]const u8, "orders:paid", "orders:packing", .left, .right, .{ .at_most = .fromMilliseconds(300) }), .{ .allocator = arena.allocator() });
    const second = (try server.entry(io, 1)).args;
    try testing.expectEqual(6, second.len);
    try testing.expectEqualStrings("0.3", second[5]);
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

## The pool, closing and statistics

The pool keeps the connections of a client, up to `max_connections`, and
opens them as calls need them, two at once at most; nothing opens them
ahead. A call that finds no idle connection and no room waits in line,
first come first served, until its deadline: `PoolExhausted`.

A connection that breaks under a call clears the pool, as a server that
broke one may have broken them all; so does a server that refuses the user
of a new connection, as it would refuse every one. A clear closes the idle
connections, closes the ones in use when they come back, and pauses the
pool: until a new connection opens, calls get `Unavailable` at once, and
one call at most every 500 ms tries to open one. So after a restart of the
server the calls hear "not sent" quickly, rather than `ConnectionLost` on
each old connection in turn. A timeout, a cancelation, and a reply that
breaks RESP3 or is too large close only their own connection.

A connection that idled for more than 30 s since its last reply, in the
pool or in a Conn that held it, answers a PING before a call takes it,
under the deadline of the call. A connection that
does not answer closes, and the call takes another or opens a new one: its
command has not gone out, so nothing ran.

`close(io)` ends the client's work, in this order:

1. the subscribers end, and their `next` returns null;
2. new calls, and the calls that wait for a connection, get `Closed`;
3. the calls in flight, and the Conns given out, get `close_timeout` (5 s)
   to end, and then their exchanges are cut: `ConnectionLost`;
4. the connections close; QUIT does not go out.

A second `close` waits for the first. `deinit` closes the client if
`close` has not, and frees it, wiping its copy of the password. Release
every Conn and deinit every subscriber before `deinit`: in safe builds a
Conn or a subscriber left panics, and so do a client moved after
`connect`, a call on another `std.Io` than the one of `init`, and a Conn,
an iterator or a subscriber called from two tasks at once.

`client.stats()` takes a snapshot, for tests and diagnostics, as the last
line of [the quick start](#quick-start) shows:

| Field | What it counts |
|---|---|
| `connections` | open connections of the pool: `idle` ones and those `in_use` by a call or a Conn |
| `opening` | connections being opened |
| `waiting` | calls waiting in line for a connection |
| `subscribers` | open subscribers, on connections of their own |
| `generation`, `clears` | the generation of the pool, and how many times it was cleared |

## Under zefir.App

zefir.App, the container of zefir-core that will build the parts of a
service, start them in order and stop them all within one deadline, is
planned. The client has the two methods that it will call, and they work
today, as [connect.zig](#what-can-go-wrong-at-the-start) shows:

- **`start(io)`** is `connect` under a deadline of `start_timeout`, 10 s
  by default. When the client cannot connect, `start` writes why to the
  log, as a warning of the scope `redis` with the message that
  `Diagnostics` would hold, such as
  `start failed: error.AuthenticationFailed: WRONGPASS …`: under App no
  caller sees the diagnostics. A program that wants them calls `connect`
  itself. Once the client is connected, `start` does nothing.
- **`shutdown(io, deadline)`** is `close` by the deadline of App's stop:
  the subscribers end first, then the calls in flight get `close_timeout`,
  but no longer than what is left 250 ms before the deadline, so that App
  has time for the rest; then their exchanges are cut. It returns no
  error: nothing of the client runs after it. On Windows a call that
  already waits for a reply holds it longer, see the TODO list at the top.

The client needs no wrapper for App: `init` does no I/O, so a factory of
the service makes it from the settings, as `main` of [the quick
start](#quick-start) does, and App calls `start` before the parts that use
the client and `shutdown` after them.

## Logs

The client logs to `std.log.scoped(.redis)`, as warnings, what an operator
needs to know: the clears of the pool, and why; the servers that refuse a
connection, with their address and the error they gave; and a `start` that
failed, with the text of its `Diagnostics`. At debug, it logs what it
skips: a push between replies, an error of CLIENT SETINFO, an idle
connection that failed its PING. It never logs arguments, values,
passwords or the values of replies: the only texts of a server in its
records are the errors of a refused handshake, as below, which a failed
`start` shows too. To send
the records to zefir-log, the root file of the program names the bridge:

```zig
pub const std_options: std.Options = .{ .logFn = log.stdLogFn };
```

and the logger installs itself as the target of std.log:

```zig
logger.installStdLog();
```

The records then have the scope `redis`, as in the run of
[connect.zig](#what-can-go-wrong-at-the-start):

```text
2026-10-22T05:28:03.515Z WARN  [redis] 127.0.0.1:6380 refused the connection: AuthenticationFailed: WRONGPASS invalid username-password pair or user is disabled.
```

Without the bridge they go where std.log writes by default, to stderr. The
errors of your own calls are yours to log: the error with
`diagnostics.message()`, as the programs here do.

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
  SELECT, and PING, which goes to the journal.
  `startWith(gpa, io, .{ .hello = .{ .password = "…" } })` makes it want a
  password, and `.hello` can make it say that it is another server.
- **A handler**, the `.handler` of `startWith`, answers the commands that
  the steps do not expect, for tests whose commands come in no set order,
  as in [the deadlines](#deadlines-and-cancellation): a type of yours with
  `pub fn answer(self, io, arena, request) FakeServer.Handler.Error!FakeServer.Reply`,
  passed as `.init(&handler)`.
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
    /// How many times the customer came, as `visit` counts them; null in a
    /// profile to save, which leaves the count as it is.
    visits: ?i64 = null,
};

pub fn init(client: *redis.Client) Profiles {
    return .{ .client = client };
}

/// Keeps `profile` as the profile of the customer `id`: a field of the
/// hash for each field of the struct that is not null.
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
    const ann = (try profiles.byId(io, .of(.root), arena.allocator(), 42)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Ann", ann.name);
    try testing.expectEqual(30, ann.age);
    try testing.expectEqual(.pro, ann.plan);
    // A field that the hash lacks takes its default.
    try testing.expectEqual(null, ann.visits);
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

test "a profile is saved as a field of the hash for each field of the struct but a null one, and a visit counts in its field" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The fields go in the order of the struct, the enum as its name, and
    // the null visits not at all, so a save never resets their count; the
    // server answers HSET with how many fields were new.
    var server: FakeServer = try .start(gpa, io, &.{
        .expect(.{ "HSET", "user:42", "name", "Ann", "age", "30", "plan", "pro" }, .{ .integer = 3 }),
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
    const visit = (try server.entry(io, 1)).args;
    try testing.expectEqual(4, visit.len);
    try testing.expectEqualStrings("HINCRBY", visit[0]);
    try server.finish(io);
}
```

- `visits` is optional: `save` leaves it out, so it never resets what
  `visit` counted.
- The client is real and talks to the server over loopback, so the
  deadlines, the cancellation and the errors in a test are those of
  production.
- The server comes before the client, and `defer client.deinit()` before
  `defer client.close(io)`, so that their `defer`s close the client first
  and stop the server last.
- The build of zefir runs these tests, and those of
  [pipelines](#pipelines) and of [deadlines](#deadlines-and-cancellation),
  in `zig build test-redis`.
