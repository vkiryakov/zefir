//! `mongo.Client`: a client of one standalone mongod of MongoDB 7.0 or
//! later, over plain TCP. `init` checks the options and does no I/O;
//! `connect` opens the first connection under the caller's deadline, so a
//! server of the wrong kind or a user it refuses shows at start; the calls
//! `runCommand`, `openCursor` and `write` go to the server; `close` ends
//! the work and `deinit` frees everything. There is no TLS: the client
//! belongs on a trusted network only.
//!
//! ```zig
//! var client: mongo.Client = try .init(gpa, io, .{ .uri = "mongodb://127.0.0.1:27017/app" });
//! defer client.deinit();
//! var diagnostics: mongo.Diagnostics = .{};
//! client.connect(io, ctx, &diagnostics) catch |err| {
//!     log.err("mongo: {t}: {s}", .{ err, diagnostics.message() });
//!     return err;
//! };
//! defer client.close(io);
//! var ids: mongo.bson.ObjectId.Generator = .init(io);
//! const db: mongo.Database = .init(&client, "app", &ids);
//! ```
//!
//! Calls come from any task. Each takes a connection of the pool for its
//! exchange, every batch of a write for its own, and gives it back: up to `maxPoolSize` connections, opened as
//! calls need them, `maxConnecting` at once, and calls that find none wait
//! in line, first come first served, within their deadline and
//! `serverSelectionTimeoutMS` (`error.PoolExhausted`). Every new
//! connection authenticates as the user of the connection string, by
//! SCRAM-SHA-256 or SCRAM-SHA-1.
//!
//! A network error on a connection, a failed authentication or a server
//! shutting down (codes 11600 and 91) clears the pool: its connections are
//! closed, and calls get `error.Unavailable` until one, at most every
//! 500 ms, opens a new connection. A timeout closes only its own
//! connection. A network error while a connection opens clears nothing;
//! its `Diagnostics.server` holds the labels SystemOverloadedError and
//! RetryableError, code 0, unless the host name is to blame.
//!
//! It logs to `std.log.scoped(.mongo)`, as warnings: the options of the
//! connection string it skips, the clears of the pool and the servers that
//! refuse a connection. Bodies of commands, passwords and the replies of
//! authentication never go to the log.
//!
//! A cursor holds its batches in the client's memory, and gets more of
//! them on any connection of the pool. One task at a time uses a cursor;
//! `deinit` every cursor before the client.
//!
//! The rules of the calls:
//!
//! 1. Concurrency. Any number of tasks and threads call a client at once;
//!    it guards what they share with `std.Io` primitives, since a lock of
//!    the OS would stop a whole thread of an event loop. A cursor serves
//!    one task at a time.
//! 2. `io` is the instance of `init`, and every wait goes through it.
//! 3. Deadline. With less than 1 ms, or less than the shortest round trip
//!    to the server, left before sending, the call is
//!    `error.DeadlineExceeded`. Otherwise the client adds `maxTimeMS` (to
//!    every command but `getMore` and `killCursors`) and waits for the
//!    reply no longer than the deadline; after sending, the error is
//!    `error.Timeout`. Without a deadline of the context or of `timeoutMS`
//!    no `maxTimeMS` goes out, and only the client's own timeouts bound
//!    the wait.
//! 4. Cancellation. The token is no alarm: the client checks it before the
//!    call, before each send and after the reply. Canceling the task ends
//!    a wait: `error.Cancelled` before sending, `error.Interrupted` after,
//!    and the task keeps its cancelation. A cancelation or a timeout in
//!    the middle of an exchange closes that connection.
//! 5. Memory. The request and its slices are borrowed until the call
//!    returns. The reply, the write result, `failure_reply` and `partial`
//!    come from `options.allocator`, during the call only; the
//!    `failure_reply` of `openCursor`, whose options have no allocator,
//!    from the client's. After it the client holds no reference to the
//!    caller's memory.
//! 6. Errors. Only `mongo.Error`. `ok: 0` is `CommandFailed`, code 50
//!    anywhere is `Timeout`, a write stopped at batch k > 1 is
//!    `IncompleteWrite`. `writeErrors` and `writeConcernError` are soft:
//!    they are in the `WriteResult`. `WriteFailed` is the collection API's.
//! 7. The client adds `$db` to every command, `maxTimeMS` by rule 3, and
//!    `ordered` to writes; nothing else.
//! 8. No retries: the client sends each command and each batch at most
//!    once.
//! 9. Writes follow `mongo.WriteRequest`: batches by the limits of the
//!    connection they go through, items in a section of kind 1, replies
//!    merged as the Bulk API spec merges them. Cursors follow
//!    `mongo.Cursor`.
//!
//! Before an exchange the client checks the request — a database name of
//! 1–63 bytes without `/\. "$` or NUL; a command whose first key names
//! it and does not start with `$`; none of the client's fields in it, nor
//! `maxTimeMS` under a deadline; a write named after its kind, without
//! `documents`, `updates`, `deletes` and `ordered`, with items — which is
//! `error.InvalidArgument`; then the context, `error.DeadlineExceeded`
//! before `error.Cancelled`. After the reply it checks the token again:
//! canceled meanwhile, the call is `error.Interrupted`, its reply freed,
//! its cursor closed, its write result in `partial`. `Cursor.next` has no
//! such check: a batch of `getMore` has moved the cursor on the server
//! already. Each call starts the caller's `Diagnostics` afresh.
//!
//! After `connect` the client must stay where it is, and every call comes
//! on the `io` of `init`: in safe builds, a call on a moved copy of the
//! client or on another `std.Io`, a cursor used by two tasks at once, and
//! `deinit` with cursors left panic.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const mongo = @import("root.zig");
const bson = mongo.bson;
const Diagnostics = mongo.Diagnostics;
const OperationContext = mongo.OperationContext;
const Cursor = @import("Cursor.zig");
const OwnedOptions = @import("OwnedOptions.zig");
const Connection = @import("engine/Connection.zig");
const Pool = @import("engine/Pool.zig");
const command_ = @import("engine/command.zig");
const connect_ = @import("engine/connect.zig");
const cursor_ = @import("engine/cursor.zig");
const write_ = @import("engine/write.zig");
const handshake = @import("engine/handshake.zig");
const KeyCache = @import("engine/KeyCache.zig");
const scram = @import("engine/scram.zig");
const time = @import("engine/time.zig");
const log = std.log.scoped(.mongo);
const Client = @This();

gpa: Allocator,
/// The `io` of `init`: every call comes on it.
io: Io,
options: OwnedOptions,
/// The `client` document of the hello of every new connection.
metadata: bson.OwnedDocument,
/// The keys of SCRAM, so that PBKDF2 runs for the first connection only.
keys: KeyCache = .{},
pool: Pool,
/// The round trips of hello on new connections, for `maxTimeMS`.
round_trips: time.RoundTrips = .{},
/// The cursors, which `close` kills while the server holds them.
cursors: cursor_.Registry = .{},
/// Set by the first `close`, and `closed` once it is done.
closing: std.atomic.Value(bool) = .init(false),
closed: Io.Event = .unset,
/// Where `connect` succeeded, 0 before, in safe builds: a call on a copy
/// of the client somewhere else panics. Atomic: any task may call while
/// another connects.
home: if (std.debug.runtime_safety) std.atomic.Value(usize) else void = if (std.debug.runtime_safety) .init(0) else {},

/// The options of `init`.
pub const Options = @import("Options.zig");
/// What `stats` returns.
pub const Stats = @import("Stats.zig");
/// The connection string as `init` reads it, and what each of its options
/// does.
pub const Uri = @import("uri.zig").Uri;

pub const InitError = error{ InvalidArgument, Unsupported, OutOfMemory };

/// Checks `options` and copies what it keeps; no I/O.
pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    const d = options.diagnostics;
    var owned: OwnedOptions = try .init(gpa, options);
    errdefer owned.deinit(gpa);
    // authMechanism=SCRAM-SHA-256 must take the password; the mechanism
    // the server picks is checked when it picks it.
    if (owned.credentials()) |c| if (c.mechanism) |mechanism| try scram.checkPassword(mechanism, c.password, null, d);
    const metadata = try handshake.metadata(gpa, owned.uri.app_name, d);
    const uri = &owned.uri;
    return .{
        .gpa = gpa,
        .io = io,
        .options = owned,
        .metadata = metadata,
        // The host is in the copy of the strings, which does not move.
        .pool = .init(.{
            .server = .{ .host = uri.host, .port = uri.port },
            .max_size = uri.max_pool_size,
            .max_connecting = uri.max_connecting,
            .max_idle_time = uri.max_idle_time,
        }),
    };
}

/// Closes the client, if `close` has not, and frees it: the copies of the
/// connection string and the password, and the keys of SCRAM, wiped.
/// `deinit` the cursors before: in safe builds a cursor left panics.
pub fn deinit(self: *Client) void {
    self.checkHome();
    if (std.debug.runtime_safety and self.cursors.liveCount(self.io) > 0) {
        @panic("zefir-mongo: Client.deinit() with cursors left: deinit every cursor before the client");
    }
    self.close(self.io);
    self.pool.deinit();
    self.keys.deinit();
    self.metadata.deinit();
    self.options.deinit(self.gpa);
    self.* = undefined;
}

/// Opens the first connection, hello and authentication included, under
/// the deadline of `ctx`. Until it succeeds, calls are
/// `error.Unavailable`; it may be called again after a failure, and does
/// nothing once the client is connected. Why it failed goes to
/// `diagnostics`.
pub fn connect(self: *Client, io: Io, ctx: core.Context, diagnostics: ?*Diagnostics) mongo.Error!void {
    self.checkUse(io);
    const d = diagnostics;
    if (d) |x| x.* = .{};
    try self.pool.enter(io, d);
    defer self.pool.leave(io);
    if (self.pool.isConnected(io)) return;
    try checkBeforeSend(io, .of(ctx), ctx.deadline, d);
    try self.pool.connect(io, self.opener(), self.runner().limits(io, ctx.deadline), d);
    if (std.debug.runtime_safety) self.home.store(@intFromPtr(self), .monotonic);
}

/// Ends the client's work, in this order: new calls, and
/// those waiting for a connection, get `error.Closed`; connections being
/// opened stop; the calls in flight get up to `close_timeout` to end, and
/// after it their exchanges are cut (`error.ConnectionLost`); the cursors
/// that the server still holds get `killCursors`, within
/// `cursor_close_timeout`, and their `next` is `error.Closed`; then the
/// connections close. A second call returns once the first is done. The
/// task's cancelation waits until it returns.
pub fn close(self: *Client, io: Io) void {
    self.checkUse(io);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    if (self.closing.swap(true, .acq_rel)) {
        self.closed.waitUncancelable(io);
        return;
    }
    self.pool.close(io, self.options.close_timeout);
    cursor_.closeAll(self.runner(), io);
    self.closed.set(io);
}

/// A snapshot of the connections and the calls waiting for them.
pub fn stats(self: *Client) Stats {
    self.checkHome();
    const counts = self.pool.counts(self.io);
    return .{
        .connections = counts.idle + counts.in_use,
        .idle = counts.idle,
        .in_use = counts.in_use,
        .opening = counts.opening,
        .waiting = counts.waiting,
        .generation = counts.generation,
        .clears = counts.clears,
        .open_cursors = self.cursors.openCount(self.io),
    };
}

/// Runs `command` and returns the server's reply, from
/// `options.allocator`; `deinit` it.
///
/// ```zig
/// const reply = try client.runCommand(io, .of(ctx), .{ .database = "app", .body = bson.literal(.{ .ping = 1 }) }, .{ .allocator = arena });
/// ```
pub fn runCommand(self: *Client, io: Io, op: OperationContext, command: mongo.Command, options: mongo.CommandOptions) mongo.Error!bson.OwnedDocument {
    self.checkUse(io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try checkCommand(&command, op, d);
    try checkContext(io, op, d);
    const reply = try command_.run(self.runner(), io, op, &command, options);
    if (op.ctx.isCancelled()) {
        reply.deinit();
        return interrupted(d);
    }
    return reply;
}

/// Runs a command that answers with a cursor, such as `find` or
/// `aggregate`, and returns the cursor with its first batch; `deinit` it.
///
/// ```zig
/// var cursor = try client.openCursor(io, .of(ctx), .{ .database = "app", .body = find }, .{ .batch_size = 100 });
/// defer cursor.deinit(io);
/// while (try cursor.next(io, .of(ctx))) |doc| try handle(doc);
/// ```
pub fn openCursor(self: *Client, io: Io, op: OperationContext, command: mongo.Command, options: mongo.CursorOptions) mongo.Error!Cursor {
    self.checkUse(io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try checkCommand(&command, op, d);
    try checkContext(io, op, d);
    const cursor: Cursor = .{ .state = try cursor_.open(self.runner(), io, op, &command, options) };
    if (op.ctx.isCancelled()) {
        // deinit sends killCursors when the server holds the cursor.
        cursor.deinit(io);
        return interrupted(d);
    }
    return cursor;
}

/// Sends the items of `request` in batches and returns their merged
/// result, from `options.allocator`; `deinit` it with that allocator.
pub fn write(self: *Client, io: Io, op: OperationContext, request: mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
    self.checkUse(io);
    const d = options.diagnostics;
    if (d) |x| x.* = .{};
    try checkWrite(&request, op, d);
    try checkContext(io, op, d);
    var result = try write_.run(self.runner(), io, op, &request, options);
    if (op.ctx.isCancelled()) {
        if (options.partial) |partial| partial.* = result else result.deinit(options.allocator);
        return interrupted(d);
    }
    return result;
}

/// In safe builds: a call on a moved copy of the client, or on another
/// `std.Io` than the one of `init`, panics, since the pool and the waits
/// of the client belong to the original and its `io`.
fn checkUse(self: *const Client, io: Io) void {
    self.checkHome();
    if (std.debug.runtime_safety and io.vtable != self.io.vtable) {
        @panic("zefir-mongo: a call on another std.Io than the client's: pass the io of Client.init");
    }
}

inline fn checkHome(self: *const Client) void {
    if (std.debug.runtime_safety) {
        const home = self.home.load(.monotonic);
        if (home != 0 and home != @intFromPtr(self)) @panic("zefir-mongo: Client moved after connect(): keep it where connect() ran (see the guide)");
    }
}

/// What the operations need of the client, for one call.
fn runner(self: *Client) command_.Runner {
    return .{
        .io = self.io,
        .gpa = self.gpa,
        .pool = &self.pool,
        .opener = self.opener(),
        .round_trips = &self.round_trips,
        .cursors = &self.cursors,
        .timeout = self.options.uri.timeout,
        .server_selection_timeout = self.options.uri.server_selection_timeout,
        .cursor_close_timeout = self.options.cursor_close_timeout,
    };
}

/// The context before `connect` opens its connection: less than 1 ms left
/// of the deadline, a canceled token or a canceled task.
fn checkBeforeSend(io: Io, op: OperationContext, deadline: ?core.Deadline, d: ?*Diagnostics) mongo.Error!void {
    if (deadline) |dl| if (dl.remaining(time.now(io)).nanoseconds < std.time.ns_per_ms) {
        return fail(d, .send, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the command went out", .{});
    };
    if (op.ctx.isCancelled()) return fail(d, .send, error.Cancelled, "the token was canceled before the command went out", .{});
    io.checkCancel() catch {
        io.recancel();
        return fail(d, .send, error.Cancelled, "the task was canceled before the command went out", .{});
    };
}

fn opener(self: *Client) Pool.Opener {
    return .{ .context = self, .open = openForPool };
}

fn openForPool(context: *anyopaque, io: Io, call: Pool.Limits, attempt: *connect_.Attempt, d: ?*Diagnostics) mongo.Error!*Pool.Entry {
    const self: *Client = @ptrCast(@alignCast(context));
    const conn = try self.open(io, call, attempt, d);
    return &conn.pooled;
}

/// What ends the opening of a connection first.
const Budget = enum { deadline, connect_timeout, server_selection };

/// Opens a connection for the pool, within `connectTimeoutMS`, the
/// deadline of the call and `serverSelectionTimeoutMS`, whichever ends
/// first.
fn open(self: *Client, io: Io, call: Pool.Limits, attempt: *connect_.Attempt, d: ?*Diagnostics) mongo.Error!*Connection {
    const uri = &self.options.uri;
    const address: Connection.Address = .{ .host = uri.host, .port = uri.port };
    var budget = call.checkout;
    var by: Budget = .server_selection;
    if (uri.connect_timeout) |timeout| {
        const limit: core.Deadline = .after(time.now(io), timeout);
        if (limit.expires.nanoseconds < budget.expires.nanoseconds) {
            budget = limit;
            by = .connect_timeout;
        }
    }
    if (call.deadline) |deadline| if (deadline.expires.nanoseconds <= budget.expires.nanoseconds) {
        budget = deadline;
        by = .deadline;
    };
    const setup: handshake.Setup = .{
        .metadata = self.metadata.raw(),
        .auth = if (self.options.credentials()) |c| .{ .credentials = c, .keys = &self.keys } else null,
    };
    // The reason of a refusal goes to the log too.
    var own: Diagnostics = .{};
    const why = d orelse &own;
    const conn = connect_.open(io, self.gpa, address, &setup, budget, attempt, why) catch |err| return switch (err) {
        error.Unavailable, error.OutOfMemory => |e| e,
        error.Unsupported, error.AuthenticationFailed => |e| {
            // The text is the server's errmsg or the driver's own: no
            // password, no reply of authentication.
            log.warn("{f} refused a connection: {t}: {s}", .{ address, e, why.message() });
            return e;
        },
        error.Timeout => switch (by) {
            .deadline => fail(d, .connect, error.DeadlineExceeded, "the deadline passed while the client connected to {f}", .{address}),
            .connect_timeout => overloaded(d, "{f} did not answer within connectTimeoutMS ({d} ms)", .{ address, uri.connect_timeout.?.toMilliseconds() }),
            .server_selection => overloaded(d, "{f} did not answer within serverSelectionTimeoutMS ({d} ms)", .{ address, uri.server_selection_timeout.toMilliseconds() }),
        },
        error.Canceled => {
            io.recancel();
            return fail(d, .connect, error.Cancelled, "the task was canceled while the client connected to {f}", .{address});
        },
        error.Stopped => fail(d, .connect, error.Closed, "the client was closed while it connected", .{}),
        error.ConcurrencyUnavailable => {
            if (d) |x| x.set(.connect, err, "no task to connect to {f} in: the std.Io has no room for one", .{address});
            return error.Unavailable;
        },
    };
    if (conn.rtt) |rtt| self.round_trips.add(io, rtt);
    return conn;
}

/// `error.Unavailable` of a connection that did not open in time, with the
/// labels of overload.
fn overloaded(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) mongo.Error {
    if (d) |x| x.set(.connect, null, fmt, args);
    handshake.markOverloaded(d);
    return error.Unavailable;
}

fn fail(d: ?*Diagnostics, phase: ?Diagnostics.Phase, err: mongo.Error, comptime fmt: []const u8, args: anytype) mongo.Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}

/// The fields that only the client writes into a command: `$db` always,
/// the rest with the sessions and read preferences of later releases.
const driver_fields = [_][]const u8{ "$db", "$readPreference", "lsid", "txnNumber", "$clusterTime", "autocommit", "startTransaction" };

/// The fields that the client writes into a write from its request.
const write_fields = [_][]const u8{ "documents", "updates", "deletes", "ordered" };

/// The rules of a command, before anything else of a call: a broken one is
/// `error.InvalidArgument`, and nothing goes out.
fn checkCommand(command: *const mongo.Command, op: OperationContext, d: ?*Diagnostics) mongo.Error!void {
    try checkDatabase(command.database, d);
    _ = try checkBody(command.body, op, &.{}, d);
}

fn checkWrite(request: *const mongo.WriteRequest, op: OperationContext, d: ?*Diagnostics) mongo.Error!void {
    try checkDatabase(request.database, d);
    const name = try checkBody(request.body, op, &write_fields, d);
    const kind = request.kind.command();
    if (!std.mem.eql(u8, name, kind)) return invalid(d, "a write of kind {s} is the command {s}, but its body starts with '{s}'", .{ kind, kind, name });
    if (request.items.len == 0) return invalid(d, "the write has no items: it needs at least one", .{});
    if (builtin.mode == .debug) for (request.items, 0..) |item, i| {
        item.validate() catch return invalid(d, "item {d} of the write is not valid BSON", .{i});
    };
}

/// The caller's context: `DeadlineExceeded` with less than 1 ms left, else
/// `Cancelled` when its token is canceled. The deadline comes first, as
/// in rpc: a server cancels the token of a call at its deadline.
fn checkContext(io: Io, op: OperationContext, d: ?*Diagnostics) mongo.Error!void {
    if (op.ctx.remaining(time.now(io))) |left| {
        if (left.nanoseconds < std.time.ns_per_ms) return fail(d, null, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the call", .{});
    }
    if (op.ctx.isCancelled()) return fail(d, null, error.Cancelled, "the token was canceled before the call", .{});
}

/// After a reply: a token canceled while the call was out.
fn interrupted(d: ?*Diagnostics) mongo.Error {
    return fail(d, null, error.Interrupted, "the token was canceled while the call was out; its outcome is dropped", .{});
}

/// A database name: 1 to 63 bytes, without NUL and without any of
/// `/\. "$`.
fn checkDatabase(name: []const u8, d: ?*Diagnostics) mongo.Error!void {
    if (name.len == 0 or name.len > 63) return invalid(d, "a database name is 1 to 63 bytes long; this one is {d}", .{name.len});
    if (std.mem.findAny(u8, name, "\x00/\\. \"$")) |at| {
        return invalid(d, "a database name holds none of / \\ . \" $, a space or NUL; '{s}' holds byte {d}", .{ name, name[at] });
    }
}

/// Checks the top level of `body` and returns the command's name, its
/// first key. In Debug it validates the whole body too.
fn checkBody(body: bson.RawDocument, op: OperationContext, extra: []const []const u8, d: ?*Diagnostics) mongo.Error![]const u8 {
    var it = body.iterator();
    const first = (it.next() catch return notBson(d)) orelse
        return invalid(d, "the command is empty: its first key is its name", .{});
    if (first.key.len == 0 or first.key[0] == '$') {
        return invalid(d, "the first key of a command is its name, which is not empty and does not start with '$'; got '{s}'", .{first.key});
    }
    var element = first;
    while (true) {
        for (driver_fields) |field| {
            if (std.mem.eql(u8, element.key, field)) return invalid(d, "the command holds '{s}', which only the driver writes", .{field});
        }
        for (extra) |field| {
            if (std.mem.eql(u8, element.key, field)) return invalid(d, "the body of a write holds '{s}', which the driver writes from the request", .{field});
        }
        if (op.ctx.deadline != null and std.mem.eql(u8, element.key, "maxTimeMS")) {
            return invalid(d, "the command holds maxTimeMS and the call has a deadline, from which the driver writes it: drop one of the two", .{});
        }
        element = (it.next() catch return notBson(d)) orelse break;
    }
    if (builtin.mode == .debug) body.validate() catch return notBson(d);
    return first.key;
}

fn invalid(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) mongo.Error {
    return fail(d, null, error.InvalidArgument, fmt, args);
}

fn notBson(d: ?*Diagnostics) mongo.Error {
    return invalid(d, "the command is not valid BSON", .{});
}
