# log

**Structured logging for Zefir services.** One JSON line (or one text line)
per record, on stdout. The message is a constant and the data goes in
fields; fields are checked when the program compiles, secrets are redacted
by type and by name, and scopes change level while the service runs. A
service logs through a lock-free queue that a writer thread empties, with
a deadline on shutdown and alerts on a thread of their own.

```zig
const logger: log.Logger = try .init(init.gpa, init.io, .{
    .service = .{ .name = "user-service", .version = "1.0.0" },
    .mode = .{ .queued = .{} },
});
defer logger.deinit();

logger.info("Application started", .{ .port = 9000 });
const users = logger.scoped("users");
users.withContext(ctx).info("User created", .{ .src = @src(), .user_id = 42, .password = password });
```

```json
{"timestamp":"2026-10-12T09:41:07.415Z","level":"info","message":"Application started","service.name":"user-service","service.version":"1.0.0","port":9000}
{"timestamp":"2026-10-12T09:41:07.416Z","level":"info","message":"User created","service.name":"user-service","service.version":"1.0.0","scope":"users","source":{"file":"users.zig","line":12},"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","user_id":42,"password":"[REDACTED]"}
```

## Contents

- [Installation](#installation)
- [Logging](#logging)
- [Fields](#fields)
- [Secrets](#secrets)
- [Scopes and levels](#scopes-and-levels)
- [Context and call site](#context-and-call-site)
- [std.log](#stdlog)
- [Output](#output)
- [Sync and queued modes](#sync-and-queued-modes)
- [Stopping](#stopping)
- [Failures and stats](#failures-and-stats)
- [Emergency records](#emergency-records)
- [Subscribers](#subscribers)
- [Interceptors](#interceptors)
- [Threads and Io](#threads-and-io)
- [Limits](#limits)
- [Performance](#performance)

Examples that `zig build test` compiles and runs:
[a service's main](service.zig) · [nested configuration, std.log and a trace](config.zig) · [queued mode with alerts](alerts.zig)

## Installation

Add Zefir to your `build.zig.zon`. The log module is on the `dev` branch
until the next release:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#dev
```

Then import the `zefir-log` module in `build.zig`:

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
            .{ .name = "log", .module = zefir.module("zefir-log") },
        },
    }),
});
```

> [!TIP]
> log is also part of the umbrella module: with `zefir.module("zefir")`
> imported as `zefir`, it is `@import("zefir").log`.

## Logging

`Logger.init(gpa, io, options)` creates the logger: logging allocates
nothing after it, and only `subscribe` allocates again. `deinit` frees
it; call it once, on any handle. A `Logger` is a small handle, copied by
value and shared freely between threads; `scoped` and `withContext`
derive more of them.

| Method | Writes |
|---|---|
| `trace`, `debug`, `info`, `warn`, `err` | a record at that level (`err` is written as `"error"`) |
| `enabled(level)` | nothing: whether a record at `level` would be written |
| `emergency` | an error record to stderr at once, see [Emergency records](#emergency-records) |

The message is a compile-time constant; anything that varies goes in the
fields, a struct literal: `logger.info("User created", .{ .user_id = id })`.
Logging never allocates, never fails and is never a cancelation point:
problems are counted in `stats()`. Field values are computed even when the
level is off, so check `enabled` before costly ones.

## Fields

| Zig type | JSON | text |
|---|---|---|
| `bool`, integers up to 64 bits | `true`, `42` | the same |
| wider integers (`u128`…) | `"340282366920938463463374607431768211455"` | the digits |
| floats | the shortest form; NaN and infinities as `"NaN"`, `"+Inf"`, `"-Inf"` | without quotes |
| strings (`[]const u8`, `[N]u8`, sentinel-terminated) | escaped; invalid UTF-8 as U+FFFD | bare when safe, else quoted |
| bytes | `zefir.log.hex(&digest)` gives lowercase hex | the same |
| optionals | `null` or the value | the same |
| enums, errors | by name: `"active"`, `"NotFound"` | the same |
| `union(enum)` | `{"running":3}` | `state.running=3` |
| structs | objects, in declaration order | dotted keys: `config.db.host=pg` |
| arrays, slices, tuples, vectors | arrays | `[1,2,3]` |
| pointers | the value they point to | the same |
| `type` | its name | the same |
| a type with `format` (as `{f}` uses it) | its text, escaped | the same |
| a type with `pub fn logValue(self) T` | the value it returns, logged by these rules | the same |

Nesting deeper than 8 levels is written as `"[MAX_DEPTH]"`, so a cycle
through pointers ends. What cannot be logged is a compile error at the
call, naming the field: untagged unions, many-item and C pointers,
`*anyopaque`, functions, error unions, `void`, positional tuples
(`.{ id }`), and names outside `[A-Za-z0-9_.-]`.

Names that records use themselves are reserved, also as a dotted path
(`.service = .{ .name = … }` is `service.name`): `timestamp`, `level`,
`message`, `service.*`, `deployment.environment.name`, `scope`, `source`,
`trace_id`, `span_id`, `truncated`, `request_id`, `correlation_id`,
`tenant_id`, `pid`, `thread_id`, `labels`, `suppressed`, and `src`, which
is the call site.

## Secrets

A type marked `pub const zefir_sensitive = true;` is written as
`"[REDACTED]"`, also inside an optional, a pointer, a slice or an array, so
neither its presence nor a count leaks. `confy.Secret` carries the marker.
`zefir.log.isSensitive(T)` tells whether a type has it.

A field named like a secret is redacted too, at any depth and in any
spelling (`api_key`, `apiKey`, `API_KEY`): `password`, `passwd`, `secret`,
`client_secret`, `api_key`, `apikey`, `access_token`, `refresh_token`,
`id_token`, `auth_token`, `authorization`, `cookie`, `set_cookie`,
`private_key`. A string you take out of a secret yourself cannot be
protected, and neither can the text a type's `format` writes, or what
std.log formats.

## Scopes and levels

```zig
const db = logger.scoped("db.pool"); // records carry "scope":"db.pool"
logger.setLevel(.debug); // the global threshold
try logger.setScopeLevel("db", .warn); // db and db.*; not dbx
try logger.setScopeLevel("db", null); // back to the global threshold
```

Every handle sees a change at once. The longest matching prefix wins, and
a trailing dot is ignored. Rules can start in the options, which confy can
read from the configuration: `.scopes = &.{.{ .prefix = "zefir.rpc", .level
= .debug }}`. `scoped` copies the name, so it need not outlive the handle;
a handle holds one scope, and `scoped` replaces it.

## Context and call site

`withContext(ctx)` copies the trace and span ids of a `core.Context`; a
context without a trace gives a handle without them. Its deadline and
cancellation do not affect logging. `.src = @src()` among the fields adds
the call site: `"source":{"file":"users.zig","line":12}`. How much of it
each level writes is set by `.source`: `none`, `file_line` (the default)
or `full`, which adds the column, the function and the module.

## std.log

```zig
pub const std_options: std.Options = .{ .logFn = zefir.log.stdLogFn };
...
logger.installStdLog(); // std.log goes to the logger from here on
```

std.log's scope becomes the record's scope and its formatted text the
message; the logger's levels and scope rules apply. `deinit` removes the
bridge, `zefir.log.uninstallStdLog()` does it earlier, and both wait for
the calls still inside the logger. std.log's arguments are formatted by
std.fmt, so redaction does not reach inside them.

## Output

JSON keys come in this order: `timestamp`, `level`, `message`, the
service fields, `scope`, `source`, `trace_id`, `span_id`, your fields in
declaration order, then `truncated`. The service fields use OpenTelemetry
names (`service.name`, `service.instance.id`, `service.version`,
`deployment.environment.name`); empty ones are left out. Time is RFC 3339
in UTC with milliseconds.

`.format = .text` writes one line for people, without the service fields:

```text
2026-10-12T09:41:07.416Z INFO  [users] User created user_id=42 password=[REDACTED] trace_id=4bf92f3577b34da6a3ce929d0e0e4736 span_id=00f067aa0ba902b7 src=users.zig:12
```

A record is at most `max_record_bytes` (4096 by default, at most 16384),
`'\n'` included. A longer one is cut (`.oversize = .truncate`: the message
loses its end, between characters, the fields that do not fit are left
out, and it ends with `"truncated":true`) or dropped (`.drop`). Every
record stays one line of valid JSON: quotes, control characters, line and
paragraph separators and bidi controls are escaped.

`.output = .stdout` is the default; `.{ .writer = &writer }` sends records
to a writer you own, as tests do.

## Sync and queued modes

| | `.sync` (default) | `.{ .queued = .{} }` |
|---|---|---|
| The call | encodes the record and writes it before it returns | encodes the record and copies it into a queue |
| Output | through the application's `io`, under a lock | a writer thread, in batches, through the logger's own Io |
| Good for | tests, tools, CLIs: a record is out even if the process dies next | services: a caller never waits for stdout |
| Memory | none | `Options.queueBytes()`: 17 MiB with the defaults |

```zig
.mode = .{ .queued = .{
    .capacity = 4096, // records the queue holds: a power of two, at least 2
    .batch_size = 128, // records per write
    .overflow = .drop_new, // or .block
} },
```

A queued call takes a slot with one compare-and-swap, copies the record in
and publishes it: no lock and no system call, unless the writer thread
sleeps and has to be woken. Only a producer stopped between taking a slot
and filling it holds back the records after it (they wait; none is lost).
When the queue is full, `.drop_new` drops the record and counts it, and
`.block` makes the caller wait for room: that blocks an OS thread, so it is
not for event loops, zio tasks or RPC workers, and it is not fair among
waiters.

Records of one thread keep their order. Records of different threads are
ordered as they took their slots, so timestamps can go back a little
between threads.

## Stopping

```zig
const deadline: core.Deadline = .after(std.Io.Clock.awake.now(io), .fromSeconds(5));
logger.shutdown(deadline.toTimeout()) catch |e| switch (e) {
    error.Timeout => std.debug.print("log: {d} records not written\n", .{logger.stats().pending}),
};
logger.deinit();
```

Stop in this order: stop taking work, wait for your own threads, then
`shutdown(timeout)`, then `deinit()`.

- `flush(timeout)` waits until every record logged before it is written.
- `shutdown(timeout)` refuses records from then on (counted in
  `stats().dropped.closed`), waits until the subscribers have handled
  their queues and then until the queue is written, and stops the
  logger's threads. `stats().pending` and `stats().alert_pending` tell
  what is left when it times out.
- Both return `error.Timeout` when the timeout passes first; another
  `shutdown` may wait again.
- `deinit` without a `shutdown` waits for everything queued, with no time
  limit. After a `shutdown` that timed out, it drops what is left and
  waits only for the write and the handler calls in progress. If stdout
  is stuck for good, exit without `deinit`.
- In sync mode `flush` returns at once, and `shutdown` waits only for the
  subscribers.

Records still queued are lost when the process ends without these steps:
`std.process.exit`, a panic, a signal. Do not log from a signal handler: a
sync record, or a queued one in `.block` mode, may wait for a lock or for
room that the interrupted thread holds.

## Failures and stats

`stats()` returns counters since `init`, from any thread:

| Field | Counts |
|---|---|
| `accepted` | records that passed the level filter |
| `written` | records that reached the output whole |
| `dropped.oversize` | too long, with `.oversize = .drop` |
| `dropped.write_failed` | the write failed, or stdout was closed |
| `dropped.queue_full` | the queue was full, with `.drop_new` |
| `dropped.closed` | logged after `shutdown` |
| `dropped.err` | error records refused for a full queue or after `shutdown` |
| `write_errors`, `torn_lines` | failed writes, and lines they cut short |
| `truncated` | records cut to `max_record_bytes` |
| `queue_depth`, `queue_capacity`, `pending` | records in the queue, its size, records not yet written |
| `scopes_overflow`, `scope_names_truncated` | scope names past the table, or cut to 128 bytes |
| `emergency_written`, `emergency_suppressed` | emergency records written, and left out |
| `alert_pending` | records waiting in the subscribers' queues |
| `alert_dropped`, `alert_failures` | records a subscriber's queue had no room for, handler errors |
| `filtered`, `hook_errors` | records interceptors dropped on purpose; records dropped because a hook logged them |

A write that fails mid-line costs that line only: the next record starts on
a new line. If stdout is closed, the logger notes it once on stderr and
drops the records that follow; that needs SIGPIPE ignored, as
`main(init: std.process.Init)` does.

Error records are never lost silently. When the queue refuses one, the
writer thread writes one record in its place,
`"message":"zefir.log: error records dropped","suppressed":N`, as soon as
it has room; `shutdown` and `deinit` note on stderr the ones it could not
report. Apart from these notes, a caller in queued mode never writes to
stderr.

## Emergency records

`logger.emergency("Disk full", .{ .free = 0 })` writes an error record to
stderr before it returns, past the queue, the interceptors and the
subscribers, also after `shutdown`, and through the logger's own Io: for
what must be seen when the regular output is stuck. At most 100 go out at
once and 100 per second after that; the next one written tells how many
were left out with `"suppressed":N`.

## Subscribers

```zig
const id = try logger.subscribe(.{
    .levels = &.{.err},
    .scope = "payments", // and its subscopes; null for any
    .context = &alerter,
    .handler = sendAlert,
});
...
logger.unsubscribe(id); // before `alerter` goes, and before `deinit`

fn sendAlert(context: ?*anyopaque, event: *const zefir.log.Event) anyerror!void {
    const alerter: *Alerter = @ptrCast(@alignCast(context.?));
    try alerter.post(event.line); // the redacted record, as the output has it
}
```

Each subscriber has a queue (`capacity`, 256 records by default; a slot
is `max_record_bytes` + 112 bytes rounded up to 128) and a thread of its
own, so a slow handler holds up nobody else. It gets the records of its
levels that pass the logger's level filter, before the output, so it gets
an error record even when the queue refuses it or stdout is closed. A full
subscriber queue drops the record (`alert_dropped`); a handler error is
counted (`alert_failures`) and not retried. The `Event` gives the level,
the timestamp, the scope and the message as the record writes them
(escaped, and cut when the record is), the trace ids and the whole line;
it is valid only during the call.

A handler may log: those records go to the output only, never back to the
subscribers, so an alert cannot trigger itself; while `shutdown` waits for
the subscribers they still go out. It must not call `unsubscribe`,
`flush` or `shutdown`. `unsubscribe` waits until the subscriber has
handled its queue (with no time limit while the logger runs; once
`shutdown` has begun, only for the call in hand); after it returns, the
handler is never called again. Call it before `deinit`. A logger takes 8
subscribers in its life.

## Interceptors

```zig
try logger.use(.{ .filter = dropHealthChecks });

fn dropHealthChecks(_: ?*anyopaque, event: *const zefir.log.Event) bool {
    return !std.mem.eql(u8, event.scope, "http.health");
}
```

An interceptor runs at the caller for every record that passes the level
filter, once it is encoded, in the order they were added; `false` drops
the record everywhere (`filtered`). It must not block or log: a record
logged from it is dropped (`hook_errors`). A logger takes 8.

## Threads and Io

The application's `io` reads the clock and does the sync writes, so log
only from threads or tasks of that `io` (under `std.Io.Threaded`, any
thread). The logger's own threads (the writer, the subscribers) and every
wait for them run on a `std.Io.Threaded` of the logger's own, and those
waits keep a cancel request for the caller's task. A handler that logs
writes through that own Io too; in sync mode under an application `io`
that is not a `std.Io.Threaded` (an evented one), it could not share the
output lock with the application's tasks, so those records are dropped
and counted in `hook_errors`: use queued mode there. Two loggers on one
stdout do not coordinate their writes: use one per process.

## Limits

| | |
|---|---|
| Record | at most 16384 bytes with `'\n'`, 4096 by default |
| Service fields | 1 KiB together |
| Scope names | 256 per logger, 128 bytes each (longer ones are cut) |
| Scope rules | 64 |
| Nesting | 8 levels |
| Queue | a power of two, at least 2 records |
| Subscribers, interceptors | 8 each |
| Emergency records | 100 at once, then 100 per second |
| Targets | 64-bit: the counters and queue positions are 64-bit atomics |

## Performance

```sh
zig build bench
```

builds `src/log/bench.zig` with ReleaseFast and prints the tables below.
A record goes to a writer that throws it away unless a table says
otherwise, so the numbers measure the logger rather than a terminal.
Latency is the time one call takes, two clock reads included. CPU is the
process's user and system time per record. The typical record is a
request log of 185 bytes of JSON.

Measured on 2026-10-12: Apple M4 (16 CPUs), macOS 26.3, Zig 0.17.0,
ReleaseFast. The machine was busy while they ran (load average about 15),
so the tails and the `drop_new` losses, which come from the writer thread
waiting for a CPU, are noisy; run the command on your machine.

**Modes and producers** (typical record, 100 000 records per producer):

| Mode | Producers | Records/s | p50 ns | p99 ns | p99.9 ns | Dropped |
|---|---:|---:|---:|---:|---:|---:|
| sync | 1 | 6.5 M | 125 | 167 | 209 | 0 |
| sync | 4 | 5.9 M | 292 | 5 083 | 10 792 | 0 |
| sync | 16 | 3.9 M | 250 | 55 542 | 256 125 | 0 |
| queued `drop_new` | 1 | 3.2 M | 208 | 1 666 | 2 542 | 0 |
| queued `drop_new` | 4 | 6.1 M | 500 | 1 333 | 8 542 | 6.5 % |
| queued `drop_new` | 16 | 7.5 M | 792 | 16 167 | 71 375 | 70.8 % |
| queued `block` | 1 | 3.2 M | 208 | 1 667 | 2 208 | 0 |
| queued `block` | 4 | 6.1 M | 583 | 1 500 | 2 291 | 0 |
| queued `block` | 16 | 3.1 M | 1 417 | 43 709 | 189 041 | 0 |

**Outputs** (typical record, 4 producers, through a 64 KiB buffer; sync
makes one write call per record):

| Mode | Output | Records/s | p50 ns | p99 ns |
|---|---|---:|---:|---:|
| sync | `/dev/null` | 0.70 M | 1 791 | 37 542 |
| sync | a pipe | 0.74 M | 1 292 | 51 792 |
| queued `drop_new` | `/dev/null` | 8.7 M | 375 | 1 167 |
| queued `drop_new` | a pipe | 7.6 M | 458 | 1 000 |

**Records** (queued `drop_new`, 4 producers): a 185-byte record costs
542 ns at p50, a 301-byte one with the call site and the trace ids 583 ns,
and a 1200-byte one 2 166 ns.

**Batches** (queued `block`, 8 producers, a reader that takes 20 µs per
write): 1.1 M records/s with batches of 32, 4.9 M with 128 (the default),
5.3 M with 512.

**Hooks** (queued `drop_new`, 4 producers):

| Hooks | Records/s | p50 ns | p99 ns |
|---|---:|---:|---:|
| none | 6.1 M | 542 | 1 458 |
| a subscriber on `.err` (other records pay one check) | 6.2 M | 583 | 1 416 |
| a subscriber on `.info` (every record copied to it too) | 4.7 M | 750 | 2 000 |
| an interceptor that keeps every record | 6.3 M | 542 | 1 375 |

**Bursts** (8 producers × 2000 records, queued `drop_new`, a reader stuck
for 1 ms per write): a queue of 1024 records drops 92 %, 4096 (the
default) 73 %, 16384 none. The queue takes 4.6, 17 and 66.5 MiB.

No scenario allocates after `init`.
