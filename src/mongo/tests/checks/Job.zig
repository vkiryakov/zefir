//! One check of the checks S and L on its way, and what the checks share:
//! the client of the check, its scripted server, calls in tasks of their
//! own, and allocators that count.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const core = @import("core");
const mongo = @import("mongo");
const bson = mongo.bson;
/// The client of a check, as the checks hold it.
const Client = *mongo.Client;
const Cursor = mongo.Cursor;
const Script = mongo.testing.Script;
const FakeServer = mongo.testing.FakeServer;
const sleepAtLeast = mongo.testing.sleepAtLeast;
const checks = @import("../checks.zig");
const Job = @This();

io: Io,
/// The caller's allocator, for what the check makes itself: scripts,
/// servers, documents, replies.
gpa: Allocator,
/// Counts what the client of the check holds.
client_gpa: Allocator,
/// The messages of the check. Only the check's own task writes to it.
arena: Allocator,
options: checks.Options,
failure: ?[]const u8 = null,
/// The client of the check, once `scripted` or `live` has set it up.
client: mongo.Client = undefined,
/// The scripted server of the check, until `end`.
stage: ?*Stage = null,
/// Whether the client is set up and not freed yet.
up: bool = false,

/// What a scripted server says about itself in hello.
pub const Hello = @FieldType(Script, "hello");

pub const Error = error{ CheckFailed, OutOfMemory };

pub fn now(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

/// `n` milliseconds, stretched by `Options.time_scale`.
pub fn ms(job: *const Job, n: i64) Io.Duration {
    return .fromMilliseconds(n * job.scale());
}

pub fn scale(job: *const Job) i64 {
    return @max(job.options.time_scale, 1);
}

/// A context whose deadline is `n` milliseconds away, stretched.
pub fn within(job: *const Job, n: i64) mongo.OperationContext {
    return .of(core.Context.root.withDeadline(.after(now(job.io), job.ms(n))));
}

pub fn fail(job: *Job, comptime fmt: []const u8, args: anytype) Error {
    job.failure = try std.fmt.allocPrint(job.arena, fmt, args);
    return error.CheckFailed;
}

pub fn expect(job: *Job, holds: bool, comptime fmt: []const u8, args: anytype) Error!void {
    if (!holds) return job.fail(fmt, args);
}

/// The payload of `result`; its error fails the check.
pub fn need(job: *Job, result: anytype, comptime what: []const u8) Error!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| job.fail(what ++ " returned error.{t}", .{err});
}

/// Fails unless `result` is `expected`; a success is freed.
pub fn expectError(job: *Job, result: anytype, expected: mongo.Error, comptime what: []const u8) Error!void {
    const value = result catch |err| {
        if (err != expected) return job.fail(what ++ " returned error.{t}, not error.{t}", .{ err, expected });
        return;
    };
    job.discard(value);
    return job.fail(what ++ " succeeded, not error.{t}", .{expected});
}

/// Frees what a call of a check returned: a reply, a cursor or the result
/// of a write whose allocator was `job.gpa`.
pub fn discard(job: *Job, value: anytype) void {
    switch (@TypeOf(value)) {
        bson.OwnedDocument => value.deinit(),
        // A document of a cursor is borrowed.
        ?bson.RawDocument => {},
        Cursor => value.deinit(job.io),
        mongo.WriteResult => {
            var result = value;
            result.deinit(job.gpa);
        },
        else => @compileError("discard: " ++ @typeName(@TypeOf(value))),
    }
}

/// A document of the check, in `job.gpa`.
pub fn encode(job: *Job, value: anytype) Error!bson.OwnedDocument {
    return job.encodeIn(job.gpa, value);
}

/// A document of the check, in `allocator`.
pub fn encodeIn(job: *Job, allocator: Allocator, value: anytype) Error!bson.OwnedDocument {
    return bson.encode(allocator, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => job.fail("a document of the check is not valid BSON", .{}),
    };
}

/// Sleeps in the check's task, which nothing cancels, for `duration` at
/// least: a check that waits out a deadline must not wake up before it.
pub fn pause(job: *Job, duration: Io.Duration) void {
    sleepAtLeast(job.io, duration) catch {};
}

/// Fails unless the call of `caller` ended with `expected`.
pub fn expectCallError(job: *Job, caller: *const Caller, expected: mongo.Error, comptime what: []const u8) Error!void {
    const err = caller.err orelse return job.fail(what ++ " succeeded, not error.{t}", .{expected});
    if (err != expected) return job.fail(what ++ " returned error.{t}, not error.{t}", .{ err, expected });
}

/// Runs `function(args)` in a task of its own and waits for it, so that a
/// check can act from another task than its own.
pub fn inTask(job: *Job, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Error!void {
    var future = job.io.concurrent(function, args) catch |err| return job.fail("no task: io.concurrent returned error.{t}", .{err});
    future.await(job.io);
}

/// Command `index` of the journal named `name`, from 0.
pub fn received(job: *Job, script: *Script, name: []const u8, index: usize) Error!Script.Entry {
    const io = job.io;
    var seen: usize = 0;
    for (0..script.received(io)) |i| {
        // The journal only grows: command i is there.
        const entry = script.entry(io, i) catch break;
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (seen == index) return entry;
        seen += 1;
    }
    return job.fail("the server got {d} command(s) named {s}, and the check expected at least {d}", .{ seen, name, index + 1 });
}

/// Waits until the journal holds `n` commands named `name`, for 10 s at
/// most, stretched.
pub fn awaitReceived(job: *Job, script: *Script, name: []const u8, n: usize) Error!void {
    const deadline: core.Deadline = .after(now(job.io), job.ms(10_000));
    while (true) {
        const got = script.count(job.io, name);
        if (got >= n) return;
        if (deadline.isExpired(now(job.io))) return job.fail("the server got {d} command(s) named {s} in {d} s, not {d}", .{ got, name, 10 * job.scale(), n });
        job.pause(.fromMilliseconds(1));
    }
}

/// Fails unless `got`, a command as the server read it, is `written` as the
/// caller gave it, with each element unchanged and in its place, plus
/// `$db` = `database` and, of the driver's own fields, only those named in
/// `extra`.
pub fn expectSent(job: *Job, got: bson.RawDocument, written: bson.RawDocument, database: []const u8, extra: []const []const u8, comptime what: []const u8) Error!void {
    var caller: std.ArrayList(Element) = .empty;
    defer caller.deinit(job.gpa);
    var has_db = false;
    var it = got.iterator();
    while (true) {
        const start = it.pos;
        const element = (it.next() catch return job.fail(what ++ " came as invalid BSON", .{})) orelse break;
        if (std.mem.eql(u8, element.key, "$db")) {
            const db = if (element.value == .string) element.value.string else "";
            try job.expect(std.mem.eql(u8, db, database), what ++ " came with $db \"{s}\", not \"{s}\"", .{ db, database });
            has_db = true;
            continue;
        }
        if (isIn(extra, element.key)) continue;
        try caller.append(job.gpa, .{ .key = element.key, .bytes = got.bytes[start..it.pos] });
    }
    try job.expect(has_db, what ++ " came without $db", .{});
    var original = written.iterator();
    for (caller.items, 0..) |sent, i| {
        const start = original.pos;
        const element = (original.next() catch null) orelse
            return job.fail(what ++ " came with '{s}', which the caller did not write", .{sent.key});
        if (!std.mem.eql(u8, element.key, sent.key)) {
            return job.fail(what ++ " came with '{s}' as element {d}, where the caller wrote '{s}'", .{ sent.key, i, element.key });
        }
        try job.expect(std.mem.eql(u8, sent.bytes, written.bytes[start..original.pos]), what ++ " came with '{s}' changed", .{sent.key});
    }
    if (original.next() catch null) |missing| return job.fail(what ++ " came without '{s}', which the caller wrote", .{missing.key});
}

/// An element of a document: its key and its bytes, type byte included.
const Element = struct { key: []const u8, bytes: []const u8 };

pub fn isIn(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// A call of `runCommand` in a task of its own, which the check may cancel.
/// The reply comes from `job.gpa`; `deinit` frees it.
pub const Caller = struct {
    job: *Job,
    client: Client,
    command: mongo.Command,
    op: mongo.OperationContext = .of(.root),
    reply: ?bson.OwnedDocument = null,
    err: ?mongo.Error = null,
    diagnostics: mongo.Diagnostics = .{},
    ended: Io.Timestamp = .zero,
    /// After the call returned, `io.checkCancel()` in its task saw a
    /// cancelation.
    kept_cancel: bool = false,
    future: ?Io.Future(void) = null,

    pub fn init(job: *Job, client: Client, command: mongo.Command) Caller {
        return .{ .job = job, .client = client, .command = command };
    }

    pub fn begin(c: *Caller) Error!void {
        c.future = c.job.io.concurrent(task, .{c}) catch |err| return c.job.fail("no task for a call: io.concurrent returned error.{t}", .{err});
    }

    fn task(c: *Caller) void {
        const io = c.job.io;
        if (c.client.runCommand(io, c.op, c.command, .{ .allocator = c.job.gpa, .diagnostics = &c.diagnostics })) |reply| {
            c.reply = reply;
        } else |err| c.err = err;
        c.ended = now(io);
        c.kept_cancel = if (io.checkCancel()) |_| false else |_| true;
    }

    /// Waits until the call has returned.
    pub fn join(c: *Caller) void {
        if (c.future) |*future| future.await(c.job.io);
    }

    /// Cancels the task and waits until the call has returned.
    pub fn cancel(c: *Caller) void {
        if (c.future) |*future| future.cancel(c.job.io);
    }

    pub fn deinit(c: *Caller) void {
        c.cancel();
        if (c.reply) |reply| reply.deinit();
        c.reply = null;
    }
};

/// The allocator of the options of one call. It counts the allocations the
/// client holds of it, and those it makes after the call returned, which
/// its rules forbid. Put it over an arena of the check, so that what a
/// broken client leaves goes with the arena.
pub const Fence = struct {
    parent: Allocator,
    live: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    late_uses: std.atomic.Value(u32) = .init(0),

    pub fn allocator(f: *Fence) Allocator {
        return .{ .ptr = f, .vtable = &vtable };
    }

    /// The call returned: what the client takes from now on is late.
    pub fn close(f: *Fence) void {
        f.closed.store(true, .release);
    }

    /// How many allocations are held.
    pub fn held(f: *const Fence) usize {
        return f.live.load(.acquire);
    }

    /// How many times the client took memory after `close`.
    pub fn late(f: *const Fence) u32 {
        return f.late_uses.load(.acquire);
    }

    fn touch(f: *Fence) void {
        if (f.closed.load(.acquire)) _ = f.late_uses.fetchAdd(1, .monotonic);
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        f.touch();
        const memory = f.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = f.live.fetchAdd(1, .monotonic);
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        f.touch();
        return f.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        f.touch();
        return f.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        f.parent.rawFree(memory, alignment, ret_addr);
        _ = f.live.fetchSub(1, .monotonic);
    }
};

/// Starts the scripted server of the check, serving `handler` with `hello`,
/// and connects a fresh client to it. `end` undoes both. When the client
/// cannot connect, the server is stopped before the check returns: the
/// stage lives in the check's frame, and the check has no `end` deferred
/// yet.
pub fn scripted(job: *Job, stage: *Stage, handler: Script.Handler, hello: Hello) Error!Client {
    stage.start(job.io, job.gpa, handler, hello) catch |err| return job.fail("the FakeServer of the check did not start: error.{t}", .{err});
    job.stage = stage;
    errdefer {
        stage.stop(job.io);
        job.stage = null;
    }
    try job.connect(stage.uri);
    return &job.client;
}

/// Connects a fresh client to the live mongod of `Options.live`. `end`
/// undoes it.
pub fn live(job: *Job) Error!Client {
    try job.connect(job.options.live.?.uri);
    return &job.client;
}

/// A fresh client of `uri`, connected; its memory is counted.
fn connect(job: *Job, uri: []const u8) Error!void {
    var d: mongo.Diagnostics = .{};
    job.client = mongo.Client.init(job.client_gpa, job.io, .{ .uri = uri, .diagnostics = &d }) catch |err|
        return job.fail("Client.init of {s} returned error.{t}: {s}", .{ uri, err, d.message() });
    job.client.connect(job.io, .root, &d) catch |err| {
        job.client.deinit();
        return job.fail("connect to {s} returned error.{t}: {s}", .{ uri, err, d.message() });
    };
    job.up = true;
}

/// `close` of the client, for a check of closing; `end` calls it again.
pub fn close(job: *Job) void {
    job.client.close(job.io);
}

/// Closes and frees the client of the check, then stops its server.
/// Every call of the check has returned, and every cursor is freed.
pub fn end(job: *Job) void {
    if (job.up) {
        job.client.close(job.io);
        job.client.deinit();
        job.up = false;
    }
    if (job.stage) |stage| {
        stage.stop(job.io);
        job.stage = null;
    }
}

/// The scripted server of one check: its script, served by `FakeServer`
/// on loopback. It points into itself: start it in place.
pub const Stage = struct {
    script: Script,
    listener: net.Server,
    server: Io.Future(Io.Cancelable!void),
    uri_buffer: [64]u8,
    uri: []const u8,

    fn start(s: *Stage, io: Io, gpa: Allocator, handler: Script.Handler, hello: Hello) !void {
        s.script = .init(gpa, handler);
        s.script.hello = hello;
        errdefer s.script.deinit();
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.uri = try FakeServer.uri(&s.listener, &s.uri_buffer);
        s.server = try io.concurrent(FakeServer.serve, .{ io, &s.listener, &s.script });
    }

    fn stop(s: *Stage, io: Io) void {
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        s.script.deinit();
    }
};

/// Counts what one check holds of the caller's allocator, so that memory
/// left after `deinit` of its client shows as a leak of that check.
pub const Counting = struct {
    parent: Allocator,
    live: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),

    pub fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        const memory = c.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = c.live.fetchAdd(1, .monotonic);
        _ = c.bytes.fetchAdd(len, .monotonic);
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        if (!c.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        c.moved(memory.len, new_len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        const moved_to = c.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.moved(memory.len, new_len);
        return moved_to;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ptr));
        c.parent.rawFree(memory, alignment, ret_addr);
        _ = c.live.fetchSub(1, .monotonic);
        _ = c.bytes.fetchSub(memory.len, .monotonic);
    }

    fn moved(c: *Counting, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            _ = c.bytes.fetchAdd(new_len - old_len, .monotonic);
        } else {
            _ = c.bytes.fetchSub(old_len - new_len, .monotonic);
        }
    }
};

test "the counting allocator counts what is held, and nothing once it is freed" {
    const testing = std.testing;
    var counting: Counting = .{ .parent = testing.allocator };
    const a = counting.allocator();
    const block = try a.alloc(u8, 16);
    try testing.expectEqual(@as(usize, 1), counting.live.load(.acquire));
    try testing.expectEqual(@as(usize, 16), counting.bytes.load(.acquire));
    a.free(block);
    try testing.expectEqual(@as(usize, 0), counting.live.load(.acquire));
    try testing.expectEqual(@as(usize, 0), counting.bytes.load(.acquire));
}

test "scripted stops the server of a check whose client cannot connect to it, and keeps nothing of either" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var job: Job = .{ .io = testing.io, .gpa = testing.allocator, .client_gpa = testing.allocator, .arena = arena.allocator(), .options = .{} };
    var queue: Script.Queue = .{ .answers = &.{} };
    var stage: Stage = undefined;
    // A mongos, which the client refuses at connect: Unsupported.
    const connected = job.scripted(&stage, queue.handler(), .{ .server_type = .mongos });
    // What the check would have ended; nothing, once scripted cleans up.
    defer job.end();
    try testing.expectError(error.CheckFailed, connected);
    try testing.expect(job.stage == null);
    try testing.expect(!job.up);
    try testing.expectStringStartsWith(job.failure.?, "connect to mongodb://127.0.0.1:");
    try testing.expect(std.mem.find(u8, job.failure.?, "returned error.Unsupported") != null);
}
