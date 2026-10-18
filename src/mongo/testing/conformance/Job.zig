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
        Cursor => value.deinit(job.io),
        results.WriteResult => {
            var result = value;
            result.deinit(job.gpa);
        },
        else => @compileError("discard: " ++ @typeName(@TypeOf(value))),
    }
}

pub fn note(job: *Job, comptime fmt: []const u8, args: anytype) Error!void {
    try job.notes.append(job.arena, try std.fmt.allocPrint(job.arena, fmt, args));
}

/// Sleeps in the check's task, which nothing cancels.
pub fn pause(job: *Job, duration: Io.Duration) void {
    job.io.sleep(duration, .awake) catch {};
}

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
