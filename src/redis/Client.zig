//! `redis.Client`: a client of one standalone server, Redis 7.2 or later
//! or Valkey 8 or later, in RESP3 over plain TCP. `init` checks the
//! options and does no I/O; `connect` opens the first connection under
//! the caller's deadline, so that a server of the wrong kind or a password
//! it refuses shows at start; `close` ends the work and `deinit` frees
//! everything. There is no TLS: the client belongs on a trusted network
//! only.
//!
//! ```zig
//! var client: redis.Client = try .init(gpa, io, .{ .url = "redis://127.0.0.1:6379/0" });
//! defer client.deinit();
//! var diagnostics: redis.Diagnostics = .{};
//! client.connect(io, ctx, &diagnostics) catch |err| {
//!     log.err("redis: {t}: {s}", .{ err, diagnostics.message() });
//!     return err;
//! };
//! defer client.close(io);
//! ```
//!
//! Every new connection shakes hands with HELLO 3, which authenticates
//! when the URL or the options give a password and names the connection
//! with `client_name`; the server must be Redis 7.2 or later or Valkey 8
//! or later, standalone. A refusal is logged to `std.log.scoped(.redis)`
//! as a warning, without the password.
//!
//! After `connect` the client must stay where it is, and every call comes
//! on the `io` of `init`: in safe builds, a call on a moved copy of the
//! client or on another `std.Io` panics.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const errors = @import("errors.zig");
const Diagnostics = errors.Diagnostics;
const OwnedOptions = @import("OwnedOptions.zig");
const Address = @import("engine/Address.zig");
const Connection = @import("engine/Connection.zig");
const connect_ = @import("engine/connect.zig");
const handshake = @import("engine/handshake.zig");
const time = @import("engine/time.zig");
const Client = @This();

gpa: Allocator,
/// The `io` of `init`: every call comes on it.
io: Io,
options: OwnedOptions,
/// The round trips of HELLO on new connections.
round_trips: time.RoundTrips = .{},
/// Held by `connect` while it opens a connection, so that one opens at a
/// time and `close` can wait for it.
connecting: Io.Mutex = .init,
/// Guards `conn` and `attempt`.
mutex: Io.Mutex = .init,
/// The connection of `connect`.
conn: ?*Connection = null,
/// The opening of a connection in progress, for `close` to stop.
attempt: ?*connect_.Attempt = null,
/// Set by the first `close`, and `closed` once it is done.
closing: std.atomic.Value(bool) = .init(false),
closed: Io.Event = .unset,
/// Where `connect` succeeded, 0 before, in safe builds: a call on a copy
/// of the client somewhere else panics. Atomic: any task may call while
/// another connects.
home: if (std.debug.runtime_safety) std.atomic.Value(usize) else void = if (std.debug.runtime_safety) .init(0) else {},

/// The options of `init`.
pub const Options = @import("Options.zig");
/// The URL as `init` reads it.
pub const Url = @import("url.zig").Url;

pub const InitError = error{ InvalidArgument, Unsupported, OutOfMemory };

pub const Error = errors.Error;

/// Checks `options` and copies what it keeps; no I/O. Why it refused them
/// goes to `options.diagnostics`.
pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    return .{ .gpa = gpa, .io = io, .options = try .init(gpa, options) };
}

/// Closes the client, if `close` has not, and frees it: the copies of the
/// URL and of the password wiped.
pub fn deinit(c: *Client) void {
    c.checkHome();
    c.close(c.io);
    c.options.deinit(c.gpa);
    c.* = undefined;
}

/// Opens the first connection, the handshake included, under the deadline
/// of `ctx` and `connect_timeout`. It may be called again after a failure,
/// and does nothing once the client is connected. Why it failed goes to
/// `diagnostics`.
pub fn connect(c: *Client, io: Io, ctx: core.Context, diagnostics: ?*Diagnostics) Error!void {
    c.checkUse(io);
    const d = diagnostics;
    if (d) |x| x.* = .{};
    if (c.closing.load(.acquire)) return closedError(d);
    c.connecting.lock(io) catch return cancelled(io, d, "the task was canceled before the client connected");
    defer c.connecting.unlock(io);
    try checkContext(io, ctx, d);
    var attempt: connect_.Attempt = .{};
    switch (c.track(io, &attempt)) {
        .connected => return,
        .closed => return closedError(d),
        .tracked => {},
    }
    defer c.untrack(io);
    const conn = try c.open(io, ctx.deadline, &attempt, d);
    if (!c.keep(io, conn)) {
        conn.destroy();
        return fail(d, .connect, error.Closed, "the client was closed while it connected", .{});
    }
    if (std.debug.runtime_safety) c.home.store(@intFromPtr(c), .monotonic);
}

/// Ends the client's work: new calls get `error.Closed`, a `connect` in
/// progress stops, and the connections close. A second call returns once
/// the first is done. The task's cancelation waits until it returns.
pub fn close(c: *Client, io: Io) void {
    c.checkUse(io);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    if (c.closing.swap(true, .acq_rel)) {
        c.closed.waitUncancelable(io);
        return;
    }
    {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (c.attempt) |attempt| attempt.stop(io);
    }
    // A connect in progress ends soon, stopped: wait for it.
    c.connecting.lockUncancelable(io);
    c.connecting.unlock(io);
    c.mutex.lockUncancelable(io);
    const conn = c.conn;
    c.conn = null;
    c.mutex.unlock(io);
    if (conn) |x| x.destroy();
    c.closed.set(io);
}

/// In safe builds: a call on a moved copy of the client, or on another
/// `std.Io` than the one of `init`, panics, since the connections and the
/// waits of the client belong to the original and its `io`.
fn checkUse(c: *const Client, io: Io) void {
    c.checkHome();
    if (std.debug.runtime_safety and io.vtable != c.io.vtable) {
        @panic("zefir-redis: a call on another std.Io than the client's: pass the io of Client.init");
    }
}

inline fn checkHome(c: *const Client) void {
    if (std.debug.runtime_safety) {
        const home = c.home.load(.monotonic);
        if (home != 0 and home != @intFromPtr(c)) @panic("zefir-redis: Client moved after connect(): keep it where connect() ran (see the guide)");
    }
}

/// Registers the opening of a connection for `close`, unless the client
/// is connected or closed already.
fn track(c: *Client, io: Io, attempt: *connect_.Attempt) enum { tracked, connected, closed } {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    if (c.closing.load(.acquire)) return .closed;
    if (c.conn != null) return .connected;
    c.attempt = attempt;
    return .tracked;
}

fn untrack(c: *Client, io: Io) void {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    c.attempt = null;
}

/// Keeps `conn`, unless `close` came meanwhile.
fn keep(c: *Client, io: Io, conn: *Connection) bool {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    if (c.closing.load(.acquire)) return false;
    c.conn = conn;
    return true;
}

/// Opens a connection within `connect_timeout` and the deadline of the
/// call, whichever ends first.
fn open(c: *Client, io: Io, deadline: ?core.Deadline, attempt: *connect_.Attempt, d: ?*Diagnostics) Error!*Connection {
    const url = &c.options.url;
    // The host is in the copy of the URL, which outlives the connection.
    const address: Address = .{ .host = url.host, .port = url.port };
    const budget = connect_.budget(time.now(io), c.options.connect_timeout, deadline);
    const setup = handshake.setupOf(&c.options);
    const conn = connect_.open(io, c.gpa, address, c.options.max_reply_bytes, &setup, budget.deadline, attempt, d) catch |err| return switch (err) {
        error.Unavailable, error.Unsupported, error.AuthenticationFailed, error.InvalidArgument, error.OutOfMemory => |e| e,
        error.Timeout => switch (budget.by) {
            .deadline => fail(d, .connect, error.DeadlineExceeded, "the deadline passed while the client connected to {f}", .{address}),
            .connect_timeout => fail(d, .connect, error.Unavailable, "{f} did not answer within connect_timeout ({d} ms)", .{ address, c.options.connect_timeout.toMilliseconds() }),
        },
        error.Canceled => cancelled(io, d, "the task was canceled while the client connected"),
        error.Stopped => fail(d, .connect, error.Closed, "the client was closed while it connected", .{}),
        error.ConcurrencyUnavailable => {
            if (d) |x| x.set(.connect, err, "no task to connect to {f} in: the std.Io has no room for one", .{address});
            return error.Unavailable;
        },
    };
    if (conn.rtt) |rtt| c.round_trips.add(io, rtt);
    return conn;
}

/// The context before `connect` opens anything: less than 1 ms left of
/// the deadline, a canceled token or a canceled task.
fn checkContext(io: Io, ctx: core.Context, d: ?*Diagnostics) Error!void {
    if (ctx.remaining(time.now(io))) |left| if (left.nanoseconds < std.time.ns_per_ms) {
        return fail(d, .connect, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the client connected", .{});
    };
    if (ctx.isCancelled()) return fail(d, .connect, error.Cancelled, "the token was canceled before the client connected", .{});
    io.checkCancel() catch return cancelled(io, d, "the task was canceled before the client connected");
}

/// `error.Cancelled` of a task that was canceled, which stays canceled.
fn cancelled(io: Io, d: ?*Diagnostics, comptime text: []const u8) Error {
    io.recancel();
    return fail(d, .connect, error.Cancelled, text, .{});
}

fn closedError(d: ?*Diagnostics) Error {
    return fail(d, null, error.Closed, "the client is closed", .{});
}

fn fail(d: ?*Diagnostics, phase: ?Diagnostics.Phase, err: Error, comptime fmt: []const u8, args: anytype) Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}
