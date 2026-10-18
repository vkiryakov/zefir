//! minidriver: a MongoDB driver of zefir-mongo in a package of its own, a
//! sample for authors of drivers. It uses only the public API of
//! zefir-mongo, `mongo.Client` with `mongo.wire` underneath, and passes the
//! conformance suite that every driver of zefir passes,
//! `mongo.testing.conformance`, against a scripted server and a live mongod.
//!
//! It is small on purpose:
//!
//! - one standalone mongod of MongoDB 7.0 or later, at `mongodb://host:port`,
//!   without TLS and without credentials; anything else in the URI is
//!   `error.Unsupported`;
//! - one connection, which one call at a time uses, under an `std.Io.Mutex`;
//!   after it breaks, the next call opens another;
//! - hello as the first command of a connection: legacy `isMaster` in an
//!   OP_MSG, with `helloOk: true`; a server that is not a standalone mongod
//!   of wire version 21 or later is `error.Unsupported`;
//! - commands, cursors and batched writes on `mongo.wire`, with the deadline
//!   of a call on every read and write of the socket, and `maxTimeMS` the
//!   time left of it;
//! - `close` cuts the call in flight and sends `killCursors` for the cursors
//!   still open.
//!
//! ```zig
//! var driver: minidriver.Client = try .init(gpa, io, .{ .uri = "mongodb://127.0.0.1:27017" });
//! defer driver.deinit();
//! try driver.connect(io, .root);
//! var ids: mongo.bson.ObjectId.Generator = .init(io);
//! const db: mongo.Database = .init(driver.client(), "app", &ids);
//! ```
//!
//! What a driver for production adds — a pool, SCRAM, the metadata of hello,
//! `maxTimeMS` less the shortest round trip, a time limit for TCP connect,
//! the whole URI — is in README.md.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const core = @import("zefir-core");
const mongo = @import("zefir-mongo");
const bson = mongo.bson;
const wire = mongo.wire;
const opmsg = wire.opmsg;
const Error = mongo.Error;
const Diagnostics = mongo.Diagnostics;
const OperationContext = mongo.OperationContext;

pub const Options = struct {
    /// "mongodb://host:port", the port 27017 when it is left out; borrowed
    /// during `init` only.
    uri: []const u8,
    /// How long hello on a new connection may take when the deadline of the
    /// call leaves more.
    connect_timeout: Io.Duration = .fromSeconds(10),
    /// The budget of the `killCursors` that `close` and `deinit` of a cursor
    /// send, and `close` of the client.
    cursor_close_timeout: Io.Duration = .fromSeconds(1),
    /// Why `init` refused the URI.
    diagnostics: ?*Diagnostics = null,
};

/// The wire version of MongoDB 7.0, the oldest server minidriver takes.
pub const min_wire_version = 21;

/// The driver. `init` does no I/O; the first call, or `connect`, opens the
/// connection. Calls come from any task, one at a time on the connection.
pub const Client = struct {
    gpa: Allocator,
    /// The `io` of `init`: every call comes on it.
    io: Io,
    /// The host of the URI, in `gpa`, and its port.
    host: []u8,
    port: u16,
    connect_timeout: Io.Duration,
    cursor_close_timeout: Io.Duration,
    /// One exchange at a time: a command, a getMore, a killCursors, or all
    /// the batches of a write.
    exchange_mutex: Io.Mutex = .init,
    /// Guards `closed`, the list of cursors and their state, and the changes
    /// of `conn`, which only the holder of `exchange_mutex` makes.
    state_mutex: Io.Mutex = .init,
    conn: ?*Connection = null,
    closed: bool = false,
    cursors: std.DoublyLinkedList = .{},
    /// What the latest hello said, for `capabilities`, which takes no `io`.
    server: Server = .{},

    pub fn init(gpa: Allocator, io: Io, options: Options) Error!Client {
        const address = try parseUri(options.uri, options.diagnostics);
        return .{
            .gpa = gpa,
            .io = io,
            .host = try gpa.dupe(u8, address.host),
            .port = address.port,
            .connect_timeout = options.connect_timeout,
            .cursor_close_timeout = options.cursor_close_timeout,
        };
    }

    /// Closes the client, if `close` has not, and frees it. `deinit` the
    /// cursors before.
    pub fn deinit(self: *Client) void {
        self.close(self.io);
        self.gpa.free(self.host);
        self.* = undefined;
    }

    pub fn client(self: *Client) mongo.Client {
        return .init(self);
    }

    /// Opens the connection now rather than at the first call, under the
    /// deadline of `ctx`. Calls open it themselves when there is none.
    pub fn connect(self: *Client, io: Io, ctx: core.Context) Error!void {
        self.checkIo(io);
        try self.acquire(io, null, false);
        defer self.exchange_mutex.unlock(io);
        try checkContext(io, .of(ctx), null);
        _ = try self.connection(io, ctx.deadline, null, false);
    }

    /// New calls, and those that wait for the connection, get `Closed`; the
    /// call in flight ends with `ConnectionLost`; the cursors still open get
    /// their `killCursors`. A second call does nothing. The task's
    /// cancelation waits until it returns.
    pub fn close(self: *Client, io: Io) void {
        self.checkIo(io);
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var kills: std.ArrayList(Kill) = .empty;

        self.state_mutex.lockUncancelable(io);
        if (self.closed) {
            self.state_mutex.unlock(io);
            return;
        }
        self.closed = true;
        // The exchange in flight sees the end of its stream.
        if (self.conn) |conn| conn.stream.shutdown(io, .both) catch {};
        while (self.cursors.popFirst()) |node| {
            const cursor: *ServerCursor = @fieldParentPtr("node", node);
            cursor.listed = false;
            cursor.ended = true;
            if (cursor.id != 0) {
                if (a.dupe(u8, cursor.ns)) |ns| kills.append(a, .{ .ns = ns, .id = cursor.id }) catch {} else |_| {}
            }
            cursor.id = 0;
        }
        self.state_mutex.unlock(io);

        // After the call in flight and those that waited: a connection of
        // its own for the killCursors.
        self.exchange_mutex.lockUncancelable(io);
        defer self.exchange_mutex.unlock(io);
        self.dropConnection(io);
        for (kills.items) |open| self.killLocked(io, open.ns, open.id);
        self.dropConnection(io);
    }

    pub fn runCommand(self: *Client, io: Io, op: OperationContext, command: *const mongo.Command, options: mongo.CommandOptions) Error!bson.OwnedDocument {
        self.checkIo(io);
        const reply = try self.exchange(io, op, .{ .database = command.database, .body = command.body }, options.allocator, options.diagnostics);
        wire.checkReply(reply.raw(), options.allocator, options.diagnostics, options.failure_reply) catch |err| {
            reply.deinit();
            return err;
        };
        return reply;
    }

    pub fn openCursor(self: *Client, io: Io, op: OperationContext, command: *const mongo.Command, options: mongo.CursorOptions) Error!mongo.Cursor {
        self.checkIo(io);
        const d = options.diagnostics;
        // The reply holds the first batch, so the cursor keeps it: the
        // driver's memory, as is failure_reply of a cursor.
        const reply = try self.exchange(io, op, .{ .database = command.database, .body = command.body }, self.gpa, d);
        errdefer reply.deinit();
        try wire.checkReply(reply.raw(), self.gpa, d, options.failure_reply);
        const first = try parseCursor(reply.raw(), .first, d);
        if (std.mem.findScalar(u8, first.ns, '.') == null) return violation(d, "the namespace '{s}' of the cursor has no collection", .{first.ns});
        const cursor = try self.gpa.create(ServerCursor);
        errdefer self.gpa.destroy(cursor);
        const ns = try self.gpa.dupe(u8, first.ns);
        errdefer self.gpa.free(ns);
        // The caller's comment, kept for the getMores as {comment: value}.
        const comment: ?bson.OwnedDocument = if (options.comment) |value| try keepComment(self.gpa, value, d) else null;
        cursor.* = .{
            .client = self,
            .id = first.id,
            .ns = ns,
            .reply = reply,
            .batch = first.batch.iterator(),
            .batch_size = options.batch_size,
            .comment = comment,
            .diagnostics = d,
            .failure_reply = options.failure_reply,
        };
        self.state_mutex.lockUncancelable(io);
        if (self.closed) {
            // Closed meanwhile: the cursor gives what it holds no more.
            cursor.listed = false;
            cursor.ended = true;
        } else self.cursors.append(&cursor.node);
        self.state_mutex.unlock(io);
        return .init(cursor);
    }

    pub fn write(self: *Client, io: Io, op: OperationContext, request: *const mongo.WriteRequest, options: mongo.WriteOptions) Error!mongo.WriteResult {
        self.checkIo(io);
        const d = options.diagnostics;
        try self.acquire(io, d, false);
        defer self.exchange_mutex.unlock(io);
        try checkContext(io, op, d);
        // The batches fit the limits of the connection they go through.
        const conn = try self.connection(io, op.ctx.deadline, d, false);
        const identifier = request.kind.items();
        // Every field the messages carry takes room, maxTimeMS among them.
        const message: opmsg.Request = .{
            .request_id = 0,
            .body = request.body,
            .database = request.database,
            .ordered = request.ordered,
            .max_time_ms = if (op.ctx.deadline != null) 0 else null,
            .sequence = .{ .identifier = identifier, .documents = request.items },
        };
        var batches = try wire.batch.Batches.init(message, .of(conn.hello), d);
        var merge: wire.batch.Merge = .{};
        defer merge.deinit(options.allocator);
        while (batches.next()) |b| {
            const reply = self.exchangeLocked(io, op, .{
                .database = request.database,
                .body = request.body,
                .ordered = request.ordered,
                .sequence = .{ .identifier = identifier, .documents = b.items },
            }, self.gpa, d) catch |err| return merge.fail(options.allocator, err, b, options);
            defer reply.deinit();
            wire.checkReply(reply.raw(), options.allocator, d, options.failure_reply) catch |err|
                return merge.fail(options.allocator, err, b, options);
            const next = merge.add(options.allocator, b, reply.raw(), request.ordered, d) catch |err|
                return merge.fail(options.allocator, err, b, options);
            switch (next) {
                .more => {},
                .done => break,
                .timeout => return merge.fail(options.allocator, error.Timeout, b, options),
            }
        }
        return merge.result(options.allocator);
    }

    pub fn capabilities(self: *Client) mongo.Capabilities {
        return .{
            .revision = 1,
            .name = "minidriver",
            .commands = true,
            .cursors = true,
            .aggregation = true,
            .batched_writes = true,
            .server = self.server.load(),
        };
    }

    /// Rule 2 of `mongo.Client`: every call comes on the `io` of `init`.
    fn checkIo(self: *const Client, io: Io) void {
        if (std.debug.runtime_safety and io.vtable != self.io.vtable)
            @panic("minidriver: a call with another std.Io than the client's; pass the io that init got");
    }

    fn isClosed(self: *Client, io: Io) bool {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        return self.closed;
    }

    /// Takes `exchange_mutex`: `Closed` after `close`, unless the call is
    /// one of the killCursors of `close`.
    fn acquire(self: *Client, io: Io, d: ?*Diagnostics, after_close: bool) Error!void {
        if (!after_close and self.isClosed(io)) return fail(d, null, error.Closed, "the client is closed", .{});
        self.exchange_mutex.lock(io) catch {
            io.recancel();
            return fail(d, .checkout, error.Cancelled, "the task was canceled while the call waited for the connection", .{});
        };
        if (!after_close and self.isClosed(io)) {
            self.exchange_mutex.unlock(io);
            return fail(d, .checkout, error.Closed, "the client was closed while the call waited for the connection", .{});
        }
    }

    /// One command and its reply, from `allocator`.
    fn exchange(self: *Client, io: Io, op: OperationContext, send: Send, allocator: Allocator, d: ?*Diagnostics) Error!bson.OwnedDocument {
        try self.acquire(io, d, send.after_close);
        defer self.exchange_mutex.unlock(io);
        return self.exchangeLocked(io, op, send, allocator, d);
    }

    /// `exchange` for the holder of `exchange_mutex`.
    fn exchangeLocked(self: *Client, io: Io, op: OperationContext, send: Send, allocator: Allocator, d: ?*Diagnostics) Error!bson.OwnedDocument {
        const deadline = op.ctx.deadline;
        try checkContext(io, op, d);
        io.checkCancel() catch {
            io.recancel();
            return fail(d, .send, error.Cancelled, "the task was canceled before the command went out", .{});
        };
        const conn = try self.connection(io, deadline, d, send.after_close);
        var max_time_ms: ?i64 = null;
        if (deadline) |dl| {
            const left = dl.remaining(Io.Clock.awake.now(io));
            if (left.nanoseconds < std.time.ns_per_ms) return fail(d, .send, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the command went out", .{});
            if (send.max_time) max_time_ms = std.math.cast(i64, @divFloor(left.nanoseconds, std.time.ns_per_ms)) orelse std.math.maxInt(i64);
        }
        const request: opmsg.Request = .{
            .request_id = conn.nextId(),
            .body = send.body,
            .database = send.database,
            .ordered = send.ordered,
            .max_time_ms = max_time_ms,
            .sequence = send.sequence,
        };
        const limit = conn.hello.max_message_size_bytes;
        if (request.length() > limit) return fail(d, .send, error.InvalidArgument, "the command is {d} bytes, and the server takes {d} at most", .{ request.length(), limit });
        conn.begin(deadline);
        opmsg.writeRequest(&conn.writer, request) catch |err| switch (err) {
            error.InvalidArgument => return fail(d, .send, error.InvalidArgument, "the command cannot be written as OP_MSG", .{}),
            error.WriteFailed => return self.broken(io, conn, d, .send),
        };
        conn.writer.flush() catch return self.broken(io, conn, d, .send);
        return opmsg.readReply(&conn.reader, allocator, .{ .request_id = request.request_id, .max_message_size = limit }, d) catch |err| switch (err) {
            // A connection that broke the protocol is used no more.
            error.ProtocolViolation, error.OutOfMemory => |e| {
                self.dropConnection(io);
                return e;
            },
            error.ReadFailed, error.EndOfStream => self.broken(io, conn, d, .wait),
        };
    }

    /// The error of an exchange whose stream failed after the command
    /// started to go out; the connection goes.
    fn broken(self: *Client, io: Io, conn: *Connection, d: ?*Diagnostics, phase: Diagnostics.Phase) Error {
        const cause = conn.err;
        self.dropConnection(io);
        const err = cause orelse {
            if (self.isClosed(io)) return fail(d, phase, error.ConnectionLost, "close() of the client cut the exchange", .{});
            return fail(d, phase, error.ConnectionLost, "the server closed the connection", .{});
        };
        switch (err) {
            error.Timeout => return fail(d, phase, error.Timeout, "the deadline passed before the reply came", .{}),
            error.Canceled => {
                io.recancel();
                return fail(d, phase, error.Interrupted, "the task was canceled while the command was out", .{});
            },
            else => {
                if (d) |x| x.set(phase, err, "the connection broke: {t}", .{err});
                return error.ConnectionLost;
            },
        }
    }

    /// The connection, opened when there is none; the caller holds
    /// `exchange_mutex`.
    fn connection(self: *Client, io: Io, deadline: ?core.Deadline, d: ?*Diagnostics, after_close: bool) Error!*Connection {
        if (self.conn) |conn| return conn;
        const conn = try self.dial(io, deadline, d);
        self.state_mutex.lockUncancelable(io);
        const refused = self.closed and !after_close;
        if (!refused) self.conn = conn;
        self.state_mutex.unlock(io);
        if (refused) {
            conn.destroy(io);
            return fail(d, .connect, error.Closed, "the client was closed while the call connected", .{});
        }
        self.server.store(conn.hello);
        return conn;
    }

    /// Closes the connection, if there is one; the caller holds
    /// `exchange_mutex`.
    fn dropConnection(self: *Client, io: Io) void {
        self.state_mutex.lockUncancelable(io);
        const conn = self.conn;
        self.conn = null;
        self.state_mutex.unlock(io);
        if (conn) |c| c.destroy(io);
    }

    /// A new connection after hello. Hello waits no longer than
    /// `connect_timeout` or the deadline, whichever comes first; TCP connect
    /// waits as long as the system lets it, since `std.Io` has no portable
    /// timeout for it (README.md).
    fn dial(self: *Client, io: Io, deadline: ?core.Deadline, d: ?*Diagnostics) Error!*Connection {
        var budget: core.Deadline = .after(Io.Clock.awake.now(io), self.connect_timeout);
        var by_deadline = false;
        if (deadline) |dl| if (dl.expires.nanoseconds <= budget.expires.nanoseconds) {
            budget = dl;
            by_deadline = true;
        };
        const stream = self.openStream(io) catch |err| return self.notConnected(io, err, by_deadline, d, .connect);
        const conn = Connection.create(self.gpa, io, stream) catch {
            stream.close(io);
            return error.OutOfMemory;
        };
        conn.hello = self.handshake(io, conn, budget, by_deadline, d) catch |err| {
            conn.destroy(io);
            return err;
        };
        return conn;
    }

    fn openStream(self: *Client, io: Io) !net.Stream {
        if (net.IpAddress.parse(self.host, self.port)) |address| return address.connect(io, .{ .mode = .stream }) else |_| {}
        const name = try net.HostName.init(self.host);
        return name.connect(io, self.port, .{ .mode = .stream });
    }

    /// The error of a connection that did not open: nothing was sent.
    fn notConnected(self: *Client, io: Io, err: anyerror, by_deadline: bool, d: ?*Diagnostics, phase: Diagnostics.Phase) Error {
        switch (err) {
            error.Canceled => {
                io.recancel();
                return fail(d, phase, error.Cancelled, "the task was canceled while the client connected to {s}:{d}", .{ self.host, self.port });
            },
            error.Timeout => if (by_deadline) {
                return fail(d, phase, error.DeadlineExceeded, "the deadline passed while the client connected to {s}:{d}", .{ self.host, self.port });
            } else {
                return fail(d, phase, error.Unavailable, "{s}:{d} did not answer hello within connect_timeout", .{ self.host, self.port });
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (d) |x| x.set(phase, err, "cannot connect to {s}:{d}: {t}", .{ self.host, self.port, err });
                return error.Unavailable;
            },
        }
    }

    /// Hello, the first command of a connection: what the server is, and the
    /// limits that writes are split by.
    fn handshake(self: *Client, io: Io, conn: *Connection, budget: core.Deadline, by_deadline: bool, d: ?*Diagnostics) Error!wire.Hello {
        conn.begin(budget);
        const id = conn.nextId();
        opmsg.writeRequest(&conn.writer, .{ .request_id = id, .body = hello_command, .database = "admin" }) catch
            return self.handshakeBroken(io, conn, by_deadline, d);
        conn.writer.flush() catch return self.handshakeBroken(io, conn, by_deadline, d);
        const reply = opmsg.readReply(&conn.reader, self.gpa, .{ .request_id = id }, d) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The diagnostics say how the reply broke OP_MSG.
            error.ProtocolViolation => return error.Unavailable,
            error.ReadFailed, error.EndOfStream => return self.handshakeBroken(io, conn, by_deadline, d),
        };
        defer reply.deinit();
        wire.checkReply(reply.raw(), self.gpa, d, null) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };
        var hello = wire.Hello.parse(reply.raw(), d) catch return error.Unavailable;
        if (hello.server_type != .standalone) {
            return fail(d, .handshake, error.Unsupported, "the server at {s}:{d} is a {s}{s}{s}; minidriver works with a standalone mongod only", .{
                self.host, self.port, describe(hello.server_type), if (hello.set_name != null) " of the replica set " else "", hello.set_name orelse "",
            });
        }
        if (hello.max_wire_version < min_wire_version) {
            return fail(d, .handshake, error.Unsupported, "the server at {s}:{d} speaks wire version {d}; minidriver needs MongoDB 7.0 or later, wire version {d}", .{
                self.host, self.port, hello.max_wire_version, min_wire_version,
            });
        }
        // A slice into the reply, which goes.
        hello.set_name = null;
        return hello;
    }

    /// The error of a hello whose stream failed: nothing was sent.
    fn handshakeBroken(self: *Client, io: Io, conn: *const Connection, by_deadline: bool, d: ?*Diagnostics) Error {
        const err = conn.err orelse return fail(d, .handshake, error.Unavailable, "the server at {s}:{d} closed the connection during hello; a server that wants TLS does so, and minidriver does not speak TLS", .{ self.host, self.port });
        return self.notConnected(io, err, by_deadline, d, .handshake);
    }

    /// Sends killCursors for cursor `id` of `ns` with a budget of its own,
    /// and ignores the reply; the task's cancelation waits until it is done.
    fn kill(self: *Client, io: Io, ns: []const u8, id: i64) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        self.acquire(io, null, false) catch return;
        defer self.exchange_mutex.unlock(io);
        self.killLocked(io, ns, id);
    }

    /// `kill` for the holder of `exchange_mutex`.
    fn killLocked(self: *Client, io: Io, ns: []const u8, id: i64) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const database, const collection = split(ns);
        var b: bson.Builder = .init(arena.allocator());
        b.putString("killCursors", collection) catch return;
        b.beginArray("cursors") catch return;
        b.putInt64("", id) catch return;
        b.end() catch return;
        const body = b.finish() catch return;
        const budget: OperationContext = .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), self.cursor_close_timeout)));
        _ = self.exchangeLocked(io, budget, .{ .database = database, .body = body.raw(), .max_time = false, .after_close = true }, arena.allocator(), null) catch {};
    }
};

const hello_command = bson.literal(.{ .isMaster = 1, .helloOk = true });

const Kill = struct { ns: []const u8, id: i64 };

/// One command as it goes out.
const Send = struct {
    database: []const u8,
    body: bson.RawDocument,
    ordered: ?bool = null,
    sequence: ?opmsg.Sequence = null,
    /// `maxTimeMS` under a deadline; getMore and killCursors go without.
    max_time: bool = true,
    /// One of the killCursors of `close`, which go out after it.
    after_close: bool = false,
};

/// What the latest hello said, in atomics: `capabilities` reads it from any
/// thread without `io`.
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

/// One TCP connection to the server, in the heap: its reader and writer
/// point into it. Every read and write of its socket waits no longer than
/// the deadline of the exchange in progress, through `io.operateTimeout`.
const Connection = struct {
    gpa: Allocator,
    io: Io,
    stream: net.Stream,
    /// The deadline of the exchange in progress; null for none.
    deadline: ?core.Deadline = null,
    /// Why the reader or the writer failed: `error.Timeout`,
    /// `error.Canceled`, or an error of the socket.
    err: ?anyerror = null,
    reader: Io.Reader,
    writer: Io.Writer,
    hello: wire.Hello = .{},
    next_id: i32 = 1,
    read_buffer: [buffer_len]u8,
    write_buffer: [buffer_len]u8,

    const buffer_len = 64 * 1024;

    fn create(gpa: Allocator, io: Io, stream: net.Stream) Allocator.Error!*Connection {
        const conn = try gpa.create(Connection);
        conn.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
            .read_buffer = undefined,
            .write_buffer = undefined,
        };
        conn.reader = .{ .vtable = &.{ .stream = streamImpl, .readVec = readVec }, .buffer = &conn.read_buffer, .seek = 0, .end = 0 };
        conn.writer = .{ .vtable = &.{ .drain = drain }, .buffer = &conn.write_buffer };
        return conn;
    }

    fn destroy(conn: *Connection, io: Io) void {
        conn.stream.close(io);
        conn.gpa.destroy(conn);
    }

    /// Starts an exchange under `deadline`.
    fn begin(conn: *Connection, deadline: ?core.Deadline) void {
        conn.deadline = deadline;
        conn.err = null;
    }

    /// The requestID of the next request; it may wrap.
    fn nextId(conn: *Connection) i32 {
        defer conn.next_id +%= 1;
        return conn.next_id;
    }

    fn timeout(conn: *const Connection) Io.Timeout {
        return if (conn.deadline) |deadline| deadline.toTimeout() else .none;
    }

    /// Whether the deadline has come: a timer may fire a little early, and
    /// the operation is tried again then.
    fn expired(conn: *const Connection) bool {
        const deadline = conn.deadline orelse return true;
        return deadline.isExpired(Io.Clock.awake.now(conn.io));
    }

    fn streamImpl(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(r, &data);
        w.advance(n);
        return n;
    }

    fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const conn: *Connection = @alignCast(@fieldParentPtr("reader", r));
        var iovecs: [8][]u8 = undefined;
        const dest_n, const data_size = try r.writableVector(&iovecs, data);
        const dest = iovecs[0..dest_n];
        while (true) {
            const result = conn.io.operateTimeout(.{ .net_read = .{ .socket_handle = conn.stream.socket.handle, .data = dest } }, conn.timeout()) catch |err| {
                if (err == error.Timeout and !conn.expired()) continue;
                conn.err = err;
                return error.ReadFailed;
            };
            const read = result.net_read catch |err| {
                conn.err = err;
                return error.ReadFailed;
            };
            if (read.data_len == 0) return error.EndOfStream;
            if (read.data_len > data_size) {
                r.end += read.data_len - data_size;
                return data_size;
            }
            return read.data_len;
        }
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const conn: *Connection = @alignCast(@fieldParentPtr("writer", w));
        while (true) {
            const result = conn.io.operateTimeout(.{ .net_write = .{
                .socket_handle = conn.stream.socket.handle,
                .header = w.buffered(),
                .data = data,
                .splat = splat,
            } }, conn.timeout()) catch |err| {
                if (err == error.Timeout and !conn.expired()) continue;
                conn.err = err;
                return error.WriteFailed;
            };
            const n = result.net_write catch |err| {
                conn.err = err;
                return error.WriteFailed;
            };
            return w.consume(n);
        }
    }
};

/// A cursor on the server, in the heap.
const ServerCursor = struct {
    client: *Client,
    node: std.DoublyLinkedList.Node = .{},
    // Guarded by `client.state_mutex`, which `close` of the client takes.
    /// The id on the server: 0 when it is exhausted, killed or unknown.
    id: i64,
    /// The namespace, "database.collection", in the client's allocator.
    ns: []u8,
    /// No more documents: closed, or ended by an error of a getMore.
    ended: bool = false,
    /// In the client's list of open cursors.
    listed: bool = true,
    // The cursor's own: one task at a time uses it.
    /// The reply that holds the current batch.
    reply: bson.OwnedDocument,
    /// The documents of the current batch that `next` has not given yet.
    batch: bson.RawDocument.Iterator,
    batch_size: ?u32,
    /// `{comment: value}`, with the comment of the options.
    comment: ?bson.OwnedDocument,
    diagnostics: ?*Diagnostics,
    failure_reply: ?*?bson.OwnedDocument,
    closed: bool = false,

    pub fn next(c: *ServerCursor, io: Io, op: OperationContext) Error!?bson.RawDocument {
        c.client.checkIo(io);
        while (true) {
            const id = c.state(io) orelse return fail(c.diagnostics, null, error.Closed, "the cursor is closed", .{});
            const element = c.batch.next() catch return c.broken(io, "a batch of the cursor is not valid BSON");
            if (element) |e| {
                if (e.value != .document) return c.broken(io, "a batch of the cursor holds something other than documents");
                return e.value.document;
            }
            if (id == 0) return null;
            try c.getMore(io, op, id);
        }
    }

    pub fn close(c: *ServerCursor, io: Io) void {
        c.client.checkIo(io);
        if (c.closed) return;
        c.closed = true;
        const client = c.client;
        client.state_mutex.lockUncancelable(io);
        if (c.listed) client.cursors.remove(&c.node);
        c.listed = false;
        c.ended = true;
        const id = c.id;
        c.id = 0;
        client.state_mutex.unlock(io);
        if (id != 0) client.kill(io, c.ns, id);
    }

    pub fn deinit(c: *ServerCursor, io: Io) void {
        c.close(io);
        const gpa = c.client.gpa;
        c.reply.deinit();
        gpa.free(c.ns);
        if (c.comment) |comment| comment.deinit();
        gpa.destroy(c);
    }

    /// The id, or null when the cursor has ended.
    fn state(c: *ServerCursor, io: Io) ?i64 {
        c.client.state_mutex.lockUncancelable(io);
        defer c.client.state_mutex.unlock(io);
        return if (c.ended) null else c.id;
    }

    /// Ends the cursor; `id`, when given, is its id on the server from now
    /// on.
    fn end(c: *ServerCursor, io: Io, id: ?i64) void {
        c.client.state_mutex.lockUncancelable(io);
        defer c.client.state_mutex.unlock(io);
        c.ended = true;
        if (id) |new| c.id = new;
    }

    fn broken(c: *ServerCursor, io: Io, comptime text: []const u8) Error {
        c.end(io, null);
        return violation(c.diagnostics, text, .{});
    }

    /// The next batch. An error before the getMore went out leaves the
    /// cursor as it was; an error of the exchange ends it.
    fn getMore(c: *ServerCursor, io: Io, op: OperationContext, id: i64) Error!void {
        const client = c.client;
        if (c.diagnostics) |d| d.* = .{};
        try checkContext(io, op, c.diagnostics);
        var arena: std.heap.ArenaAllocator = .init(client.gpa);
        defer arena.deinit();
        const database, const collection = split(c.ns);
        var b: bson.Builder = .init(arena.allocator());
        b.putInt64("getMore", id) catch return error.OutOfMemory;
        b.putString("collection", collection) catch return error.OutOfMemory;
        if (c.batch_size) |n| {
            const put = if (std.math.cast(i32, n)) |small| b.putInt32("batchSize", small) else b.putInt64("batchSize", n);
            put catch return error.OutOfMemory;
        }
        if (c.comment) |kept| if (kept.raw().get("comment") catch null) |comment| {
            b.putValue("comment", comment) catch return error.OutOfMemory;
        };
        const body = b.finish() catch return error.OutOfMemory;
        const reply = client.exchange(io, op, .{ .database = database, .body = body.raw(), .max_time = false }, client.gpa, c.diagnostics) catch |err| {
            if (mongo.outcome(err) == .may_have_executed) c.end(io, null);
            return err;
        };
        errdefer reply.deinit();
        wire.checkReply(reply.raw(), client.gpa, c.diagnostics, c.failure_reply) catch |err| {
            // CursorNotFound: there is nothing to kill on the server.
            c.end(io, if (mongo.ServerError.fromReply(reply.raw()).code == 43) 0 else null);
            return err;
        };
        const more = parseCursor(reply.raw(), .next, c.diagnostics) catch |err| {
            c.end(io, null);
            return err;
        };
        if (!std.mem.eql(u8, more.ns, c.ns)) {
            const ns = try client.gpa.dupe(u8, more.ns);
            client.state_mutex.lockUncancelable(io);
            const old = c.ns;
            c.ns = ns;
            client.state_mutex.unlock(io);
            client.gpa.free(old);
        }
        c.reply.deinit();
        c.reply = reply;
        c.batch = more.batch.iterator();
        client.state_mutex.lockUncancelable(io);
        if (!c.ended) c.id = more.id;
        client.state_mutex.unlock(io);
    }
};

/// The `cursor` of a reply: its id, namespace and batch.
const Parsed = struct { id: i64, ns: []const u8, batch: bson.RawDocument };

const Batch = enum { first, next };

fn parseCursor(reply: bson.RawDocument, batch: Batch, d: ?*Diagnostics) Error!Parsed {
    const cursor = (reply.get("cursor") catch null) orelse return violation(d, "the reply holds no cursor; the command may have run", .{});
    if (cursor != .document) return violation(d, "cursor in the reply is not a document", .{});
    const id = if (cursor.document.get("id") catch null) |value| value.asI64() catch null else null;
    const ns = if (cursor.document.get("ns") catch null) |value| switch (value) {
        .string => |text| text,
        else => null,
    } else null;
    const key = switch (batch) {
        .first => "firstBatch",
        .next => "nextBatch",
    };
    const docs = (cursor.document.get(key) catch null) orelse return violation(d, "the cursor in the reply has no {s}", .{key});
    if (docs != .array) return violation(d, "{s} of the cursor in the reply is not an array", .{key});
    return .{
        .id = id orelse return violation(d, "the cursor in the reply has no id of an integer", .{}),
        .ns = ns orelse return violation(d, "the cursor in the reply has no ns", .{}),
        .batch = docs.array,
    };
}

/// The database and the collection of a namespace "database.collection":
/// the collection is all after the first dot, "fs.chunks" of "app.fs.chunks".
fn split(ns: []const u8) struct { []const u8, []const u8 } {
    const dot = std.mem.findScalar(u8, ns, '.') orelse return .{ ns, "" };
    return .{ ns[0..dot], ns[dot + 1 ..] };
}

/// The caller's context before a command goes out: less than 1 ms left of
/// the deadline, or a canceled token.
fn checkContext(io: Io, op: OperationContext, d: ?*Diagnostics) Error!void {
    if (op.ctx.remaining(Io.Clock.awake.now(io))) |left| {
        if (left.nanoseconds < std.time.ns_per_ms) return fail(d, null, error.DeadlineExceeded, "less than 1 ms was left of the deadline", .{});
    }
    if (op.ctx.isCancelled()) return fail(d, null, error.Cancelled, "the token was canceled", .{});
}

fn describe(server_type: wire.Hello.ServerType) []const u8 {
    return switch (server_type) {
        .standalone => "standalone mongod",
        .mongos => "mongos",
        .rs_primary => "primary",
        .rs_secondary => "secondary",
        .rs_arbiter => "arbiter",
        .rs_other => "member",
        .rs_ghost => "member that is not initialized yet",
    };
}

/// `{comment: value}` in `gpa`: the comment of a cursor, kept for its
/// getMores after the caller's memory is gone.
fn keepComment(gpa: Allocator, value: bson.Value, d: ?*Diagnostics) Error!bson.OwnedDocument {
    var b: bson.Builder = .init(gpa);
    defer b.deinit();
    b.putValue("comment", value) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => fail(d, null, error.InvalidArgument, "the comment of the cursor cannot be written as BSON", .{}),
    };
    return b.finish() catch error.OutOfMemory;
}

fn fail(d: ?*Diagnostics, phase: ?Diagnostics.Phase, err: Error, comptime fmt: []const u8, args: anytype) Error {
    if (d) |x| x.set(phase, null, fmt, args);
    return err;
}

fn violation(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    return fail(d, .receive, error.ProtocolViolation, fmt, args);
}

/// The host and the port of a URI.
const Address = struct { host: []const u8, port: u16 };

/// "mongodb://host:port", the host an IP address, `[an IPv6 one]` or a
/// name, the port 27017 when left out, and a "/" or "/database" after them;
/// TLS, credentials, several hosts, SRV and options are `Unsupported`.
fn parseUri(uri: []const u8, d: ?*Diagnostics) Error!Address {
    const scheme = "mongodb://";
    if (std.mem.startsWith(u8, uri, "mongodb+srv://")) return fail(d, null, error.Unsupported, "minidriver does not look up SRV records: use mongodb://host:port", .{});
    if (!std.mem.startsWith(u8, uri, scheme)) return fail(d, null, error.InvalidArgument, "a URI starts with mongodb://", .{});
    const rest = uri[scheme.len..];
    const authority_end = std.mem.findAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..authority_end];
    if (std.mem.findScalar(u8, rest[authority_end..], '?')) |at| {
        var pairs = std.mem.splitAny(u8, rest[authority_end + at + 1 ..], "&;");
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            const name = pair[0 .. std.mem.findScalar(u8, pair, '=') orelse pair.len];
            if (std.ascii.startsWithIgnoreCase(name, "tls") or std.ascii.eqlIgnoreCase(name, "ssl"))
                return fail(d, null, error.Unsupported, "minidriver does not speak TLS; use a trusted network", .{});
            return fail(d, null, error.Unsupported, "minidriver takes no options in the URI; got '{s}'", .{name});
        }
    }
    if (std.mem.findScalar(u8, authority, '@') != null)
        return fail(d, null, error.Unsupported, "minidriver does not authenticate: connect to a mongod without --auth, with no user in the URI", .{});
    if (std.mem.findScalar(u8, authority, ',') != null) return fail(d, null, error.Unsupported, "minidriver connects to one host, and the URI names several", .{});
    var host = authority;
    var port_text: ?[]const u8 = null;
    if (std.mem.startsWith(u8, authority, "[")) {
        const close = std.mem.findScalar(u8, authority, ']') orelse return fail(d, null, error.InvalidArgument, "the IPv6 address of the URI has no ']'", .{});
        host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return fail(d, null, error.InvalidArgument, "after the IPv6 address of the URI comes ':' and the port", .{});
            port_text = after[1..];
        }
    } else if (std.mem.findScalar(u8, authority, ':')) |colon| {
        if (std.mem.findScalarLast(u8, authority, ':') != colon) return fail(d, null, error.InvalidArgument, "an IPv6 address in a URI goes in brackets: [::1]:27017", .{});
        host = authority[0..colon];
        port_text = authority[colon + 1 ..];
    }
    if (host.len == 0) return fail(d, null, error.InvalidArgument, "the URI names no host", .{});
    const port = if (port_text) |text| std.fmt.parseInt(u16, text, 10) catch 0 else 27017;
    if (port == 0) return fail(d, null, error.InvalidArgument, "the port of the URI is 1 to 65535", .{});
    return .{ .host = host, .port = port };
}

pub const testing = struct {
    /// The harness of `mongo.testing.conformance.run`: a fresh client on the
    /// target of each check, connected.
    pub const Harness = struct {
        client: Client = undefined,

        pub fn setUp(h: *Harness, io: Io, gpa: Allocator, target: mongo.testing.conformance.Target) !mongo.Client {
            const uri = switch (target) {
                .scripted => |s| s.uri,
                .live => |l| l.uri,
            };
            h.client = try .init(gpa, io, .{ .uri = uri });
            errdefer h.client.deinit();
            try h.client.connect(io, .root);
            return h.client.client();
        }

        pub fn close(h: *Harness, io: Io) void {
            h.client.close(io);
        }

        pub fn tearDown(h: *Harness, io: Io) void {
            _ = io;
            h.client.deinit();
        }
    };
};

const t = std.testing;
const Script = mongo.testing.Script;
const FakeServer = mongo.testing.FakeServer;

test "minidriver keeps the contract of zefir-mongo: layer S of the conformance suite" {
    var harness: testing.Harness = .{};
    var report = try mongo.testing.conformance.run(t.io, t.allocator, &harness, .{});
    defer report.deinit();
    if (report.failedCount() > 0) {
        std.debug.print("{f}", .{&report});
        return error.TestUnexpectedResult;
    }
    // A driver on the wire takes S16; layer L needs a live mongod.
    try t.expect(report.outcome(.s16) == .passed);
    try t.expectEqual(@as(usize, 10), report.skippedCount());
}

test "the URI is mongodb://host:port; TLS, credentials, several hosts and options are Unsupported" {
    const accepted = [_]struct { []const u8, []const u8, u16 }{
        .{ "mongodb://127.0.0.1:27117", "127.0.0.1", 27117 },
        .{ "mongodb://db.example.com", "db.example.com", 27017 },
        .{ "mongodb://localhost:27017/", "localhost", 27017 },
        .{ "mongodb://localhost/app", "localhost", 27017 },
        .{ "mongodb://[::1]:27018", "::1", 27018 },
        .{ "mongodb://[::1]", "::1", 27017 },
    };
    for (accepted) |case| {
        const uri, const host, const port = case;
        var client: Client = try .init(t.allocator, t.io, .{ .uri = uri });
        defer client.deinit();
        try t.expectEqualStrings(host, client.host);
        try t.expectEqual(port, client.port);
    }
    const refused = [_]struct { []const u8, Error, []const u8 }{
        .{ "mongodb://127.0.0.1:27017/?tls=true", error.Unsupported, "minidriver does not speak TLS; use a trusted network" },
        .{ "mongodb://127.0.0.1/?ssl=true", error.Unsupported, "minidriver does not speak TLS; use a trusted network" },
        .{ "mongodb://127.0.0.1/?tlsCAFile=ca.pem", error.Unsupported, "minidriver does not speak TLS; use a trusted network" },
        .{ "mongodb://app:secret@127.0.0.1/app", error.Unsupported, "minidriver does not authenticate: connect to a mongod without --auth, with no user in the URI" },
        .{ "mongodb://a.example.com,b.example.com", error.Unsupported, "minidriver connects to one host, and the URI names several" },
        .{ "mongodb+srv://cluster.example.com", error.Unsupported, "minidriver does not look up SRV records: use mongodb://host:port" },
        .{ "mongodb://127.0.0.1/?appName=app", error.Unsupported, "minidriver takes no options in the URI; got 'appName'" },
        .{ "postgres://127.0.0.1", error.InvalidArgument, "a URI starts with mongodb://" },
        .{ "mongodb://", error.InvalidArgument, "the URI names no host" },
        .{ "mongodb://127.0.0.1:0", error.InvalidArgument, "the port of the URI is 1 to 65535" },
        .{ "mongodb://127.0.0.1:65536", error.InvalidArgument, "the port of the URI is 1 to 65535" },
        .{ "mongodb://127.0.0.1:port", error.InvalidArgument, "the port of the URI is 1 to 65535" },
        .{ "mongodb://::1:27017", error.InvalidArgument, "an IPv6 address in a URI goes in brackets: [::1]:27017" },
        .{ "mongodb://[::1", error.InvalidArgument, "the IPv6 address of the URI has no ']'" },
    };
    for (refused) |case| {
        const uri, const expected, const message = case;
        var d: Diagnostics = .{};
        try t.expectError(expected, Client.init(t.allocator, t.io, .{ .uri = uri, .diagnostics = &d }));
        try t.expectEqualStrings(message, d.message());
    }
}

/// Answers every command with `{ok: 1.0}`.
const Ok = struct {
    pub fn answer(o: *Ok, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = o;
        _ = io;
        _ = arena;
        _ = request;
        return .{ .reply = Script.ok };
    }
};

/// A FakeServer of `script` on loopback, in a task of its own.
const Served = struct {
    listener: net.Server,
    server: Io.Future(Io.Cancelable!void),
    buffer: [64]u8 = undefined,

    /// Lives where it is: the task points into it.
    fn start(s: *Served, io: Io, script: *Script) !void {
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, script });
    }

    fn uri(s: *Served) ![]const u8 {
        return FakeServer.uri(&s.listener, &s.buffer);
    }

    fn stop(s: *Served, io: Io) void {
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
    }
};

const ping: mongo.Command = .{ .database = "admin", .body = bson.literal(.{ .ping = 1 }) };

test "a server that is not a standalone mongod of MongoDB 7.0 or later is Unsupported, and gets no command" {
    const io = t.io;
    const cases = [_]struct { wire.Hello, []const u8 }{
        .{ .{ .server_type = .rs_ghost }, "is a member that is not initialized yet; minidriver works with a standalone mongod only" },
        .{ .{ .server_type = .rs_primary, .set_name = "rs7" }, "is a primary of the replica set rs7; minidriver works with a standalone mongod only" },
        .{ .{ .server_type = .mongos }, "is a mongos; minidriver works with a standalone mongod only" },
        .{ .{ .max_wire_version = 20 }, "speaks wire version 20; minidriver needs MongoDB 7.0 or later, wire version 21" },
    };
    for (cases) |case| {
        const hello, const text = case;
        var ok: Ok = .{};
        var script: Script = .init(t.allocator, .init(&ok));
        defer script.deinit();
        script.hello = hello;
        var served: Served = undefined;
        try served.start(io, &script);
        defer served.stop(io);
        var client: Client = try .init(t.allocator, io, .{ .uri = try served.uri() });
        defer client.deinit();
        var d: Diagnostics = .{};
        try t.expectError(error.Unsupported, client.client().runCommand(io, .of(.root), ping, .{ .allocator = t.allocator, .diagnostics = &d }));
        if (!std.mem.endsWith(u8, d.message(), text)) {
            std.debug.print("{s}\n", .{d.message()});
            return error.TestUnexpectedResult;
        }
        try t.expectEqual(@as(usize, 0), script.received(io));
    }
}

test "a port where no server listens is Unavailable, and a name is looked up: localhost" {
    const io = t.io;
    var ok: Ok = .{};
    var script: Script = .init(t.allocator, .init(&ok));
    defer script.deinit();
    var served: Served = undefined;
    try served.start(io, &script);
    var buffer: [64]u8 = undefined;
    const port = FakeServer.port(&served.listener);
    // The port of a server that has stopped.
    served.stop(io);
    {
        var client: Client = try .init(t.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://127.0.0.1:{d}", .{port}) });
        defer client.deinit();
        var d: Diagnostics = .{};
        try t.expectError(error.Unavailable, client.client().runCommand(io, .of(.root), ping, .{ .allocator = t.allocator, .diagnostics = &d }));
        try t.expect(d.phase.? == .connect);
        try t.expect(std.mem.startsWith(u8, d.message(), "cannot connect to 127.0.0.1:"));
    }
    try served.start(io, &script);
    defer served.stop(io);
    var client: Client = try .init(t.allocator, io, .{ .uri = try std.fmt.bufPrint(&buffer, "mongodb://localhost:{d}", .{FakeServer.port(&served.listener)}) });
    defer client.deinit();
    const reply = try client.client().runCommand(io, .of(.root), ping, .{ .allocator = t.allocator });
    reply.deinit();
}
