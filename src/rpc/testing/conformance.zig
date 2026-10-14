//! `rpc.testing.conformance`: the conformance suite of rpc transports. It
//! checks that a transport keeps the rules of `rpc.ClientTransport` and
//! `rpc.ServerTransport` that the engine relies on: bodies and metadata
//! byte for byte, failures, deadlines, cancelation, sizes, drain, a broken
//! link, the discipline of the server side and the lifecycle; T1–T22 of the
//! specification. Every transport passes the same checks: memory in the
//! tests of zefir-rpc, NATS with a fake connection and with a live broker, a
//! transport of your own in the tests of its package.
//!
//! ```zig
//! const Harness = struct {
//!     transport: MyTransport = undefined,
//!
//!     pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator) !rpc.testing.conformance.Pair {
//!         h.transport = try .init(gpa, io, .{});
//!         return .{ .client = h.transport.clientTransport(), .server = h.transport.serverTransport() };
//!     }
//!
//!     pub fn tearDown(h: *Harness, io: std.Io, pair: rpc.testing.conformance.Pair) void {
//!         _ = pair;
//!         h.transport.deinit(io);
//!     }
//! };
//!
//! test "my transport keeps the rules of rpc" {
//!     var harness: Harness = .{};
//!     var report = try rpc.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
//!     defer report.deinit();
//!     if (report.failedCount() > 0) {
//!         std.debug.print("{f}", .{&report});
//!         return error.TestUnexpectedResult;
//!     }
//! }
//! ```
//!
//! The harness is a pointer to a type with these methods:
//!
//! - `setUp(h, io, gpa) !Pair`: a fresh client side and server side of the
//!   transport, connected, so that what the client sends reaches the
//!   server side once it has started. The transport takes its memory from
//!   `gpa`: the suite counts it, and memory left after `tearDown` fails the
//!   check as a leak.
//! - `tearDown(h, io, pair) void`: frees what `setUp` made. By then the
//!   suite has stopped the server side and every call has returned.
//! - optional `breakLink(h, io, pair) void`: breaks the link between the
//!   sides in the middle of calls, as a dropped connection does (T12, T18).
//! - optional `restartPeer(h, io, pair) !void`: restarts the other side,
//!   such as the broker, and returns once it serves again (T17).
//! - optional `sameAddress(h, io, pair) !rpc.ServerTransport`: one more
//!   server side at the address `pair.server` holds, whose `start` must
//!   fail while `pair.server` runs (T14). `tearDown` frees it.
//!
//! `run` returns a report instead of failing through `std.testing`, so any
//! test runner can call it, also one that turns a panic into an exit code.
//! Each check runs in a task of its own on a fresh pair, and ends with
//! `tearDown`. Checks are chosen by `info()` of the client side: one the
//! transport cannot take is skipped, with the reason in the report; a part
//! of a check that cannot run is a note. Times are generous for CI;
//! `Options.time_scale` stretches them further.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const ClientTransport = @import("../ClientTransport.zig");
const ServerTransport = @import("../ServerTransport.zig");
const RawServer = @import("../engine/RawServer.zig");
const RawClient = @import("../engine/RawClient.zig");
const Context = @import("../engine/Context.zig").Context;
const middleware = @import("../middleware.zig");
const RecordingDispatcher = @import("RecordingDispatcher.zig");

const Route = model.Route;
const Response = model.Response;
const Entry = model.Metadata.Entry;
const CallError = ClientTransport.CallError;

/// The two sides of one transport, connected.
pub const Pair = struct {
    client: ClientTransport,
    server: ServerTransport,
};

pub const Options = struct {
    /// Runs T17, which restarts the other side, such as the broker, through
    /// `harness.restartPeer`.
    live_broker: bool = false,
    /// Runs only these checks; null runs all of them.
    only: ?[]const Check = null,
    /// Stretches every time of the suite: deadlines, waits and tolerances.
    /// Raise it for a slow machine or a remote broker.
    time_scale: u32 = 1,
};

/// The checks, T1–T22 of the specification.
pub const Check = enum {
    t1,
    t2,
    t3,
    t4,
    t5,
    t6,
    t7,
    t8,
    t9,
    t10,
    t11,
    t12,
    t13,
    t14,
    t15,
    t16,
    t17,
    t18,
    t19,
    t20,
    t21,
    t22,

    /// "T1" to "T22".
    pub fn label(check: Check) []const u8 {
        return switch (check) {
            inline else => |c| comptime "T" ++ @tagName(c)[1..],
        };
    }

    /// What the check proves, in a few words.
    pub fn title(check: Check) []const u8 {
        return switch (check) {
            .t1 => "echo: bodies byte for byte, empty, not UTF-8",
            .t2 => "metadata: order, repeated keys, empty values, reserved keys",
            .t3 => "failures: every code, app code, message, field and failure body",
            .t4 => "the head on the server: route, request id, codec, peer",
            .t5 => "budget: the server sees the time left; a past deadline is not sent",
            .t6 => "client deadline: Timeout on time; a late response is not seen",
            .t7 => "canceling the caller: Canceled once; the server is told",
            .t8 => "64 calls at once with random delays: responses not mixed up",
            .t9 => "sizes: a body at the limit and one byte over; response limits",
            .t10 => "unknown route: unimplemented or Unavailable",
            .t11 => "drain: calls in flight answered, new ones not taken",
            .t12 => "broken link: ConnectionLost, Unavailable, calls canceled",
            .t13 => "server discipline under the recording dispatcher",
            .t14 => "lifecycle: a busy address, drain and close twice",
            .t15 => "memory: the caller's buffers and allocator after return",
            .t16 => "at-least-once delivery: one response per call",
            .t17 => "restart of the other side: new calls go through",
            .t18 => "reentrance: an answer before start returns, a cancel during start, start refused",
            .t19 => "drain, close and release keep a cancelation of their task",
            .t20 => "close while a request is on its way: abandon, bounded close",
            .t21 => "a refusal at admission arrives with refused = true",
            .t22 => "metadata of middleware passes unchanged",
        };
    }
};

/// What came of one check.
pub const Outcome = union(enum) {
    passed,
    /// What went wrong, for people.
    failed: []const u8,
    /// Why the check did not run.
    skipped: []const u8,
};

/// A part of a check that did not run, and why.
pub const Note = struct { check: Check, text: []const u8 };

/// What came of a run. It owns its strings: one `deinit`.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    /// `info().name` of the client side.
    transport_name: []const u8 = "",
    outcomes: std.EnumArray(Check, Outcome) = .initFill(.{ .skipped = "not run" }),
    notes: []const Note = &.{},
    /// Entries of the transport's function tables left at their defaults,
    /// such as "rpc.ServerTransport.isReady": a feature the transport may
    /// have meant to provide.
    defaults: []const []const u8 = &.{},

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
        r.* = undefined;
    }

    pub fn outcome(r: *const Report, check: Check) Outcome {
        return r.outcomes.get(check);
    }

    pub fn failedCount(r: *const Report) usize {
        return r.count(.failed);
    }

    pub fn passedCount(r: *const Report) usize {
        return r.count(.passed);
    }

    pub fn skippedCount(r: *const Report) usize {
        return r.count(.skipped);
    }

    fn count(r: *const Report, tag: std.meta.Tag(Outcome)) usize {
        var n: usize = 0;
        for (r.outcomes.values) |o| {
            if (o == tag) n += 1;
        }
        return n;
    }

    /// One line a check, then the notes and the defaults: `{f}`.
    pub fn format(r: *const Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("rpc conformance of \"{s}\": {d} passed, {d} failed, {d} skipped\n", .{
            r.transport_name, r.passedCount(), r.failedCount(), r.skippedCount(),
        });
        for (std.enums.values(Check)) |check| {
            switch (r.outcome(check)) {
                .passed => try w.print("  passed   {s: <3}  {s}\n", .{ check.label(), check.title() }),
                .failed => |why| try w.print("  FAILED   {s: <3}  {s}: {s}\n", .{ check.label(), check.title(), why }),
                .skipped => |why| try w.print("  skipped  {s: <3}  {s}: {s}\n", .{ check.label(), check.title(), why }),
            }
        }
        for (r.notes) |note| try w.print("  note     {s: <3}  {s}\n", .{ note.check.label(), note.text });
        if (r.defaults.len > 0) {
            try w.writeAll("  defaults left by the transport:");
            for (r.defaults) |name| try w.print(" {s}", .{name});
            try w.writeAll("\n");
        }
    }
};

/// `Canceled`: the caller's task was canceled; checked between checks.
pub const RunError = error{ OutOfMemory, Canceled };

/// Runs the checks on fresh pairs from `harness`, each in a task of its
/// own, and reports what came of them. `gpa` must be thread-safe, such as
/// `std.testing.allocator`: transports allocate from their tasks. `io`
/// must offer concurrency (`std.testing.io` does): every check runs clients
/// and servers in tasks of their own.
pub fn run(io: std.Io, gpa: std.mem.Allocator, harness: anytype, options: Options) RunError!Report {
    const h: Harness = .of(harness);
    // A Debug allocator may take a cancelable lock: blocked, the work of
    // `run` cannot swallow a cancelation of the caller, which it checks
    // between the checks.
    const outer = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(outer);

    var report: Report = .{ .arena = .init(gpa) };
    errdefer report.deinit();
    const arena = report.arena.allocator();

    var probe: Probe = .{ .io = io, .gpa = gpa, .arena = arena, .harness = h };
    var probe_task = io.concurrent(Probe.go, .{&probe}) catch {
        report.outcomes = .initFill(.{ .failed = no_concurrency });
        return report;
    };
    probe_task.await(io);
    report.transport_name = probe.client_info.name;
    if (probe.failure) |why| {
        report.outcomes = .initFill(.{ .failed = why });
        return report;
    }
    if (probe.is_ready_default) report.defaults = try arena.dupe([]const u8, &.{"rpc.ServerTransport.isReady"});

    var notes: std.ArrayList(Note) = .empty;
    for (std.enums.values(Check)) |check| {
        try checkpoint(io, outer);
        const result: Outcome = if (!selected(options, check))
            .{ .skipped = "not in options.only" }
        else if (skipReason(check, &probe, h, options)) |why|
            .{ .skipped = why }
        else
            try runCheck(io, gpa, arena, h, &probe, options, check, &notes);
        report.outcomes.set(check, result);
    }
    report.notes = notes.items;
    return report;
}

const no_concurrency = "no task for the check: io.concurrent returned error.ConcurrencyUnavailable; the suite needs an std.Io with concurrency";

/// A cancelation point of the caller between two checks.
fn checkpoint(io: std.Io, outer: std.Io.CancelProtection) error{Canceled}!void {
    _ = io.swapCancelProtection(outer);
    defer _ = io.swapCancelProtection(.blocked);
    return io.checkCancel();
}

fn selected(options: Options, check: Check) bool {
    const only = options.only orelse return true;
    return std.mem.indexOfScalar(Check, only, check) != null;
}

fn skipReason(check: Check, probe: *const Probe, h: Harness, options: Options) ?[]const u8 {
    return switch (check) {
        .t12 => if (h.break_link == null)
            "the harness has no breakLink"
        else if (!probe.client_info.reports_connection_loss)
            "info().reports_connection_loss is false: the client sees a broken link only at the deadline"
        else
            null,
        .t16 => if (probe.server_info.delivery != .at_least_once) "info().delivery is not at_least_once" else null,
        .t17 => if (!options.live_broker)
            "it needs a live broker: options.live_broker is false"
        else if (h.restart_peer == null)
            "the harness has no restartPeer"
        else
            null,
        else => null,
    };
}

/// Runs one check in a task of its own: a false `Canceled` of the transport
/// stays in that task, and the caller's cancelation in the caller's.
fn runCheck(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    h: Harness,
    probe: *const Probe,
    options: Options,
    check: Check,
    notes: *std.ArrayList(Note),
) error{OutOfMemory}!Outcome {
    var counting: Counting = .{ .parent = gpa };
    var job: Job = .{
        .io = io,
        .gpa = counting.allocator(),
        .arena = arena,
        .harness = h,
        .info = probe.client_info,
        .server_info = probe.server_info,
        .options = options,
    };
    var task = io.concurrent(Job.go, .{ &job, check }) catch return .{ .failed = no_concurrency };
    task.await(io);
    for (job.notes.items) |text| try notes.append(arena, .{ .check = check, .text = text });
    const leaked = counting.live.load(.acquire);
    if (leaked > 0) {
        const leak = try std.fmt.allocPrint(arena, "{d} bytes in {d} allocation(s) were still held after harness.tearDown", .{ counting.bytes.load(.acquire), leaked });
        return .{ .failed = if (job.failure) |why| try std.fmt.allocPrint(arena, "{s}; {s}", .{ why, leak }) else leak };
    }
    return if (job.failure) |why| .{ .failed = why } else .passed;
}

/// The harness behind a pointer and a table of its methods.
const Harness = struct {
    ptr: *anyopaque,
    set_up: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror!Pair,
    tear_down: *const fn (ptr: *anyopaque, io: std.Io, pair: Pair) void,
    break_link: ?*const fn (ptr: *anyopaque, io: std.Io, pair: Pair) void,
    restart_peer: ?*const fn (ptr: *anyopaque, io: std.Io, pair: Pair) anyerror!void,
    same_address: ?*const fn (ptr: *anyopaque, io: std.Io, pair: Pair) anyerror!ServerTransport,

    const where = "rpc.testing.conformance.run: ";

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

    /// A method of a harness: `fn (self: *H, io: std.Io, last: Last)`
    /// returning `Payload`, or an error union of it when `may_fail`.
    const Hook = struct {
        name: []const u8,
        required: bool,
        Last: type,
        Payload: type,
        may_fail: bool,
        signature: []const u8,
    };

    const pair_param = "pair: rpc.testing.conformance.Pair";
    const hooks = [_]Hook{
        .{ .name = "setUp", .required = true, .Last = std.mem.Allocator, .Payload = Pair, .may_fail = true, .signature = "pub fn setUp(self: *@This(), io: std.Io, gpa: std.mem.Allocator) !rpc.testing.conformance.Pair" },
        .{ .name = "tearDown", .required = true, .Last = Pair, .Payload = void, .may_fail = false, .signature = "pub fn tearDown(self: *@This(), io: std.Io, " ++ pair_param ++ ") void" },
        .{ .name = "breakLink", .required = false, .Last = Pair, .Payload = void, .may_fail = false, .signature = "pub fn breakLink(self: *@This(), io: std.Io, " ++ pair_param ++ ") void" },
        .{ .name = "restartPeer", .required = false, .Last = Pair, .Payload = void, .may_fail = true, .signature = "pub fn restartPeer(self: *@This(), io: std.Io, " ++ pair_param ++ ") !void" },
        .{ .name = "sameAddress", .required = false, .Last = Pair, .Payload = ServerTransport, .may_fail = true, .signature = "pub fn sameAddress(self: *@This(), io: std.Io, " ++ pair_param ++ ") !rpc.ServerTransport" },
    };

    /// Whether `H` declares `hook` in the form the suite calls.
    fn hookFits(comptime H: type, comptime hook: Hook) bool {
        const function = switch (@typeInfo(@TypeOf(@field(H, hook.name)))) {
            .@"fn" => |function| function,
            else => return false,
        };
        const params = function.param_types;
        if (params.len != 3 or params[0] != *H or params[1] != std.Io or params[2] != hook.Last) return false;
        const Return = function.return_type orelse return false;
        if (Return == hook.Payload) return true;
        if (!hook.may_fail) return false;
        return switch (@typeInfo(Return)) {
            .error_union => |error_union| error_union.payload == hook.Payload,
            else => false,
        };
    }

    fn of(harness: anytype) Harness {
        const Ptr = @TypeOf(harness);
        const H = comptime expectHarness(Ptr);
        const gen = struct {
            fn setUp(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror!Pair {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.setUp(io, gpa);
            }
            fn tearDown(ptr: *anyopaque, io: std.Io, pair: Pair) void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                self.tearDown(io, pair);
            }
            fn breakLink(ptr: *anyopaque, io: std.Io, pair: Pair) void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                self.breakLink(io, pair);
            }
            fn restartPeer(ptr: *anyopaque, io: std.Io, pair: Pair) anyerror!void {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.restartPeer(io, pair);
            }
            fn sameAddress(ptr: *anyopaque, io: std.Io, pair: Pair) anyerror!ServerTransport {
                const self: Ptr = @ptrCast(@alignCast(ptr));
                return self.sameAddress(io, pair);
            }
        };
        return .{
            .ptr = harness,
            .set_up = gen.setUp,
            .tear_down = gen.tearDown,
            .break_link = if (@hasDecl(H, "breakLink")) gen.breakLink else null,
            .restart_peer = if (@hasDecl(H, "restartPeer")) gen.restartPeer else null,
            .same_address = if (@hasDecl(H, "sameAddress")) gen.sameAddress else null,
        };
    }
};

/// What the suite learns of the transport before the checks: one pair,
/// set up and torn down in a task of its own.
const Probe = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    harness: Harness,
    client_info: transport.Info = .{ .name = "" },
    server_info: transport.Info = .{ .name = "" },
    is_ready_default: bool = false,
    failure: ?[]const u8 = null,

    fn go(p: *Probe) void {
        const pair = p.harness.set_up(p.harness.ptr, p.io, p.gpa) catch |err| {
            p.failure = std.fmt.allocPrint(p.arena, "harness.setUp returned error.{t}", .{err}) catch "harness.setUp failed";
            return;
        };
        defer p.harness.tear_down(p.harness.ptr, p.io, pair);
        p.client_info = pair.client.info();
        p.server_info = pair.server.info();
        // The names point into the transport, which tearDown frees.
        p.client_info.name = p.arena.dupe(u8, p.client_info.name) catch "";
        p.server_info.name = p.arena.dupe(u8, p.server_info.name) catch "";
        p.is_ready_default = pair.server.vtable.isReady == &ServerTransport.alwaysReady;
    }
};

const CheckError = error{ CheckFailed, OutOfMemory };

/// One check on its way: what it may use, and what it found.
const Job = struct {
    io: std.Io,
    /// Counts what the check holds; the transport gets it in `setUp`.
    gpa: std.mem.Allocator,
    /// The report's arena: messages and notes.
    arena: std.mem.Allocator,
    harness: Harness,
    /// Of the client side, from the probe.
    info: transport.Info,
    server_info: transport.Info,
    options: Options,
    failure: ?[]const u8 = null,
    notes: std.ArrayList([]const u8) = .empty,

    fn go(job: *Job, check: Check) void {
        job.runBody(check) catch |err| switch (err) {
            error.CheckFailed => {},
            error.OutOfMemory => if (job.failure == null) {
                job.failure = "out of memory";
            },
        };
    }

    fn runBody(job: *Job, check: Check) CheckError!void {
        return switch (check) {
            .t1 => t1(job),
            .t2 => t2(job),
            .t3 => t3(job),
            .t4 => t4(job),
            .t5 => t5(job),
            .t6 => t6(job),
            .t7 => t7(job),
            .t8 => t8(job),
            .t9 => t9(job),
            .t10 => t10(job),
            .t11 => t11(job),
            .t12 => t12(job),
            .t13 => t13(job),
            .t14 => t14(job),
            .t15 => t15(job),
            .t16 => t16(job),
            .t17 => t17(job),
            .t18 => t18(job),
            .t19 => t19(job),
            .t20 => t20(job),
            .t21 => t21(job),
            .t22 => t22(job),
        };
    }

    /// `n` milliseconds, stretched by `Options.time_scale`.
    fn ms(job: *const Job, n: i64) std.Io.Duration {
        return .fromMilliseconds(n * job.scale());
    }

    fn scale(job: *const Job) i64 {
        return @max(job.options.time_scale, 1);
    }

    fn fail(job: *Job, comptime fmt: []const u8, args: anytype) CheckError {
        job.failure = try std.fmt.allocPrint(job.arena, fmt, args);
        return error.CheckFailed;
    }

    fn expect(job: *Job, holds: bool, comptime fmt: []const u8, args: anytype) CheckError!void {
        if (!holds) return job.fail(fmt, args);
    }

    /// The payload of `result`; its error fails the check.
    fn need(job: *Job, result: anytype, comptime what: []const u8) CheckError!@typeInfo(@TypeOf(result)).error_union.payload {
        return result catch |err| job.fail(what ++ " returned error.{t}", .{err});
    }

    fn note(job: *Job, comptime fmt: []const u8, args: anytype) CheckError!void {
        try job.notes.append(job.arena, try std.fmt.allocPrint(job.arena, fmt, args));
    }

    fn setUp(job: *Job) CheckError!Pair {
        return job.need(job.harness.set_up(job.harness.ptr, job.io, job.gpa), "harness.setUp");
    }

    fn tearDown(job: *Job, pair: Pair) void {
        job.harness.tear_down(job.harness.ptr, job.io, pair);
    }

    /// Sleeps in the check's task, which nothing cancels.
    fn pause(job: *Job, duration: std.Io.Duration) void {
        job.io.sleep(duration, .awake) catch {};
    }

    /// Waits until `condition.holds()`, looking every millisecond, for at
    /// most `limit`; false when it never held.
    fn eventually(job: *Job, limit: std.Io.Duration, condition: anytype) bool {
        const deadline: core.Deadline = .after(now(job.io), limit);
        while (!condition.holds()) {
            if (deadline.isExpired(now(job.io))) return false;
            job.pause(.fromMilliseconds(1));
        }
        return true;
    }

    /// Sends `call` through `client` in the check's task.
    fn send(job: *Job, client: ClientTransport, call: Call, sent: *Sent) void {
        sendCall(job, client, call, sent);
    }

    /// The response of a call that must succeed.
    fn ok(job: *Job, sent: *const Sent, comptime what: []const u8) CheckError!Response {
        const response = sent.result catch |err| return job.fail(what ++ " returned error.{t}", .{err});
        return switch (response.status) {
            .ok => response,
            .failure => |f| job.fail(what ++ " got the failure {t} {s} \"{s}\"{s}", .{ f.code, f.app_code, f.message, if (response.refused) ", refused" else "" }),
        };
    }

    fn expectError(job: *Job, sent: *const Sent, expected: CallError, comptime what: []const u8) CheckError!void {
        if (sent.result) |response| {
            return job.fail(what ++ " returned {s}, not error.{t}", .{ job.describe(response), expected });
        } else |err| {
            if (err != expected) return job.fail(what ++ " returned error.{t}, not error.{t}", .{ err, expected });
        }
    }

    /// The failure of a call that must be refused with `expected`.
    fn refusal(job: *Job, sent: *const Sent, expected: model.Failure, what: []const u8) CheckError!void {
        const response = sent.result catch |err| return job.fail("{s} returned error.{t}, not a refusal", .{ what, err });
        const got = switch (response.status) {
            .ok => return job.fail("{s} succeeded, not refused", .{what}),
            .failure => |f| f,
        };
        try job.expect(got.code == expected.code and std.mem.eql(u8, got.app_code, expected.app_code) and
            std.mem.eql(u8, got.message, expected.message), "{s} came as {t} {s} \"{s}\", not {t} {s} \"{s}\"", .{
            what, got.code, got.app_code, got.message, expected.code, expected.app_code, expected.message,
        });
        try job.expect(response.refused, "{s} came without refused = true: the client cannot tell that the call did not run", .{what});
    }

    /// A response, for messages.
    fn describe(job: *Job, response: Response) []const u8 {
        return switch (response.status) {
            .ok => std.fmt.allocPrint(job.arena, "a success with {d} bytes", .{response.body.len}) catch "a success",
            .failure => |f| std.fmt.allocPrint(job.arena, "the failure {t} {s} \"{s}\"{s}", .{
                f.code, f.app_code, f.message, if (response.refused) ", refused" else "",
            }) catch "a failure",
        };
    }

    fn sameMetadata(job: *Job, comptime what: []const u8, got: []const Entry, expected: []const Entry) CheckError!void {
        if (got.len != expected.len) return job.fail(what ++ ": {d} entries, not {d}", .{ got.len, expected.len });
        for (got, expected, 0..) |g, e, i| {
            if (!std.mem.eql(u8, g.key, e.key) or !std.mem.eql(u8, g.value, e.value))
                return job.fail(what ++ ": entry {d} is {s}: \"{s}\", not {s}: \"{s}\"", .{ i, g.key, g.value, e.key, e.value });
        }
    }

    /// The engine with the sample methods on `side`; start it in place.
    fn engine(job: *Job, side: ServerTransport, samples: *Samples, options: EngineOptions) CheckError!RawServer {
        const methods = samples.methods();
        return job.need(RawServer.init(job.gpa, .{
            .transport = side,
            .methods = &methods,
            .middleware = options.middleware,
            .limits = .{ .default_timeout = .fromSeconds(60) },
            .shutdown_grace = options.grace,
        }), "rpc.RawServer.init");
    }

    fn startEngine(job: *Job, server: *RawServer) CheckError!void {
        try job.need(server.start(job.io), "rpc.RawServer.start (the transport's start)");
    }

    /// The recording dispatcher on `side`, started in place.
    fn record(job: *Job, recorder: *RecordingDispatcher, side: ServerTransport, options: RecordingDispatcher.Options) CheckError!void {
        recorder.* = try job.need(RecordingDispatcher.init(job.gpa, options), "RecordingDispatcher.init");
        recorder.start(job.io, side) catch |err| {
            recorder.deinit(job.io);
            return job.fail("rpc.ServerTransport.start returned error.{t}", .{err});
        };
    }

    fn waitStarted(job: *Job, recorder: *RecordingDispatcher, n: usize) CheckError!void {
        recorder.waitStarted(job.io, n) catch |err|
            return job.fail("the server side did not start call {d} within {d} s: error.{t}", .{ n - 1, RecordingDispatcher.wait_limit.toSeconds(), err });
    }

    fn view(job: *Job, recorder: *RecordingDispatcher, index: usize) CheckError!RecordingDispatcher.CallView {
        return recorder.call(job.io, index) catch job.fail("the server side never got call {d}", .{index});
    }

    fn respond(job: *Job, recorder: *RecordingDispatcher, index: usize, response: *const Response) CheckError!void {
        recorder.respond(job.io, index, response) catch |err|
            return job.fail("Reply.send of call {d} returned error.{t}", .{ index, err });
    }

    fn release(job: *Job, recorder: *RecordingDispatcher, index: usize, disposition: transport.Reply.Disposition) CheckError!void {
        recorder.releaseCall(job.io, index, disposition) catch
            return job.fail("the server side never got call {d}", .{index});
    }

    /// One call answered with its own body through the recorder: call
    /// `index`, the `started`-th to start.
    fn echoed(job: *Job, recorder: *RecordingDispatcher, client: ClientTransport, index: usize, started: usize, body: []const u8) CheckError!void {
        var caller: Caller = .init(job, client, .{ .body = body });
        defer caller.deinit();
        try caller.begin();
        try job.waitStarted(recorder, started);
        try job.respond(recorder, index, &.{ .status = .ok, .body = body });
        try job.release(recorder, index, .completed);
        caller.join();
        const response = try job.ok(&caller.sent, "a call");
        try job.expect(std.mem.eql(u8, response.body, body), "a call got {d} bytes back, not the {d} it was answered with", .{ response.body.len, body.len });
    }

    fn noViolations(job: *Job, recorder: *const RecordingDispatcher) CheckError!void {
        const found = recorder.violations();
        if (found.len == 0) return;
        const first = found[0];
        if (first.call) |index|
            return job.fail("the server side broke a rule of rpc.ServerTransport: {t} on call {d} ({d} violations in all)", .{ first.rule, index, found.len });
        return job.fail("the server side broke a rule of rpc.ServerTransport: {t} ({d} violations in all)", .{ first.rule, found.len });
    }
};

const EngineOptions = struct {
    middleware: []const middleware.Middleware = &.{},
    grace: std.Io.Duration = .fromSeconds(10),
};

/// One call through the client side, as `rpc.RawClient` sends it.
const Call = struct {
    route: Route = echo_route,
    body: []const u8 = "",
    metadata: []const Entry = &.{},
    /// From the moment the call is sent.
    timeout: std.Io.Duration = .fromSeconds(10),
    /// In place of `timeout`.
    deadline: ?core.Deadline = null,
    max_response_bytes: usize = 1 << 20,
    max_response_metadata_entries: u32 = 64,
    max_response_metadata_bytes: u32 = 16 * 1024,
};

/// What came of one call.
const Sent = struct {
    result: CallError!Response = error.Unexpected,
    request_id: [16]u8 = @splat(0),
    deadline: core.Deadline = .at(.zero),
    began: std.Io.Timestamp = .zero,
    ended: std.Io.Timestamp = .zero,
    /// After `call` returned, `io.checkCancel()` in the same task saw a
    /// cancelation: the transport re-armed the one it had reported.
    cancel_left: bool = false,
    /// The memory of the response.
    arena: std.heap.ArenaAllocator,
    /// The allocator the call got: it counts what the transport did with it
    /// after `call` returned.
    fence: Fence,

    fn deinit(s: *Sent) void {
        s.arena.deinit();
        s.* = undefined;
    }
};

/// Sends `call` through `client` in the current task and records what came
/// of it.
fn sendCall(job: *const Job, client: ClientTransport, call: Call, sent: *Sent) void {
    const io = job.io;
    sent.* = .{ .arena = .init(job.gpa), .fence = undefined };
    sent.fence = .{ .parent = sent.arena.allocator() };
    io.random(&sent.request_id);
    sent.began = now(io);
    sent.deadline = call.deadline orelse .after(sent.began, call.timeout);
    const request: transport.Request = .{
        .route = call.route,
        .request_id = sent.request_id,
        .codec = "json",
        .ctx = core.Context.root.withDeadline(sent.deadline),
        .metadata = call.metadata,
        .body = call.body,
    };
    sent.result = client.call(io, &request, .{
        .allocator = sent.fence.allocator(),
        .max_response_bytes = call.max_response_bytes,
        .max_response_metadata_entries = call.max_response_metadata_entries,
        .max_response_metadata_bytes = call.max_response_metadata_bytes,
    });
    sent.ended = now(io);
    sent.fence.close();
    sent.cancel_left = if (io.checkCancel()) |_| false else |_| true;
}

/// A call in a task of its own, which the check may cancel.
const Caller = struct {
    job: *Job,
    client: ClientTransport,
    call: Call,
    /// The task waits until the check cancels it, then calls with the
    /// cancelation pending.
    cancel_first: bool = false,
    sent: Sent = undefined,
    future: ?std.Io.Future(void) = null,

    fn init(job: *Job, client: ClientTransport, call: Call) Caller {
        return .{ .job = job, .client = client, .call = call };
    }

    fn begin(c: *Caller) CheckError!void {
        c.future = c.job.io.concurrent(task, .{c}) catch |err|
            return c.job.fail("no task for a call: io.concurrent returned error.{t}", .{err});
    }

    fn task(c: *Caller) void {
        const io = c.job.io;
        if (c.cancel_first) {
            if (io.sleep(.fromSeconds(3600), .awake)) |_| {} else |_| io.recancel();
        }
        sendCall(c.job, c.client, c.call, &c.sent);
    }

    /// Waits until the call has returned.
    fn join(c: *Caller) void {
        if (c.future) |*future| future.await(c.job.io);
    }

    /// Cancels the task and waits until the call has returned.
    fn cancel(c: *Caller) void {
        if (c.future) |*future| future.cancel(c.job.io);
    }

    fn deinit(c: *Caller) void {
        if (c.future == null) return;
        c.cancel();
        c.sent.deinit();
    }
};

/// The allocator a call gets in `CallOptions`: it counts what the
/// transport does with it after `call` has returned.
const Fence = struct {
    parent: std.mem.Allocator,
    closed: std.atomic.Value(bool) = .init(false),
    late_uses: std.atomic.Value(u32) = .init(0),

    fn allocator(f: *Fence) std.mem.Allocator {
        return .{ .ptr = f, .vtable = &vtable };
    }

    fn close(f: *Fence) void {
        f.closed.store(true, .release);
    }

    fn late(f: *const Fence) u32 {
        return f.late_uses.load(.acquire);
    }

    fn touch(f: *Fence) void {
        if (f.closed.load(.acquire)) _ = f.late_uses.fetchAdd(1, .monotonic);
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const f: *Fence = @ptrCast(@alignCast(ptr));
        f.touch();
        return f.parent.rawAlloc(len, alignment, ret_addr);
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
        f.touch();
        f.parent.rawFree(memory, alignment, ret_addr);
    }
};

/// Counts what one check holds of the caller's allocator, so that memory
/// left after `tearDown` shows as a leak of that check.
const Counting = struct {
    parent: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

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

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn toMilliseconds(duration: std.Io.Duration) i64 {
    return @intCast(@divTrunc(duration.nanoseconds, std.time.ns_per_ms));
}

// The routes and methods of the checks.

const service = "conformance";
const echo_route: Route = .{ .service = service, .version = 1, .method = "echo" };
const gate_route: Route = .{ .service = service, .version = 1, .method = "gate" };
const sleep_route: Route = .{ .service = service, .version = 1, .method = "sleep" };
const meta_route: Route = .{ .service = service, .version = 1, .method = "meta" };
/// Another version, so that the head shows the version that came.
const head_route: Route = .{ .service = service, .version = 7, .method = "head" };
/// What the recording dispatcher serves.
const recorded_routes = [_]Route{ echo_route, head_route };

/// The key middleware writes in T22.
const middleware_key = "x-conformance";

const busy: model.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Too many calls" };
const no_task: model.Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "No task for the call" };

/// The methods of the engine in the checks, on bytes; the state is shared
/// by all calls.
const Samples = struct {
    scale: i64,
    /// `gate` answers once it is set; canceling the call ends the wait.
    gate_open: std.Io.Event = .unset,
    /// Calls that entered `gate`.
    entered: std.atomic.Value(u32) = .init(0),

    fn methods(s: *Samples) [4]RawServer.Method {
        return .{
            .{ .route = echo_route, .handler = .{ .ptr = s, .handle = echoFn } },
            .{ .route = gate_route, .handler = .{ .ptr = s, .handle = gateFn } },
            .{ .route = sleep_route, .handler = .{ .ptr = s, .handle = sleepFn } },
            .{ .route = meta_route, .handler = .{ .ptr = s, .handle = metaFn } },
        };
    }

    /// Answers with the request.
    fn echoFn(_: *anyopaque, _: *Context, request: []const u8) anyerror![]const u8 {
        return request;
    }

    /// Answers with the request once the gate opens.
    fn gateFn(ptr: *anyopaque, ctx: *Context, request: []const u8) anyerror![]const u8 {
        const s: *Samples = @ptrCast(@alignCast(ptr));
        _ = s.entered.fetchAdd(1, .acq_rel);
        try s.gate_open.wait(ctx.io());
        return request;
    }

    /// Sleeps as many milliseconds as the first byte of the request says,
    /// then answers with the request.
    fn sleepFn(ptr: *anyopaque, ctx: *Context, request: []const u8) anyerror![]const u8 {
        const s: *Samples = @ptrCast(@alignCast(ptr));
        const pause: i64 = if (request.len > 0) request[0] else 0;
        try ctx.io().sleep(.fromMilliseconds(pause * s.scale), .awake);
        return request;
    }

    /// Answers with the value of `middleware_key` in the request metadata.
    fn metaFn(_: *anyopaque, ctx: *Context, _: []const u8) anyerror![]const u8 {
        return ctx.metadata().get(middleware_key) orelse "none";
    }
};

fn serverLink(ctx: *Context, next: *middleware.Next) anyerror!void {
    try ctx.setResponseMetadata(middleware_key, "server");
    return next.run();
}

fn clientLink(ctx: *RawClient.ClientContext, next: *RawClient.ClientNext) anyerror!void {
    try ctx.addMetadata(middleware_key, "client");
    return next.run();
}

/// A server side between the engine and the transport that tells the
/// check when the engine's `drain` has returned.
const Spy = struct {
    inner: ServerTransport,
    drained: std.Io.Event = .unset,

    fn serverTransport(s: *Spy) ServerTransport {
        return .init(s);
    }

    pub fn start(s: *Spy, io: std.Io, dispatcher: transport.Dispatcher) ServerTransport.StartError!void {
        return s.inner.start(io, dispatcher);
    }

    pub fn drain(s: *Spy, io: std.Io) void {
        s.inner.drain(io);
        s.drained.set(io);
    }

    pub fn close(s: *Spy, io: std.Io) void {
        s.inner.close(io);
    }

    pub fn info(s: *Spy) transport.Info {
        return s.inner.info();
    }

    pub fn isReady(s: *Spy) bool {
        return s.inner.isReady();
    }
};

/// Conditions for `Job.eventually`.
const AtLeast = struct {
    counter: *const std.atomic.Value(u32),
    n: u32,

    fn holds(c: AtLeast) bool {
        return c.counter.load(.acquire) >= c.n;
    }
};

const IsSet = struct {
    event: *const std.Io.Event,

    fn holds(c: IsSet) bool {
        return c.event.isSet();
    }
};

/// The recorder saw a cancel of call `index`.
const CancelSeen = struct {
    recorder: *RecordingDispatcher,
    io: std.Io,
    index: usize,

    fn holds(c: CancelSeen) bool {
        const seen = c.recorder.call(c.io, c.index) catch return false;
        return seen.cancels > 0;
    }
};

/// The `start` of call `index` runs now.
const Starting = struct {
    recorder: *RecordingDispatcher,
    io: std.Io,
    index: usize,

    fn holds(c: Starting) bool {
        const seen = c.recorder.call(c.io, c.index) catch return false;
        return seen.starting;
    }
};

/// The `start` of call `index` has returned.
const StartReturned = struct {
    recorder: *RecordingDispatcher,
    io: std.Io,
    index: usize,

    fn holds(c: StartReturned) bool {
        const seen = c.recorder.call(c.io, c.index) catch return false;
        return !seen.starting;
    }
};

// The checks, T1–T22.

const not_utf8 = [_]u8{ 0xff, 0xfe, 0x00, 0x80, 0xc3, 0x28, 0xed, 0xa0 };
const all_bytes: [1024]u8 = all: {
    @setEvalBranchQuota(2000);
    var bytes: [1024]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i);
    break :all bytes;
};

fn t1(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var samples: Samples = .{ .scale = job.scale() };
    var server = try job.engine(pair.server, &samples, .{});
    defer server.deinit(io);
    try job.startEngine(&server);
    const limit = job.info.max_body_bytes orelse all_bytes.len;
    const bodies = [_][]const u8{ "conformance", "", &not_utf8, all_bytes[0..@min(all_bytes.len, limit)] };
    for (bodies) |body| {
        var sent: Sent = undefined;
        job.send(pair.client, .{ .body = body }, &sent);
        defer sent.deinit();
        const response = try job.ok(&sent, "an echo");
        try job.expect(std.mem.eql(u8, response.body, body), "an echo of {d} bytes came back changed, {d} bytes", .{ body.len, response.body.len });
        try job.expect(response.metadata.len == 0, "an echo came back with {d} metadata entries the server never set", .{response.metadata.len});
    }
}

const t2_request = [_]Entry{
    .{ .key = "traceparent", .value = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
    .{ .key = "tracestate", .value = "congo=t61rcWkgMzE,rojo=00f067aa0ba902b7" },
    .{ .key = "authorization", .value = "Bearer conformance-token" },
    .{ .key = "zefir-correlation-id", .value = "order-42" },
    .{ .key = "x-b", .value = "2" },
    .{ .key = "x-a", .value = "1" },
    .{ .key = "x-a", .value = "" },
    .{ .key = "x-empty", .value = "" },
    .{ .key = "x-a", .value = "3" },
};

const t2_response = [_]Entry{
    .{ .key = "x-z", .value = "last" },
    .{ .key = "x-y", .value = "" },
    .{ .key = "x-z", .value = "first" },
};

fn t2(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);
    var caller: Caller = .init(job, pair.client, .{ .body = "metadata", .metadata = &t2_request });
    defer caller.deinit();
    try caller.begin();
    try job.waitStarted(&recorder, 1);
    try job.sameMetadata("the request metadata on the server", (try job.view(&recorder, 0)).head.metadata, &t2_request);
    try job.respond(&recorder, 0, &.{ .status = .ok, .metadata = &t2_response, .body = "metadata" });
    try job.release(&recorder, 0, .completed);
    caller.join();
    const response = try job.ok(&caller.sent, "a call with metadata");
    try job.sameMetadata("the response metadata on the client", response.metadata, &t2_response);
    recorder.close(io);
    try job.noViolations(&recorder);
}

const violations_body =
    \\{"violations":[{"field":"items[2].name","code":"validation.not_empty","message":"must not be empty"}]}
;

fn t3(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);
    for (std.enums.values(core.ErrorCode), 0..) |code, i| {
        // Every other failure has a field and a body of violations.
        const with_field = i % 2 == 0;
        var app_code: [64]u8 = undefined;
        var message: [96]u8 = undefined;
        const failure: model.Failure = .{
            .code = code,
            .app_code = std.fmt.bufPrint(&app_code, "conformance.{t}", .{code}) catch unreachable,
            .message = std.fmt.bufPrint(&message, "The failure {t}, for people", .{code}) catch unreachable,
            .field = if (with_field) "items[2].name" else null,
        };
        const body = if (with_field) violations_body else "";
        var caller: Caller = .init(job, pair.client, .{ .body = "failure" });
        defer caller.deinit();
        try caller.begin();
        try job.waitStarted(&recorder, i + 1);
        try job.respond(&recorder, i, &.{ .status = .{ .failure = failure }, .body = body });
        try job.release(&recorder, i, .completed);
        caller.join();
        const response = caller.sent.result catch |err| return job.fail("the failure {t} came as error.{t}", .{ code, err });
        const got = switch (response.status) {
            .ok => return job.fail("the failure {t} came as a success", .{code}),
            .failure => |f| f,
        };
        try job.expect(got.code == code, "the failure {t} came with the code {t}", .{ code, got.code });
        try job.expect(std.mem.eql(u8, got.app_code, failure.app_code), "the failure {t} came with the app code \"{s}\", not \"{s}\"", .{ code, got.app_code, failure.app_code });
        try job.expect(std.mem.eql(u8, got.message, failure.message), "the failure {t} came with the message \"{s}\", not \"{s}\"", .{ code, got.message, failure.message });
        if (failure.field) |field| {
            const came = got.field orelse return job.fail("the failure {t} lost its field \"{s}\"", .{ code, field });
            try job.expect(std.mem.eql(u8, came, field), "the failure {t} came with the field \"{s}\", not \"{s}\"", .{ code, came, field });
        } else {
            try job.expect(got.field == null, "the failure {t} came with a field it never had", .{code});
        }
        try job.expect(std.mem.eql(u8, response.body, body), "the body of the failure {t} came changed: {d} bytes, not {d}", .{ code, response.body.len, body.len });
        try job.expect(!response.refused, "the failure {t} of a call that ran came with refused = true", .{code});
    }
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t4(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);
    var caller: Caller = .init(job, pair.client, .{ .route = head_route, .body = "head" });
    defer caller.deinit();
    const before = now(io);
    try caller.begin();
    try job.waitStarted(&recorder, 1);
    const after = now(io);
    const head = (try job.view(&recorder, 0)).head;
    try job.expect(std.mem.eql(u8, head.route.service, head_route.service) and head.route.version == head_route.version and
        std.mem.eql(u8, head.route.method, head_route.method), "the server got the route {s}.v{d}.{s}, not {s}.v{d}.{s}", .{
        head.route.service, head.route.version, head.route.method, head_route.service, head_route.version, head_route.method,
    });
    try job.expect(std.mem.eql(u8, &head.request_id, &caller.sent.request_id), "the server got another request id than the client sent", .{});
    try job.expect(std.mem.eql(u8, head.codec, "json"), "the server got the codec \"{s}\", not \"json\"", .{head.codec});
    switch (head.peer) {
        .none, .ip => {},
        .name => |name| try job.expect(name.len > 0, "the peer of a request is an empty name; use .none when the transport knows none", .{}),
    }
    try job.expect(head.received_at.nanoseconds >= before.nanoseconds and head.received_at.nanoseconds <= after.nanoseconds, "received_at is not between the call and its start on the server: not on the std.Io.Clock.awake clock?", .{});
    try job.respond(&recorder, 0, &.{ .status = .ok, .body = "head" });
    try job.release(&recorder, 0, .completed);
    caller.join();
    _ = try job.ok(&caller.sent, "a call");
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t5(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);

    const budget = job.ms(1000);
    var caller: Caller = .init(job, pair.client, .{ .body = "budget", .timeout = budget });
    defer caller.deinit();
    try caller.begin();
    try job.waitStarted(&recorder, 1);
    const timeout = (try job.view(&recorder, 0)).head.timeout orelse
        return job.fail("the server got no budget: RequestHead.timeout is null", .{});
    try job.expect(timeout.nanoseconds > 0, "the server got a budget of {d} ns", .{timeout.nanoseconds});
    try job.expect(timeout.nanoseconds <= budget.nanoseconds, "the server got a budget of {d} ms, more than the {d} ms the client had", .{ toMilliseconds(timeout), toMilliseconds(budget) });
    try job.respond(&recorder, 0, &.{ .status = .ok, .body = "budget" });
    try job.release(&recorder, 0, .completed);
    caller.join();
    _ = try job.ok(&caller.sent, "a call with a budget");

    // A deadline that has passed, and one less than 1 ms away: not sent.
    const late = [_]std.Io.Duration{ .fromMilliseconds(-1), .fromMicroseconds(500) };
    for (late) |offset| {
        var sent: Sent = undefined;
        job.send(pair.client, .{ .body = "too late", .deadline = .at(now(io).addDuration(offset)) }, &sent);
        defer sent.deinit();
        try job.expectError(&sent, error.Timeout, "a call with less than 1 ms left");
    }
    job.pause(job.ms(50));
    if (recorder.call(io, 1)) |_| {
        return job.fail("a call with less than 1 ms left reached the server", .{});
    } else |_| {}
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t6(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);

    var caller: Caller = .init(job, pair.client, .{ .body = "silent", .timeout = job.ms(200) });
    defer caller.deinit();
    try caller.begin();
    try job.waitStarted(&recorder, 1);
    caller.join();
    const sent = &caller.sent;
    try job.expectError(sent, error.Timeout, "a call the server never answered");
    // Not before the deadline (rule 3 allows 1 ms), not long after it.
    const early = sent.ended.durationTo(sent.deadline.expires);
    try job.expect(early.nanoseconds <= std.time.ns_per_ms, "Timeout came {d} ms before the deadline", .{toMilliseconds(early)});
    const overdue = sent.deadline.expires.durationTo(sent.ended);
    try job.expect(overdue.nanoseconds <= job.ms(500).nanoseconds, "Timeout came {d} ms after the deadline", .{toMilliseconds(overdue)});
    if (job.info.propagates_cancellation) {
        try job.expect(job.eventually(job.ms(2000), CancelSeen{ .recorder = &recorder, .io = io, .index = 0 }), "info().propagates_cancellation is set, and the server got no Incoming.cancel after the client's Timeout", .{});
    } else {
        try job.note("the cancel on the server after Timeout was not checked: info().propagates_cancellation is false", .{});
    }
    // A late response: the transport drops it, or says that no one waits.
    recorder.respond(io, 0, &.{ .status = .ok, .body = "late" }) catch |err| switch (err) {
        error.Closed => {},
        else => return job.fail("Reply.send of a late response returned error.{t}", .{err}),
    };
    try job.release(&recorder, 0, .canceled);
    // The next call gets its own response, not the late one.
    try job.echoed(&recorder, pair.client, 1, 2, "fresh");
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t7(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);

    // Canceled while it waits for the response.
    var waiting: Caller = .init(job, pair.client, .{ .body = "cancel me" });
    defer waiting.deinit();
    try waiting.begin();
    try job.waitStarted(&recorder, 1);
    const canceled_at = now(io);
    waiting.cancel();
    const took = canceled_at.durationTo(now(io));
    try job.expectError(&waiting.sent, error.Canceled, "a call whose task was canceled");
    try job.expect(!waiting.sent.cancel_left, "after Canceled, io.checkCancel() saw the cancelation again: the transport re-armed the one it reported", .{});
    try job.expect(took.nanoseconds <= job.ms(2000).nanoseconds, "Canceled came {d} ms after the task was canceled", .{toMilliseconds(took)});
    if (job.info.propagates_cancellation) {
        try job.expect(job.eventually(job.ms(2000), CancelSeen{ .recorder = &recorder, .io = io, .index = 0 }), "info().propagates_cancellation is set, and the server got no Incoming.cancel of a canceled call", .{});
    } else {
        try job.note("the cancel on the server was not checked: info().propagates_cancellation is false", .{});
    }
    try job.release(&recorder, 0, .canceled);

    // Canceled before the call: Canceled, once.
    var early: Caller = .init(job, pair.client, .{ .body = "canceled before" });
    early.cancel_first = true;
    defer early.deinit();
    try early.begin();
    early.cancel();
    try job.expectError(&early.sent, error.Canceled, "a call made with a cancelation pending");
    try job.expect(!early.sent.cancel_left, "after Canceled, io.checkCancel() saw the cancelation again: the transport re-armed the one it reported", .{});
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t8(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var samples: Samples = .{ .scale = job.scale() };
    var server = try job.engine(pair.server, &samples, .{});
    defer server.deinit(io);
    try job.startEngine(&server);

    const n = 64;
    var bodies: [n][9]u8 = undefined;
    var callers: [n]Caller = undefined;
    var begun: usize = 0;
    defer for (callers[0..begun]) |*c| c.deinit();
    for (&bodies, &callers, 0..) |*body, *caller, i| {
        var delay: [1]u8 = undefined;
        io.random(&delay);
        // The first byte is the handler's delay, up to 20 ms.
        body[0] = delay[0] % 21;
        _ = std.fmt.bufPrint(body[1..], "call-{d:0>3}", .{i}) catch unreachable;
        caller.* = .init(job, pair.client, .{ .route = sleep_route, .body = body });
        try caller.begin();
        begun += 1;
    }
    for (&callers, &bodies, 0..) |*caller, *body, i| {
        caller.join();
        const response = try job.ok(&caller.sent, "one of 64 calls at once");
        try job.expect(std.mem.eql(u8, response.body, body), "call {d} of 64 got the response of another call", .{i});
    }
}

fn t9(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    const limit = job.info.max_body_bytes;
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes, .max_request_bytes = @max(1 << 20, limit orelse 0) });
    defer recorder.deinit(io);
    var index: usize = 0;

    if (limit) |max| {
        const body = try job.gpa.alloc(u8, max + 1);
        defer job.gpa.free(body);
        @memset(body, 'x');
        var caller: Caller = .init(job, pair.client, .{ .body = body[0..max] });
        defer caller.deinit();
        try caller.begin();
        try job.waitStarted(&recorder, 1);
        const got = (try job.view(&recorder, 0)).body_len;
        try job.expect(got == max, "a body of max_body_bytes ({d}) came to the server as {d} bytes", .{ max, got });
        try job.respond(&recorder, 0, &.{ .status = .ok });
        try job.release(&recorder, 0, .completed);
        caller.join();
        _ = try job.ok(&caller.sent, "a call with a body of max_body_bytes");
        index = 1;

        var over: Sent = undefined;
        job.send(pair.client, .{ .body = body }, &over);
        defer over.deinit();
        try job.expectError(&over, error.RequestTooLarge, "a call with a body one byte over max_body_bytes");
        job.pause(job.ms(50));
        if (recorder.call(io, 1)) |_| {
            return job.fail("a body one byte over max_body_bytes reached the server", .{});
        } else |_| {}
    } else {
        try job.note("the body limit was not checked: info().max_body_bytes is null", .{});
    }

    // Responses over the limits the caller set.
    const response_limit: usize = if (limit) |max| @min(1024, max -| 1) else 1024;
    const big = try job.gpa.alloc(u8, response_limit + 1);
    defer job.gpa.free(big);
    @memset(big, 'r');
    const value: [57]u8 = @splat('v');
    const five = [_]Entry{
        .{ .key = "x-1", .value = "" }, .{ .key = "x-2", .value = "" }, .{ .key = "x-3", .value = "" },
        .{ .key = "x-4", .value = "" }, .{ .key = "x-5", .value = "" },
    };
    const Case = struct { what: []const u8, response: Response, fits: bool };
    // Metadata of 2 + (3 + 3 + 56) bytes is exactly 64.
    const cases = [_]Case{
        .{ .what = "a response body of max_response_bytes", .response = .{ .status = .ok, .body = big[0..response_limit] }, .fits = true },
        .{ .what = "a response body one byte over max_response_bytes", .response = .{ .status = .ok, .body = big }, .fits = false },
        .{ .what = "a response with max_response_metadata_entries entries", .response = .{ .status = .ok, .metadata = five[0..4] }, .fits = true },
        .{ .what = "a response with one entry over max_response_metadata_entries", .response = .{ .status = .ok, .metadata = &five }, .fits = false },
        .{ .what = "a response with max_response_metadata_bytes of metadata", .response = .{ .status = .ok, .metadata = &.{.{ .key = "x-k", .value = value[0..56] }} }, .fits = true },
        .{ .what = "a response with one byte of metadata over max_response_metadata_bytes", .response = .{ .status = .ok, .metadata = &.{.{ .key = "x-k", .value = &value }} }, .fits = false },
    };
    for (cases, index..) |case, i| {
        var caller: Caller = .init(job, pair.client, .{
            .body = "limits",
            .max_response_bytes = response_limit,
            .max_response_metadata_entries = 4,
            .max_response_metadata_bytes = 64,
        });
        defer caller.deinit();
        try caller.begin();
        try job.waitStarted(&recorder, i + 1);
        try job.respond(&recorder, i, &case.response);
        try job.release(&recorder, i, .completed);
        caller.join();
        if (case.fits) {
            const response = caller.sent.result catch |err| return job.fail("{s} returned error.{t}", .{ case.what, err });
            try job.expect(response.body.len == case.response.body.len and response.metadata.len == case.response.metadata.len, "{s} came changed", .{case.what});
        } else {
            if (caller.sent.result) |response| {
                return job.fail("{s} came as {s}, not error.ResponseTooLarge", .{ case.what, job.describe(response) });
            } else |err| try job.expect(err == error.ResponseTooLarge, "{s} returned error.{t}, not ResponseTooLarge", .{ case.what, err });
        }
    }
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t10(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var samples: Samples = .{ .scale = job.scale() };
    var server = try job.engine(pair.server, &samples, .{});
    defer server.deinit(io);
    try job.startEngine(&server);
    const unknown = [_]Route{
        .{ .service = service, .version = 1, .method = "missing" },
        .{ .service = service, .version = 9, .method = "echo" },
        .{ .service = "missing", .version = 1, .method = "echo" },
    };
    for (unknown) |route| {
        var sent: Sent = undefined;
        job.send(pair.client, .{ .route = route, .timeout = job.ms(2000) }, &sent);
        defer sent.deinit();
        const response = sent.result catch |err| {
            try job.expect(err == error.Unavailable, "a call to {s}.v{d}.{s}, which no server serves, returned error.{t}, not Unavailable or a failure unimplemented", .{ route.service, route.version, route.method, err });
            continue;
        };
        switch (response.status) {
            .ok => return job.fail("a call to {s}.v{d}.{s}, which no server serves, succeeded", .{ route.service, route.version, route.method }),
            .failure => |f| {
                try job.expect(f.code == .unimplemented, "a call to {s}.v{d}.{s}, which no server serves, got the failure {t}, not unimplemented", .{ route.service, route.version, route.method, f.code });
                try job.expect(response.refused, "the refusal of an unknown route came without refused = true", .{});
            },
        }
    }
}

fn t11(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var spy: Spy = .{ .inner = pair.server };
    var samples: Samples = .{ .scale = job.scale() };
    var server = try job.engine(spy.serverTransport(), &samples, .{ .grace = job.ms(10_000) });
    defer server.deinit(io);
    // Whatever happens, the handlers end before the server's deinit.
    defer samples.gate_open.set(io);
    try job.startEngine(&server);
    try job.expect(server.isReady(), "rpc.RawServer.isReady() is false for a running server: the transport's isReady says it cannot serve", .{});

    var callers: [3]Caller = undefined;
    var begun: usize = 0;
    defer for (callers[0..begun]) |*c| c.deinit();
    for (&callers) |*caller| {
        caller.* = .init(job, pair.client, .{ .route = gate_route, .body = "in flight" });
        try caller.begin();
        begun += 1;
    }
    try job.expect(job.eventually(job.ms(5000), AtLeast{ .counter = &samples.entered, .n = callers.len }), "the handlers of {d} calls did not start", .{callers.len});
    server.requestStop(io);
    try job.expect(job.eventually(job.ms(5000), IsSet{ .event = &spy.drained }), "the transport's drain did not return", .{});
    try job.expect(!server.isReady(), "rpc.RawServer.isReady() is true while the server drains", .{});

    var after: Sent = undefined;
    job.send(pair.client, .{ .body = "after drain", .timeout = job.ms(300) }, &after);
    defer after.deinit();
    if (after.result) |response| {
        return job.fail("a call after drain got {s}: the transport took it", .{job.describe(response)});
    } else |err| if (job.info.reports_unprocessed) {
        try job.expect(err == error.Unavailable, "a call after drain returned error.{t}; with info().reports_unprocessed it is Unavailable", .{err});
    } else {
        try job.expect(err == error.Unavailable or err == error.Timeout, "a call after drain returned error.{t}, not Unavailable or Timeout", .{err});
    }

    samples.gate_open.set(io);
    for (&callers) |*caller| {
        caller.join();
        const response = try job.ok(&caller.sent, "a call in flight during drain");
        try job.expect(std.mem.eql(u8, response.body, "in flight"), "a call in flight during drain got another body", .{});
    }
    try job.need(server.wait(io), "rpc.RawServer.wait after the stop");
}

fn t12(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);

    var callers: [3]Caller = undefined;
    var begun: usize = 0;
    defer for (callers[0..begun]) |*c| c.deinit();
    for (&callers) |*caller| {
        caller.* = .init(job, pair.client, .{ .body = "on the link" });
        try caller.begin();
        begun += 1;
    }
    try job.waitStarted(&recorder, callers.len);
    const broken_at = now(io);
    job.harness.break_link.?(job.harness.ptr, io, pair);
    for (&callers) |*caller| {
        caller.join();
        try job.expectError(&caller.sent, error.ConnectionLost, "a call sent before the link broke");
        const took = broken_at.durationTo(caller.sent.ended);
        try job.expect(took.nanoseconds <= job.ms(2000).nanoseconds, "ConnectionLost came {d} ms after the link broke", .{toMilliseconds(took)});
    }
    var after: Sent = undefined;
    job.send(pair.client, .{ .body = "after the break", .timeout = job.ms(1000) }, &after);
    defer after.deinit();
    try job.expectError(&after, error.Unavailable, "a call after the link broke");
    for (0..callers.len) |i| {
        try job.expect(job.eventually(job.ms(2000), CancelSeen{ .recorder = &recorder, .io = io, .index = i }), "the server got no Incoming.cancel of call {d} on the broken link", .{i});
        try job.release(&recorder, i, .canceled);
    }
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t13(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);
    var admitted: usize = 0;
    var started: usize = 0;

    for (0..4) |_| {
        try job.echoed(&recorder, pair.client, admitted, started + 1, "answered");
        admitted += 1;
        started += 1;
    }
    // Refused at admission, then by the engine at start.
    const refusals = [_]struct { model.Failure, bool }{ .{ busy, true }, .{ busy, true }, .{ no_task, false }, .{ no_task, false } };
    for (refusals) |entry| {
        const failure, const at_admission = entry;
        recorder.setAdmit(io, if (at_admission) .{ .reject = failure } else .accept);
        recorder.setStart(io, if (at_admission) .run else .{ .fail = failure });
        var sent: Sent = undefined;
        job.send(pair.client, .{ .body = "refused" }, &sent);
        defer sent.deinit();
        try job.refusal(&sent, failure, if (at_admission) "a call refused at admission" else "a call whose start was refused");
        admitted += 1;
    }
    recorder.setAdmit(io, .accept);
    recorder.setStart(io, .run);
    // The client gives up at its deadline.
    {
        var caller: Caller = .init(job, pair.client, .{ .body = "gives up", .timeout = job.ms(200) });
        defer caller.deinit();
        try caller.begin();
        try job.waitStarted(&recorder, started + 1);
        caller.join();
        try job.expectError(&caller.sent, error.Timeout, "a call the server never answered");
        try job.release(&recorder, admitted, .canceled);
        admitted += 1;
        started += 1;
    }
    // Calls still running when close begins; the engine releases them
    // after it.
    var callers: [2]Caller = undefined;
    var begun: usize = 0;
    defer for (callers[0..begun]) |*c| c.deinit();
    for (&callers) |*caller| {
        caller.* = .init(job, pair.client, .{ .body = "at close", .timeout = job.ms(1000) });
        try caller.begin();
        begun += 1;
    }
    try job.waitStarted(&recorder, started + callers.len);
    recorder.close(io);
    for (0..callers.len) |i| try job.release(&recorder, admitted + i, .canceled);
    for (&callers) |*caller| caller.join();
    try job.noViolations(&recorder);
}

fn t14(job: *Job) CheckError!void {
    try busyAddress(job);
    try twice(job);
}

/// A second server side at a busy address does not start, and leaves
/// nothing behind.
fn busyAddress(job: *Job) CheckError!void {
    const same_address = job.harness.same_address orelse
        return job.note("a busy address was not checked: the harness has no sameAddress", .{});
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var samples: Samples = .{ .scale = job.scale() };
    var server = try job.engine(pair.server, &samples, .{});
    defer server.deinit(io);
    try job.startEngine(&server);
    const rival = try job.need(same_address(job.harness.ptr, io, pair), "harness.sameAddress");
    var recorder: RecordingDispatcher = try job.need(RecordingDispatcher.init(job.gpa, .{ .routes = &recorded_routes }), "RecordingDispatcher.init");
    defer recorder.deinit(io);
    if (recorder.start(io, rival)) |_| {
        return job.fail("a second server side at the address of a running one started", .{});
    } else |_| {}
    var sent: Sent = undefined;
    job.send(pair.client, .{ .body = "still served" }, &sent);
    defer sent.deinit();
    const response = try job.ok(&sent, "a call after a start failed at the same address");
    try job.expect(std.mem.eql(u8, response.body, "still served"), "a call after a start failed at the same address got another body", .{});
    try job.expect(recorder.events().len == 0, "the server side whose start failed called its dispatcher", .{});
}

/// Calls without end from a client task: they keep the transport busy
/// while the check drains and closes it.
const Hammer = struct {
    job: *Job,
    client: ClientTransport,
    stop: std.atomic.Value(bool) = .init(false),
    /// A call returned `Canceled` though nothing canceled its task.
    false_cancel: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    fn begin(h: *Hammer) CheckError!void {
        h.future = h.job.io.concurrent(task, .{h}) catch |err|
            return h.job.fail("no task for calls: io.concurrent returned error.{t}", .{err});
    }

    fn task(h: *Hammer) void {
        while (!h.stop.load(.acquire)) {
            var sent: Sent = undefined;
            sendCall(h.job, h.client, .{ .body = "hammer", .timeout = h.job.ms(500) }, &sent);
            defer sent.deinit();
            if (sent.result) |_| {} else |err| {
                if (err == error.Canceled) h.false_cancel.store(true, .release);
                h.job.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
        }
    }

    fn finish(h: *Hammer) void {
        h.stop.store(true, .release);
        if (h.future) |*future| future.await(h.job.io);
    }
};

/// `drain` and `close` twice, with calls coming all the while; once `close`
/// has returned, nothing reaches the dispatcher.
fn twice(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes, .admit = .{ .reject = busy } });
    defer recorder.deinit(io);
    var hammers: [4]Hammer = undefined;
    var begun: usize = 0;
    defer for (hammers[0..begun]) |*h| h.finish();
    for (&hammers) |*h| {
        h.* = .{ .job = job, .client = pair.client };
        try h.begin();
        begun += 1;
    }
    recorder.waitAdmitted(io, 8) catch |err| return job.fail("calls did not reach the server: error.{t}", .{err});
    recorder.drain(io);
    pair.server.drain(io);
    recorder.close(io);
    pair.server.close(io);
    job.pause(job.ms(20));
    for (hammers[0..begun]) |*h| h.finish();
    for (&hammers) |*h| try job.expect(!h.false_cancel.load(.acquire), "a call returned Canceled though nothing canceled its task", .{});
    try job.noViolations(&recorder);
}

/// The caller's own request: buffers it overwrites once the call returns.
const Owned = struct {
    body: [24]u8 = "the caller's own body...".*,
    key: [8]u8 = "x-caller".*,
    value: [16]u8 = "the caller's own".*,
    entries: [1]Entry = undefined,

    fn call(o: *Owned, timeout: std.Io.Duration) Call {
        o.entries = .{.{ .key = &o.key, .value = &o.value }};
        return .{ .body = &o.body, .metadata = &o.entries, .timeout = timeout };
    }

    fn scribble(o: *Owned) void {
        @memset(&o.body, 'Z');
        @memset(&o.key, 'z');
        @memset(&o.value, 'Z');
    }
};

const late_body: [4096]u8 = @splat('l');
const late_response: Response = .{
    .status = .ok,
    .metadata = &.{ .{ .key = "x-late", .value = "1" }, .{ .key = "x-late", .value = "2" } },
    .body = &late_body,
};

fn t15(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);
    var owned: [3]Owned = .{ .{}, .{}, .{} };

    // A success: the response lives in the caller's allocator.
    var answered: Caller = .init(job, pair.client, owned[0].call(job.ms(10_000)));
    defer answered.deinit();
    try answered.begin();
    try job.waitStarted(&recorder, 1);
    try job.respond(&recorder, 0, &.{ .status = .ok, .metadata = &.{.{ .key = "x-response", .value = "kept" }}, .body = "the response" });
    try job.release(&recorder, 0, .completed);
    answered.join();
    const kept = try job.ok(&answered.sent, "a call");
    owned[0].scribble();

    // Timeout, then a late response.
    var timed_out: Caller = .init(job, pair.client, owned[1].call(job.ms(200)));
    defer timed_out.deinit();
    try timed_out.begin();
    try job.waitStarted(&recorder, 2);
    timed_out.join();
    try job.expectError(&timed_out.sent, error.Timeout, "a call the server never answered");
    owned[1].scribble();
    recorder.respond(io, 1, &late_response) catch {};
    try job.release(&recorder, 1, .canceled);

    // Canceled, then a late response.
    var canceled: Caller = .init(job, pair.client, owned[2].call(job.ms(10_000)));
    defer canceled.deinit();
    try canceled.begin();
    try job.waitStarted(&recorder, 3);
    canceled.cancel();
    try job.expectError(&canceled.sent, error.Canceled, "a call whose task was canceled");
    owned[2].scribble();
    recorder.respond(io, 2, &late_response) catch {};
    try job.release(&recorder, 2, .canceled);

    // More work for the transport, then the memory of the calls above.
    try job.echoed(&recorder, pair.client, 3, 4, "later");
    const outcomes = [_]struct { []const u8, *Caller }{ .{ "success", &answered }, .{ "Timeout", &timed_out }, .{ "Canceled", &canceled } };
    for (outcomes) |entry| {
        const name, const caller = entry;
        const late = caller.sent.fence.late();
        try job.expect(late == 0, "the transport used the allocator of a call {d} times after the call returned with {s}", .{ late, name });
    }
    try job.expect(std.mem.eql(u8, kept.body, "the response") and kept.metadata.len == 1 and
        std.mem.eql(u8, kept.metadata[0].key, "x-response") and std.mem.eql(u8, kept.metadata[0].value, "kept"), "the response of a call changed after the call returned: it points into the transport's memory, not CallOptions.allocator", .{});
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t16(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var samples: Samples = .{ .scale = job.scale() };
    var server = try job.engine(pair.server, &samples, .{});
    defer server.deinit(io);
    try job.startEngine(&server);
    for (0..9) |i| {
        // A pause before the last call: late duplicates have come by then.
        if (i == 8) job.pause(job.ms(100));
        var body: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&body, "again{d:0>3}", .{i}) catch unreachable;
        var sent: Sent = undefined;
        job.send(pair.client, .{ .body = &body }, &sent);
        defer sent.deinit();
        const response = try job.ok(&sent, "a call");
        try job.expect(std.mem.eql(u8, response.body, &body), "call {d} got the response of another call: a duplicate answered twice", .{i});
    }
}

fn t17(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var samples: Samples = .{ .scale = job.scale() };
    var server = try job.engine(pair.server, &samples, .{});
    defer server.deinit(io);
    try job.startEngine(&server);
    {
        var sent: Sent = undefined;
        job.send(pair.client, .{ .body = "before" }, &sent);
        defer sent.deinit();
        _ = try job.ok(&sent, "a call before the restart");
    }
    try job.need(job.harness.restart_peer.?(job.harness.ptr, io, pair), "harness.restartPeer");
    // Calls may fail while the client reconnects, then go through.
    const deadline: core.Deadline = .after(now(io), job.ms(10_000));
    var passed: u32 = 0;
    while (passed < 3) {
        var sent: Sent = undefined;
        job.send(pair.client, .{ .body = "after", .timeout = job.ms(1000) }, &sent);
        defer sent.deinit();
        if (sent.result) |response| {
            if (response.status == .ok) passed += 1;
        } else |err| {
            if (err == error.Canceled) return job.fail("a call after the restart returned Canceled though nothing canceled its task", .{});
            passed = 0;
        }
        if (passed < 3 and deadline.isExpired(now(io))) return job.fail("calls did not go through within {d} ms after the restart", .{toMilliseconds(job.ms(10_000))});
    }
}

fn t18(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    const hold = job.ms(300);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes, .start = .{ .hold = hold } });
    defer recorder.deinit(io);

    // The engine answers and releases the call before its start returns.
    {
        var caller: Caller = .init(job, pair.client, .{ .body = "early" });
        defer caller.deinit();
        try caller.begin();
        try job.waitStarted(&recorder, 1);
        try job.respond(&recorder, 0, &.{ .status = .ok, .body = "early" });
        try job.release(&recorder, 0, .completed);
        const answered_in_start = (try job.view(&recorder, 0)).starting;
        caller.join();
        const response = try job.ok(&caller.sent, "a call answered before its start returned");
        try job.expect(std.mem.eql(u8, response.body, "early"), "a call answered before its start returned got another body", .{});
        if (!answered_in_start) try job.note("the answer came after start returned, so it did not test an answer during start", .{});
    }
    // The client gives up while start runs: a cancel waits until start
    // returns.
    recorder.setStart(io, .{ .hold = job.ms(600) });
    {
        var caller: Caller = .init(job, pair.client, .{ .body = "gives up", .timeout = job.ms(200) });
        defer caller.deinit();
        try caller.begin();
        try job.waitStarted(&recorder, 2);
        caller.join();
        try job.expectError(&caller.sent, error.Timeout, "a call whose deadline passed while its start ran");
        _ = job.eventually(job.ms(2600), StartReturned{ .recorder = &recorder, .io = io, .index = 1 });
        if (job.info.propagates_cancellation) _ = job.eventually(job.ms(500), CancelSeen{ .recorder = &recorder, .io = io, .index = 1 });
        try job.release(&recorder, 1, .canceled);
    }
    // The engine has no task for the call: the transport answers with a
    // refusal, and no Reply call follows.
    recorder.setStart(io, .{ .fail = no_task });
    {
        var sent: Sent = undefined;
        job.send(pair.client, .{ .body = "no task" }, &sent);
        defer sent.deinit();
        try job.refusal(&sent, no_task, "a call whose start was refused");
    }
    if (job.harness.break_link != null and job.info.reports_connection_loss) {
        try brokenDuringStart(job, &recorder, pair);
    } else {
        try job.note("a broken link during start was not checked: it needs harness.breakLink and info().reports_connection_loss", .{});
    }
    recorder.close(io);
    try job.noViolations(&recorder);
}

/// The link breaks while three calls are in start (calls 3–5 of T18): one
/// runs on after its start, one is answered and released before its start
/// returns, and the start of one is refused. The cancel a transport holds
/// back during start goes only to the first, once its start has returned:
/// the engine has freed the other two by then.
fn brokenDuringStart(job: *Job, recorder: *RecordingDispatcher, pair: Pair) CheckError!void {
    const io = job.io;
    const hold = job.ms(600);
    recorder.setStart(io, .{ .hold = hold });
    var kept: Caller = .init(job, pair.client, .{ .body = "kept" });
    defer kept.deinit();
    var released: Caller = .init(job, pair.client, .{ .body = "released" });
    defer released.deinit();
    try kept.begin();
    try released.begin();
    // Two calls of T18 have started before these.
    try job.waitStarted(recorder, 4);
    recorder.setStart(io, .{ .fail_after = .{ .hold = hold, .failure = no_task } });
    var refused: Caller = .init(job, pair.client, .{ .body = "refused" });
    defer refused.deinit();
    try refused.begin();
    try job.expect(job.eventually(job.ms(5000), Starting{ .recorder = recorder, .io = io, .index = 5 }), "the start of call 5 did not begin", .{});
    const kept_index: usize = if (std.mem.eql(u8, (try job.view(recorder, 3)).body orelse "", "kept")) 3 else 4;
    const released_index = 7 - kept_index;

    job.harness.break_link.?(job.harness.ptr, io, pair);
    // The link is gone: the response may be lost, and the call ends anyway.
    recorder.respond(io, released_index, &.{ .status = .ok, .body = "released" }) catch {};
    try job.release(recorder, released_index, .completed);
    kept.join();
    released.join();
    refused.join();
    try job.expectError(&kept.sent, error.ConnectionLost, "a call whose link broke while its start ran");
    for ([_]usize{ 3, 4, 5 }) |index| _ = job.eventually(job.ms(2600), StartReturned{ .recorder = recorder, .io = io, .index = index });
    try job.expect(job.eventually(job.ms(2000), CancelSeen{ .recorder = recorder, .io = io, .index = kept_index }), "the server got no Incoming.cancel of a call whose link broke while its start ran", .{});
    // A cancel of the other two would come about now: cancel_after_end.
    job.pause(job.ms(50));
    try job.release(recorder, kept_index, .canceled);
}

/// Releases, drains and closes in a task with a cancelation pending, and
/// tells after each whether the cancelation is still there.
const Keeper = struct {
    job: *Job,
    recorder: *RecordingDispatcher,
    canceled: bool = false,
    after_release: ?bool = null,
    after_drain: ?bool = null,
    after_close: ?bool = null,

    fn task(k: *Keeper) void {
        const io = k.job.io;
        // Waits until the check cancels the task.
        if (io.sleep(.fromSeconds(3600), .awake)) |_| return else |_| {}
        k.canceled = true;
        io.recancel();
        k.recorder.releaseCall(io, 0, .completed) catch {};
        k.after_release = kept(io);
        if (!k.after_release.?) return;
        io.recancel();
        k.recorder.drain(io);
        k.after_drain = kept(io);
        if (!k.after_drain.?) return;
        io.recancel();
        k.recorder.close(io);
        k.after_close = kept(io);
    }

    /// Whether a cancelation is pending; the check takes it.
    fn kept(io: std.Io) bool {
        io.checkCancel() catch return true;
        return false;
    }
};

fn t19(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);
    var caller: Caller = .init(job, pair.client, .{ .body = "kept" });
    defer caller.deinit();
    try caller.begin();
    try job.waitStarted(&recorder, 1);
    try job.respond(&recorder, 0, &.{ .status = .ok, .body = "kept" });

    var keeper: Keeper = .{ .job = job, .recorder = &recorder };
    var task = io.concurrent(Keeper.task, .{&keeper}) catch |err|
        return job.fail("no task for the check: io.concurrent returned error.{t}", .{err});
    task.cancel(io);
    caller.join();
    _ = try job.ok(&caller.sent, "a call");
    try job.expect(keeper.canceled, "the task of the check was not canceled", .{});
    const steps = [_]struct { []const u8, ?bool }{
        .{ "Reply.release", keeper.after_release },
        .{ "drain", keeper.after_drain },
        .{ "close", keeper.after_close },
    };
    for (steps) |step| {
        const name, const result = step;
        const still = result orelse break;
        try job.expect(still, "{s} swallowed a cancelation of its task: io.checkCancel() after it saw none", .{name});
    }
    try job.noViolations(&recorder);
}

fn t20(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    const hold = job.ms(300);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes, .admit = .{ .hold = hold } });
    defer recorder.deinit(io);
    var caller: Caller = .init(job, pair.client, .{ .body = "on its way" });
    defer caller.deinit();
    try caller.begin();
    recorder.waitAdmitted(io, 1) catch |err| return job.fail("the call did not reach the server: error.{t}", .{err});
    const began = now(io);
    recorder.close(io);
    const took = began.durationTo(now(io));
    try job.expect(took.nanoseconds <= hold.nanoseconds + job.ms(2000).nanoseconds, "close took {d} ms with a call in admission", .{toMilliseconds(took)});
    caller.join();
    if (caller.sent.result) |response| {
        if (response.status == .ok) return job.fail("a call the server side closed on during its admission succeeded", .{});
    } else |err| {
        try job.expect(err != error.Canceled, "a call the server side closed on returned Canceled though nothing canceled its task", .{});
    }
    const state = (try job.view(&recorder, 0)).state;
    try job.expect(state == .abandoned, "a call in admission when close began ended {t}, not abandoned", .{state});
    try job.noViolations(&recorder);
}

fn t21(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var recorder: RecordingDispatcher = undefined;
    try job.record(&recorder, pair.server, .{ .routes = &recorded_routes });
    defer recorder.deinit(io);
    const refusals = [_]model.Failure{
        busy,
        .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Server is stopping" },
        .{ .code = .invalid_argument, .app_code = "rpc.invalid_metadata", .message = "Invalid metadata" },
    };
    for (refusals) |failure| {
        recorder.setAdmit(io, .{ .reject = failure });
        var sent: Sent = undefined;
        job.send(pair.client, .{ .body = "refused" }, &sent);
        defer sent.deinit();
        try job.refusal(&sent, failure, "a call refused at admission");
    }
    recorder.close(io);
    try job.noViolations(&recorder);
}

fn t22(job: *Job) CheckError!void {
    const io = job.io;
    const pair = try job.setUp();
    defer job.tearDown(pair);
    var samples: Samples = .{ .scale = job.scale() };
    var server = try job.engine(pair.server, &samples, .{ .middleware = &.{.of(serverLink)} });
    defer server.deinit(io);
    try job.startEngine(&server);
    var client = try job.need(RawClient.init(job.gpa, .{ .transport = pair.client, .middleware = &.{.of(clientLink)} }), "rpc.RawClient.init");
    defer client.deinit();
    var result = try job.need(client.call(io, .root, meta_route, "", .{ .timeout = job.ms(5000) }), "rpc.RawClient.call");
    defer result.deinit();
    switch (result.response.status) {
        .ok => {},
        .failure => |f| return job.fail("a call through middleware got the failure {t} {s} \"{s}\"", .{ f.code, f.app_code, f.message }),
    }
    try job.expect(std.mem.eql(u8, result.response.body, "client"), "the handler saw \"{s}\" under {s}, which client middleware set to \"client\"", .{ result.response.body, middleware_key });
    try job.sameMetadata("the response metadata of server middleware", result.response.metadata, &.{.{ .key = middleware_key, .value = "server" }});
}
