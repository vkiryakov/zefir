//! `redis.Client`: a client of one standalone server, Redis 7.2 or later
//! or Valkey 8 or later, in RESP3 over plain TCP. `init` checks the
//! options and does no I/O; `connect` opens the first connection under
//! the caller's deadline, so that a server of the wrong kind or a password
//! it refuses shows at start; `run` sends a command of `redis.cmd` and
//! returns its reply, `pipeline` sends many in one exchange, `iterate`
//! walks the pages of a scan, and `subscribe` gives the messages of
//! channels on a connection of its own; `close` ends the work and `deinit`
//! frees everything.
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
//! const views = try client.run(io, .of(ctx), redis.cmd.incr("views:/home"), .{});
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
//!    leaves beyond 150 ms and the shortest round trip, or its own timeout
//!    when shorter, for a quiet server answers a timeout up to 100 ms
//!    late: the call ends with an empty reply before the deadline, not
//!    with `error.Timeout`. With less than 151 ms and that round trip
//!    left, it is `error.DeadlineExceeded`, and the text names the command
//!    that does not block. Without a deadline of the context,
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
//! Under zefir.App the client is a bean of its own: `start` is `connect`
//! under a deadline of `Options.start_timeout`, which logs why it failed,
//! and `shutdown` is `close` by the deadline of App's stop. `connect` and
//! `close` stay for direct use.
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
const Subscriber = @import("Subscriber.zig");
const Iterator = @import("Iterator.zig").Iterator;
const OwnedOptions = @import("OwnedOptions.zig");
const Connection = @import("engine/Connection.zig");
const Pool = @import("engine/Pool.zig");
const connect_ = @import("engine/connect.zig");
const subscription = @import("engine/subscription.zig");
const time = @import("engine/time.zig");
const log = std.log.scoped(.redis);
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
/// How many Conns of `acquire` are not released, in safe builds: `deinit`
/// with one panics.
conns: if (std.debug.runtime_safety) std.atomic.Value(usize) else void = if (std.debug.runtime_safety) .init(0) else {},
/// The subscribers of `subscribe`, on connections of their own.
subscribers: subscription.Registry = .{},

/// The options of `init`.
pub const Options = @import("Options.zig");
/// What `stats` returns.
pub const Stats = @import("Stats.zig");
/// The URL as `init` reads it.
pub const Url = @import("url.zig").Url;

/// What `init` fails with: `InvalidArgument` for options or a URL that
/// break a rule, `Unsupported` for a URL of what the client does not
/// serve, such as TLS or a UNIX socket, and `OutOfMemory`; the text goes to
/// `Options.diagnostics`.
pub const InitError = error{ InvalidArgument, Unsupported, OutOfMemory };

/// What the calls of the client fail with: `redis.Error`.
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
/// URL and of the password wiped. Release every Conn and deinit every
/// Subscriber first.
pub fn deinit(c: *Client) void {
    calls.checkHome(c);
    if (std.debug.runtime_safety and c.conns.load(.monotonic) != 0) {
        @panic("zefir-redis: Client.deinit() with a Conn not released: release every Conn before the client");
    }
    if (std.debug.runtime_safety and !c.subscribers.isEmpty(c.io)) {
        @panic("zefir-redis: Client.deinit() with a Subscriber left: deinit every Subscriber before the client");
    }
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

/// Ends the client's work, in this order: the subscribers end, and their
/// `next` returns null, while their memory waits for their `deinit`;
/// new calls, and those waiting for a connection, get `error.Closed`;
/// connections being opened stop; the calls in flight and the Conns given
/// out get up to `close_timeout` to end, a Conn by its release, and after
/// it their exchanges are cut (`error.ConnectionLost`); then the
/// connections close, that of a Conn left at its release. A second call
/// returns once the first is done. The task's cancelation waits until it
/// returns. QUIT does not go out: the connections just close.
///
/// On Windows, under zio, the cut does not end a read that already waits
/// for the server: such a call ends with the reply or at its own deadline,
/// and `close` waits for it past `close_timeout`, so a blocking command
/// with `.forever` and no deadline holds `close` until the server answers.
pub fn close(c: *Client, io: Io) void {
    calls.checkUse(c, io);
    c.subscribers.closeAll(io);
    c.pool.close(io, c.options.close_timeout);
}

/// For zefir.App, which starts the client before the beans that use it:
/// `connect` under a deadline `Options.start_timeout` away. Why it failed
/// goes to the log, as a warning: under App no caller sees the
/// `Diagnostics`. A program that wants them calls `connect`. Once the
/// client is connected, it does nothing.
pub fn start(c: *Client, io: Io) Error!void {
    var diagnostics: Diagnostics = .{};
    const ctx = core.Context.root.withDeadline(.after(time.now(io), c.options.start_timeout));
    c.connect(io, ctx, &diagnostics) catch |err| {
        log.warn("start failed: error.{t}: {s}", .{ err, diagnostics.message() });
        return err;
    };
}

/// For zefir.App, which stops the client after the beans that use it:
/// `close` by `deadline`. The subscribers end first; the calls in flight
/// get `close_timeout` to end, cut so that the wait ends 250 ms before
/// `deadline` at the latest, then their exchanges are cut, and the client
/// is closed when it returns. It has no error to return: nothing of the
/// client runs after it. As a second `close`, it returns once the first is
/// done. On Windows a call that already waits for a reply ends only with
/// the reply or at its own deadline, and `shutdown` waits for it, past
/// `deadline` too: see `close`.
pub fn shutdown(c: *Client, io: Io, deadline: Io.Clock.Timestamp) !void {
    calls.checkUse(c, io);
    const due: core.Deadline = .at(deadline.toClock(io, .awake).raw.subDuration(shutdown_reserve));
    const left = due.remaining(time.now(io));
    const budget = if (left.nanoseconds < c.options.close_timeout.nanoseconds) left else c.options.close_timeout;
    c.subscribers.closeAll(io);
    c.pool.close(io, budget);
}

/// How much earlier than its deadline `shutdown` ends its wait, so that the
/// caller, which waits for it until that deadline, sees it return in time.
const shutdown_reserve: Io.Duration = .fromMilliseconds(250);

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
        .subscribers = c.subscribers.count(c.io),
        .generation = counts.generation,
        .clears = counts.clears,
    };
}

/// Runs `command`, a value of `redis.cmd`, on a connection of the pool,
/// and returns its reply, from `options.allocator` when it holds strings
/// or slices.
///
/// ```zig
/// const rank = try client.run(io, .of(ctx), redis.cmd.zrank("leaders", "ann"), .{});
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
///     redis.cmd.incr("views:/home"),
///     redis.cmd.get([]const u8, "motd"),
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

/// The items of `command`, a scan of `redis.cmd`, `scan`, `hscan`, `sscan`
/// or `zscan`, one at a time: `redis.Iterator`. It does no I/O: each page
/// is an exchange of its `next`. The client and the slices of the command
/// must outlive the iterator.
///
/// ```zig
/// var keys = client.iterate(redis.cmd.scan(.{ .match = "session:*" }), .{ .allocator = gpa });
/// defer keys.deinit();
/// while (try keys.next(io, op)) |key| try cleanUp(key);
/// ```
pub fn iterate(c: *Client, command: anytype, options: requests.IterateOptions) Iterator(contract.ItemOf(@TypeOf(command), "redis.Client.iterate")) {
    return .init(c, command.page(), options);
}

/// A connection of the pool for the calling task alone, until
/// `conn.release`: for WATCH and the transaction that depends on it
/// (`redis.Conn`). It waits in line for one as a call does, within the
/// deadline of `op`, else `timeout` from now: `error.PoolExhausted` when
/// the deadline ends there. `close` waits for the Conn as for a call in
/// flight, up to `close_timeout`. Release every Conn before `deinit`.
pub fn acquire(c: *Client, io: Io, op: OperationContext) Error!Conn {
    calls.checkUse(c, io);
    try calls.checkContext(io, op, null);
    try c.pool.enter(io, null);
    defer c.pool.leave(io);
    const entry = try c.pool.checkOut(io, c.opener(), calls.deadlineOf(c, io, op, .none), null);
    c.pool.hold(io);
    if (std.debug.runtime_safety) _ = c.conns.fetchAdd(1, .monotonic);
    return .{ .client = c, .entry = entry };
}

/// A subscriber of `options.channels` and `options.patterns`, on a
/// connection of its own outside the pool, with the same handshake:
/// SUBSCRIBE and PSUBSCRIBE go out in one write, and it returns once the
/// server has confirmed each name, within the deadline of `op`, else
/// `timeout` from now. A refusal of the server, such as NOPERM, is
/// `error.ServerError`. `redis.Subscriber` says the rest.
///
/// ```zig
/// var sub = try client.subscribe(io, op, .{ .channels = &.{"orders"} });
/// defer sub.deinit();
/// ```
pub fn subscribe(c: *Client, io: Io, op: OperationContext, options: requests.SubscribeOptions) Error!Subscriber {
    return .{ .client = c, .state = try subscription.subscribe(c, io, op, options) };
}

fn opener(c: *Client) Pool.Opener {
    return .{ .context = c, .open = openForPool };
}

fn openForPool(context: *anyopaque, io: Io, deadline: ?core.Deadline, attempt: *connect_.Attempt, d: ?*Diagnostics) Error!*Pool.Entry {
    const c: *Client = @ptrCast(@alignCast(context));
    const conn = try calls.open(c, io, deadline, attempt, d);
    return &conn.pooled;
}

/// The context before `connect` opens anything: less than 1 ms left of
/// the deadline, a canceled token or a canceled task.
fn checkConnect(io: Io, ctx: core.Context, d: ?*Diagnostics) Error!void {
    if (ctx.remaining(time.now(io))) |left| if (left.nanoseconds < std.time.ns_per_ms) {
        return calls.fail(d, .connect, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the client connected", .{});
    };
    if (ctx.isCancelled()) return calls.fail(d, .connect, error.Cancelled, "the token was canceled before the client connected", .{});
    io.checkCancel() catch return calls.cancelled(io, d, "the task was canceled before the client connected");
}
