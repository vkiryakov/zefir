//! The native driver. `init` checks the options and does no I/O;
//! `connect` opens the first connection under the caller's deadline, so a
//! server of the wrong kind or a user it refuses shows at start; `client()`
//! hands out the `mongo.Client` that the code above uses; `close` ends the
//! work and `deinit` frees everything.
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
//! Calls come from any task. Each takes a connection of the pool for its
//! exchange and gives it back: up to `maxPoolSize` connections, opened as
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
//! After `connect` the client must stay where it is, and every call comes
//! on the `io` of `init`: in safe builds, a call on a moved copy of the
//! client or on another `std.Io` panics.

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
const Pool = @import("engine/Pool.zig");
const command_ = @import("engine/command.zig");
const connect_ = @import("engine/connect.zig");
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
/// What the latest hello said, for `capabilities`, which takes no `io`.
server: Server = .{},
/// The round trips of hello on new connections, for `maxTimeMS`.
round_trips: time.RoundTrips = .{},
/// Where `connect` succeeded, 0 before, in safe builds: a call on a copy
/// of the client somewhere else panics. Atomic: any task may call while
/// another connects.
home: if (std.debug.runtime_safety) std.atomic.Value(usize) else void = if (std.debug.runtime_safety) .init(0) else {},

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
pub fn deinit(self: *Client) void {
    self.checkHome();
    self.close(self.io);
    self.pool.deinit();
    self.keys.deinit();
    self.metadata.deinit();
    self.options.deinit(self.gpa);
    self.* = undefined;
}

/// The handle of the contract, for `mongo.Database` and the code above.
pub fn client(self: *Client) mongo.Client {
    self.checkHome();
    return .init(self);
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

/// Ends the client's work, in the order of the contract: new calls, and
/// those waiting for a connection, get `error.Closed`; connections being
/// opened stop; the calls in flight get up to `close_timeout` to end, and
/// after it their exchanges are cut (`error.ConnectionLost`); then the
/// connections close. A second call returns once the first is done. The
/// task's cancelation waits until it returns.
pub fn close(self: *Client, io: Io) void {
    self.checkUse(io);
    self.pool.close(io, self.options.close_timeout);
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
        .open_cursors = 0,
    };
}

pub fn capabilities(self: *Client) mongo.Capabilities {
    self.checkHome();
    return .{
        .revision = 1,
        .name = handshake.driver_name,
        .commands = true,
        .server = self.server.load(),
    };
}

pub fn runCommand(self: *Client, io: Io, op: OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) mongo.Error!bson.OwnedDocument {
    self.checkUse(io);
    return command_.run(self.runner(), io, op, command, options);
}

pub fn openCursor(self: *Client, io: Io, op: OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) mongo.Error!mongo.Cursor {
    self.checkUse(io);
    _ = .{ op, command };
    return fail(options.diagnostics, null, error.Unsupported, "this version of zefir-mongo-async-driver runs commands only, without cursors", .{});
}

pub fn write(self: *Client, io: Io, op: OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) mongo.Error!mongo.WriteResult {
    self.checkUse(io);
    _ = .{ op, request };
    return fail(options.diagnostics, null, error.Unsupported, "this version of zefir-mongo-async-driver runs commands only, without batched writes", .{});
}

/// In safe builds: a call on a moved copy of the client, or on another
/// `std.Io` than the one of `init`, panics, since the pool and the waits
/// of the client belong to the original and its `io`.
fn checkUse(self: *const Client, io: Io) void {
    self.checkHome();
    if (std.debug.runtime_safety and io.vtable != self.io.vtable) {
        @panic("zefir-mongo-async-driver: a call on another std.Io than the client's: pass the io of Client.init");
    }
}

inline fn checkHome(self: *const Client) void {
    if (std.debug.runtime_safety) {
        const home = self.home.load(.monotonic);
        if (home != 0 and home != @intFromPtr(self)) @panic("zefir-mongo-async-driver: Client moved after connect(): keep it where connect() ran (see the guide)");
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
        .timeout = self.options.uri.timeout,
        .server_selection_timeout = self.options.uri.server_selection_timeout,
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
    self.server.store(conn.hello);
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
