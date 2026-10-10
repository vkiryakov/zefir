# core

**The execution context of Zefir services.** One small value carries an
operation's deadline, its cancellation token and its W3C trace identity
through your code — without allocating, reading a clock or doing I/O.
Transports (RPC, HTTP, job queues) create it; your code passes it down and
checks it.

```zig
var token: core.CancellationToken = .init; // owned by the request
const ctx = core.Context.root
    .withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(2)))
    .withCancellation(&token);

fn getUser(ctx: core.Context, io: std.Io, id: u64) !User {
    try ctx.check(std.Io.Clock.awake.now(io)); // error.Cancelled or error.DeadlineExceeded
    ...
}
```

## Contents

- [Installation](#installation)
- [Context](#context)
- [Passing a context](#passing-a-context)
- [Ownership and lifetimes](#ownership-and-lifetimes)
- [Cancellation](#cancellation)
- [Deadlines and clocks](#deadlines-and-clocks)
- [Trace identity](#trace-identity)
- [W3C headers](#w3c-headers)
- [Errors](#errors)
- [Thread safety](#thread-safety)
- [Limits](#limits)
- [Benchmarks](#benchmarks)

Examples that `zig build test` compiles and runs:
[HTTP handler](http_handler.zig) · [RPC handler](rpc_handler.zig) · [Gateway → User → Billing](services.zig)

## Installation

Add Zefir to your `build.zig.zon`; core ships since v0.2.0:

```sh
zig fetch --save git+https://github.com/vkiryakov/zefir#v0.2.0
```

Then import the `zefir-core` module in `build.zig`:

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
            .{ .name = "core", .module = zefir.module("zefir-core") },
        },
    }),
});
```

> [!TIP]
> core is also part of the umbrella module: with `zefir.module("zefir")`
> imported as `zefir`, it is `@import("zefir").core`. Both are the same module.

## Context

| Field | Meaning | Derive with |
| --- | --- | --- |
| `trace: ?TraceContext` | trace identity; null when tracing is off | `withTrace` |
| `deadline: ?Deadline` | the earliest deadline in effect | `withDeadline` (never extends it) |
| `cancellation: ?*const CancellationToken` | the token that cancels the operation | `withCancellation` (replaces it) |

`Context.root` has none of them. Every `with*` returns a new context; the
original stays as it was. The fields are read-only: change them only through
`with*`, or the "deadlines never grow" rule breaks.

- `ctx.check(now)` returns `error.Cancelled` when the token is cancelled,
  otherwise `error.DeadlineExceeded` when the deadline has passed. When both
  hold, cancellation wins.
- `ctx.isCancelled()`, `ctx.isExpired(now)` and `ctx.remaining(now)` answer one
  question each; `remaining` is null without a deadline and never negative.

## Passing a context

One rule for RPC, HTTP and background jobs:

- code below the handler — services, repositories, clients — takes
  `ctx: core.Context` **by value** as a parameter;
- the allocator and `std.Io` are separate parameters (or constructor-injected
  fields of long-lived services); a context carries neither;
- transport types (an RPC context, an HTTP request) never cross the handler
  boundary.

```zig
fn find(repo: Repository, ctx: core.Context, io: std.Io, id: u64) !User {
    try ctx.check(std.Io.Clock.awake.now(io));
    ...
}
```

A context is 96 bytes and copying it costs nothing beyond that.

## Ownership and lifetimes

A context owns nothing. It **borrows** two things:

- the `CancellationToken` it points to;
- through `trace.state`, the bytes of the incoming `tracestate` header.

So a context must not outlive the scope that owns them:

| Where | Who owns the token and the header bytes |
| --- | --- |
| HTTP request | the request scope |
| RPC call | the call scope |
| WebSocket | the connection or the message scope |
| Background job | the job's execution scope |
| Database query | uses the context of its caller |

An asynchronous task must not keep a borrowed context after its owner ends.
**A job that outlives the request** gets its own context, built from `root`:

```zig
var job_token: core.CancellationToken = .init;     // owned by the job
var job_trace = request_trace.child(job_span_id);  // same trace, new span
job_trace.state = .empty;                          // or parse bytes the job owns
const job_ctx = core.Context.root
    .withTrace(job_trace)
    .withCancellation(&job_token)
    .withDeadline(.after(now, job_budget));
```

Replacing the token with `withCancellation` is not enough: the derived
context would keep the request's deadline and its tracestate bytes.

## Cancellation

`CancellationToken` is a cooperative flag:

- `var token: core.CancellationToken = .init;` then `token.cancel()` from any
  thread, any number of times; `isCancelled()` never goes back to false;
- everything a thread wrote before its `cancel()` is visible to a thread that
  sees `isCancelled() == true`;
- it wakes no one and interrupts no I/O; the token must outlive the contexts
  that point to it, and must not be copied once they do.

Use the token for **explicit** cancellation only: the client went away, the
connection broke, the server is stopping. A timeout is a deadline. Rules for
runtimes and adapters built on `std.Io`:

1. Never cancel the token to signal a timeout. Set a deadline;
   `check` reports `error.DeadlineExceeded` once the time has passed.
2. Wake waiting tasks with `std.Io` task cancellation. Cancel a task for a
   timeout only once `now >= deadline.expires`, and arm timers with
   `deadline.toTimeout()`.
3. An adapter that gets `error.Canceled` from `std.Io` reads a fresh time and
   calls `ctx.check(now)`, returning its error. If the check passes, the task
   — not the operation — was cancelled: return `error.Canceled` unchanged.
4. Long CPU work checks `ctx.check(fresh now)` (and `io.checkCancel()` if
   needed) at its checkpoints; `isCancelled()` alone does not see the deadline.

`error.Cancelled` from core is **not** `std.Io`'s `error.Canceled`. Core's
error repeats on every check while the token is cancelled; `std.Io`'s is
returned once by a cancelation point and follows `recancel` and
`CancelProtection` rules.

## Deadlines and clocks

Deadlines are `std.Io.Timestamp` values on the **`std.Io.Clock.awake`**
clock: monotonic and not affected by changes to the system time. core never
reads the clock — you pass `now`:

```zig
const now = std.Io.Clock.awake.now(io);
const deadline: core.Deadline = .after(now, .fromMilliseconds(500));
deadline.isExpired(now);   // true from the moment now reaches expires
deadline.remaining(now);   // never negative
deadline.toTimeout();      // a std.Io.Timeout on the awake clock
```

A timestamp means nothing on another machine. **Send the remaining budget**,
not the deadline: the caller writes `ctx.remaining(now)` (for example in
milliseconds) and the receiver builds its own `Deadline.after(now, budget)`.
`after` saturates instead of overflowing, so a huge budget from the wire is
safe; a negative one has already expired.

## Trace identity

- `TraceId` (16 bytes) and `SpanId` (8 bytes) are byte arrays. Build them with
  `fromBytes` or `parseHex` (lowercase hex); all-zero ids are rejected. Print
  them with `{f}`. A struct literal can hold an invalid id: don't build them
  that way.
- `TraceFlags` is a byte with `sampled` and `random` fields; unknown bits are
  kept in `reserved`.
- `TraceContext` is `trace_id`, `span_id`, `flags`, `state` and `is_remote`.
  `parent.child(span_id)` is the identity of a child span: same trace, flags
  and state, local.

core generates no ids. Generate one with `std.Io`:

```zig
var bytes: [8]u8 = undefined;
io.random(&bytes);
const span_id = core.SpanId.fromBytes(bytes) catch unreachable; // all zero: retry in real code
```

## W3C headers

`core.w3c` parses and formats the W3C Trace Context headers for any
transport. It follows Level 1 plus the two Level 2 additions the official
test suite checks: the `random` flag and the tracestate key grammar.

Receiving:

```zig
const trace: ?core.TraceContext = if (core.w3c.parseTraceparent(traceparent)) |parsed| blk: {
    var with_state = parsed;
    with_state.state = core.w3c.parseTracestate(tracestate) catch .empty; // a bad tracestate is dropped
    break :blk with_state;
} else |_| null; // a bad traceparent restarts the trace; tracestate is not parsed
```

Sending, after `ctx.trace.?.child(span_id)` for your own span:

```zig
var traceparent: [core.w3c.traceparent_len]u8 = undefined;
const value = core.w3c.formatTraceparent(trace, &traceparent); // always version 00
if (!trace.state.isEmpty()) send("tracestate", trace.state.header);
```

- **traceparent:** version `00` exactly (55 characters, lowercase hex, no
  all-zero ids); newer versions are read the W3C way and written back as
  `00`; spaces and tabs around the value are ignored.
- **Flags:** `sampled` and `random` are sent; unknown bits are kept in memory
  but always sent as zero, as W3C requires.
- **tracestate:** at most 32 entries; keys and values follow the W3C grammar;
  empty members and whitespace around them are allowed; a repeated key is
  allowed and kept (`get` returns the left-most value). Any other invalid
  entry makes the whole tracestate invalid — the traceparent stays.
- **Lifetime:** `TraceState` borrows the bytes you parsed. Parse them from a
  buffer that lives as long as the request.

The transport's part:

- header names are case-insensitive;
- two or more `traceparent` fields are invalid;
- join several `tracestate` fields with `,` in their order before parsing;
- drop a `tracestate` that arrives without a valid `traceparent`;
- do not send an empty tracestate;
- if your transport allows only `0x20-0x7E` in values, check tracestate with
  `parseTracestate` instead: the whitespace it keeps may contain a tab.

## Errors

Zig error sets stay the way code reports errors. `core.ErrorCode` names the
class of a failure, so a transport can map it to its own status:

| Code | Meaning |
| --- | --- |
| `cancelled` | the caller cancelled the operation |
| `unknown` | an error with no better code |
| `invalid_argument` | the request is invalid regardless of the system state |
| `deadline_exceeded` | the deadline expired before the operation finished |
| `not_found` | a requested entity does not exist |
| `already_exists` | the entity to create already exists |
| `permission_denied` | the caller is known but not allowed to do this |
| `resource_exhausted` | a quota or limit ran out |
| `failed_precondition` | the system is not in the state the operation needs |
| `aborted` | aborted, typically by a concurrency conflict |
| `out_of_range` | a value is outside the valid range |
| `unimplemented` | not implemented or not supported |
| `internal` | an invariant is broken |
| `unavailable` | unavailable right now; retrying may help |
| `data_loss` | unrecoverable data loss or corruption |
| `unauthenticated` | no valid credentials |

These are the canonical codes of gRPC, Connect and Twirp. `ErrorCode.fromContextError`
maps `error.Cancelled` and `error.DeadlineExceeded`; `ErrorInfo` pairs a code
with a borrowed message that core never fills in by itself.

## Thread safety

A context is an immutable value: any number of threads may read the same
context while the token and the header bytes it borrows are alive.
`cancel` and `isCancelled` are atomic. There is no thread-local or global
state.

## Limits

| What | Limit |
| --- | --- |
| `Context` | 96 bytes, passed by value |
| Allocation, clock reads, I/O | none |
| traceparent written | 55 characters, version `00` |
| tracestate | 32 entries; key and value up to 256 characters; no total length limit |

Not in core: creating spans, sampling, exporting, generating ids, linked
tokens, waking waiting tasks, baggage.

## Benchmarks

```sh
zig build bench
```

prints the environment and nanoseconds per operation, built with
ReleaseFast. Numbers depend on the machine.
