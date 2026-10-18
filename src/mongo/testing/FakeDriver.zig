//! `mongo.testing.FakeDriver`: a driver of `mongo.Client` in the process,
//! over a `Script`, for the tests of code on the collection API and of
//! applications. The test says what the server answers and reads in the
//! script's journal what came; nothing goes over a network.
//!
//! ```zig
//! var queue: Script.Queue = .{ .answers = &.{.{ .reply = bson.literal(.{ .n = 2, .ok = 1.0 }) }} };
//! var script: Script = .init(gpa, queue.handler());
//! defer script.deinit();
//! var fake: FakeDriver = .init(gpa, &script);
//! defer fake.deinit();
//! const db: mongo.Database = .init(fake.client(), "app", &ids);
//! ```
//!
//! It acts as a driver on one standalone mongod whose hello is
//! `script.hello`. Each command goes to the script as a wire driver sends
//! it, an OP_MSG read back as a server reads it: the body as the caller
//! gave it with `$db` added, `maxTimeMS` under a deadline (the time left,
//! in whole milliseconds), `ordered` and a section of kind 1 for a write.
//! The handler gets every command, `ping` and `hello` included. Then:
//!
//! - Writes go in batches by the limits of `script.hello`, through
//!   `mongo.wire.batch`, and their replies are merged by its rules.
//! - Cursors go to the script for `getMore` and `killCursors`, in the
//!   cursor's namespace.
//! - A delayed answer is waited for in the caller's task, so deadlines and
//!   cancelation are real: past the deadline the call is `Timeout`, and a
//!   task canceled meanwhile gets `Interrupted` and keeps its cancelation.
//! - `close_connection` is `ConnectionLost`; `refuse_connections` is
//!   `ConnectionLost` for its call and `Unavailable` for the calls after
//!   it, until the script accepts connections again; `malformed` is
//!   `ProtocolViolation`. Each ends the fake connection: the next call
//!   opens another, with the next number in the journal.
//!
//! The fake does not check that `io` is the one it was made with, nor
//! that a cursor serves one task at a time.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("../bson.zig");
const read = @import("../bson/read.zig");
const wire = @import("../wire.zig");
const opmsg = wire.opmsg;
const errors = @import("../errors.zig");
const requests = @import("../requests.zig");
const results = @import("../results.zig");
const capabilities_ = @import("../contract/capabilities.zig");
const rules = @import("../contract/rules.zig");
const Client = @import("../contract/Client.zig");
const Cursor = @import("../contract/Cursor.zig");
const Script = @import("Script.zig");
const Error = errors.Error;
const Diagnostics = errors.Diagnostics;
const OperationContext = requests.OperationContext;
const FakeDriver = @This();

allocator: Allocator,
script: *Script,
/// The budget of the killCursors that `close` and `deinit` of a cursor
/// send, and `close` of the driver.
cursor_close_timeout: Io.Duration = .fromSeconds(1),
/// Guards `connection`, `cursors` and the state of the cursors in it.
mutex: Io.Mutex = .init,
/// The number of the fake connection, or null when there is none.
connection: ?u32 = null,
next_request_id: std.atomic.Value(i32) = .init(1),
/// Set by `close`: new calls are `Closed`, and held answers end at once.
closed: Io.Event = .unset,
closing: std.atomic.Value(bool) = .init(false),
/// The open cursors, for `close`.
cursors: std.DoublyLinkedList = .{},

/// A fake driver over `script`; `allocator` holds its cursors.
pub fn init(allocator: Allocator, script: *Script) FakeDriver {
    return .{ .allocator = allocator, .script = script };
}

/// The fake holds nothing for itself: `close` it first when cursors are
/// open, and `deinit` the cursors before it.
pub fn deinit(self: *FakeDriver) void {
    self.* = undefined;
}

pub fn client(self: *FakeDriver) Client {
    return .init(self);
}

/// Opens the fake connection now rather than at the first call:
/// `Unavailable` while the script refuses connections.
pub fn connect(self: *FakeDriver, io: Io, ctx: core.Context) Error!void {
    if (self.closed.isSet()) return error.Closed;
    try rules.checkContext(io, .of(ctx), null);
    _ = try self.connectionFor(io, null);
}

/// New calls get `Closed`; a call waiting for a held answer ends with
/// `ConnectionLost`; open cursors get their `killCursors`. A second call
/// does nothing.
pub fn close(self: *FakeDriver, io: Io) void {
    if (self.closing.swap(true, .acq_rel)) return;
    self.closed.set(io);
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        self.mutex.lockUncancelable(io);
        const node = self.cursors.popFirst();
        var kill: ?Kill = null;
        if (node) |n| {
            const c: *FakeCursor = @fieldParentPtr("node", n);
            c.listed = false;
            c.ended = true;
            if (c.id != 0) kill = .{ .id = c.id, .ns = arena.allocator().dupe(u8, c.ns) catch null };
            c.id = 0;
        }
        self.mutex.unlock(io);
        if (node == null) break;
        if (kill) |k| if (k.ns) |ns| self.killCursor(io, ns, k.id);
    }
    self.mutex.lockUncancelable(io);
    self.connection = null;
    self.mutex.unlock(io);
}

const Kill = struct { id: i64, ns: ?[]const u8 };

pub fn runCommand(self: *FakeDriver, io: Io, op: OperationContext, command: *const requests.Command, options: requests.CommandOptions) Error!bson.OwnedDocument {
    const reply = try self.exchange(io, op, .{ .database = command.database, .body = command.body }, options.allocator, options.diagnostics);
    wire.checkReply(reply.raw(), options.allocator, options.diagnostics, options.failure_reply) catch |err| {
        reply.deinit();
        return err;
    };
    return reply;
}

pub fn openCursor(self: *FakeDriver, io: Io, op: OperationContext, command: *const requests.Command, options: requests.CursorOptions) Error!Cursor {
    const reply = try self.exchange(io, op, .{ .database = command.database, .body = command.body }, self.allocator, options.diagnostics);
    errdefer reply.deinit();
    // Decision 7 of the plan: the failure_reply of a cursor comes from the
    // driver's allocator.
    try wire.checkReply(reply.raw(), self.allocator, options.diagnostics, options.failure_reply);
    const first = try parseCursor(reply.raw(), .first, options.diagnostics);
    const c = try self.allocator.create(FakeCursor);
    errdefer self.allocator.destroy(c);
    const ns = try self.allocator.dupe(u8, first.ns);
    errdefer self.allocator.free(ns);
    if (std.mem.findScalar(u8, ns, '.') == null) return violation(options.diagnostics, "the namespace '{s}' of the cursor has no collection", .{ns});
    const comment: ?bson.Value = if (options.comment) |value| try results.dupeValue(self.allocator, value) else null;
    c.* = .{
        .driver = self,
        .id = first.id,
        .ns = ns,
        .reply = reply,
        .batch = first.batch.iterator(),
        .batch_size = options.batch_size,
        .comment = comment,
        .diagnostics = options.diagnostics,
        .failure_reply = options.failure_reply,
    };
    self.mutex.lockUncancelable(io);
    self.cursors.append(&c.node);
    self.mutex.unlock(io);
    return .init(c);
}

pub fn write(self: *FakeDriver, io: Io, op: OperationContext, request: *const requests.WriteRequest, options: requests.WriteOptions) Error!results.WriteResult {
    const identifier = request.kind.items();
    // The batches take room for every field their messages carry.
    const message: opmsg.Request = .{
        .request_id = 0,
        .body = request.body,
        .database = request.database,
        .ordered = request.ordered,
        .max_time_ms = if (op.ctx.deadline != null) 0 else null,
        .sequence = .{ .identifier = identifier, .documents = request.items },
    };
    var batches = try wire.batch.Batches.init(message, .of(self.script.hello), options.diagnostics);
    var merge: wire.batch.Merge = .{};
    defer merge.deinit(options.allocator);
    while (batches.next()) |b| {
        const reply = self.exchange(io, op, .{
            .database = request.database,
            .body = request.body,
            .ordered = request.ordered,
            .sequence = .{ .identifier = identifier, .documents = b.items },
        }, options.allocator, options.diagnostics) catch |err| return merge.fail(options.allocator, err, b, options);
        defer reply.deinit();
        wire.checkReply(reply.raw(), options.allocator, options.diagnostics, options.failure_reply) catch |err|
            return merge.fail(options.allocator, err, b, options);
        const next = merge.add(options.allocator, b, reply.raw(), request.ordered, options.diagnostics) catch |err|
            return merge.fail(options.allocator, err, b, options);
        switch (next) {
            .more => {},
            .done => break,
            .timeout => return merge.fail(options.allocator, error.Timeout, b, options),
        }
    }
    return merge.result(options.allocator);
}

pub fn capabilities(self: *FakeDriver) capabilities_.Capabilities {
    const hello = self.script.hello;
    return .{
        .revision = 1,
        .name = "fake",
        .commands = true,
        .cursors = true,
        .aggregation = true,
        .batched_writes = true,
        .server = .{
            .kind = .standalone,
            .max_wire_version = hello.max_wire_version,
            .max_bson_object_size = hello.max_bson_object_size,
            .max_message_size_bytes = hello.max_message_size_bytes,
            .max_write_batch_size = hello.max_write_batch_size,
        },
    };
}

/// One command as it goes out.
const Send = struct {
    database: []const u8,
    body: bson.RawDocument,
    ordered: ?bool = null,
    sequence: ?opmsg.Sequence = null,
    /// `maxTimeMS` goes out under a deadline: not in getMore and
    /// killCursors.
    max_time: bool = true,
    /// The killCursors of `close`, which go out after it.
    after_close: bool = false,
};

/// Sends `send` to the script on the fake connection, as a wire driver
/// sends it, and returns the reply, copied into `allocator`.
fn exchange(self: *FakeDriver, io: Io, op: OperationContext, send: Send, allocator: Allocator, diagnostics: ?*Diagnostics) Error!bson.OwnedDocument {
    if (!send.after_close and self.closed.isSet()) return fail(diagnostics, null, error.Closed, "the client is closed", .{});
    if (op.ctx.isCancelled()) return fail(diagnostics, .send, error.Cancelled, "the token was canceled before the command went out", .{});
    const deadline = op.ctx.deadline;
    var max_time_ms: ?i64 = null;
    if (deadline) |d| {
        const left = d.remaining(Io.Clock.awake.now(io));
        if (left.nanoseconds < std.time.ns_per_ms) return fail(diagnostics, .send, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the command went out", .{});
        if (send.max_time) max_time_ms = std.math.cast(i64, @divFloor(left.nanoseconds, std.time.ns_per_ms)) orelse std.math.maxInt(i64);
    }
    const hello = self.script.hello;
    const message: opmsg.Request = .{
        .request_id = self.next_request_id.fetchAdd(1, .monotonic),
        .body = send.body,
        .database = send.database,
        .ordered = send.ordered,
        .max_time_ms = max_time_ms,
        .sequence = send.sequence,
    };
    if (message.length() > hello.max_message_size_bytes) {
        return fail(diagnostics, .send, error.InvalidArgument, "the command is {d} bytes, and the server takes {d} at most", .{ message.length(), hello.max_message_size_bytes });
    }
    const connection = try self.connectionFor(io, diagnostics);

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The message as a driver writes it, read back as a server reads it.
    var out: Io.Writer.Allocating = .init(a);
    opmsg.writeRequest(&out.writer, message) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.InvalidArgument => fail(diagnostics, .send, error.InvalidArgument, "the command cannot be written as OP_MSG", .{}),
    };
    var reader: Io.Reader = .fixed(out.written());
    const incoming = opmsg.readRequest(&reader, a, hello.max_message_size_bytes, null) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(diagnostics, .send, error.InvalidArgument, "the command is not valid BSON", .{}),
    };
    const request: Script.Request = .of(connection, &incoming);
    try self.script.record(io, &request);

    const answer = self.script.answer(io, a, &request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {
            self.dropConnection(io, connection);
            io.recancel();
            return fail(diagnostics, .wait, error.Interrupted, "the task was canceled while the command was out", .{});
        },
    };
    const reply = switch (answer) {
        .reply => |doc| doc,
        .delayed => |d| try self.wait(io, deadline, d, connection, diagnostics),
        .close_connection => return self.lost(io, connection, diagnostics, "the server closed the connection after the command"),
        .refuse_connections => {
            self.script.refuseConnections();
            return self.lost(io, connection, diagnostics, "the server closed the connection after the command, and refuses new ones");
        },
        .malformed => |defect| {
            self.dropConnection(io, connection);
            return fail(diagnostics, .receive, error.ProtocolViolation, "the reply broke OP_MSG ({t})", .{defect});
        },
    };
    // A reply that came after the deadline is not seen: the call timed
    // out first.
    if (deadline) |d| {
        if (d.isExpired(Io.Clock.awake.now(io))) {
            self.dropConnection(io, connection);
            return fail(diagnostics, .wait, error.Timeout, "the deadline passed before the reply came", .{});
        }
    }
    read.validate(reply.bytes, read.max_levels) catch {
        self.dropConnection(io, connection);
        return fail(diagnostics, .receive, error.ProtocolViolation, "the reply is not valid BSON, or nests too deep", .{});
    };
    return reply.dupe(allocator);
}

/// Waits for a held answer: until its delay, the deadline, the task's
/// cancelation or `close`, whichever comes first.
fn wait(self: *FakeDriver, io: Io, deadline: ?core.Deadline, held: Script.Delayed, connection: u32, diagnostics: ?*Diagnostics) Error!bson.RawDocument {
    const reply_at = Io.Clock.awake.now(io).addDuration(held.after);
    while (true) {
        const now = Io.Clock.awake.now(io);
        if (now.nanoseconds >= reply_at.nanoseconds) return held.reply;
        var until = reply_at;
        if (deadline) |d| {
            if (d.isExpired(now)) {
                self.dropConnection(io, connection);
                return fail(diagnostics, .wait, error.Timeout, "the deadline passed while the server held the reply", .{});
            }
            if (d.expires.nanoseconds < until.nanoseconds) until = d.expires;
        }
        self.closed.waitTimeout(io, .{ .deadline = until.withClock(.awake) }) catch |err| switch (err) {
            // The time came, or a spurious wakeup: look again.
            error.Timeout => continue,
            error.Canceled => {
                self.dropConnection(io, connection);
                io.recancel();
                return fail(diagnostics, .wait, error.Interrupted, "the task was canceled while the server held the reply", .{});
            },
        };
        return self.lost(io, connection, diagnostics, "close() of the client cut the exchange");
    }
}

fn lost(self: *FakeDriver, io: Io, connection: u32, diagnostics: ?*Diagnostics, comptime text: []const u8) Error {
    self.dropConnection(io, connection);
    return fail(diagnostics, .wait, error.ConnectionLost, text, .{});
}

/// The fake connection, opened when there is none.
fn connectionFor(self: *FakeDriver, io: Io, diagnostics: ?*Diagnostics) Error!u32 {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.connection) |connection| return connection;
    const connection = self.script.openConnection() orelse
        return fail(diagnostics, .connect, error.Unavailable, "the server refuses connections", .{});
    self.connection = connection;
    return connection;
}

/// Ends the fake connection `connection`, unless another call ended it
/// already and opened another.
fn dropConnection(self: *FakeDriver, io: Io, connection: u32) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.connection == connection) self.connection = null;
}

/// Sends killCursors for cursor `id` of `ns` with a fresh budget, and
/// ignores the reply; the task's cancelation waits until it is done.
fn killCursor(self: *FakeDriver, io: Io, ns: []const u8, id: i64) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const database, const collection = split(ns);
    var b: bson.Builder = .init(arena.allocator());
    b.putString("killCursors", collection) catch return;
    b.beginArray("cursors") catch return;
    b.putInt64("", id) catch return;
    b.end() catch return;
    const body = b.finish() catch return;
    const budget: OperationContext = .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), self.cursor_close_timeout)));
    if (self.exchange(io, budget, .{ .database = database, .body = body.raw(), .max_time = false, .after_close = true }, arena.allocator(), null)) |_| {} else |_| {}
}

/// The database and the collection of a namespace "database.collection".
fn split(ns: []const u8) struct { []const u8, []const u8 } {
    const dot = std.mem.findScalar(u8, ns, '.') orelse return .{ ns, "" };
    return .{ ns[0..dot], ns[dot + 1 ..] };
}

/// A cursor of the fake, in the heap.
const FakeCursor = struct {
    driver: *FakeDriver,
    node: std.DoublyLinkedList.Node = .{},
    // Guarded by `driver.mutex`, which `close` of the driver takes.
    /// The id on the server: 0 when it is exhausted, killed or unknown.
    id: i64,
    /// The namespace, "database.collection".
    ns: []u8,
    /// No more documents: closed, or ended by an error of a getMore.
    ended: bool = false,
    /// In the driver's list of open cursors.
    listed: bool = true,
    // The cursor's own, used by one task at a time.
    /// The reply that holds the current batch.
    reply: bson.OwnedDocument,
    /// The documents of the current batch that `next` has not given yet.
    batch: bson.RawDocument.Iterator,
    batch_size: ?u32,
    comment: ?bson.Value,
    diagnostics: ?*Diagnostics,
    failure_reply: ?*?bson.OwnedDocument,
    /// `close` was called.
    closed: bool = false,

    pub fn next(c: *FakeCursor, io: Io, op: OperationContext) Error!?bson.RawDocument {
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

    pub fn close(c: *FakeCursor, io: Io) void {
        if (c.closed) return;
        c.closed = true;
        const driver = c.driver;
        driver.mutex.lockUncancelable(io);
        if (c.listed) driver.cursors.remove(&c.node);
        c.listed = false;
        c.ended = true;
        const id = c.id;
        c.id = 0;
        driver.mutex.unlock(io);
        if (id != 0) driver.killCursor(io, c.ns, id);
    }

    pub fn deinit(c: *FakeCursor, io: Io) void {
        c.close(io);
        const allocator = c.driver.allocator;
        c.reply.deinit();
        allocator.free(c.ns);
        if (c.comment) |comment| results.freeValue(allocator, comment);
        allocator.destroy(c);
    }

    /// The id, or null when the cursor has ended.
    fn state(c: *FakeCursor, io: Io) ?i64 {
        c.driver.mutex.lockUncancelable(io);
        defer c.driver.mutex.unlock(io);
        return if (c.ended) null else c.id;
    }

    fn end(c: *FakeCursor, io: Io, id: ?i64) void {
        c.driver.mutex.lockUncancelable(io);
        defer c.driver.mutex.unlock(io);
        c.ended = true;
        if (id) |new| c.id = new;
    }

    fn broken(c: *FakeCursor, io: Io, comptime text: []const u8) Error {
        c.end(io, null);
        return fail(c.diagnostics, .receive, error.ProtocolViolation, text, .{});
    }

    /// The next batch. An error before the command went out leaves the
    /// cursor as it was; an error of the exchange ends it.
    fn getMore(c: *FakeCursor, io: Io, op: OperationContext, id: i64) Error!void {
        if (c.diagnostics) |d| d.* = .{};
        try rules.checkContext(io, op, c.diagnostics);
        var arena: std.heap.ArenaAllocator = .init(c.driver.allocator);
        defer arena.deinit();
        const database, const collection = split(c.ns);
        var b: bson.Builder = .init(arena.allocator());
        b.putInt64("getMore", id) catch return error.OutOfMemory;
        b.putString("collection", collection) catch return error.OutOfMemory;
        if (c.batch_size) |n| {
            const put = if (std.math.cast(i32, n)) |small| b.putInt32("batchSize", small) else b.putInt64("batchSize", n);
            put catch return error.OutOfMemory;
        }
        if (c.comment) |comment| b.putValue("comment", comment) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidBson => fail(c.diagnostics, .send, error.InvalidArgument, "the comment of the cursor cannot be written", .{}),
        };
        const body = b.finish() catch return error.OutOfMemory;
        const reply = c.driver.exchange(io, op, .{ .database = database, .body = body.raw(), .max_time = false }, c.driver.allocator, c.diagnostics) catch |err| {
            if (errors.outcome(err) == .may_have_executed) c.end(io, null);
            return err;
        };
        errdefer reply.deinit();
        wire.checkReply(reply.raw(), c.driver.allocator, c.diagnostics, c.failure_reply) catch |err| {
            const code = errors.ServerError.fromReply(reply.raw()).code;
            // CursorNotFound: there is nothing to kill on the server.
            c.end(io, if (code == 43) 0 else null);
            return err;
        };
        const more = parseCursor(reply.raw(), .next, c.diagnostics) catch |err| {
            c.end(io, null);
            return err;
        };
        if (!std.mem.eql(u8, more.ns, c.ns)) {
            const ns = try c.driver.allocator.dupe(u8, more.ns);
            c.driver.mutex.lockUncancelable(io);
            const old = c.ns;
            c.ns = ns;
            c.driver.mutex.unlock(io);
            c.driver.allocator.free(old);
        }
        c.reply.deinit();
        c.reply = reply;
        c.batch = more.batch.iterator();
        c.driver.mutex.lockUncancelable(io);
        if (!c.ended) c.id = more.id;
        c.driver.mutex.unlock(io);
    }
};

/// The `cursor` of a reply: its id, namespace and batch.
const Parsed = struct { id: i64, ns: []const u8, batch: bson.RawDocument };

fn parseCursor(reply: bson.RawDocument, batch: Script.CursorBatch, diagnostics: ?*Diagnostics) Error!Parsed {
    const cursor = (reply.get("cursor") catch null) orelse
        return violation(diagnostics, "the reply holds no cursor; the command may have run", .{});
    if (cursor != .document) return violation(diagnostics, "cursor in the reply is not a document", .{});
    const id = if (cursor.document.get("id") catch null) |value| value.asI64() catch null else null;
    const ns = if (cursor.document.get("ns") catch null) |value| switch (value) {
        .string => |text| text,
        else => null,
    } else null;
    const key = switch (batch) {
        .first => "firstBatch",
        .next => "nextBatch",
    };
    const docs = (cursor.document.get(key) catch null) orelse return violation(diagnostics, "the cursor in the reply has no {s}", .{key});
    if (docs != .array) return violation(diagnostics, "{s} of the cursor in the reply is not an array", .{key});
    return .{
        .id = id orelse return violation(diagnostics, "the cursor in the reply has no id of an integer", .{}),
        .ns = ns orelse return violation(diagnostics, "the cursor in the reply has no ns", .{}),
        .batch = docs.array,
    };
}

fn fail(diagnostics: ?*Diagnostics, phase: ?Diagnostics.Phase, err: Error, comptime fmt: []const u8, args: anytype) Error {
    if (diagnostics) |d| d.set(phase, null, fmt, args);
    return err;
}

fn violation(diagnostics: ?*Diagnostics, comptime fmt: []const u8, args: anytype) Error {
    return fail(diagnostics, .receive, error.ProtocolViolation, fmt, args);
}
