//! zefir-log — structured logging. One engine per process and any number of
//! cheap handles. Each record is one JSON line (or one text line) on stdout:
//! written before the call returns (`.sync`, the default), or copied into a
//! queue that a writer thread writes in batches (`.queued`, for services).
//!
//! ```zig
//! pub const std_options: std.Options = .{ .logFn = zefir.log.stdLogFn };
//!
//! const logger = try zefir.log.Logger.init(init.gpa, init.io, .{
//!     .service = .{ .name = "user-service", .version = "1.0.0" },
//! });
//! defer logger.deinit();
//! logger.installStdLog(); // std.log records go to the logger too
//!
//! logger.info("Application started", .{ .port = 9000 });
//! const users = logger.scoped("users");
//! users.withContext(ctx).info("User created", .{ .src = @src(), .user = user, .password = password });
//! // …"scope":"users","source":{"file":"users.zig","line":12},"trace_id":"…","span_id":"…",
//! //   "user":{"id":42,"name":"Ada"},"password":"[REDACTED]"}
//! ```
//!
//! The message is a constant; variable data goes in the fields, a struct
//! literal. A field holds scalars and strings (integers wider than 64 bits
//! and NaN or infinities are written as strings, invalid UTF-8 as U+FFFD,
//! enums and errors by name), structs (objects; dotted keys in text),
//! tagged unions, arrays, slices and tuples, optionals and pointers (both
//! followed). Objects, arrays and unions nested deeper than 8 levels are
//! written as "[MAX_DEPTH]". `.src = @src()` adds the call site,
//! `withContext(ctx)` the trace ids, and `zefir.log.hex(bytes)` logs bytes
//! as hex.
//!
//! A type logs its own text through the `format` method that `{f}` uses,
//! or another value through `pub fn logValue(self) U`. Both run when the
//! record is written, twice when it has to be cut, so they must have no
//! side effects; `logValue` must not return slices into a by-value `self`.
//! The text `format` writes is trusted: the logger escapes it, but redacts
//! nothing inside it.
//!
//! A type marked `pub const zefir_sensitive = true;` (`confy.Secret` is) is
//! written as "[REDACTED]", also inside an optional, a pointer, a slice or
//! an array; so is any field named like a secret (`password`, `api_key`,
//! `accessToken`, …), at any depth. Names that records use themselves
//! (`level`, `message`, `scope`, …, also as a dotted path such as
//! `.service = .{ .name = … }`) and types the logger cannot write are
//! compile errors at the call.
//!
//! Levels change at run time: `setLevel` for the global threshold and
//! `setScopeLevel` for a scope and its subscopes; existing handles see the
//! change at once. Logging never allocates and never fails: problems are
//! counted in `stats()`. Tests capture records with
//! `.output = .{ .writer = &writer }`.
//!
//! With the std.log bridge, std.log's scope becomes the record's scope and
//! its formatted text the message. The arguments are formatted by std.fmt,
//! not walked by the logger, so redaction does not reach inside them.
//!
//! If stdout is closed, the logger notes it once on stderr and drops the
//! records that follow. That needs SIGPIPE ignored, as `main(init:
//! std.process.Init)` does; a bare `main()` is killed by SIGPIPE first.
//!
//! In queued mode a call encodes its record, then copies it into the queue
//! with no lock and no system call; only a producer stopped between taking
//! a slot and filling it holds back the records after it. A full queue
//! drops the record (`.drop_new`, counted) or makes the caller wait
//! (`.block`, which blocks the OS thread and wakes all waiters at once,
//! so it is not fair). Records of one thread keep their order; records of
//! different threads are ordered as they took their slots, so timestamps
//! can go back a little between threads. An error record the logger has to
//! drop is never lost silently: one summary record with `"suppressed":N`
//! takes its place.
//!
//! Stop in this order: stop taking work, wait for the application's own
//! threads, `shutdown(timeout)` (records still queued are written; later
//! ones are refused), then `deinit()`. Without `shutdown`, `deinit` waits
//! for the queue with no time limit. Records still queued are lost when the
//! process ends without them: `std.process.exit`, a panic, a signal.
//! `emergency(msg, fields)` writes to stderr at once, for what must be seen
//! even then.
//!
//! Do not log from a signal handler: a sync record or a queued one in
//! `.block` mode may wait for a lock or for room that the interrupted
//! thread holds.
//!
//! `subscribe` adds a subscriber for alerts: it gets copies of the records
//! of its levels (and scope) on a thread and a queue of its own, before
//! they reach the output, so it gets an error record even when the queue
//! or stdout refuses it. Records a handler logs never return to the
//! subscribers. `use` adds an interceptor: it sees each record at the
//! caller, once encoded, and drops it by returning false. Both get an
//! `Event`: the level, the time, the scope, the message, the trace ids and
//! the whole line, valid during the call. More in `examples/README.md`.

const std = @import("std");
const options = @import("options.zig");
const hooks = @import("hooks.zig");

pub const Level = @import("level.zig").Level;
/// Whether a type is marked `pub const zefir_sensitive = true;`: the logger
/// writes such values as "[REDACTED]". The check lives in zefir-core, so
/// every module shares one marker.
pub const isSensitive = @import("core").isSensitive;
/// Logs bytes as lowercase hex: `.digest = zefir.log.hex(&digest)`.
pub const hex = @import("hex.zig").hex;
/// The `logFn` that bridges std.log: see `Logger.installStdLog`.
pub const stdLogFn = @import("std_log.zig").stdLogFn;
/// Sends std.log back to `std.log.defaultLog`.
pub const uninstallStdLog = @import("std_log.zig").uninstall;
pub const Logger = @import("Logger.zig");
pub const Stats = @import("Engine.zig").Stats;
pub const InitError = Logger.InitError;
pub const Options = options.Options;
pub const Service = options.Service;
pub const ScopeRule = options.ScopeRule;
pub const Format = options.Format;
pub const OversizePolicy = options.OversizePolicy;
pub const SourceMode = options.SourceMode;
pub const SourceOptions = options.SourceOptions;
pub const Mode = options.Mode;
pub const Queued = options.Queued;
pub const OverflowPolicy = options.OverflowPolicy;
pub const Output = options.Output;
pub const Event = hooks.Event;
pub const Subscription = hooks.Subscription;
pub const SubscriptionId = hooks.SubscriptionId;
pub const SubscribeError = hooks.SubscribeError;
pub const Interceptor = hooks.Interceptor;

test "isSensitive is core's check, so one marker serves every module" {
    const Token = struct {
        value: []const u8,
        pub const zefir_sensitive = true;
    };
    try std.testing.expect(isSensitive(Token));
    try std.testing.expect(!isSensitive(struct { value: []const u8 }));
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("level.zig");
    _ = @import("timestamp.zig");
    _ = @import("options.zig");
    _ = @import("escape.zig");
    _ = @import("redact.zig");
    _ = @import("fields.zig");
    _ = @import("encode.zig");
    _ = @import("scopes.zig");
    _ = @import("Engine.zig");
    _ = @import("Logger.zig");
    _ = @import("hex.zig");
    _ = @import("std_log.zig");
    _ = @import("Queue.zig");
    _ = @import("writer.zig");
    _ = @import("emergency.zig");
    _ = @import("tests/stress.zig");
    _ = @import("hooks.zig");
    _ = @import("tests/hooks.zig");
}
