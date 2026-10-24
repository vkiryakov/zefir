//! One check of `odm.testing.conformance` on its way: what it may use, the
//! helpers that the checks share, and what it found. Also the harness
//! behind its table, and the allocators that count what a check holds and
//! what a call does with the allocator it got.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const core = @import("core");
const bson = @import("mongo-bson");
const odm = @import("../../root.zig");
const conformance = @import("../conformance.zig");
const Setup = conformance.Setup;
const Job = @This();

io: Io,
/// Counts what the check holds: the harness gets it in `setUp`.
gpa: Allocator,
/// The report's arena: the messages.
arena: Allocator,
harness: Harness,
options: conformance.Options,
check: conformance.Check,
body: Body,
/// What `setUp` gave, during the check.
setup: Setup = undefined,
/// Memory for documents and results, over `gpa`, freed before `tearDown`.
scratch: Allocator = undefined,
/// The diagnostics of the latest call of the check's task.
diag: odm.Diagnostics = .{},
/// Canceled, for the contexts of C5.
token: core.CancellationToken = .init,
driver_name: []const u8 = "",
failure: ?[]const u8 = null,
skipped: ?[]const u8 = null,

pub const Error = error{ CheckFailed, CheckSkipped, OutOfMemory };

/// What a check does, in its task.
pub const Body = *const fn (job: *Job) Error!void;

pub fn go(job: *Job, done: *Io.Event) void {
    defer done.set(job.io);
    job.runBody() catch |err| switch (err) {
        error.CheckFailed, error.CheckSkipped => {},
        error.OutOfMemory => if (job.failure == null) {
            job.failure = "out of memory";
        },
    };
}

fn runBody(job: *Job) Error!void {
    const setup = job.harness.set_up(job.harness.ptr, job.io, job.gpa) catch |err|
        return job.fail("harness.setUp returned error.{t}", .{err});
    defer job.harness.tear_down(job.harness.ptr, job.io, setup);
    job.setup = setup;
    // A name of the driver's table: constant, it outlives the setup.
    job.driver_name = setup.driver.name();
    var scratch: std.heap.ArenaAllocator = .init(job.gpa);
    defer scratch.deinit();
    job.scratch = scratch.allocator();
    job.token.cancel();
    return job.body(job);
}

/// `n` milliseconds, stretched by `Options.time_scale`.
pub fn ms(job: *const Job, n: i64) Io.Duration {
    return .fromMilliseconds(n * @as(i64, @max(job.options.time_scale, 1)));
}

pub fn now(job: *const Job) Io.Timestamp {
    return Io.Clock.awake.now(job.io);
}

/// Milliseconds since `since`.
pub fn elapsed(job: *const Job, since: Io.Timestamp) i64 {
    return since.durationTo(job.now()).toMilliseconds();
}

/// A context whose deadline is `n` stretched milliseconds away.
pub fn within(job: *const Job, n: i64) core.Context {
    return core.Context.root.withDeadline(.after(job.now(), job.ms(n)));
}

/// The context of a call that should go through: 10 s.
pub fn ctx(job: *const Job) core.Context {
    return job.within(10_000);
}

/// A context with less than 1 ms left.
pub fn nearlyExpired(job: *const Job) core.Context {
    return core.Context.root.withDeadline(.after(job.now(), .fromMicroseconds(500)));
}

/// A context whose token is canceled.
pub fn canceled(job: *const Job) core.Context {
    return core.Context.root.withCancellation(&job.token);
}

pub fn fail(job: *Job, comptime fmt: []const u8, args: anytype) Error {
    job.failure = try std.fmt.allocPrint(job.arena, fmt, args);
    return error.CheckFailed;
}

pub fn expect(job: *Job, holds: bool, comptime fmt: []const u8, args: anytype) Error!void {
    if (!holds) return job.fail(fmt, args);
}

pub fn skip(job: *Job, why: []const u8) Error {
    job.skipped = why;
    return error.CheckSkipped;
}

/// The payload of `result`; its error fails the check, with the text of
/// the job's diagnostics.
pub fn need(job: *Job, result: anytype, comptime what: []const u8) Error!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| job.fail(what ++ " returned error.{t}: {s}", .{ err, job.diag.message() });
}

/// Fails unless `result` is `expected`. A cursor that came instead is
/// freed.
pub fn expectError(job: *Job, result: anytype, expected: odm.DriverError, comptime what: []const u8) Error!void {
    if (result) |payload| {
        if (@TypeOf(payload) == odm.RawCursor) payload.deinit(job.io);
        return job.fail(what ++ " succeeded, not error.{t}", .{expected});
    } else |err| {
        if (err != expected) return job.fail(what ++ " returned error.{t}, not error.{t}: {s}", .{ err, expected, job.diag.message() });
    }
}

/// A client of `config` from the driver of the setup; `release` it.
pub fn open(job: *Job, config: odm.ConnectionConfig, comptime what: []const u8) Error!odm.Client {
    var settings = config;
    settings.diagnostics = &job.diag;
    return job.setup.driver.open(job.io, &settings) catch |err|
        job.fail("open of " ++ what ++ " returned error.{t}: {s}", .{ err, job.diag.message() });
}

/// A client of the settings of the setup, connected.
pub fn connected(job: *Job) Error!odm.Client {
    const client = try job.open(job.setup.config, "the settings of setUp");
    errdefer job.release(client);
    try job.need(client.connect(job.io, job.ctx(), &job.diag), "connect with the settings of setUp");
    return client;
}

/// Closes `client`, again if it is closed, and frees it.
pub fn release(job: *Job, client: odm.Client) void {
    client.close(job.io);
    client.deinit();
}

/// The options of a call: the scratch memory and the job's diagnostics.
pub fn call(job: *Job) odm.Client.CallOptions {
    return .{ .allocator = job.scratch, .diagnostics = &job.diag };
}

/// The collection `name` of the database of the setup.
pub fn ns(job: *const Job, name: []const u8) odm.Client.Namespace {
    return .{ .database = job.setup.database, .collection = name };
}

/// The documents of `cursor` to its end, copied into the scratch memory;
/// the cursor is freed.
pub fn drain(job: *Job, cursor: odm.RawCursor, comptime what: []const u8) Error![]const bson.RawDocument {
    defer cursor.deinit(job.io);
    var docs: std.ArrayList(bson.RawDocument) = .empty;
    while (try job.need(cursor.next(job.io, job.ctx(), &job.diag), "next of " ++ what)) |doc| {
        try docs.append(job.scratch, .{ .bytes = try job.scratch.dupe(u8, doc.bytes) });
    }
    return docs.items;
}

/// The documents that `request` finds, in their order.
pub fn findAll(job: *Job, client: odm.Client, request: odm.Client.FindRequest, comptime what: []const u8) Error![]const bson.RawDocument {
    const cursor = try job.need(client.find(job.io, job.ctx(), &request, job.call()), what);
    return job.drain(cursor, what);
}

/// The whole number `key` of `doc`, or the check fails.
pub fn number(job: *Job, doc: bson.RawDocument, key: []const u8) Error!i64 {
    const value = (doc.get(key) catch null) orelse return job.fail("a document holds no '{s}': {f}", .{ key, doc });
    return value.asI64() catch job.fail("'{s}' of a document is not a whole number: {f}", .{ key, doc });
}

/// Fails unless the field `key` of `docs` holds `expected`, in order.
pub fn expectNumbers(job: *Job, docs: []const bson.RawDocument, key: []const u8, expected: []const i64, what: []const u8) Error!void {
    var got: std.ArrayList(i64) = .empty;
    for (docs) |doc| try got.append(job.scratch, try job.number(doc, key));
    if (!std.mem.eql(i64, got.items, expected)) return job.fail("{s} gave {any} of '{s}', not {any}", .{ what, got.items, key, expected });
}

/// Fails unless `got` is `expected`, byte for byte.
pub fn expectDocument(job: *Job, got: bson.RawDocument, expected: bson.RawDocument, comptime what: []const u8) Error!void {
    if (!std.mem.eql(u8, got.bytes, expected.bytes)) return job.fail(what ++ " is {f}, not {f}", .{ got, expected });
}

/// Sleeps in the check's task, which nothing cancels.
pub fn pause(job: *const Job, duration: Io.Duration) void {
    const until = job.now().addDuration(duration);
    // A sleep of std's Io on Windows may end a tick of its timer early.
    while (job.now().nanoseconds < until.nanoseconds) {
        job.io.sleep(job.now().durationTo(until), .awake) catch return;
    }
}

/// The harness behind a pointer and a table of its methods.
pub const Harness = struct {
    ptr: *anyopaque,
    set_up: *const fn (ptr: *anyopaque, io: Io, gpa: Allocator) anyerror!Setup,
    tear_down: *const fn (ptr: *anyopaque, io: Io, setup: Setup) void,
    bad_credentials: ?*const fn (ptr: *anyopaque) odm.ConnectionConfig,
    unreachable_server: ?*const fn (ptr: *anyopaque) odm.ConnectionConfig,
    stall: ?*const fn (ptr: *anyopaque, io: Io, setup: Setup) anyerror!void,

    const where = "odm.testing.conformance.run: ";
    const setup_param = "setup: odm.testing.conformance.Setup";

    /// A method of a harness: `fn (self: *H, Params…)` returning `Payload`,
    /// or an error union of it when `may_fail`.
    const Hook = struct {
        name: []const u8,
        required: bool,
        Params: []const type,
        Payload: type,
        may_fail: bool,
        signature: []const u8,
    };

    const hooks = [_]Hook{
        .{ .name = "setUp", .required = true, .Params = &.{ Io, Allocator }, .Payload = Setup, .may_fail = true, .signature = "pub fn setUp(self: *@This(), io: std.Io, gpa: std.mem.Allocator) !odm.testing.conformance.Setup" },
        .{ .name = "tearDown", .required = true, .Params = &.{ Io, Setup }, .Payload = void, .may_fail = false, .signature = "pub fn tearDown(self: *@This(), io: std.Io, " ++ setup_param ++ ") void" },
        .{ .name = "badCredentials", .required = false, .Params = &.{}, .Payload = odm.ConnectionConfig, .may_fail = false, .signature = "pub fn badCredentials(self: *@This()) odm.ConnectionConfig" },
        .{ .name = "unreachableServer", .required = false, .Params = &.{}, .Payload = odm.ConnectionConfig, .may_fail = false, .signature = "pub fn unreachableServer(self: *@This()) odm.ConnectionConfig" },
        .{ .name = "stall", .required = false, .Params = &.{ Io, Setup }, .Payload = void, .may_fail = true, .signature = "pub fn stall(self: *@This(), io: std.Io, " ++ setup_param ++ ") !void" },
    };

    /// The type `Ptr` points to. Stops the build unless it is a pointer to
    /// one mutable struct with `setUp` and `tearDown`, and every method of
    /// a harness it has takes the form the suite calls, with a message that
    /// names what to write.
    fn expectHarness(comptime Ptr: type) type {
        const not_a_pointer = where ++ "pass a pointer to the harness, e.g. &harness; got " ++ @typeName(Ptr);
        const pointer = switch (@typeInfo(Ptr)) {
            .pointer => |pointer| pointer,
            else => @compileError(not_a_pointer),
        };
        if (pointer.size != .one or @typeInfo(pointer.child) != .@"struct") @compileError(not_a_pointer);
        if (pointer.attrs.@"const") @compileError(where ++ "the harness must be mutable, declared with var; got " ++ @typeName(Ptr));
        const H = pointer.child;
        inline for (hooks) |hook| {
            if (@hasDecl(H, hook.name)) {
                if (!hookFits(H, hook))
                    @compileError(where ++ @typeName(H) ++ "." ++ hook.name ++ " has another signature; expected " ++ hook.signature);
            } else if (hook.required) {
                @compileError(where ++ @typeName(H) ++ " has no method " ++ hook.name ++ "; expected " ++ hook.signature);
            }
        }
        return H;
    }

    /// Whether `H` declares `hook` in the form the suite calls.
    fn hookFits(comptime H: type, comptime hook: Hook) bool {
        const function = switch (@typeInfo(@TypeOf(@field(H, hook.name)))) {
            .@"fn" => |function| function,
            else => return false,
        };
        const params = function.param_types;
        if (params.len != hook.Params.len + 1 or params[0] != *H) return false;
        inline for (params[1..], hook.Params) |param, expected| {
            if (param != expected) return false;
        }
        const Return = function.return_type orelse return false;
        if (Return == hook.Payload) return true;
        if (!hook.may_fail) return false;
        return switch (@typeInfo(Return)) {
            .error_union => |error_union| error_union.payload == hook.Payload,
            else => false,
        };
    }

    pub fn of(harness: anytype) Harness {
        const Ptr = @TypeOf(harness);
        const H = comptime expectHarness(Ptr);
        const gen = struct {
            fn self(ptr: *anyopaque) Ptr {
                return @ptrCast(@alignCast(ptr));
            }
            fn setUp(ptr: *anyopaque, io: Io, gpa: Allocator) anyerror!Setup {
                return self(ptr).setUp(io, gpa);
            }
            fn tearDown(ptr: *anyopaque, io: Io, setup: Setup) void {
                self(ptr).tearDown(io, setup);
            }
            fn badCredentials(ptr: *anyopaque) odm.ConnectionConfig {
                return self(ptr).badCredentials();
            }
            fn unreachableServer(ptr: *anyopaque) odm.ConnectionConfig {
                return self(ptr).unreachableServer();
            }
            fn stall(ptr: *anyopaque, io: Io, setup: Setup) anyerror!void {
                return self(ptr).stall(io, setup);
            }
        };
        return .{
            .ptr = harness,
            .set_up = gen.setUp,
            .tear_down = gen.tearDown,
            .bad_credentials = if (@hasDecl(H, "badCredentials")) gen.badCredentials else null,
            .unreachable_server = if (@hasDecl(H, "unreachableServer")) gen.unreachableServer else null,
            .stall = if (@hasDecl(H, "stall")) gen.stall else null,
        };
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

/// The allocator of one call, for C8: it knows the blocks it gave, and
/// counts what the driver does with it once the call has returned. Its
/// memory is an arena over the job's allocator, freed by `deinit`.
pub const Fence = struct {
    arena: std.heap.ArenaAllocator,
    closed: std.atomic.Value(bool) = .init(false),
    late: std.atomic.Value(u32) = .init(0),
    blocks: [64][]u8 = undefined,
    held: usize = 0,

    pub fn init(parent: Allocator) Fence {
        return .{ .arena = .init(parent) };
    }

    pub fn deinit(f: *Fence) void {
        f.arena.deinit();
    }

    pub fn allocator(f: *Fence) Allocator {
        return .{ .ptr = f, .vtable = &vtable };
    }

    /// The call returned: any use from now on is late.
    pub fn close(f: *Fence) void {
        f.closed.store(true, .release);
    }

    /// How many times the driver used the allocator after the call.
    pub fn lateUses(f: *const Fence) u32 {
        return f.late.load(.acquire);
    }

    /// Whether `bytes` lie in a block that the call took and did not free.
    pub fn owns(f: *const Fence, bytes: []const u8) bool {
        const start = @intFromPtr(bytes.ptr);
        for (f.blocks[0..f.held]) |block| {
            const from = @intFromPtr(block.ptr);
            if (start >= from and start + bytes.len <= from + block.len) return true;
        }
        return false;
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    /// Counts a use after the call; true when it is one.
    fn touch(f: *Fence) bool {
        if (!f.closed.load(.acquire)) return false;
        _ = f.late.fetchAdd(1, .monotonic);
        return true;
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        // A late use is counted, and gets nothing: the arena is the call's.
        if (f.touch()) return null;
        const memory = f.arena.allocator().rawAlloc(len, alignment, ret_addr) orelse return null;
        // Past 64 blocks held at once, `owns` does not know the rest.
        if (f.held < f.blocks.len) {
            f.blocks[f.held] = memory[0..len];
            f.held += 1;
        }
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        if (f.touch()) return false;
        if (!f.arena.allocator().rawResize(memory, alignment, new_len, ret_addr)) return false;
        f.forget(memory);
        f.remember(memory.ptr[0..new_len]);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        if (f.touch()) return null;
        const moved_to = f.arena.allocator().rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        f.forget(memory);
        f.remember(moved_to[0..new_len]);
        return moved_to;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        if (f.touch()) return;
        f.forget(memory);
        f.arena.allocator().rawFree(memory, alignment, ret_addr);
    }

    fn remember(f: *Fence, block: []u8) void {
        if (f.held == f.blocks.len) return;
        f.blocks[f.held] = block;
        f.held += 1;
    }

    fn forget(f: *Fence, memory: []u8) void {
        for (f.blocks[0..f.held], 0..) |block, i| {
            if (block.ptr == memory.ptr) {
                f.blocks[i] = f.blocks[f.held - 1];
                f.held -= 1;
                return;
            }
        }
    }
};
