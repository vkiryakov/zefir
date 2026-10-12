//! zefir-log — structured logging. One engine per process and any number of
//! cheap handles. Each record is one JSON line (or one text line), written
//! to stdout before the call returns.
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

const std = @import("std");
const options = @import("options.zig");

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
}
