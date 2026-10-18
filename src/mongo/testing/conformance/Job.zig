//! One check of `mongo.testing.conformance` on its way, and what the checks
//! share: the harness behind a table of functions, the scripted server of a
//! check, calls in tasks of their own, and allocators that count.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("../../bson.zig");
const wire = @import("../../wire.zig");
const errors = @import("../../contract/errors.zig");
const requests = @import("../../contract/requests.zig");
const results = @import("../../contract/results.zig");
const Client = @import("../../contract/Client.zig");
const Cursor = @import("../../contract/Cursor.zig");
const Script = @import("../Script.zig");
const FakeServer = @import("../FakeServer.zig");
const conformance = @import("../conformance.zig");
const Job = @This();

io: Io,
/// The caller's allocator, for what the suite makes itself: scripts,
/// servers, documents, replies.
gpa: Allocator,
/// Counts what the driver holds: the harness gets it in `setUp`.
driver_gpa: Allocator,
/// The report's arena: the messages of the check. Only the check's own task
/// writes to it.
arena: Allocator,
harness: Harness,
options: conformance.Options,
/// Whether the driver connected to the FakeServer in the probe: it speaks
/// the wire protocol.
on_wire: bool,
failure: ?[]const u8 = null,
notes: std.ArrayList([]const u8) = .empty,
/// The scripted server of the check, until `end`.
stage: ?*Stage = null,
/// Whether a driver is set up and not torn down yet.
up: bool = false,

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
pub fn within(job: *const Job, n: i64) requests.OperationContext {
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
pub fn expectError(job: *Job, result: anytype, expected: errors.Error, comptime what: []const u8) Error!void {
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
        results.WriteResult => {
            var result = value;
            result.deinit(job.gpa);
        },
        else => @compileError("discard: " ++ @typeName(@TypeOf(value))),
    }
}

/// A document of the check, in `job.gpa`.
pub fn encode(job: *Job, value: anytype) Error!bson.OwnedDocument {
    return bson.encode(job.gpa, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBson => job.fail("a document of the check is not valid BSON", .{}),
    };
}

pub fn note(job: *Job, comptime fmt: []const u8, args: anytype) Error!void {
    try job.notes.append(job.arena, try std.fmt.allocPrint(job.arena, fmt, args));
}

/// Sleeps in the check's task, which nothing cancels.
pub fn pause(job: *Job, duration: Io.Duration) void {
    job.io.sleep(duration, .awake) catch {};
}

/// Fails unless the call of `caller` ended with `expected`.
pub fn expectCallError(job: *Job, caller: *const Caller, expected: errors.Error, comptime what: []const u8) Error!void {
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
        const entry = script.entry(io, i);
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
    while (script.count(job.io, name) < n) {
        if (deadline.isExpired(now(job.io))) return job.fail("the server got {d} command(s) named {s} in {d} s, not {d}", .{ script.count(job.io, name), name, 10 * job.scale(), n });
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
    command: requests.Command,
    op: requests.OperationContext = .of(.root),
    reply: ?bson.OwnedDocument = null,
    err: ?errors.Error = null,
    diagnostics: errors.Diagnostics = .{},
    ended: Io.Timestamp = .zero,
    /// After the call returned, `io.checkCancel()` in its task saw a
    /// cancelation.
    kept_cancel: bool = false,
    future: ?Io.Future(void) = null,

    pub fn init(job: *Job, client: Client, command: requests.Command) Caller {
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
/// driver holds of it, and those it makes after the call returned, which
/// the contract forbids. Put it over an arena of the check, so that what a
/// broken driver leaves goes with the arena.
pub const Fence = struct {
    parent: Allocator,
    live: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    late_uses: std.atomic.Value(u32) = .init(0),

    pub fn allocator(f: *Fence) Allocator {
        return .{ .ptr = f, .vtable = &vtable };
    }

    /// The call returned: what the driver takes from now on is late.
    pub fn close(f: *Fence) void {
        f.closed.store(true, .release);
    }

    /// How many allocations are held.
    pub fn held(f: *const Fence) usize {
        return f.live.load(.acquire);
    }

    /// How many times the driver took memory after `close`.
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
/// and sets up a fresh driver on it. `end` undoes both.
pub fn scripted(job: *Job, stage: *Stage, handler: Script.Handler, hello: wire.Hello) Error!Client {
    stage.start(job.io, job.gpa, handler, hello) catch |err| return job.fail("the FakeServer of the check did not start: error.{t}", .{err});
    const client = job.harness.set_up(job.harness.ptr, job.io, job.driver_gpa, .{ .scripted = .{ .uri = stage.uri, .script = &stage.script } }) catch |err| {
        stage.stop(job.io);
        return job.fail("harness.setUp returned error.{t}", .{err});
    };
    job.stage = stage;
    job.up = true;
    return client;
}

/// Sets up a fresh driver on the live mongod of `Options.live`. `end`
/// undoes it.
pub fn live(job: *Job) Error!Client {
    const uri = job.options.live.?.uri;
    const client = job.harness.set_up(job.harness.ptr, job.io, job.driver_gpa, .{ .live = .{ .uri = uri } }) catch |err|
        return job.fail("harness.setUp returned error.{t}", .{err});
    job.up = true;
    return client;
}

/// `close` of the driver, for a check of closing; `end` calls it again.
pub fn close(job: *Job) void {
    job.harness.close(job.harness.ptr, job.io);
}

/// Closes and tears down the driver of the check, then stops its server.
/// Every call of the check has returned, and every cursor is freed.
pub fn end(job: *Job) void {
    if (job.up) {
        job.harness.close(job.harness.ptr, job.io);
        job.harness.tear_down(job.harness.ptr, job.io);
        job.up = false;
    }
    if (job.stage) |stage| {
        stage.stop(job.io);
        job.stage = null;
    }
}

/// The harness behind a pointer and a table of its methods.
pub const Harness = struct {
    ptr: *anyopaque,
    set_up: *const fn (ptr: *anyopaque, io: Io, gpa: Allocator, target: conformance.Target) anyerror!Client,
    close: *const fn (ptr: *anyopaque, io: Io) void,
    tear_down: *const fn (ptr: *anyopaque, io: Io) void,

    const where = "mongo.testing.conformance.run: ";

    /// A method of a harness: `fn (self: *H, io: std.Io, rest...)`
    /// returning `Payload`, or an error union of it when `may_fail`.
    const Method = struct {
        name: []const u8,
        rest: []const type,
        Payload: type,
        may_fail: bool,
        signature: []const u8,
    };

    const methods = [_]Method{
        .{ .name = "setUp", .rest = &.{ Allocator, conformance.Target }, .Payload = Client, .may_fail = true, .signature = "pub fn setUp(self: *@This(), io: std.Io, gpa: std.mem.Allocator, target: mongo.testing.conformance.Target) !mongo.Client" },
        .{ .name = "close", .rest = &.{}, .Payload = void, .may_fail = false, .signature = "pub fn close(self: *@This(), io: std.Io) void" },
        .{ .name = "tearDown", .rest = &.{}, .Payload = void, .may_fail = false, .signature = "pub fn tearDown(self: *@This(), io: std.Io) void" },
    };

    /// The type `Ptr` points to. Stops the build unless it is a pointer to
    /// one mutable struct with the three methods of a harness in the form
    /// the suite calls, with a message that names what to write.
    fn expectHarness(comptime Ptr: type) type {
        const not_a_pointer = where ++ "pass a pointer to the harness, e.g. &harness; got " ++ @typeName(Ptr);
        const pointer = switch (@typeInfo(Ptr)) {
            .pointer => |pointer| pointer,
            else => @compileError(not_a_pointer),
        };
        if (pointer.size != .one or @typeInfo(pointer.child) != .@"struct") @compileError(not_a_pointer);
        if (pointer.attrs.@"const") @compileError(where ++ "the harness must be mutable, declared with var; got " ++ @typeName(Ptr));
        const H = pointer.child;
        inline for (methods) |method| {
            if (!@hasDecl(H, method.name))
                @compileError(where ++ @typeName(H) ++ " has no method " ++ method.name ++ "; expected " ++ method.signature);
            if (!fits(H, method))
                @compileError(where ++ @typeName(H) ++ "." ++ method.name ++ " has another signature; expected " ++ method.signature);
        }
        return H;
    }

    /// Whether `H` declares `method` in the form the suite calls.
    fn fits(comptime H: type, comptime method: Method) bool {
        const function = switch (@typeInfo(@TypeOf(@field(H, method.name)))) {
            .@"fn" => |function| function,
            else => return false,
        };
        const params = function.param_types;
        if (params.len != 2 + method.rest.len or params[0] != *H or params[1] != Io) return false;
        inline for (method.rest, params[2..]) |Expected, Param| {
            if (Param != Expected) return false;
        }
        const Return = function.return_type orelse return false;
        if (Return == method.Payload) return true;
        if (!method.may_fail) return false;
        return switch (@typeInfo(Return)) {
            .error_union => |error_union| error_union.payload == method.Payload,
            else => false,
        };
    }

    pub fn of(harness: anytype) Harness {
        const Ptr = @TypeOf(harness);
        _ = comptime expectHarness(Ptr);
        const gen = struct {
            fn setUp(ptr: *anyopaque, io: Io, gpa: Allocator, target: conformance.Target) anyerror!Client {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.setUp(io, gpa, target);
            }
            fn close(ptr: *anyopaque, io: Io) void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                self.close(io);
            }
            fn tearDown(ptr: *anyopaque, io: Io) void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                self.tearDown(io);
            }
        };
        return .{ .ptr = harness, .set_up = gen.setUp, .close = gen.close, .tear_down = gen.tearDown };
    }
};

/// What the suite learns of the driver before the checks, on one scripted
/// server, set up and torn down in a task of its own: its name, its
/// revision, and whether it connects to the FakeServer at all.
pub const Probe = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    harness: Harness,
    name: []const u8 = "",
    revision: u16 = 0,
    wire: bool = false,
    failure: ?[]const u8 = null,

    pub fn go(p: *Probe) void {
        var answering: Answering = .{ .with = .{ .reply = Script.ok } };
        var stage: Stage = undefined;
        stage.start(p.io, p.gpa, answering.handler(), .{}) catch |err| {
            p.failure = std.fmt.allocPrint(p.arena, "the FakeServer of the probe did not start: error.{t}", .{err}) catch "the FakeServer did not start";
            return;
        };
        defer stage.stop(p.io);
        const client = p.harness.set_up(p.harness.ptr, p.io, p.gpa, .{ .scripted = .{ .uri = stage.uri, .script = &stage.script } }) catch |err| {
            p.failure = std.fmt.allocPrint(p.arena, "harness.setUp returned error.{t}", .{err}) catch "harness.setUp failed";
            return;
        };
        defer p.harness.tear_down(p.harness.ptr, p.io);
        defer p.harness.close(p.harness.ptr, p.io);
        const caps = client.capabilities();
        // The name points into the driver, which tearDown frees.
        p.name = p.arena.dupe(u8, caps.name) catch "";
        p.revision = caps.revision;
        // A driver that connects only for its first command connects now.
        const op: requests.OperationContext = .of(core.Context.root.withDeadline(.after(now(p.io), .fromSeconds(10))));
        if (client.runCommand(p.io, op, .{ .database = "admin", .body = ping }, .{ .allocator = p.gpa })) |reply| reply.deinit() else |_| {}
        p.wire = stage.script.acceptedConnections() > 0;
    }
};

pub const ping = bson.literal(.{ .ping = 1 });

/// The scripted server of one check: its script, served by `FakeServer`
/// on loopback. It points into itself: start it in place.
pub const Stage = struct {
    script: Script,
    listener: net.Server,
    server: Io.Future(Io.Cancelable!void),
    uri_buffer: [64]u8,
    uri: []const u8,

    fn start(s: *Stage, io: Io, gpa: Allocator, handler: Script.Handler, hello: wire.Hello) !void {
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

/// Answers every command with one answer.
pub const Answering = struct {
    with: Script.Answer,

    pub fn handler(a: *Answering) Script.Handler {
        return .init(a);
    }

    pub fn answer(a: *Answering, io: Io, arena: Allocator, request: *const Script.Request) Script.HandlerError!Script.Answer {
        _ = io;
        _ = arena;
        _ = request;
        return a.with;
    }
};

/// Counts what one check holds of the caller's allocator, so that memory
/// left after `tearDown` shows as a leak of that check.
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
