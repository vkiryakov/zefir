//! `mongo.testing.conformance`: the conformance suite of MongoDB drivers.
//! A driver works with zefir when it implements `mongo.Client` and passes
//! this suite. Every driver runs the same checks: `FakeDriver` in the tests
//! of zefir-mongo, the native driver in its own, and a driver of your own
//! in the tests of its package.
//!
//! The checks come in two layers:
//!
//! - S, against a scripted server. For each check the suite sets up a
//!   `mongo.testing.Script`: what the server answers, after which delays,
//!   with which failures and limits. A driver that speaks the wire
//!   protocol connects to it through `mongo.testing.FakeServer`, at
//!   `mongodb://127.0.0.1:<port>`, without TLS and credentials; a driver
//!   in the process, such as `FakeDriver`, runs the script itself. No
//!   server is needed, and hello can declare tiny limits, so that a write
//!   of a few items splits into batches.
//! - L, against a live mongod, given in `Options.live`: real error codes,
//!   cursors and limits. With `fail_points`, on a mongod started with
//!   `enableTestCommands=1`, the checks L7–L10 make the server fail
//!   through the fail point `failCommand`.
//!
//! ```zig
//! const Harness = struct {
//!     driver: MyDriver = undefined,
//!
//!     pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator, target: mongo.testing.conformance.Target) !mongo.Client {
//!         const uri = switch (target) {
//!             .scripted => |s| s.uri, // a driver in the process takes s.script
//!             .live => |l| l.uri,
//!         };
//!         h.driver = try .init(gpa, io, .{ .uri = uri });
//!         try h.driver.connect(io, .root);
//!         return h.driver.client();
//!     }
//!
//!     pub fn close(h: *Harness, io: std.Io) void {
//!         h.driver.close(io);
//!     }
//!
//!     pub fn tearDown(h: *Harness, io: std.Io) void {
//!         _ = io;
//!         h.driver.deinit();
//!     }
//! };
//!
//! test "my driver keeps the contract of zefir-mongo" {
//!     var harness: Harness = .{};
//!     var report = try mongo.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
//!     defer report.deinit();
//!     if (report.failedCount() > 0) {
//!         std.debug.print("{f}", .{&report});
//!         return error.TestUnexpectedResult;
//!     }
//! }
//! ```
//!
//! The harness is a pointer to a type with three methods:
//!
//! - `setUp(h, io, gpa, target) !mongo.Client`: a fresh driver for
//!   `target`, connected. The driver takes its memory from `gpa`: the suite
//!   counts it, and memory still held after `tearDown` fails the check as
//!   a leak.
//! - `close(h, io) void`: `close` of the driver. The suite calls it at the
//!   end of every check, and in the middle of the checks of closing, so a
//!   second call must do nothing.
//! - `tearDown(h, io) void`: `deinit` of the driver. By then every call of
//!   the check has returned and every cursor is deinitialized.
//!
//! `run` returns a report instead of failing through `std.testing`, so any
//! test runner can call it, also one that turns a panic into an exit code.
//! Each check runs in a task of its own, on a fresh driver. A check the
//! driver cannot take is skipped, with the reason in the report: a check of
//! a later revision of the contract than the driver's; S16 when the driver
//! never connected to the FakeServer, since it reads no OP_MSG then; L
//! without `Options.live`. Times are generous for CI, and
//! `Options.time_scale` stretches them further.

const std = @import("std");
const Script = @import("Script.zig");
const Job = @import("conformance/Job.zig");
const scripted = @import("conformance/scripted.zig");
const live = @import("conformance/live.zig");

/// Where the driver of a check connects; `setUp` gets it.
pub const Target = union(enum) {
    /// The scripted server of a check of layer S.
    scripted: Scripted,
    /// The live mongod of `Options.live`, for a check of layer L.
    live: Live,

    pub const Scripted = struct {
        /// "mongodb://127.0.0.1:<port>": `mongo.testing.FakeServer` serves
        /// `script` there, to a driver that speaks the wire protocol.
        uri: []const u8,
        /// The script itself, for a driver in the process, such as
        /// `mongo.testing.FakeDriver`.
        script: *Script,
    };

    pub const Live = struct {
        uri: []const u8,
    };
};

pub const Options = struct {
    /// Runs only these checks; null runs all of them.
    only: ?[]const Check = null,
    /// Stretches the deadlines, delays and tolerances the checks rely on:
    /// raise it for a slow machine or a remote server.
    time_scale: u32 = 1,
    /// The mongod of layer L; null skips the layer.
    live: ?Live = null,

    pub const Live = struct {
        /// The URI of the mongod, as the driver takes it, such as
        /// "mongodb://127.0.0.1:27017". The checks write to the database
        /// "zefir_conformance" and drop what they made.
        uri: []const u8,
        /// Runs L7–L10, which configure the fail point `failCommand`: the
        /// mongod must run with `enableTestCommands=1`, and nothing else
        /// may use it meanwhile.
        fail_points: bool = false,
    };
};

/// The checks. Later releases may add checks, so a `switch` over it needs
/// an `else` branch.
pub const Check = enum {
    s1,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    s8,
    s9,
    s10,
    s11,
    s12,
    s13,
    s14,
    s15,
    s16,
    s17,
    s18,
    s19,
    s20,
    s21,
    l1,
    l2,
    l3,
    l4,
    l5,
    l6,
    l7,
    l8,
    l9,
    l10,

    /// "S1" to "S21", "L1" to "L10".
    pub fn label(check: Check) []const u8 {
        return switch (check) {
            inline else => |c| comptime (if (@tagName(c)[0] == 's') "S" else "L") ++ @tagName(c)[1..],
        };
    }

    /// What the check proves, in a few words.
    pub fn title(check: Check) []const u8 {
        return switch (check) {
            .s1 => "a command goes out as it is, with $db; its reply comes back byte for byte",
            .s2 => "the driver's fields: maxTimeMS within the deadline, none in getMore and killCursors, no sessions",
            .s3 => "ok: 0 is CommandFailed with the server's error and reply; code 50 is Timeout",
            .s4 => "not sent: a past deadline, a canceled token and a bad request reach no server",
            .s5 => "a deadline in flight: Timeout on time; the late reply is not seen",
            .s6 => "cancelation in flight: Interrupted, and the task keeps its cancelation",
            .s7 => "64 calls at once with random delays get their own replies; a cursor moves between tasks",
            .s8 => "a cursor: firstBatch and three getMore in its namespace, then null and null again",
            .s9 => "close and deinit of a cursor: one killCursors, none at the end, one past the deadline",
            .s10 => "errors of a cursor: a lost getMore ends it, a deadline before getMore does not",
            .s11 => "batches by count: a maxWriteBatchSize of 3 splits 10 items as 3+3+3+1, in sections of kind 1",
            .s12 => "batches by size: each message within maxMessageSizeBytes; an item no message holds is not sent",
            .s13 => "merging: the indexes of writeErrors and upserted shifted, counts summed, ordered stops",
            .s14 => "a write cut at its third batch: IncompleteWrite with the two batches before in partial",
            .s15 => "the connection: closed after a request, refused, and back again",
            .s16 => "wire only: a reply that breaks OP_MSG is ProtocolViolation, and its connection is dropped",
            .s17 => "closing the client: calls out end, new ones are Closed, open cursors are killed, twice is harmless",
            .s18 => "memory: replies only from the options' allocator, the caller's buffers free after return",
            .s19 => "capabilities: the revision, the four of revision 1, none reserved, stable, a name",
            .s20 => "cancelation is never swallowed: close, deinit and paths of errors keep it",
            .s21 => "a token canceled after the second batch: IncompleteWrite for Cancelled; before sending: Cancelled",
            .l1 => "a full round on a fresh collection: insert, find, update, findAndModify, delete, count",
            .l2 => "a real cursor: 250 documents at a batchSize of 7; close in its middle kills it",
            .l3 => "real write errors: duplicates refused at their indexes; unordered goes on, ordered stops",
            .l4 => "an unknown command: CommandFailed 59 with Diagnostics and failure_reply",
            .l5 => "64 tasks of 20 operations each",
            .l6 => "large: a document of 16 MiB there and back, a find of 18 MiB, an insert of 50 MiB",
            .l7 => "fail point closeConnection: ConnectionLost, and the next call goes through",
            .l8 => "fail point errorCode 91 with a label: CommandFailed with both, and no retry",
            .l9 => "fail point 462 with SystemOverloadedError and RetryableError: CommandFailed, and no retry",
            .l10 => "fail points blockConnection past the deadline and errorCode 50: Timeout",
        };
    }

    pub const Layer = enum { scripted, live };

    pub fn layer(check: Check) Layer {
        return if (@tagName(check)[0] == 's') .scripted else .live;
    }

    /// Whether the check configures fail points: L7–L10.
    pub fn needsFailPoints(check: Check) bool {
        return switch (check) {
            .l7, .l8, .l9, .l10 => true,
            else => false,
        };
    }

    /// The revision of the contract that the check needs of a driver.
    pub fn revision(check: Check) u16 {
        _ = check;
        return 1;
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
    /// `capabilities().name` of the driver.
    driver_name: []const u8 = "",
    outcomes: std.EnumArray(Check, Outcome) = .initFill(.{ .skipped = "not run" }),
    notes: []const Note = &.{},

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

    /// A line a check, then the notes: `{f}`.
    pub fn format(r: *const Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("mongo conformance of \"{s}\": {d} passed, {d} failed, {d} skipped\n", .{
            r.driver_name, r.passedCount(), r.failedCount(), r.skippedCount(),
        });
        for (std.enums.values(Check)) |check| {
            switch (r.outcome(check)) {
                .passed => try w.print("  passed   {s: <3}  {s}\n", .{ check.label(), check.title() }),
                .failed => |why| try w.print("  FAILED   {s: <3}  {s}: {s}\n", .{ check.label(), check.title(), why }),
                .skipped => |why| try w.print("  skipped  {s: <3}  {s}: {s}\n", .{ check.label(), check.title(), why }),
            }
        }
        for (r.notes) |note| try w.print("  note     {s: <3}  {s}\n", .{ note.check.label(), note.text });
    }
};

/// `Canceled`: the caller's task was canceled; checked between checks.
pub const RunError = error{ OutOfMemory, Canceled };

/// Runs the checks on fresh drivers from `harness`, each in a task of its
/// own, and reports what came of them. `gpa` must be thread-safe, such as
/// `std.testing.allocator`: drivers and servers allocate from their tasks.
/// `io` must offer concurrency (`std.testing.io` and zio do): every check
/// runs the server and its calls in tasks of their own.
pub fn run(io: std.Io, gpa: std.mem.Allocator, harness: anytype, options: Options) RunError!Report {
    const h: Job.Harness = .of(harness);
    // A Debug allocator may take a cancelable lock: blocked, the work of
    // `run` cannot swallow a cancelation of the caller, which it checks
    // between the checks.
    const outer = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(outer);

    var report: Report = .{ .arena = .init(gpa) };
    errdefer report.deinit();
    const arena = report.arena.allocator();

    var probe: Job.Probe = .{ .io = io, .gpa = gpa, .arena = arena, .harness = h };
    var probe_task = io.concurrent(Job.Probe.go, .{&probe}) catch {
        report.outcomes = .initFill(.{ .failed = no_concurrency });
        return report;
    };
    probe_task.await(io);
    report.driver_name = probe.name;
    if (probe.failure) |why| {
        report.outcomes = .initFill(.{ .failed = why });
        return report;
    }

    var notes: std.ArrayList(Note) = .empty;
    for (std.enums.values(Check)) |check| {
        try checkpoint(io, outer);
        const result: Outcome = if (!selected(options, check))
            .{ .skipped = "not in options.only" }
        else if (try skipReason(arena, check, &probe, options)) |why|
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
    return std.mem.findScalar(Check, only, check) != null;
}

fn skipReason(arena: std.mem.Allocator, check: Check, probe: *const Job.Probe, options: Options) error{OutOfMemory}!?[]const u8 {
    if (probe.revision < check.revision()) {
        return try std.fmt.allocPrint(arena, "it needs revision {d} of the contract, and the driver declares {d}", .{ check.revision(), probe.revision });
    }
    if (check == .s16 and !probe.wire) return "it is for drivers on the wire: no connection came to the FakeServer, so the driver reads no OP_MSG";
    if (check.layer() == .live) {
        const l = options.live orelse return "it needs a live mongod: options.live is null";
        if (check.needsFailPoints()) {
            if (!l.fail_points) return "it needs fail points: options.live.fail_points is false";
            if (!probe.wire) return "fail points need a driver on the wire: no connection came to the FakeServer, and a fail point acts on the connections of a driver to mongod";
        }
    }
    return null;
}

/// Runs one check in a task of its own, on a driver whose memory a counting
/// allocator watches.
fn runCheck(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    h: Job.Harness,
    probe: *const Job.Probe,
    options: Options,
    check: Check,
    notes: *std.ArrayList(Note),
) error{OutOfMemory}!Outcome {
    var counting: Job.Counting = .{ .parent = gpa };
    var job: Job = .{
        .io = io,
        .gpa = gpa,
        .driver_gpa = counting.allocator(),
        .arena = arena,
        .harness = h,
        .options = options,
        .on_wire = probe.wire,
    };
    var task = io.concurrent(go, .{ &job, check }) catch return .{ .failed = no_concurrency };
    task.await(io);
    for (job.notes.items) |text| try notes.append(arena, .{ .check = check, .text = text });
    const leaked = counting.live.load(.acquire);
    if (leaked > 0) {
        const leak = try std.fmt.allocPrint(arena, "{d} bytes in {d} allocation(s) were still held after harness.tearDown", .{ counting.bytes.load(.acquire), leaked });
        return .{ .failed = if (job.failure) |why| try std.fmt.allocPrint(arena, "{s}; {s}", .{ why, leak }) else leak };
    }
    return if (job.failure) |why| .{ .failed = why } else .passed;
}

fn go(job: *Job, check: Check) void {
    runBody(job, check) catch |err| switch (err) {
        error.CheckFailed => {},
        error.OutOfMemory => if (job.failure == null) {
            job.failure = "out of memory";
        },
    };
}

fn runBody(job: *Job, check: Check) Job.Error!void {
    return switch (check) {
        .s1 => scripted.s1(job),
        .s2 => scripted.s2(job),
        .s3 => scripted.s3(job),
        .s4 => scripted.s4(job),
        .s5 => scripted.s5(job),
        .s6 => scripted.s6(job),
        .s7 => scripted.s7(job),
        .s8 => scripted.s8(job),
        .s9 => scripted.s9(job),
        .s10 => scripted.s10(job),
        .s11 => scripted.s11(job),
        .s12 => scripted.s12(job),
        .s13 => scripted.s13(job),
        .s14 => scripted.s14(job),
        .s15 => scripted.s15(job),
        .s16 => scripted.s16(job),
        .s17 => scripted.s17(job),
        .s18 => scripted.s18(job),
        .s19 => scripted.s19(job),
        .s20 => scripted.s20(job),
        .s21 => scripted.s21(job),
        .l1 => live.l1(job),
        .l2 => live.l2(job),
        .l3 => live.l3(job),
        .l4 => live.l4(job),
        .l5 => live.l5(job),
        .l6 => live.l6(job),
        .l7 => live.l7(job),
        .l8 => live.l8(job),
        .l9 => live.l9(job),
        .l10 => live.l10(job),
    };
}
