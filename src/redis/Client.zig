//! `redis.Client`: a client of one standalone server, Redis 7.2 or later
//! or Valkey 8 or later, in RESP3 over plain TCP. `init` checks the
//! options and does no I/O; `connect` opens the first connection under
//! the caller's deadline, so that a server of the wrong kind or a password
//! it refuses shows at start; `run` sends a command of `redis.cmd` and
//! returns its reply, and `pipeline` sends many in one exchange; `close`
//! ends the work and `deinit` frees everything.
//! There is no TLS: the client belongs on a trusted network only.
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
//! const views = try client.run(io, .of(ctx), redis.cmd.raw(i64, .{ "INCR", "views:/home" }), .{});
//! ```
//!
//! Calls come from any task. Each takes a connection of the pool for its
//! exchange and gives it back: up to `max_connections` of them, opened as
//! calls need them, two at once, and calls that find none wait in line,
//! first come first served, within their deadline (`error.PoolExhausted`).
//! Every new connection shakes hands with HELLO 3, which authenticates
//! when the URL or the options give a password and names the connection
//! with `client_name`; the server must be Redis 7.2 or later or Valkey 8
//! or later, standalone. A refusal is logged to `std.log.scoped(.redis)`
//! as a warning, without the password.
//!
//! A connection that breaks under a call, or a server that refuses the
//! user of a new one, clears the pool: its connections close, and calls
//! get `error.Unavailable` until one, at most every 500 ms, opens a new
//! connection. A timeout, a cancelation and a reply that breaks RESP3 or
//! is too large close only their own connection. The clears are logged as
//! warnings.
//!
//! The rules of a call:
//!
//! 1. Concurrency. Any number of tasks and threads call a client at once;
//!    it guards what they share with `std.Io` primitives.
//! 2. `io` is the instance of `init`, and every wait goes through it.
//! 3. Deadline. A call's deadline is its context's, else `timeout` of the
//!    options from the start of the call, else there is none. It bounds
//!    the line of the pool, the opening of a connection, the write and the
//!    reply. With less than 1 ms, or less than the shortest round trip to
//!    the server, left before sending, the call is
//!    `error.DeadlineExceeded` and nothing goes out; once the command went
//!    out, the error is `error.Timeout` and its connection closes. A
//!    blocking command of the catalog sends the server what the deadline
//!    leaves beyond 150 ms, or its own timeout when shorter, for a quiet
//!    server answers a timeout up to 100 ms late: the call ends with an
//!    empty reply before the deadline, not with `error.Timeout`. With 150
//!    ms or less left, it is `error.DeadlineExceeded`, and the text names
//!    the command that does not block. Without a deadline of the context,
//!    it sends its own timeout, and `timeout` of the options is the margin
//!    after it.
//! 4. Cancellation. The token is no alarm: the client checks it before the
//!    call and before it sends, never after the reply, which it returns,
//!    since a reply of LPOP or GETDEL has taken its data off the server
//!    already. Canceling the task ends a wait: `error.Cancelled` before
//!    sending, `error.Interrupted` after, and the task keeps its
//!    cancelation.
//! 5. Memory. The command and its slices are borrowed until the call
//!    returns. The reply comes from `options.allocator` only, an arena that
//!    the client never frees from; a reply whose type holds strings or
//!    slices without one is `error.InvalidArgument` before anything goes
//!    out.
//! 6. Errors. Only `redis.Error`; `redis.outcome` tells whether the server
//!    may have run the command, and `Diagnostics` the details.
//! 7. No retries: each command goes out at most once.
//! 8. A connection whose reply is not read to its end never goes back to
//!    the pool: a reply that does not fit the type is read to its end
//!    (`error.UnexpectedReply`), and so is an error of the server
//!    (`error.ServerError`); after anything else the connection closes.
//! 9. Pushes between replies and attributes are skipped; a push is logged
//!    at debug.
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
const requests = @import("requests.zig");
const OperationContext = requests.OperationContext;
const RunOptions = requests.RunOptions;
const contract = @import("cmd/contract.zig");
const calls = @import("calls.zig");
const Conn = @import("Conn.zig");
const OwnedOptions = @import("OwnedOptions.zig");
const Address = @import("engine/Address.zig");
const Connection = @import("engine/Connection.zig");
const Pool = @import("engine/Pool.zig");
const connect_ = @import("engine/connect.zig");
const handshake = @import("engine/handshake.zig");
const time = @import("engine/time.zig");
const Client = @This();

gpa: Allocator,
/// The `io` of `init`: every call comes on it.
io: Io,
options: OwnedOptions,
pool: Pool,
/// The round trips of HELLO on new connections.
round_trips: time.RoundTrips = .{},
/// Where `connect` succeeded, 0 before, in safe builds: a call on a copy
/// of the client somewhere else panics. Atomic: any task may call while
/// another connects.
home: if (std.debug.runtime_safety) std.atomic.Value(usize) else void = if (std.debug.runtime_safety) .init(0) else {},

/// The options of `init`.
pub const Options = @import("Options.zig");
/// What `stats` returns.
pub const Stats = @import("Stats.zig");
/// The URL as `init` reads it.
pub const Url = @import("url.zig").Url;

pub const InitError = error{ InvalidArgument, Unsupported, OutOfMemory };

pub const Error = errors.Error;

/// What `run` returns for a command of type `C`; a compile error when `C`
/// is not a command.
pub fn ReplyOf(comptime C: type) type {
    return contract.ReplyOn(C, "redis.Client.run", .client);
}

/// What `pipeline` returns for commands of type `Commands`: for a tuple of
/// commands, a tuple of `redis.CommandError!T`, one for each command in
/// its order, `T` the type of its reply; for many commands of one type, a
/// slice of them.
pub fn Results(comptime Commands: type) type {
    return contract.Results(Commands, "redis.Client.pipeline", .client);
}

/// Checks `options` and copies what it keeps; no I/O. Why it refused them
/// goes to `options.diagnostics`.
pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    const owned: OwnedOptions = try .init(gpa, options);
    return .{
        .gpa = gpa,
        .io = io,
        .options = owned,
        // The host is in the copy of the URL, which does not move.
        .pool = .init(.{ .server = .{ .host = owned.url.host, .port = owned.url.port }, .max_size = owned.max_connections }),
    };
}

/// Closes the client, if `close` has not, and frees it: the copies of the
/// URL and of the password wiped.
pub fn deinit(c: *Client) void {
    calls.checkHome(c);
    c.close(c.io);
    c.pool.deinit();
    c.options.deinit(c.gpa);
    c.* = undefined;
}

/// Opens the first connection, the handshake included, under the deadline
/// of `ctx` and `connect_timeout`. Until it succeeds, calls are
/// `error.Unavailable`; it may be called again after a failure, and does
/// nothing once the client is connected. Why it failed goes to
/// `diagnostics`.
pub fn connect(c: *Client, io: Io, ctx: core.Context, diagnostics: ?*Diagnostics) Error!void {
    calls.checkUse(c, io);
    const d = diagnostics;
    if (d) |x| x.* = .{};
    try c.pool.enter(io, d);
    defer c.pool.leave(io);
    if (c.pool.isConnected(io)) return;
    try checkConnect(io, ctx, d);
    try c.pool.connect(io, c.opener(), ctx.deadline, d);
    if (std.debug.runtime_safety) c.home.store(@intFromPtr(c), .monotonic);
}

/// Ends the client's work, in this order: new calls, and those waiting
/// for a connection, get `error.Closed`; connections being opened stop;
/// the calls in flight get up to `close_timeout` to end, and after it
/// their exchanges are cut (`error.ConnectionLost`); then the connections
/// close. A second call returns once the first is done. The task's
/// cancelation waits until it returns. QUIT does not go out: the
/// connections just close.
pub fn close(c: *Client, io: Io) void {
    calls.checkUse(c, io);
    c.pool.close(io, c.options.close_timeout);
}

/// A snapshot of the connections and of the calls waiting for them.
pub fn stats(c: *Client) Stats {
    calls.checkHome(c);
    const counts = c.pool.counts(c.io);
    return .{
        .connections = counts.idle + counts.in_use,
        .idle = counts.idle,
        .in_use = counts.in_use,
        .opening = counts.opening,
        .waiting = counts.waiting,
        .subscribers = 0,
        .generation = counts.generation,
        .clears = counts.clears,
    };
}

/// Runs `command`, a value of `redis.cmd`, on a connection of the pool,
/// and returns its reply, from `options.allocator` when it holds strings
/// or slices.
///
/// ```zig
/// const rank = try client.run(io, .of(ctx), redis.cmd.raw(?u64, .{ "ZRANK", "leaders", "ann" }), .{});
/// ```
pub fn run(c: *Client, io: Io, op: OperationContext, command: anytype, options: RunOptions) Error!ReplyOf(@TypeOf(command)) {
    calls.checkUse(c, io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try calls.checkCommand(command, options, d);
    try calls.checkContext(io, op, d);
    _ = try calls.roomOf(c, io, op, .{command}, null, d);
    try c.pool.enter(io, d);
    defer c.pool.leave(io);
    const deadline = calls.deadlineOf(c, io, op, calls.waitOf(.{command}));
    const entry = try c.pool.checkOut(io, c.opener(), deadline, d);
    var after: Pool.After = .ok;
    defer c.pool.checkIn(io, entry, after);
    const conn = Connection.of(entry);
    return calls.one(c, conn, io, op, command, options, deadline, d) catch |err| {
        after = calls.afterExchange(conn, err, d);
        return err;
    };
}

/// Runs `commands` on one connection of the pool in one exchange: all of
/// them go out in one write, and their replies come back in order. On the
/// server, commands of other clients may run between them: a pipeline is
/// no transaction.
///
/// `commands` is a tuple of commands, whose results are a tuple of
/// `redis.CommandError!T`, one for each command in its order; or many
/// commands of one type, a slice of them or a pointer to their array,
/// whose results are a slice from `options.allocator`, which it then
/// needs. An error of one command, `ServerError` or `UnexpectedReply`, is
/// the value in its place, and `options.diagnostics` holds the first of
/// them, its index in `command`. Every command is checked before anything
/// goes out: one that breaks a rule, or no command at all, is
/// `error.InvalidArgument` for the whole call. An error of the exchange
/// itself, a connection that broke or a deadline that passed, is the
/// error of the call: an unknown part of the commands ran, and
/// `diagnostics.answered` says how many replies came, of commands that
/// surely ran.
///
/// ```zig
/// const r = try client.pipeline(io, op, .{
///     redis.cmd.raw(i64, .{ "INCR", "views:/home" }),
///     redis.cmd.raw(?[]const u8, .{ "GET", "motd" }),
/// }, .{ .allocator = arena });
/// const views = try r[0];
/// const motd = try r[1];
/// ```
pub fn pipeline(c: *Client, io: Io, op: OperationContext, commands: anytype, options: RunOptions) Error!Results(@TypeOf(commands)) {
    calls.checkUse(c, io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try calls.checkCommands(commands, options, d, "redis.Client.pipeline");
    try calls.checkContext(io, op, d);
    _ = try calls.roomOf(c, io, op, commands, null, d);
    var results = try calls.slots(Results(@TypeOf(commands)), commands, options);
    try c.pool.enter(io, d);
    defer c.pool.leave(io);
    const deadline = calls.deadlineOf(c, io, op, calls.waitOf(commands));
    const entry = try c.pool.checkOut(io, c.opener(), deadline, d);
    var after: Pool.After = .ok;
    defer c.pool.checkIn(io, entry, after);
    const conn = Connection.of(entry);
    calls.many(c, conn, io, op, commands, &results, options, deadline, d) catch |err| {
        after = calls.afterExchange(conn, err, d);
        return err;
    };
    return results;
}

/// A connection of the pool for the calling task alone, until
/// `conn.release`: for WATCH and the transaction that depends on it
/// (`redis.Conn`). It waits in line for one as a call does, within the
/// deadline of `op`, else `timeout` from now: `error.PoolExhausted` when
/// the deadline ends there. Release every Conn before `deinit`.
pub fn acquire(c: *Client, io: Io, op: OperationContext) Error!Conn {
    calls.checkUse(c, io);
    try calls.checkContext(io, op, null);
    try c.pool.enter(io, null);
    defer c.pool.leave(io);
    const entry = try c.pool.checkOut(io, c.opener(), calls.deadlineOf(c, io, op, .none), null);
    return .{ .client = c, .entry = entry };
}

fn opener(c: *Client) Pool.Opener {
    return .{ .context = c, .open = openForPool };
}

fn openForPool(context: *anyopaque, io: Io, deadline: ?core.Deadline, attempt: *connect_.Attempt, d: ?*Diagnostics) Error!*Pool.Entry {
    const c: *Client = @ptrCast(@alignCast(context));
    const conn = try c.open(io, deadline, attempt, d);
    return &conn.pooled;
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
            .deadline => calls.fail(d, .connect, error.DeadlineExceeded, "the deadline passed while the client connected to {f}", .{address}),
            .connect_timeout => calls.fail(d, .connect, error.Unavailable, "{f} did not answer within connect_timeout ({d} ms)", .{ address, c.options.connect_timeout.toMilliseconds() }),
        },
        error.Canceled => cancelled(io, d, "the task was canceled while the client connected"),
        error.Stopped => calls.fail(d, .connect, error.Closed, "the client was closed while it connected", .{}),
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
fn checkConnect(io: Io, ctx: core.Context, d: ?*Diagnostics) Error!void {
    if (ctx.remaining(time.now(io))) |left| if (left.nanoseconds < std.time.ns_per_ms) {
        return calls.fail(d, .connect, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the client connected", .{});
    };
    if (ctx.isCancelled()) return calls.fail(d, .connect, error.Cancelled, "the token was canceled before the client connected", .{});
    io.checkCancel() catch return cancelled(io, d, "the task was canceled before the client connected");
}

/// `error.Cancelled` of a task that was canceled, which stays canceled.
fn cancelled(io: Io, d: ?*Diagnostics, comptime text: []const u8) Error {
    io.recancel();
    return calls.fail(d, .connect, error.Cancelled, text, .{});
}
