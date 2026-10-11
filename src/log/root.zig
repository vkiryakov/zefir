//! zefir-log — structured logging. One engine per process and any number of
//! cheap handles. Each record is one JSON line (or one text line), written
//! to stdout before the call returns.
//!
//! ```zig
//! const logger = try zefir.log.Logger.init(init.gpa, init.io, .{
//!     .service = .{ .name = "user-service", .version = "1.0.0" },
//! });
//! defer logger.deinit();
//!
//! logger.info("Application started", .{ .port = 9000 });
//! const users = logger.scoped("users");
//! users.info("User created", .{ .user_id = id, .password = password }); // "password":"[REDACTED]"
//! ```
//!
//! The message is a constant; variable data goes in the fields, a struct
//! literal. Fields are scalars and strings: bool, integers (wider than 64
//! bits as strings), floats (NaN and infinities as strings), strings
//! (invalid UTF-8 becomes U+FFFD), enums and errors by name, optionals and
//! null. A field named like a secret (`password`, `api_key`, `cookie`, …)
//! is written as "[REDACTED]". Names that records use themselves (`level`,
//! `message`, `scope`, …) and types the logger cannot write are compile
//! errors at the call.
//!
//! Levels change at run time: `setLevel` for the global threshold and
//! `setScopeLevel` for a scope and its subscopes; existing handles see the
//! change at once. Logging never allocates and never fails: problems are
//! counted in `stats()`. Tests capture records with
//! `.output = .{ .writer = &writer }`.
//!
//! If stdout is closed, the logger notes it once on stderr and drops the
//! records that follow. That needs SIGPIPE ignored, as `main(init:
//! std.process.Init)` does; a bare `main()` is killed by SIGPIPE first.

const std = @import("std");
const options = @import("options.zig");

pub const Level = @import("level.zig").Level;
pub const Logger = @import("Logger.zig");
pub const Stats = @import("Engine.zig").Stats;
pub const InitError = Logger.InitError;
pub const Options = options.Options;
pub const Service = options.Service;
pub const ScopeRule = options.ScopeRule;
pub const Format = options.Format;
pub const OversizePolicy = options.OversizePolicy;
pub const Output = options.Output;

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
}
