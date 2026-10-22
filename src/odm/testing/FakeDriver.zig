//! `odm.testing.FakeDriver`: a driver without a network, for the tests of
//! odm and of the code over it. It runs no query. A plan per connection
//! string says how its clients open and connect, and may name a gate that
//! holds their calls; a queue of replies per connection string answers
//! their operations; a journal keeps a copy of every call that went out,
//! to check what odm sent; counts follow the clients.
//!
//! ```zig
//! var fake: odm.testing.FakeDriver = .init(gpa);
//! defer fake.deinit();
//! try fake.plan("fake://shop", .{ .connects = &.{ error.Unavailable, null } });
//! try fake.reply("fake://shop", .{ .count = 3 });
//! // Hand fake.driver() to the code under test, then check what it sent:
//! const sent = fake.journal(io);
//! try std.testing.expect(sent[sent.len - 1].call == .count);
//! ```
//!
//! Without a plan a client connects at once. An operation takes the next
//! reply queued for its connection string; without one, `find` and
//! `aggregate` give an empty cursor, the writes zeros, `count` 0 and
//! `command` `{ok: 1.0}`. Every capability is there. A call keeps the
//! rules of the contract: less than 1 ms to the deadline is
//! `DeadlineExceeded` and a canceled token `Cancelled`, both journaling
//! nothing; before a `connect` succeeded an operation is `Unavailable`,
//! after `close` `Closed`; each call starts its diagnostics afresh.
//!
//! The fake stays where it is once `driver` gave it out. `plan` and `reply`
//! take no lock and may come at any time, from any task. `gpa` must be
//! thread-safe, as `std.testing.allocator` is: the clients copy their
//! calls into it from their tasks.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const Client = odm.Client;
const Diagnostics = odm.Diagnostics;
const DriverError = odm.DriverError;

const FakeDriver = @This();

gpa: Allocator,
/// Guards the journal, the replies that operations took, the connects that
/// plans answered and the calls of each client that wait at gates.
mutex: Io.Mutex = .init,
/// The plans, the newest first; `plan` pushes them without the mutex.
plans: std.atomic.Value(?*PlanNode) = .init(null),
/// The replies, the newest first; `reply` pushes them without the mutex.
replies: std.atomic.Value(?*ReplyNode) = .init(null),
entries: std.ArrayList(Request) = .empty,
/// The copies that the journal holds.
journal_arena: std.heap.ArenaAllocator,
opened: std.atomic.Value(usize) = .init(0),
connected: std.atomic.Value(usize) = .init(0),
closed: std.atomic.Value(usize) = .init(0),
close_calls: std.atomic.Value(usize) = .init(0),
freed: std.atomic.Value(usize) = .init(0),
cursors: std.atomic.Value(usize) = .init(0),

pub const name = "fake";

/// How the clients of a connection string open and connect.
pub const Plan = struct {
    /// The error of `open`; null opens a client.
    open: ?odm.Driver.OpenError = null,
    /// The results of the connects of the clients, in the order they come
    /// under this plan: null is a success, the last one repeats once they
    /// run out, and an empty list connects every time.
    connects: []const ?DriverError = &.{},
    /// How long a `connect` takes before its result: until then `close`
    /// ends it with `Closed`, its deadline with `DeadlineExceeded` and the
    /// cancelation of its task with `Cancelled`.
    connect_delay: Io.Duration = .zero,
    /// Holds `ping` and every data operation, once journaled.
    gate: ?*Gate = null,
};

/// The answer of the next data operation of a client: `find`,
/// `aggregate`, the writes, `count`, `createIndexes` or `command`. A reply
/// of another kind than the operation's is `ProtocolViolation`.
pub const Reply = union(enum) {
    /// `find` and `aggregate`: the documents of the cursor.
    documents: []const bson.RawDocument,
    /// `insert` (`inserted`), `update` (`matched`, `modified` and
    /// `upserted_id`) and `delete` (`deleted`).
    write: struct { inserted: u64 = 0, matched: u64 = 0, modified: u64 = 0, deleted: u64 = 0, upserted_id: ?bson.Value = null },
    count: u64,
    /// `command`: the server's reply; `createIndexes` takes it as a success.
    command: bson.RawDocument,
    /// Any operation: its error, with the code, the index and the text of
    /// its diagnostics.
    failure: struct { err: DriverError, code: ?i32 = null, index: ?usize = null, message: []const u8 = "" },
};

/// A call that went out, as the journal keeps it: a copy, with every slice
/// and document, until the fake's `deinit`.
pub const Request = struct { uri: []const u8, call: Call };

pub const Call = union(enum) {
    connect,
    ping,
    close,
    insert: Client.InsertRequest,
    update: Client.UpdateRequest,
    delete: Client.DeleteRequest,
    find: Client.FindRequest,
    aggregate: Client.AggregateRequest,
    count: Client.CountRequest,
    create_indexes: Client.IndexRequest,
    command: Client.CommandRequest,
};

pub const Counts = struct {
    /// The clients that `open` made.
    opened: usize,
    /// The clients whose `connect` succeeded, each once.
    connected: usize,
    /// The clients closed, each once.
    closed: usize,
    /// The calls of `close`, the second one of a client too.
    close_calls: usize,
    /// The clients that `deinit` freed.
    freed: usize,
    /// The cursors that `find` and `aggregate` made and `deinit` did not
    /// free yet.
    cursors: usize,
};

/// Holds the calls of the clients whose plan names it: `ping` and every
/// data operation, once journaled. A call at the gate ends when it opens
/// (then with its reply), at `close` of its client (`Closed`), at its
/// deadline (`Timeout`) or at the cancelation of its task (`Interrupted`;
/// the task stays canceled). Declare it as `.{}`, and keep it while calls
/// may wait at it.
pub const Gate = struct {
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    opened: bool = false,
    count: usize = 0,

    /// Lets the calls at the gate go, and every later one: the gate stays
    /// open.
    pub fn open(g: *Gate, io: Io) void {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        g.opened = true;
        g.changed.broadcast(io);
    }

    /// How many calls wait at the gate.
    pub fn waiting(g: *Gate, io: Io) usize {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        return g.count;
    }

    /// Until `n` calls wait here; error.Timeout after 5 s on the .awake clock.
    pub fn waitFor(g: *Gate, io: Io, n: usize) error{Timeout}!void {
        const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);
        while (g.count < n) {
            if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) return error.Timeout;
            // A timeout, or a wake for another change: the loop looks again.
            g.changed.waitTimeout(io, &g.mutex, .{ .deadline = give_up.withClock(.awake) }) catch {};
        }
    }
};

/// A fake with no plans, no replies and an empty journal, in `gpa`.
pub fn init(gpa: Allocator) FakeDriver {
    return .{ .gpa = gpa, .journal_arena = .init(gpa) };
}

/// Frees the plans, the replies and the journal; every client of the fake
/// is freed first.
pub fn deinit(f: *FakeDriver) void {
    var plans = f.plans.load(.acquire);
    while (plans) |node| {
        plans = node.next;
        node.arena.deinit();
        f.gpa.destroy(node);
    }
    var replies = f.replies.load(.acquire);
    while (replies) |node| {
        replies = node.next;
        node.arena.deinit();
        f.gpa.destroy(node);
    }
    f.entries.deinit(f.gpa);
    f.journal_arena.deinit();
    f.* = undefined;
}

/// The driver of the fake, named "fake".
pub fn driver(f: *FakeDriver) odm.Driver {
    return .init(f);
}

/// Replaces the plan of `uri`; a client looks its plan up at each call.
pub fn plan(f: *FakeDriver, uri: []const u8, p: Plan) Allocator.Error!void {
    const node = try f.gpa.create(PlanNode);
    node.* = .{ .arena = .init(f.gpa), .plan = p };
    errdefer {
        node.arena.deinit();
        f.gpa.destroy(node);
    }
    const a = node.arena.allocator();
    node.uri = try a.dupe(u8, uri);
    node.plan.connects = try a.dupe(?DriverError, p.connects);
    push(PlanNode, &f.plans, node);
}

/// Queues the reply of the next data operation of any client of `uri`.
pub fn reply(f: *FakeDriver, uri: []const u8, r: Reply) Allocator.Error!void {
    const node = try f.gpa.create(ReplyNode);
    node.* = .{ .arena = .init(f.gpa), .reply = .{ .count = 0 } };
    errdefer {
        node.arena.deinit();
        f.gpa.destroy(node);
    }
    const a = node.arena.allocator();
    node.uri = try a.dupe(u8, uri);
    node.reply = try copyReply(a, r);
    push(ReplyNode, &f.replies, node);
}

/// The calls that went out, in order. Valid until the next call into the
/// fake.
pub fn journal(f: *FakeDriver, io: Io) []const Request {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    return f.entries.items;
}

/// The counts of the clients and of their cursors so far.
pub fn counts(f: *FakeDriver, io: Io) Counts {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    return .{
        .opened = f.opened.load(.monotonic),
        .connected = f.connected.load(.monotonic),
        .closed = f.closed.load(.monotonic),
        .close_calls = f.close_calls.load(.monotonic),
        .freed = f.freed.load(.monotonic),
        .cursors = f.cursors.load(.monotonic),
    };
}

/// `odm.Driver.open`: a client of `config.uri`, unless the uri is empty
/// (`InvalidArgument`) or its plan refuses it.
pub fn open(f: *FakeDriver, io: Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!Client {
    _ = io;
    const d = config.diagnostics;
    if (d) |x| x.* = .{};
    if (config.uri.len == 0) return fail(d, error.InvalidArgument, "the uri is empty", .{});
    if (f.planOf(config.uri)) |node| {
        if (node.plan.open) |err| return fail(d, err, "the plan of the fake refuses to open a client: {t}", .{err});
    }
    const c = try f.gpa.create(FakeClient);
    errdefer f.gpa.destroy(c);
    c.* = .{ .fake = f, .uri = try f.gpa.dupe(u8, config.uri) };
    _ = f.opened.fetchAdd(1, .monotonic);
    return .init(c);
}

const PlanNode = struct {
    next: ?*PlanNode = null,
    arena: std.heap.ArenaAllocator,
    uri: []const u8 = "",
    plan: Plan,
    /// How many connects the plan answered, under the mutex.
    connects_made: usize = 0,

    /// The result of the next connect under the plan; null is a success.
    fn nextConnect(node: *PlanNode) ?DriverError {
        const results = node.plan.connects;
        if (results.len == 0) return null;
        defer node.connects_made += 1;
        return results[@min(node.connects_made, results.len - 1)];
    }
};

const ReplyNode = struct {
    next: ?*ReplyNode = null,
    arena: std.heap.ArenaAllocator,
    uri: []const u8 = "",
    reply: Reply,
    /// An operation took the reply, under the mutex.
    taken: bool = false,
};

/// Pushes `node` in front of the list at `head`. A node does not change
/// once it is in, but for the fields that the mutex guards, so readers walk
/// the list without a lock.
fn push(comptime Node: type, head: *std.atomic.Value(?*Node), node: *Node) void {
    var first = head.load(.acquire);
    while (true) {
        node.next = first;
        first = head.cmpxchgWeak(first, node, .acq_rel, .acquire) orelse return;
    }
}

/// The newest plan of `uri`, or null for none.
fn planOf(f: *FakeDriver, uri: []const u8) ?*PlanNode {
    var it = f.plans.load(.acquire);
    while (it) |node| : (it = node.next) {
        if (std.mem.eql(u8, node.uri, uri)) return node;
    }
    return null;
}

/// The oldest reply of `uri` that no operation took, now taken; null for
/// none.
fn take(f: *FakeDriver, io: Io, uri: []const u8) ?*const Reply {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    var oldest: ?*ReplyNode = null;
    var it = f.replies.load(.acquire);
    while (it) |node| : (it = node.next) {
        if (!node.taken and std.mem.eql(u8, node.uri, uri)) oldest = node;
    }
    const node = oldest orelse return null;
    node.taken = true;
    return &node.reply;
}

/// Puts a copy of `call` in the journal.
fn record(f: *FakeDriver, io: Io, uri: []const u8, call: Call) Allocator.Error!void {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    const a = f.journal_arena.allocator();
    const entry: Request = .{ .uri = try a.dupe(u8, uri), .call = try copyCall(a, call) };
    try f.entries.append(f.gpa, entry);
}

/// A client of the fake: one connection string.
const FakeClient = struct {
    fake: *FakeDriver,
    uri: []const u8,
    connected: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    in_flight: std.atomic.Value(usize) = .init(0),
    at_gate: std.atomic.Value(usize) = .init(0),
    /// Set by `close`: it ends a `connect` in its delay.
    closing: Io.Event = .unset,
    /// The calls at a gate, under the fake's mutex: `close` wakes them.
    waiters: std.DoublyLinkedList = .{},

    pub const capabilities: odm.Capabilities = .{ .aggregate = true, .count = true, .indexes = true, .command = true };

    pub fn connect(c: *FakeClient, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
        if (d) |x| x.* = .{};
        if (c.closed.load(.acquire)) return fail(d, error.Closed, "the client is closed", .{});
        try checkContext(io, ctx, d);
        const f = c.fake;
        const node = f.planOf(c.uri);
        try f.record(io, c.uri, .connect);
        _ = c.in_flight.fetchAdd(1, .monotonic);
        defer _ = c.in_flight.fetchSub(1, .monotonic);
        if (c.connected.load(.acquire)) return;
        if (node) |n| if (n.plan.connect_delay.nanoseconds > 0) try c.delay(io, n.plan.connect_delay, ctx, d);
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        if (c.closed.load(.acquire)) return fail(d, error.Closed, "the client was closed while it connected", .{});
        if (node) |n| if (n.nextConnect()) |err| return fail(d, err, "the plan of the fake fails this connect with {t}", .{err});
        if (!c.connected.swap(true, .acq_rel)) _ = f.connected.fetchAdd(1, .monotonic);
    }

    pub fn ping(c: *FakeClient, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
        const gate = try c.begin(io, ctx, d, .ping);
        defer c.end();
        try c.pass(io, gate, ctx, d);
    }

    pub fn close(c: *FakeClient, io: Io) void {
        const f = c.fake;
        // Out of memory, the call stays out of the journal: close cannot fail.
        f.record(io, c.uri, .close) catch {};
        _ = f.close_calls.fetchAdd(1, .monotonic);
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        if (c.closed.swap(true, .acq_rel)) return;
        _ = f.closed.fetchAdd(1, .monotonic);
        c.closing.set(io);
        var it = c.waiters.first;
        while (it) |node| : (it = node.next) {
            const waiter: *Waiter = @fieldParentPtr("node", node);
            waiter.gate.mutex.lockUncancelable(io);
            defer waiter.gate.mutex.unlock(io);
            waiter.gate.changed.broadcast(io);
        }
    }

    pub fn deinit(c: *FakeClient) void {
        const f = c.fake;
        f.gpa.free(c.uri);
        f.gpa.destroy(c);
        _ = f.freed.fetchAdd(1, .monotonic);
    }

    pub fn stats(c: *FakeClient) ?Client.PoolStats {
        const live = c.connected.load(.acquire) and !c.closed.load(.acquire);
        return .{
            .connections = @intFromBool(live),
            .idle = 0,
            .in_use = c.in_flight.load(.monotonic),
            .waiting = c.at_gate.load(.monotonic),
        };
    }

    pub fn insert(c: *FakeClient, io: Io, ctx: core.Context, request: *const Client.InsertRequest, options: Client.CallOptions) DriverError!Client.InsertResult {
        const d = options.diagnostics;
        const gate = try c.begin(io, ctx, d, .{ .insert = request.* });
        defer c.end();
        const r = try c.answer(io, gate, ctx, d) orelse return .{ .inserted = 0 };
        return switch (r.*) {
            .write => |w| .{ .inserted = w.inserted },
            else => wrongReply(d, r, "insert"),
        };
    }

    pub fn update(c: *FakeClient, io: Io, ctx: core.Context, request: *const Client.UpdateRequest, options: Client.CallOptions) DriverError!Client.UpdateResult {
        const d = options.diagnostics;
        const gate = try c.begin(io, ctx, d, .{ .update = request.* });
        defer c.end();
        const r = try c.answer(io, gate, ctx, d) orelse return .{ .matched = 0, .modified = 0 };
        const w = switch (r.*) {
            .write => |write| write,
            else => return wrongReply(d, r, "update"),
        };
        return .{
            .matched = w.matched,
            .modified = w.modified,
            .upserted_id = if (w.upserted_id) |id| try dupeValue(options.allocator, id) else null,
        };
    }

    pub fn delete(c: *FakeClient, io: Io, ctx: core.Context, request: *const Client.DeleteRequest, options: Client.CallOptions) DriverError!Client.DeleteResult {
        const d = options.diagnostics;
        const gate = try c.begin(io, ctx, d, .{ .delete = request.* });
        defer c.end();
        const r = try c.answer(io, gate, ctx, d) orelse return .{ .deleted = 0 };
        return switch (r.*) {
            .write => |w| .{ .deleted = w.deleted },
            else => wrongReply(d, r, "delete"),
        };
    }

    pub fn find(c: *FakeClient, io: Io, ctx: core.Context, request: *const Client.FindRequest, options: Client.CallOptions) DriverError!odm.RawCursor {
        const d = options.diagnostics;
        const gate = try c.begin(io, ctx, d, .{ .find = request.* });
        defer c.end();
        return c.openCursor(io, gate, ctx, d, "find");
    }

    pub fn aggregate(c: *FakeClient, io: Io, ctx: core.Context, request: *const Client.AggregateRequest, options: Client.CallOptions) DriverError!odm.RawCursor {
        const d = options.diagnostics;
        const gate = try c.begin(io, ctx, d, .{ .aggregate = request.* });
        defer c.end();
        return c.openCursor(io, gate, ctx, d, "aggregate");
    }

    pub fn count(c: *FakeClient, io: Io, ctx: core.Context, request: *const Client.CountRequest, options: Client.CallOptions) DriverError!u64 {
        const d = options.diagnostics;
        const gate = try c.begin(io, ctx, d, .{ .count = request.* });
        defer c.end();
        const r = try c.answer(io, gate, ctx, d) orelse return 0;
        return switch (r.*) {
            .count => |n| n,
            else => wrongReply(d, r, "count"),
        };
    }

    pub fn createIndexes(c: *FakeClient, io: Io, ctx: core.Context, request: *const Client.IndexRequest, options: Client.CallOptions) DriverError!void {
        const d = options.diagnostics;
        const gate = try c.begin(io, ctx, d, .{ .create_indexes = request.* });
        defer c.end();
        const r = try c.answer(io, gate, ctx, d) orelse return;
        switch (r.*) {
            .command => {},
            else => return wrongReply(d, r, "createIndexes"),
        }
    }

    pub fn command(c: *FakeClient, io: Io, ctx: core.Context, request: *const Client.CommandRequest, options: Client.CallOptions) DriverError!bson.RawDocument {
        const d = options.diagnostics;
        const gate = try c.begin(io, ctx, d, .{ .command = request.* });
        defer c.end();
        const answered: bson.RawDocument = if (try c.answer(io, gate, ctx, d)) |r| switch (r.*) {
            .command => |doc| doc,
            else => return wrongReply(d, r, "command"),
        } else ok_reply;
        return .{ .bytes = try options.allocator.dupe(u8, answered.bytes) };
    }

    /// What every call checks before it goes out, then the journal: the
    /// gate of the plan, if any. After it, `end` comes once the call ends.
    fn begin(c: *FakeClient, io: Io, ctx: core.Context, d: ?*Diagnostics, call: Call) DriverError!?*Gate {
        if (d) |x| x.* = .{};
        try checkContext(io, ctx, d);
        if (c.closed.load(.acquire)) return fail(d, error.Closed, "the client is closed", .{});
        if (!c.connected.load(.acquire)) return fail(d, error.Unavailable, "connect has not succeeded", .{});
        try c.fake.record(io, c.uri, call);
        _ = c.in_flight.fetchAdd(1, .monotonic);
        const node = c.fake.planOf(c.uri) orelse return null;
        return node.plan.gate;
    }

    fn end(c: *FakeClient) void {
        _ = c.in_flight.fetchSub(1, .monotonic);
    }

    /// The way of a call that went out: through the gate, if any, then the
    /// token, as after a reply.
    fn pass(c: *FakeClient, io: Io, gate: ?*Gate, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
        if (gate) |g| try c.wait(io, g, ctx, d);
        if (ctx.isCancelled()) return fail(d, error.Interrupted, "the token was canceled while the call was out", .{});
    }

    /// The reply of an operation that went out: the next one queued for the
    /// uri, or null for none. A failure is its error, with its diagnostics.
    fn answer(c: *FakeClient, io: Io, gate: ?*Gate, ctx: core.Context, d: ?*Diagnostics) DriverError!?*const Reply {
        try c.pass(io, gate, ctx, d);
        const r = c.fake.take(io, c.uri) orelse return null;
        switch (r.*) {
            .failure => |failure| {
                if (d) |x| x.set(failure.code, failure.index, "{s}", .{failure.message});
                return failure.err;
            },
            else => return r,
        }
    }

    fn openCursor(c: *FakeClient, io: Io, gate: ?*Gate, ctx: core.Context, d: ?*Diagnostics, comptime operation: []const u8) DriverError!odm.RawCursor {
        const documents: []const bson.RawDocument = if (try c.answer(io, gate, ctx, d)) |r| switch (r.*) {
            .documents => |list| list,
            else => return wrongReply(d, r, operation),
        } else &.{};
        const cursor = try c.fake.gpa.create(FakeCursor);
        cursor.* = .{ .client = c, .documents = documents };
        _ = c.fake.cursors.fetchAdd(1, .monotonic);
        return .init(cursor);
    }

    /// Waits at `gate` until it opens, the client closes, the deadline
    /// passes or the task is canceled.
    fn wait(c: *FakeClient, io: Io, gate: *Gate, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
        const f = c.fake;
        var waiter: Waiter = .{ .gate = gate };
        f.mutex.lockUncancelable(io);
        c.waiters.append(&waiter.node);
        f.mutex.unlock(io);
        defer {
            f.mutex.lockUncancelable(io);
            c.waiters.remove(&waiter.node);
            f.mutex.unlock(io);
        }
        _ = c.at_gate.fetchAdd(1, .monotonic);
        defer _ = c.at_gate.fetchSub(1, .monotonic);
        gate.mutex.lockUncancelable(io);
        defer gate.mutex.unlock(io);
        gate.count += 1;
        defer gate.count -= 1;
        gate.changed.broadcast(io);
        while (true) {
            if (c.closed.load(.acquire)) return fail(d, error.Closed, "the client was closed while the call waited at a gate", .{});
            if (gate.opened) return;
            if (ctx.deadline) |deadline| {
                if (deadline.isExpired(Io.Clock.awake.now(io))) return fail(d, error.Timeout, "the deadline passed while the call waited at a gate", .{});
            }
            gate.changed.waitTimeout(io, &gate.mutex, step(io, ctx.deadline, null)) catch |err| switch (err) {
                // The deadline, a step of a far one, or a wake for another
                // change: the loop looks again.
                error.Timeout => {},
                error.Canceled => {
                    io.recancel();
                    return fail(d, error.Interrupted, "the task was canceled while the call waited at a gate", .{});
                },
            };
        }
    }

    /// The delay of a connect: it ends early at `close`, at the deadline
    /// and at the cancelation of the task.
    fn delay(c: *FakeClient, io: Io, duration: Io.Duration, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
        const until = Io.Clock.awake.now(io).addDuration(duration);
        while (true) {
            if (c.closed.load(.acquire)) return fail(d, error.Closed, "the client was closed while it connected", .{});
            const now = Io.Clock.awake.now(io);
            if (ctx.deadline) |deadline| {
                if (deadline.isExpired(now)) return fail(d, error.DeadlineExceeded, "the deadline passed while the client connected", .{});
            }
            if (now.nanoseconds >= until.nanoseconds) return;
            c.closing.waitTimeout(io, step(io, ctx.deadline, until)) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => {
                    io.recancel();
                    return fail(d, error.Cancelled, "the task was canceled while the client connected", .{});
                },
            };
        }
    }
};

/// A call of a client at a gate.
const Waiter = struct {
    gate: *Gate,
    node: std.DoublyLinkedList.Node = .{},
};

/// A cursor over the documents of a reply, which the fake keeps until its
/// `deinit`.
const FakeCursor = struct {
    client: *FakeClient,
    documents: []const bson.RawDocument,
    at: usize = 0,

    pub fn next(cursor: *FakeCursor, io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!?bson.RawDocument {
        if (d) |x| x.* = .{};
        if (cursor.client.closed.load(.acquire)) return fail(d, error.Closed, "the client of the cursor is closed", .{});
        try checkContext(io, ctx, d);
        if (cursor.at == cursor.documents.len) return null;
        defer cursor.at += 1;
        return cursor.documents[cursor.at];
    }

    pub fn deinit(cursor: *FakeCursor, io: Io) void {
        _ = io;
        const f = cursor.client.fake;
        f.gpa.destroy(cursor);
        _ = f.cursors.fetchSub(1, .monotonic);
    }
};

const ok_reply = bson.literal(.{ .ok = 1.0 });

/// `err`, with the text in `d`.
fn fail(d: ?*Diagnostics, err: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
    if (d) |x| x.set(null, null, fmt, args);
    return err;
}

/// Rules 4 and 5 of the contract before a call goes out: `DeadlineExceeded`
/// with less than 1 ms left, else `Cancelled` for a canceled token.
fn checkContext(io: Io, ctx: core.Context, d: ?*Diagnostics) DriverError!void {
    if (ctx.remaining(Io.Clock.awake.now(io))) |left| {
        if (left.nanoseconds < std.time.ns_per_ms) return fail(d, error.DeadlineExceeded, "less than 1 ms was left of the deadline before the call", .{});
    }
    if (ctx.isCancelled()) return fail(d, error.Cancelled, "the token was canceled before the call", .{});
}

fn wrongReply(d: ?*Diagnostics, r: *const Reply, comptime operation: []const u8) error{ProtocolViolation} {
    return fail(d, error.ProtocolViolation, "the reply queued for this uri is '{t}', which '" ++ operation ++ "' does not take", .{r.*});
}

/// Where the next wait ends: at `deadline` or at `until`, whichever comes
/// first, and an hour from now at the most, since some `std.Io`
/// implementations overflow on a far one.
fn step(io: Io, deadline: ?core.Deadline, until: ?Io.Timestamp) Io.Timeout {
    var end = Io.Clock.awake.now(io).addDuration(.fromSeconds(3600));
    if (deadline) |x| {
        if (x.expires.nanoseconds < end.nanoseconds) end = x.expires;
    }
    if (until) |x| {
        if (x.nanoseconds < end.nanoseconds) end = x;
    }
    return .{ .deadline = end.withClock(.awake) };
}

fn copyCall(a: Allocator, call: Call) Allocator.Error!Call {
    switch (call) {
        .connect, .ping, .close => return call,
        .insert => |r| {
            var copy = r;
            copy.ns = try copyNamespace(a, r.ns);
            copy.documents = try copyDocuments(a, r.documents);
            return .{ .insert = copy };
        },
        .update => |r| {
            var copy = r;
            copy.ns = try copyNamespace(a, r.ns);
            copy.filter = try copyDocument(a, r.filter);
            copy.update = try copyDocument(a, r.update);
            return .{ .update = copy };
        },
        .delete => |r| {
            var copy = r;
            copy.ns = try copyNamespace(a, r.ns);
            copy.filter = try copyDocument(a, r.filter);
            return .{ .delete = copy };
        },
        .find => |r| {
            var copy = r;
            copy.ns = try copyNamespace(a, r.ns);
            copy.filter = try copyDocument(a, r.filter);
            if (r.sort) |doc| copy.sort = try copyDocument(a, doc);
            if (r.projection) |doc| copy.projection = try copyDocument(a, doc);
            return .{ .find = copy };
        },
        .aggregate => |r| {
            var copy = r;
            copy.ns = try copyNamespace(a, r.ns);
            copy.pipeline = try copyDocuments(a, r.pipeline);
            return .{ .aggregate = copy };
        },
        .count => |r| {
            var copy = r;
            copy.ns = try copyNamespace(a, r.ns);
            copy.filter = try copyDocument(a, r.filter);
            return .{ .count = copy };
        },
        .create_indexes => |r| {
            var copy = r;
            copy.ns = try copyNamespace(a, r.ns);
            const indexes = try a.alloc(Client.IndexSpec, r.indexes.len);
            for (indexes, r.indexes) |*to, from| {
                to.* = from;
                to.name = try a.dupe(u8, from.name);
                to.keys = try copyDocument(a, from.keys);
            }
            copy.indexes = indexes;
            return .{ .create_indexes = copy };
        },
        .command => |r| {
            var copy = r;
            copy.database = try a.dupe(u8, r.database);
            copy.body = try copyDocument(a, r.body);
            return .{ .command = copy };
        },
    }
}

fn copyReply(a: Allocator, r: Reply) Allocator.Error!Reply {
    switch (r) {
        .documents => |list| return .{ .documents = try copyDocuments(a, list) },
        .write => |w| {
            var copy = w;
            if (w.upserted_id) |id| copy.upserted_id = try dupeValue(a, id);
            return .{ .write = copy };
        },
        .count => return r,
        .command => |doc| return .{ .command = try copyDocument(a, doc) },
        .failure => |x| {
            var copy = x;
            copy.message = try a.dupe(u8, x.message);
            return .{ .failure = copy };
        },
    }
}

fn copyNamespace(a: Allocator, at: Client.Namespace) Allocator.Error!Client.Namespace {
    return .{ .database = try a.dupe(u8, at.database), .collection = try a.dupe(u8, at.collection) };
}

fn copyDocument(a: Allocator, doc: bson.RawDocument) Allocator.Error!bson.RawDocument {
    return .{ .bytes = try a.dupe(u8, doc.bytes) };
}

fn copyDocuments(a: Allocator, list: []const bson.RawDocument) Allocator.Error![]const bson.RawDocument {
    const copy = try a.alloc(bson.RawDocument, list.len);
    for (copy, list) |*to, from| to.* = try copyDocument(a, from);
    return copy;
}

/// A copy of `value` whose strings, documents and bytes are allocations of
/// their own in `a`, as `upserted_id` is in the allocator of the call.
fn dupeValue(a: Allocator, value: bson.Value) Allocator.Error!bson.Value {
    return switch (value) {
        .string => |text| .{ .string = try a.dupe(u8, text) },
        .javascript => |code| .{ .javascript = try a.dupe(u8, code) },
        .symbol => |symbol| .{ .symbol = try a.dupe(u8, symbol) },
        .document => |doc| .{ .document = try copyDocument(a, doc) },
        .array => |doc| .{ .array = try copyDocument(a, doc) },
        .binary => |binary| .{ .binary = .{ .subtype = binary.subtype, .bytes = try a.dupe(u8, binary.bytes) } },
        .regex => |regex| regex: {
            const pattern = try a.dupe(u8, regex.pattern);
            errdefer a.free(pattern);
            break :regex .{ .regex = .{ .pattern = pattern, .options = try a.dupe(u8, regex.options) } };
        },
        .db_pointer => |pointer| .{ .db_pointer = .{ .namespace = try a.dupe(u8, pointer.namespace), .id = pointer.id } },
        .javascript_with_scope => |code| code: {
            const text = try a.dupe(u8, code.code);
            errdefer a.free(text);
            break :code .{ .javascript_with_scope = .{ .code = text, .scope = try copyDocument(a, code.scope) } };
        },
        else => value,
    };
}
