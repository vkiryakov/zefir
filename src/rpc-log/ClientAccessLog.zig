//! `rpc_log.ClientAccessLog`: the access log of a client, as middleware.
//! It writes one record per call once the call is over, at a level chosen
//! by the outcome (`Levels`):
//!
//! ```zig
//! var client_log: rpc_log.ClientAccessLog = .init(logger.scoped("rpc.client"), .{});
//! var client = try rpc.Client.init(gpa, .{ …, .middleware = .{&client_log} });
//! ```
//!
//! Put it first in the client's chain, so that its time covers the other
//! links. A response makes the record's `code`: "ok", or the code and
//! `app_code` of the server's failure. An error without a response
//! (`rpc.RawClient.CallError`) is written by name in `error`, with the
//! code it amounts to, the way gRPC names failures that happen on the
//! client:
//!
//! | error                                                              | code                 |
//! | ------------------------------------------------------------------ | -------------------- |
//! | `Unavailable`, `ConnectionLost`, `ClientClosed`, `TransportFailed` | `unavailable`        |
//! | `DeadlineExceeded`                                                 | `deadline_exceeded`  |
//! | `Cancelled`                                                        | `cancelled`          |
//! | `AccessDenied`                                                     | `permission_denied`  |
//! | `TooManyPendingRequests`, `RequestTooLarge`, `ResponseTooLarge`, `OutOfMemory` | `resource_exhausted` |
//! | `UnsupportedProtocol`                                              | `unimplemented`      |
//! | `ProtocolViolation`, `MiddlewareFailed`                            | `internal`           |
//!
//! Under `rpc.Client` the chain sees the response before the client
//! decodes it, so the log tells what the server sent:
//!
//! - A success that does not decode as the client's contract (contracts
//!   that diverged) is logged as `ok`, and the call ends with
//!   `error.InvalidResponse`; a body over the client's limit ends with
//!   `error.ResponseTooLarge` after the same `ok`.
//! - A request the client does not send never reaches the chain and has
//!   no record: one against its rules or that JSON cannot carry, invalid
//!   metadata, route or credentials. The `rpc.Client` result says so with
//!   `sent = false`.
//!
//! The record never holds a body, credentials or metadata. One
//! `ClientAccessLog` serves all calls at once and keeps no state between
//! them.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const log = @import("log");
const Levels = @import("Levels.zig");
const record = @import("record.zig");

const ClientAccessLog = @This();

logger: log.Logger,
options: Options,

pub const Options = struct {
    /// The level of a record by the outcome of its call.
    levels: Levels = .{},
};

/// No I/O and no allocation: a handle of `logger` and the options.
pub fn init(logger: log.Logger, options: Options) ClientAccessLog {
    return .{ .logger = logger, .options = options };
}

/// The link of the client's chain: runs the rest of the chain and writes
/// its record, then returns the chain's outcome as it is.
pub fn run(self: *ClientAccessLog, ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void {
    const started = std.Io.Clock.awake.now(ctx.io());
    const result = next.run();
    self.write(ctx, started, result);
    return result;
}

fn write(self: *const ClientAccessLog, ctx: *rpc.ClientContext, started: std.Io.Timestamp, result: anyerror!void) void {
    const ended = std.Io.Clock.awake.now(ctx.io());
    var failure: ?rpc.Failure = null;
    var failed: ?anyerror = null;
    if (result) |_| {
        if (ctx.response()) |response| switch (response.status) {
            .ok => {},
            .failure => |f| failure = f,
        };
    } else |err| failed = err;
    const code: ?core.ErrorCode = if (failure) |f| f.code else if (failed) |err| codeOf(err) else null;
    const level = self.options.levels.of(code);
    if (!self.logger.enabled(level)) return;

    const route = ctx.route();
    const request_id = std.fmt.bytesToHex(ctx.requestId(), .lower);
    const fields: record.Fields = .{
        .service = route.service,
        .version = route.version,
        .method = route.method,
        .request_id = &request_id,
        .code = if (code) |c| @tagName(c) else "ok",
        .app_code = if (failure) |f| f.app_code else "",
        .@"error" = if (failed) |err| @errorName(err) else "",
        .duration_ms = record.milliseconds(started.durationTo(ended)),
        .transport = ctx.transport().name,
    };
    const shape: u2 = @as(u2, @intFromBool(failure != null)) | (@as(u2, @intFromBool(failed != null)) << 1);
    const logger = self.logger.withContext(ctx.operation());
    switch (shape) {
        inline else => |bits| record.emit(logger, level, "RPC call made", .{
            .app_code = bits & 1 != 0,
            .@"error" = bits & 2 != 0,
        }, fields),
    }
}

/// The code a call amounts to when it ended with `err` and no response.
fn codeOf(err: anyerror) core.ErrorCode {
    return switch (err) {
        error.Unavailable, error.ConnectionLost, error.ClientClosed, error.TransportFailed => .unavailable,
        error.DeadlineExceeded => .deadline_exceeded,
        error.Cancelled => .cancelled,
        error.AccessDenied => .permission_denied,
        error.TooManyPendingRequests, error.RequestTooLarge, error.ResponseTooLarge, error.OutOfMemory => .resource_exhausted,
        error.UnsupportedProtocol => .unimplemented,
        else => .internal,
    };
}

test "every error of the client engine amounts to a code" {
    const expected = [_]struct { anyerror, core.ErrorCode }{
        .{ error.Unavailable, .unavailable },
        .{ error.AccessDenied, .permission_denied },
        .{ error.ConnectionLost, .unavailable },
        .{ error.Cancelled, .cancelled },
        .{ error.DeadlineExceeded, .deadline_exceeded },
        .{ error.TooManyPendingRequests, .resource_exhausted },
        .{ error.RequestTooLarge, .resource_exhausted },
        .{ error.ResponseTooLarge, .resource_exhausted },
        .{ error.ProtocolViolation, .internal },
        .{ error.UnsupportedProtocol, .unimplemented },
        .{ error.ClientClosed, .unavailable },
        .{ error.TransportFailed, .unavailable },
        .{ error.MiddlewareFailed, .internal },
        .{ error.OutOfMemory, .resource_exhausted },
    };
    // Every name of the engine's set is in the table.
    const names = @typeInfo(rpc.RawClient.CallError).error_set.error_names.?;
    try std.testing.expectEqual(names.len, expected.len);
    for (expected) |entry| try std.testing.expectEqual(entry[1], codeOf(entry[0]));
}
