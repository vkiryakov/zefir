//! `rpc_log.AccessLog`: the access log of a server, as middleware. It
//! writes one record per call once the call's chain has run, at a level
//! chosen by the outcome (`Levels`):
//!
//! ```zig
//! var access_log: rpc_log.AccessLog = .init(logger.scoped("rpc"), .{
//!     .metadata_keys = &.{"x-tenant"},
//! });
//! var server = try rpc.Server.init(gpa, .{ …, .middleware = .{ &access_log, &limiter } });
//! ```
//!
//! Put it first in the server's chain: then it sees the outcome of every
//! layer inside it, and its time covers them. It works the same under
//! `rpc.RawServer`: `.middleware = &.{.of(&access_log)}`.
//!
//! The record names the failure the client got: the engine's mapping of
//! the error (`ctx.mapError`); `deadline_exceeded` once the deadline has
//! passed, whatever the chain returned, as the engine then sends it; and
//! `cancelled` for a call the engine ended at the client's cancel or at
//! the stop, even when the handler returned success afterwards. Only the
//! engine knows the outcome for sure; what middleware cannot see, it does
//! not log as it went out:
//!
//! - Calls the engine ends before the chain have no record: refused at
//!   admission (an unknown method, the limits, a full queue), refused by
//!   the authenticator, or out of time before their handler's task began.
//!   The counters of a route, `rpc.transport.Dispatcher.routeStats` (NATS
//!   micro shows them), count those of a known route.
//! - A success the engine still turns into a failure after the chain is
//!   logged as a success: a response over `max_response_bytes`, or one the
//!   transport cannot carry, goes out as `resource_exhausted`; one that
//!   ends within about a tenth of a millisecond before the deadline goes
//!   out as `deadline_exceeded` when the engine reads the clock past it.
//! - A handler that ignores the client's cancel or the stop and outlives
//!   the deadline is logged as `deadline_exceeded`, though its client got
//!   `cancelled` from the stop, or nothing after giving up.
//!
//! The record never holds the body of a request or a response,
//! credentials, metadata outside `metadata_keys`, or the identity beyond
//! its subject. One `AccessLog` serves all calls at once and keeps no
//! state between them.

const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");
const log = @import("log");
const Levels = @import("Levels.zig");
const record = @import("record.zig");

const AccessLog = @This();

logger: log.Logger,
options: Options,

pub const Options = struct {
    /// The level of a record by the outcome of its call.
    levels: Levels = .{},
    /// Keys of the request's metadata whose values the record carries in
    /// `rpc.metadata`, every value in the order it came, such as
    /// `&.{"x-tenant"}`. Borrowed: the list must outlive the middleware. No
    /// other metadata reaches the log, and the reserved keys never do. List
    /// no key whose value is a secret: the record writes it as it is.
    metadata_keys: []const []const u8 = &.{},
    /// Whether the record carries the subject of the caller's identity in
    /// `rpc.subject`, null for an anonymous call. The rest of the identity
    /// never goes in.
    log_subject: bool = false,
};

/// The most metadata entries one record carries; the listed entries past
/// them are left out.
pub const max_metadata_entries = 16;

/// No I/O and no allocation: a handle of `logger` and the options.
pub fn init(logger: log.Logger, options: Options) AccessLog {
    return .{ .logger = logger, .options = options };
}

/// The link of the server's chain: runs the rest of the chain and writes
/// its record, then returns the chain's outcome as it is.
pub fn run(self: *AccessLog, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
    const started = std.Io.Clock.awake.now(ctx.io());
    const result = next.run();
    self.write(ctx, started, result);
    return result;
}

fn write(self: *const AccessLog, ctx: *rpc.Context, started: std.Io.Timestamp, result: anyerror!void) void {
    const ended = std.Io.Clock.awake.now(ctx.io());
    const operation = ctx.operation();
    const failure = outcome(ctx, operation, ended, result);
    const level = self.options.levels.of(if (failure) |f| f.code else null);
    if (!self.logger.enabled(level)) return;

    const route = ctx.route();
    const request_id = std.fmt.bytesToHex(ctx.requestId(), .lower);
    const peer = ctx.peer();
    var entries: [max_metadata_entries]rpc.Metadata.Entry = undefined;
    const fields: record.Fields = .{
        .service = route.service,
        .version = route.version,
        .method = route.method,
        .request_id = &request_id,
        .code = if (failure) |f| @tagName(f.code) else "ok",
        .app_code = if (failure) |f| f.app_code else "",
        .duration_ms = record.milliseconds(started.durationTo(ended)),
        .transport = ctx.transport().name,
        .peer = .{ .peer = peer },
        .subject = if (ctx.identity()) |identity| identity.subject else null,
        .metadata = listed(ctx.metadata(), self.options.metadata_keys, &entries),
    };
    const shape: u4 = @as(u4, @intFromBool(failure != null)) |
        (@as(u4, @intFromBool(peer != .none)) << 1) |
        (@as(u4, @intFromBool(self.options.log_subject)) << 2) |
        (@as(u4, @intFromBool(self.options.metadata_keys.len > 0)) << 3);
    const logger = self.logger.withContext(operation);
    switch (shape) {
        inline else => |bits| record.emit(logger, level, "RPC call served", .{
            .app_code = bits & 1 != 0,
            .peer = bits & 2 != 0,
            .subject = bits & 4 != 0,
            .metadata = bits & 8 != 0,
        }, fields),
    }
}

/// The failure the client got, as far as the chain can tell; null for a
/// success.
fn outcome(ctx: *rpc.Context, operation: core.Context, ended: std.Io.Timestamp, result: anyerror!void) ?rpc.Failure {
    // Past the deadline the engine sends deadline_exceeded, whatever the
    // chain returned: it decides after the handler's task has ended, so
    // later than this, even when it has not canceled the token yet.
    if (operation.isExpired(ended)) return ctx.mapError(error.DeadlineExceeded);
    // The engine cancels the call's token when it ends the call itself: at
    // the client's cancel, at the stop. Its failure went out then.
    if (operation.isCancelled()) return ctx.mapError(error.Cancelled);
    result catch |err| return ctx.mapError(err);
    return null;
}

/// The entries of `view` whose keys `keys` lists, in the order they came;
/// at most `out.len` of them.
fn listed(view: rpc.Metadata.View, keys: []const []const u8, out: []rpc.Metadata.Entry) []const rpc.Metadata.Entry {
    var n: usize = 0;
    if (keys.len == 0) return out[0..0];
    for (view.entries) |entry| {
        if (n == out.len) break;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key, key)) {
                out[n] = entry;
                n += 1;
                break;
            }
        }
    }
    return out[0..n];
}

test "the listed metadata: every value of the listed keys, in order, no more than the room" {
    const view: rpc.Metadata.View = .{ .entries = &.{
        .{ .key = "x-tenant", .value = "acme" },
        .{ .key = "x-secret", .value = "hidden" },
        .{ .key = "x-region", .value = "eu" },
        .{ .key = "x-tenant", .value = "acme-eu" },
    } };
    var room: [2]rpc.Metadata.Entry = undefined;
    const got = listed(view, &.{ "x-region", "x-tenant" }, &room);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("acme", got[0].value);
    try std.testing.expectEqualStrings("eu", got[1].value);

    var more: [max_metadata_entries]rpc.Metadata.Entry = undefined;
    try std.testing.expectEqual(@as(usize, 3), listed(view, &.{ "x-region", "x-tenant" }, &more).len);
    try std.testing.expectEqual(@as(usize, 0), listed(view, &.{}, &more).len);
    try std.testing.expectEqual(@as(usize, 0), listed(view, &.{"authorization"}, &more).len);
}
