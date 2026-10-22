//! `redis.Conn`: a connection of the client's pool held by one task, from
//! `client.acquire` until `release`, for what keeps state on a connection:
//! WATCH and the transaction that depends on it.
//!
//! ```zig
//! // Take a coffee off the stock, only if nobody took the last one first.
//! var conn = try client.acquire(io, op);
//! defer conn.release(io);
//! try conn.run(io, op, redis.cmd.watch(&.{"stock:coffee"}), .{});
//! const left = try conn.run(io, op, redis.cmd.get(i64, "stock:coffee"), .{}) orelse 0;
//! if (left == 0) return error.OutOfStock;
//! ```
//!
//! - `run` and `pipeline` take the same commands as the client's, and keep
//!   its rules: the deadline, the token, the memory of the reply, the
//!   errors. Only they run `cmd.watch` and `cmd.unwatch`. `transaction`
//!   runs commands between MULTI and EXEC, null when a key under WATCH
//!   changed.
//! - While the task holds it, the pool does not touch the connection, and
//!   `client.stats()` counts it in use. `client.acquire` waits in line for
//!   it as a call does: `error.PoolExhausted` when the deadline ends there.
//! - `release` gives the connection back to the pool, unless keys may be
//!   under WATCH on it: then it closes the connection, so that no later
//!   call gets the keys of another, and sends no UNWATCH behind the
//!   caller's back. To keep the connection, run `cmd.unwatch()` first.
//!   `release` again does nothing.
//! - An error after which the connection closes (`ConnectionLost`,
//!   `Timeout`, `Interrupted`, `ProtocolViolation`, `ReplyTooLarge`,
//!   `OutOfMemory`) leaves the Conn empty: its calls are `error.Closed`
//!   from then on, and `release` only frees it. `ServerError` and
//!   `UnexpectedReply` leave the connection as it was.
//! - `client.close` gives a Conn `close_timeout`, as a call in flight:
//!   its calls go on meanwhile, such as the transaction after its WATCH,
//!   and `close` returns once the Conn is released. After that time its
//!   exchange in progress is cut (`error.ConnectionLost`), and so is its
//!   connection: its calls are `error.Closed`, and `release` closes the
//!   connection. A Conn that is not released holds `close` up for
//!   `close_timeout`.
//!
//! The methods take `*Conn`, for the Conn holds the state of its
//! connection: `var conn`. One task at a time calls a Conn, and every
//! Conn is released before the client's `deinit`: in safe builds, a call
//! from a second task while one runs, and `deinit` with a Conn not
//! released, panic.

const std = @import("std");
const Io = std.Io;
const errors = @import("errors.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const requests = @import("requests.zig");
const OperationContext = requests.OperationContext;
const RunOptions = requests.RunOptions;
const contract = @import("cmd/contract.zig");
const calls = @import("calls.zig");
const Client = @import("Client.zig");
const Connection = @import("engine/Connection.zig");
const Pool = @import("engine/Pool.zig");
const Conn = @This();

client: *Client,
/// The connection; null once an error closed it, or after `release`.
entry: ?*Pool.Entry,
/// Whether keys may be under WATCH on the connection: set by a WATCH that
/// succeeded, cleared by UNWATCH and once a transaction sent EXEC.
watching: bool = false,
released: bool = false,
/// In safe builds: set while a method runs, so that a second task that
/// calls meanwhile panics.
busy: if (std.debug.runtime_safety) std.atomic.Value(bool) else void = if (std.debug.runtime_safety) .init(false) else {},

/// What `run` returns for a command of type `C`.
pub fn ReplyOf(comptime C: type) type {
    return contract.ReplyOn(C, "redis.Conn.run", .conn);
}

/// What `pipeline` returns for commands of type `Commands`, as for the
/// client: `redis.Client.Results`.
pub fn Results(comptime Commands: type) type {
    return contract.Results(Commands, "redis.Conn.pipeline", .conn);
}

/// Runs `command` on the connection of the Conn and returns its reply, by
/// the rules of `client.run`.
pub fn run(conn: *Conn, io: Io, op: OperationContext, command: anytype, options: RunOptions) Error!ReplyOf(@TypeOf(command)) {
    conn.enter();
    defer conn.leave();
    const c = conn.client;
    calls.checkUse(c, io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try calls.checkCommand(command, options, d);
    try calls.checkContext(io, op, d);
    _ = try calls.roomOf(c, io, op, .{command}, null, d);
    const connection = try conn.held(d);
    try c.pool.enterHeld(io, d);
    defer c.pool.leave(io);
    const deadline = calls.deadlineOf(c, io, op, calls.waitOf(.{command}));
    const reply = calls.one(c, connection, io, op, command, options, deadline, d) catch |err| {
        conn.after(io, calls.afterExchange(connection, err, d));
        return err;
    };
    conn.mark(@TypeOf(command), true);
    return reply;
}

/// Runs `commands` on the connection of the Conn in one exchange, by the
/// rules of `client.pipeline`.
pub fn pipeline(conn: *Conn, io: Io, op: OperationContext, commands: anytype, options: RunOptions) Error!Results(@TypeOf(commands)) {
    conn.enter();
    defer conn.leave();
    const c = conn.client;
    calls.checkUse(c, io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try calls.checkCommands(commands, options, d, "redis.Conn.pipeline");
    try calls.checkContext(io, op, d);
    _ = try calls.roomOf(c, io, op, commands, null, d);
    const connection = try conn.held(d);
    var results = try calls.slots(Results(@TypeOf(commands)), commands, options);
    try c.pool.enterHeld(io, d);
    defer c.pool.leave(io);
    const deadline = calls.deadlineOf(c, io, op, calls.waitOf(commands));
    calls.many(c, connection, io, op, commands, &results, options, deadline, d) catch |err| {
        conn.after(io, calls.afterExchange(connection, err, d));
        return err;
    };
    if (comptime @typeInfo(@TypeOf(commands)) == .@"struct") {
        inline for (@typeInfo(@TypeOf(commands)).@"struct".field_types, 0..) |C, i| {
            conn.mark(C, if (results[i]) |_| true else |_| false);
        }
    } else for (results) |result| {
        conn.mark(contract.Element(@TypeOf(commands)), if (result) |_| true else |_| false);
    }
    return results;
}

/// Runs `commands` as a transaction on the connection of the Conn, and
/// returns their results as `pipeline` does, or null when a key under
/// WATCH changed and the server ran none of them.
///
/// MULTI goes out on its own first, so that a server that refuses it, as
/// for a user without +multi, gets none of the commands:
/// `error.ServerError`. The commands and EXEC then go out in one write.
/// An error of one command as EXEC runs it, such as WRONGTYPE, is the
/// value in its place, and the other commands ran: there is no rollback.
/// A server that drops the whole transaction answers EXEC with EXECABORT,
/// and nothing ran: `error.ServerError` whose `diagnostics.code()` is
/// "EXECABORT". When the server refused a command as it queued it, an
/// unknown one or one the user may not run, `diagnostics.command` is its
/// index and `diagnostics.refused()` its own code and text; when EXEC
/// failed a check of its own (READONLY, OOM), both are null.
///
/// The token is checked before MULTI and once more before the commands go
/// out: canceled in between, the call is `error.Cancelled`, and the
/// connection closes rather than stay inside MULTI. A connection that
/// breaks once MULTI went out leaves it open whether EXEC ran:
/// `diagnostics.answered` counts the replies that came, MULTI's and each
/// QUEUED among them. Inside a transaction a blocking command does not
/// block, and its timeout goes to the server as given. EXEC ends the
/// WATCH of the connection, so `release` keeps the connection after a
/// transaction that sent it.
///
/// ```zig
/// const done = try conn.transaction(io, op, .{
///     redis.cmd.decr("stock:coffee"),
///     redis.cmd.rpush("orders:new", .{order_id}),
/// }, .{});
/// _ = done orelse return error.TryAgain; // the stock changed after WATCH
/// ```
pub fn transaction(conn: *Conn, io: Io, op: OperationContext, commands: anytype, options: RunOptions) Error!?Queued(@TypeOf(commands)) {
    conn.enter();
    defer conn.leave();
    const c = conn.client;
    calls.checkUse(c, io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try calls.checkCommands(commands, options, d, "redis.Conn.transaction");
    try calls.checkContext(io, op, d);
    const connection = try conn.held(d);
    var results = try calls.slots(Queued(@TypeOf(commands)), commands, options);
    try c.pool.enterHeld(io, d);
    defer c.pool.leave(io);
    // Nothing blocks inside a transaction.
    const deadline = calls.deadlineOf(c, io, op, .none);
    const executed = calls.transaction(c, connection, io, op, commands, &results, options, deadline, d, &conn.watching) catch |err| {
        conn.after(io, calls.afterExchange(connection, err, d));
        return err;
    };
    return if (executed) results else null;
}

/// What `transaction` returns for commands of type `Commands`, when the
/// server ran them: the results of a pipeline of them.
fn Queued(comptime Commands: type) type {
    return contract.Results(Commands, "redis.Conn.transaction", .transaction);
}

/// Gives the connection back to the pool, or closes it when keys may be
/// under WATCH on it; after an error that closed it, only frees the Conn.
/// A second call does nothing.
pub fn release(conn: *Conn, io: Io) void {
    conn.enter();
    defer conn.leave();
    if (conn.released) return;
    const c = conn.client;
    calls.checkUse(c, io);
    if (conn.entry) |entry| {
        c.pool.checkIn(io, entry, if (conn.watching) .broken else .ok);
        c.pool.unhold(io);
    }
    conn.entry = null;
    conn.released = true;
    if (std.debug.runtime_safety) _ = c.conns.fetchSub(1, .monotonic);
}

/// In safe builds: a call while another task's runs panics.
fn enter(conn: *Conn) void {
    if (std.debug.runtime_safety and conn.busy.swap(true, .acquire)) {
        @panic("zefir-redis: a Conn used by two tasks at once: one task at a time calls a Conn");
    }
}

fn leave(conn: *Conn) void {
    if (std.debug.runtime_safety) conn.busy.store(false, .release);
}

/// The connection of the Conn, or `error.Closed` when it has none.
fn held(conn: *const Conn, d: ?*Diagnostics) Error!*Connection {
    if (conn.entry) |entry| return Connection.of(entry);
    if (conn.released) return calls.fail(d, .checkout, error.Closed, "the Conn was released", .{});
    return calls.fail(d, .checkout, error.Closed, "the Conn lost its connection to an error before: release it, and acquire another", .{});
}

/// What an exchange that failed left of the connection: one that is no
/// longer usable goes back to the pool, which closes it, and the Conn is
/// empty.
fn after(conn: *Conn, io: Io, left: Pool.After) void {
    if (left == .ok) return;
    conn.client.pool.checkIn(io, conn.entry.?, left);
    conn.client.pool.unhold(io);
    conn.entry = null;
}

/// Notes what a command of type `C` did to the WATCH of the connection,
/// when it `succeeded`.
fn mark(conn: *Conn, comptime C: type, succeeded: bool) void {
    switch (comptime contract.scopeOf(C)) {
        .any => {},
        .connection => |rule| if (succeeded) {
            conn.watching = rule.watching;
        },
    }
}
