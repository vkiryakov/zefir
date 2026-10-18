//! The native driver. `init` checks the options and does no I/O;
//! `connect` opens the first connection under the caller's deadline, so a
//! server of the wrong kind shows at start; `client()` hands out the
//! `mongo.Client` that the code above uses; `close` ends the work and
//! `deinit` frees everything.
//!
//! ```zig
//! var driver: mongo_async_driver.Client = try .init(gpa, io, .{ .uri = "mongodb://127.0.0.1:27017/app" });
//! defer driver.deinit();
//! var diagnostics: mongo.Diagnostics = .{};
//! driver.connect(io, ctx, &diagnostics) catch |err| {
//!     log.err("mongo: {t}: {s}", .{ err, diagnostics.message() });
//!     return err;
//! };
//! defer driver.close(io);
//! var ids: mongo.bson.ObjectId.Generator = .init(io);
//! const db: mongo.Database = .init(driver.client(), "app", &ids);
//! ```
//!
//! Calls come from any task, one at a time on the connection; a connection
//! that breaks is opened again by the next call. After `connect` the
//! client must stay where it is.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
const wire = mongo.wire;
const Diagnostics = mongo.Diagnostics;
const OperationContext = mongo.OperationContext;
const Options = @import("Options.zig");
const OwnedOptions = @import("OwnedOptions.zig");
const Stats = @import("Stats.zig");
const Connection = @import("engine/Connection.zig");
const connect_ = @import("engine/connect.zig");
const handshake = @import("engine/handshake.zig");
const time = @import("engine/time.zig");
const Client = @This();

gpa: Allocator,
/// The `io` of `init`: every call comes on it.
io: Io,
options: OwnedOptions,
/// The hello of every new connection.
hello: bson.OwnedDocument,
/// One call at a time on the connection, and on its opening.
exchange_mutex: Io.Mutex = .init,
/// Guards what follows, which `close` and `stats` read from other tasks.
state_mutex: Io.Mutex = .init,
state: State = .initialized,
conn: ?*Connection = null,
/// The opening in progress, for `close` to stop.
attempt: ?*connect_.Attempt = null,
in_use: bool = false,
waiting: usize = 0,
/// What the latest hello said, for `capabilities`, which takes no `io`.
server: Server = .{},

pub const State = enum { initialized, ready, closed };

pub const InitError = error{ InvalidArgument, Unsupported, OutOfMemory };

/// Checks `options` and copies what it keeps; no I/O.
pub fn init(gpa: Allocator, io: Io, options: Options) InitError!Client {
    const d = options.diagnostics;
    var owned: OwnedOptions = try .init(gpa, options);
    errdefer owned.deinit(gpa);
    if (owned.credentials() != null) {
        if (d) |x| x.set(null, null, "the connection string names a user, and this version of zefir-mongo-async-driver does not authenticate yet: connect to a mongod without --auth", .{});
        return error.Unsupported;
    }
    const metadata = try handshake.metadata(gpa, owned.uri.app_name, d);
    defer metadata.deinit();
    const hello = handshake.command(gpa, metadata.raw(), .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => error.InvalidArgument,
    };
    return .{ .gpa = gpa, .io = io, .options = owned, .hello = hello };
}

/// Closes the client, if `close` has not, and frees it.
pub fn deinit(self: *Client) void {
    self.close(self.io);
    self.hello.deinit();
    self.options.deinit(self.gpa);
    self.* = undefined;
}

/// The handle of the contract, for `mongo.Database` and the code above.
pub fn client(self: *Client) mongo.Client {
    return .init(self);
}

/// Opens the first connection, hello included, under the deadline of
/// `ctx`. Until it succeeds, calls are `error.Unavailable`; it may be
/// called again after a failure, and does nothing once the client is
/// connected. Why it failed goes to `diagnostics`.
pub fn connect(self: *Client, io: Io, ctx: core.Context, diagnostics: ?*Diagnostics) mongo.Error!void {
    const d = diagnostics;
    if (d) |x| x.* = .{};
    if (self.isClosed(io)) return fail(d, null, error.Closed, "the client is closed", .{});
    try self.lockExchange(io, d);
    defer self.unlockExchange(io);
    if (self.isClosed(io)) return fail(d, .checkout, error.Closed, "the client was closed while connect() waited", .{});
    if (self.conn != null) return;
    try checkBeforeSend(io, .of(ctx), ctx.deadline, d);
    _ = try self.open(io, ctx.deadline, d);
    self.state_mutex.lockUncancelable(io);
    defer self.state_mutex.unlock(io);
    if (self.state == .initialized) self.state = .ready;
}

/// Ends the client's work: new calls, and those that wait for the
/// connection, get `error.Closed`; the call in flight ends with
/// `error.ConnectionLost`, and an opening in progress stops. A second call
/// does nothing. The task's cancelation waits until it returns.
pub fn close(self: *Client, io: Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    self.state_mutex.lockUncancelable(io);
    if (self.state == .closed) {
        self.state_mutex.unlock(io);
        return;
    }
    self.state = .closed;
    if (self.attempt) |a| a.stop(io);
    if (self.conn) |c| c.shutdown(io);
    self.state_mutex.unlock(io);
    // After the call in flight.
    self.exchange_mutex.lockUncancelable(io);
    defer self.exchange_mutex.unlock(io);
    self.state_mutex.lockUncancelable(io);
    const conn = self.conn;
    self.conn = null;
    self.state_mutex.unlock(io);
    if (conn) |c| c.destroy();
}

/// A snapshot of the connections and the calls waiting for them.
pub fn stats(self: *Client) Stats {
    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    const connected = @intFromBool(self.conn != null);
    const in_use = @intFromBool(self.conn != null and self.in_use);
    return .{
        .connections = connected,
        .idle = connected - in_use,
        .in_use = in_use,
        .opening = @intFromBool(self.attempt != null),
        .waiting = self.waiting,
        .generation = 0,
        .clears = 0,
        .open_cursors = 0,
    };
}

pub fn capabilities(self: *Client) mongo.Capabilities {
    return .{
        .revision = 1,
        .name = handshake.driver_name,
        .commands = true,
        .server = self.server.load(),
    };
}

pub fn runCommand(self: *Client, io: Io, op: OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!bson.OwnedDocument {
    const d = options.diagnostics;
    const deadline = self.deadlineOf(io, op);
    const conn = try self.acquire(io, op, deadline, d);
    defer self.unlockExchange(io);
    const reply = conn.exchange(.{ .database = command.database, .body = command.body }, options.allocator, deadline, d) catch |err| {
        if (err == error.ConnectionLost and self.isClosed(io)) return fail(d, .wait, error.ConnectionLost, "close() of the client cut the exchange", .{});
        return err;
    };
    wire.checkReply(reply.raw(), options.allocator, d, options.failure_reply) catch |err| {
        reply.deinit();
        return err;
    };
    return reply;
}

pub fn openCursor(self: *Client, io: Io, op: OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor {
    _ = .{ self, io, op, command };
    return fail(options.diagnostics, null, error.Unsupported, "this version of zefir-mongo-async-driver runs commands only, without cursors", .{});
}

pub fn write(self: *Client, io: Io, op: OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
    _ = .{ self, io, op, request };
    return fail(options.diagnostics, null, error.Unsupported, "this version of zefir-mongo-async-driver runs commands only, without batched writes", .{});
}

/// The deadline of a call: its context's, else `timeoutMS` from now.
fn deadlineOf(self: *const Client, io: Io, op: OperationContext) ?core.Deadline {
    if (op.ctx.deadline) |deadline| return deadline;
    const timeout = self.options.uri.timeout orelse return null;
    return .after(time.now(io), timeout);
}

fn isClosed(self: *Client, io: Io) bool {
    self.state_mutex.lockUncancelable(io);
    defer self.state_mutex.unlock(io);
    return self.state == .closed;
}

/// Takes the connection for one call, opening it when there is none.
/// `unlockExchange` gives it back.
fn acquire(self: *Client, io: Io, op: OperationContext, deadline: ?core.Deadline, d: ?*Diagnostics) mongo.Error!*Connection {
    self.state_mutex.lockUncancelable(io);
    const state = self.state;
    self.state_mutex.unlock(io);
    switch (state) {
        .initialized => return fail(d, .checkout, error.Unavailable, "connect() has not succeeded", .{}),
        .closed => return fail(d, .checkout, error.Closed, "the client is closed", .{}),
        .ready => {},
    }
    try self.lockExchange(io, d);
    errdefer self.unlockExchange(io);
    if (self.isClosed(io)) return fail(d, .checkout, error.Closed, "the client was closed while the call waited for the connection", .{});
    try checkBeforeSend(io, op, deadline, d);
    return self.conn orelse try self.open(io, deadline, d);
}

fn lockExchange(self: *Client, io: Io, d: ?*Diagnostics) mongo.Error!void {
    self.state_mutex.lockUncancelable(io);
    self.waiting += 1;
    self.state_mutex.unlock(io);
    const locked = self.exchange_mutex.lock(io);
    self.state_mutex.lockUncancelable(io);
    self.waiting -= 1;
    if (locked) |_| self.in_use = true else |_| {}
    self.state_mutex.unlock(io);
    locked catch {
        io.recancel();
        return fail(d, .checkout, error.Cancelled, "the task was canceled while it waited for the connection", .{});
    };
}

/// Gives the connection back, and closes it when its exchange left it
/// unusable.
fn unlockExchange(self: *Client, io: Io) void {
    self.state_mutex.lockUncancelable(io);
    self.in_use = false;
    const broken = if (self.conn) |c| !c.usable else false;
    const conn = self.conn;
    if (broken) self.conn = null;
    self.state_mutex.unlock(io);
    if (broken) conn.?.destroy();
    self.exchange_mutex.unlock(io);
}

/// The context before a command goes out: less than 1 ms left of the
/// deadline, a canceled token or a canceled task.
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

/// Opens a connection for the holder of `exchange_mutex`, within
/// `connectTimeoutMS` or the deadline, whichever comes first.
fn open(self: *Client, io: Io, deadline: ?core.Deadline, d: ?*Diagnostics) mongo.Error!*Connection {
    const uri = &self.options.uri;
    const address: Connection.Address = .{ .host = uri.host, .port = uri.port };
    var budget: ?core.Deadline = if (uri.connect_timeout) |t| .after(time.now(io), t) else null;
    var by_deadline = false;
    if (deadline) |dl| if (budget == null or dl.expires.nanoseconds <= budget.?.expires.nanoseconds) {
        budget = dl;
        by_deadline = true;
    };
    var attempt: connect_.Attempt = .{};
    self.state_mutex.lockUncancelable(io);
    self.attempt = &attempt;
    self.state_mutex.unlock(io);
    const opened = connect_.open(io, self.gpa, address, self.hello.raw(), budget, &attempt, d);
    self.state_mutex.lockUncancelable(io);
    self.attempt = null;
    const closed = self.state == .closed;
    if (!closed) if (opened) |conn| {
        self.conn = conn;
    } else |_| {};
    self.state_mutex.unlock(io);
    const conn = opened catch |err| {
        if (closed) return fail(d, .connect, error.Closed, "the client was closed while it connected", .{});
        return switch (err) {
            error.Unavailable, error.Unsupported, error.OutOfMemory => |e| e,
            error.Timeout => if (by_deadline)
                fail(d, .connect, error.DeadlineExceeded, "the deadline passed while the client connected to {f}", .{address})
            else
                fail(d, .connect, error.Unavailable, "{f} did not answer within connectTimeoutMS ({d} ms)", .{ address, uri.connect_timeout.?.toMilliseconds() }),
            error.Canceled => {
                io.recancel();
                return fail(d, .connect, error.Cancelled, "the task was canceled while the client connected to {f}", .{address});
            },
            error.ConcurrencyUnavailable => {
                if (d) |x| x.set(.connect, err, "no task to connect to {f} in: the std.Io has no room for one", .{address});
                return error.Unavailable;
            },
        };
    };
    if (closed) {
        conn.destroy();
        return fail(d, .connect, error.Closed, "the client was closed while it connected", .{});
    }
    self.server.store(conn.hello);
    return conn;
}

fn fail(d: ?*Diagnostics, phase: ?Diagnostics.Phase, err: mongo.Error, comptime fmt: []const u8, args: anytype) mongo.Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}

/// What the latest hello said, in atomics: `capabilities` reads it from
/// any thread without `io`.
const Server = struct {
    known: std.atomic.Value(bool) = .init(false),
    max_wire_version: std.atomic.Value(i32) = .init(0),
    max_bson_object_size: std.atomic.Value(u32) = .init(0),
    max_message_size_bytes: std.atomic.Value(u32) = .init(0),
    max_write_batch_size: std.atomic.Value(u32) = .init(0),

    fn store(s: *Server, hello: wire.Hello) void {
        s.max_wire_version.store(hello.max_wire_version, .monotonic);
        s.max_bson_object_size.store(hello.max_bson_object_size, .monotonic);
        s.max_message_size_bytes.store(hello.max_message_size_bytes, .monotonic);
        s.max_write_batch_size.store(hello.max_write_batch_size, .monotonic);
        s.known.store(true, .release);
    }

    fn load(s: *const Server) ?mongo.ServerInfo {
        if (!s.known.load(.acquire)) return null;
        return .{
            .kind = .standalone,
            .max_wire_version = s.max_wire_version.load(.monotonic),
            .max_bson_object_size = s.max_bson_object_size.load(.monotonic),
            .max_message_size_bytes = s.max_message_size_bytes.load(.monotonic),
            .max_write_batch_size = s.max_write_batch_size.load(.monotonic),
        };
    }
};
