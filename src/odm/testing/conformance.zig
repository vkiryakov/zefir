//! `odm.testing.conformance`: the conformance suite of odm drivers. A
//! driver is "zefir compatible" when it passes it. Group C, C1–C10, checks
//! the discipline of the contract (`odm.Driver`, `odm.Client`,
//! `odm.RawCursor`) without data: no network in `open`, deadlines,
//! cancelation, closing, cursors after it, memory, concurrency and
//! secrets. Group D, D1–D10, checks the data on a server that runs the
//! queries: inserts and their `_id`s, duplicate keys, indexes, filters,
//! sorts and cursors, updates, deletes, counts, aggregations and commands.
//! `mongo.OdmDriver` passes both against mongod, and `odm.testing.FakeDriver`
//! group C; a driver of your own runs it in the tests of its package,
//! against its server.
//!
//! ```zig
//! const Harness = struct {
//!     driver: MyDriver = undefined,
//!
//!     pub fn setUp(h: *Harness, io: std.Io, gpa: std.mem.Allocator) !odm.testing.conformance.Setup {
//!         _ = io;
//!         h.driver = .init(gpa);
//!         return .{ .driver = h.driver.driver(), .config = .{ .uri = "mongodb://127.0.0.1:27017" }, .database = "conformance" };
//!     }
//!
//!     pub fn tearDown(h: *Harness, io: std.Io, setup: odm.testing.conformance.Setup) void {
//!         dropDatabase(io, setup.database);
//!     }
//! };
//!
//! test "my driver is zefir compatible" {
//!     var harness: Harness = .{};
//!     var report = try odm.testing.conformance.run(std.testing.io, std.testing.allocator, &harness, .{});
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
//! - `setUp(h, io, gpa) !Setup`: the driver, the settings of a server that
//!   works, and a fresh, empty database on it. The driver takes its memory
//!   from `gpa`: the suite counts it, and memory left after `tearDown`
//!   fails the check as a leak.
//! - `tearDown(h, io, setup) void`: frees what `setUp` made, and drops the
//!   database. By then every client of the check is closed and freed.
//! - optional `badCredentials(h) odm.ConnectionConfig`: the settings of a
//!   login that the server refuses, whose password is `secret` (C3, C10).
//! - optional `unreachableServer(h) odm.ConnectionConfig`: the settings of
//!   a server that is not there (C1, C10); without it, the suite uses
//!   `mongodb://odm_conformance@127.0.0.1:1/`, a closed port on loopback.
//! - optional `stall(h, io, setup) !void`: the next `find` of a client of
//!   `setup.config` hangs on the server, past 5 s, so that C6 cuts it
//!   while it is in flight.
//!
//! `run` returns a report instead of failing through `std.testing`, so any
//! test runner can call it, also one that turns a panic into an exit code.
//! Each check runs on a fresh setup, in a task of its own: a check past
//! its time limit, 60 s, is canceled and fails. A check that needs a hook
//! or a capability that is missing is skipped, with the reason in the
//! report. Times are generous for CI; `Options.time_scale` stretches them
//! further.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const odm = @import("../root.zig");
const Job = @import("checks/Job.zig");
const contract = @import("checks/contract.zig");
const data = @import("checks/data.zig");

/// What a check gets from `harness.setUp`.
pub const Setup = struct {
    /// The driver under test: the checks open its clients.
    driver: odm.Driver,
    /// The settings of a server that works: `open` and `connect` succeed
    /// with them. No check changes them.
    config: odm.ConnectionConfig,
    /// A fresh, empty database on that server, for the checks of group D
    /// and the writes of group C.
    database: []const u8,
};

pub const Options = struct {
    /// Runs group D, which needs a server that runs the queries: a driver
    /// without one, as `FakeDriver`, runs group C only.
    data: bool = true,
    /// Runs only these checks; null runs all of them.
    only: ?[]const Check = null,
    /// Stretches the deadlines, waits and tolerances the checks rely on,
    /// and their time limit: raise it for a slow machine or a remote
    /// server.
    time_scale: u32 = 1,
};

/// The password that the checks of secrets look for in every text of the
/// diagnostics; `badCredentials` of the harness uses it.
pub const secret = "zefir-conformance-secret";

/// The checks of table 7.4 of the design. Later releases may add checks,
/// so a `switch` over it needs an `else` branch.
pub const Check = enum {
    c1,
    c2,
    c3,
    c4,
    c5,
    c6,
    c7,
    c8,
    c9,
    c10,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    d10,

    /// "C1" to "C10", "D1" to "D10".
    pub fn label(check: Check) []const u8 {
        return switch (check) {
            inline else => |c| comptime (if (@tagName(c)[0] == 'c') "C" else "D") ++ @tagName(c)[1..],
        };
    }

    /// What the check proves, in a few words.
    pub fn title(check: Check) []const u8 {
        return switch (check) {
            .c1 => "open does no I/O; connect to a server that is not there fails within its deadline",
            .c2 => "connect succeeds, again does nothing, and is Closed after close",
            .c3 => "a login that the server refuses is AuthenticationFailed",
            .c4 => "less than 1 ms left: DeadlineExceeded for every operation, nothing sent",
            .c5 => "a canceled token: Cancelled for every operation, nothing sent",
            .c6 => "close from two tasks and again: the call in flight cut within 2 s, new calls Closed",
            .c7 => "after close of the client its cursors are Closed, and their deinit works",
            .c8 => "memory: nothing left after deinit; results only from the allocator of the call, during it",
            .c9 => "16 tasks of 20 ping and find each, at once",
            .c10 => "the password is in no text after errors of the settings, the login and the network",
            .d1 => "insert and find: documents with _id of ObjectId, string and int64 come back the same",
            .d2 => "a repeated _id is DuplicateKey with its index, and the documents before it are in",
            .d3 => "indexes: again is no error; unique refuses a second key; sparse lets documents without it in",
            .d4 => "find: equality, $gte, $in, $regex, two sort keys, skip, limit, projection, batches, limit 1",
            .d5 => "a deadline before getMore is DeadlineExceeded, and the cursor goes on with a new context",
            .d6 => "update: matched and modified, none matched, the _id of an upsert; replace keeps _id",
            .d7 => "delete one and many; count with a filter",
            .d8 => "aggregate with $match and $group",
            .d9 => "command: ping; an unknown command is CommandFailed with code 59",
            .d10 => "a document of next stays whole until the next call of its cursor, while another cursor works",
        };
    }

    /// Group C or group D.
    pub fn needsData(check: Check) bool {
        return @tagName(check)[0] == 'd';
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

/// What came of a run. It owns its strings: one `deinit`.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    /// `name()` of the driver of the setups.
    driver_name: []const u8 = "",
    outcomes: std.EnumArray(Check, Outcome) = .initFill(.{ .skipped = "not run" }),

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
        r.* = undefined;
    }

    pub fn outcome(r: *const Report, check: Check) Outcome {
        return r.outcomes.get(check);
    }

    pub fn passedCount(r: *const Report) usize {
        return r.count(.passed);
    }

    pub fn failedCount(r: *const Report) usize {
        return r.count(.failed);
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

    /// A line of totals, then one line a check: `{f}`.
    pub fn format(r: *const Report, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("odm conformance of \"{s}\": {d} passed, {d} failed, {d} skipped\n", .{
            r.driver_name, r.passedCount(), r.failedCount(), r.skippedCount(),
        });
        for (std.enums.values(Check)) |check| {
            switch (r.outcome(check)) {
                .passed => try w.print("  passed   {s: <3}  {s}\n", .{ check.label(), check.title() }),
                .failed => |why| try w.print("  FAILED   {s: <3}  {s}: {s}\n", .{ check.label(), check.title(), why }),
                .skipped => |why| try w.print("  skipped  {s: <3}  {s}: {s}\n", .{ check.label(), check.title(), why }),
            }
        }
    }
};

/// `Canceled`: the caller's task was canceled; checked between checks.
pub const RunError = error{ OutOfMemory, Canceled };

/// Runs the checks, each on a fresh setup from `harness` and in a task of
/// its own, and reports what came of them. `gpa` must be thread-safe, such
/// as `std.testing.allocator`: drivers allocate from their tasks. `io` must
/// offer concurrency, as std's test `Io` and zio do: the checks run calls
/// in tasks of their own.
pub fn run(io: Io, gpa: Allocator, harness: anytype, options: Options) RunError!Report {
    const h: Job.Harness = .of(harness);
    // A Debug allocator may take a cancelable lock: blocked, the work of
    // `run` cannot swallow a cancelation of the caller, which it checks
    // between the checks.
    const outer = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(outer);

    var report: Report = .{ .arena = .init(gpa) };
    errdefer report.deinit();
    const arena = report.arena.allocator();
    for (std.enums.values(Check)) |check| {
        try checkpoint(io, outer);
        const result: Outcome = if (!selected(options, check))
            .{ .skipped = "not in options.only" }
        else if (skipReason(check, h, options)) |why|
            .{ .skipped = why }
        else
            try runCheck(io, gpa, arena, h, options, check, &report.driver_name);
        report.outcomes.set(check, result);
    }
    return report;
}

/// A cancelation point of the caller between two checks.
fn checkpoint(io: Io, outer: Io.CancelProtection) error{Canceled}!void {
    _ = io.swapCancelProtection(outer);
    defer _ = io.swapCancelProtection(.blocked);
    return io.checkCancel();
}

fn selected(options: Options, check: Check) bool {
    const only = options.only orelse return true;
    return std.mem.findScalar(Check, only, check) != null;
}

/// Why `check` cannot run with this harness and these options; the
/// capabilities of the client are known only to the check itself.
fn skipReason(check: Check, h: Job.Harness, options: Options) ?[]const u8 {
    if (check.needsData() and !options.data) return "options.data is false: the checks of group D need a server that runs the queries";
    return switch (check) {
        .c3 => if (h.bad_credentials == null) "the harness has no badCredentials" else null,
        .c6 => if (h.stall == null) "the harness has no stall: no call stays in flight to be cut" else null,
        else => null,
    };
}

const no_concurrency = "no task for the check: io.concurrent returned error.ConcurrencyUnavailable; the suite needs an std.Io with concurrency";

/// How long a check may run before it counts as hung, stretched by
/// `Options.time_scale`.
const time_limit: Io.Duration = .fromSeconds(60);

/// Runs one check in a task of its own, on a setup whose allocator counts
/// what the check holds; writes the driver's name into `driver_name` once.
fn runCheck(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    h: Job.Harness,
    options: Options,
    check: Check,
    driver_name: *[]const u8,
) error{OutOfMemory}!Outcome {
    var counting: Job.Counting = .{ .parent = gpa };
    var job: Job = .{
        .io = io,
        .gpa = counting.allocator(),
        .arena = arena,
        .harness = h,
        .options = options,
        .check = check,
        .body = bodyOf(check),
    };
    var done: Io.Event = .unset;
    var task = io.concurrent(Job.go, .{ &job, &done }) catch return .{ .failed = no_concurrency };
    const limit: Io.Duration = .fromNanoseconds(time_limit.nanoseconds * @max(options.time_scale, 1));
    const hung = !awaitDone(io, &done, limit);
    if (hung) {
        // Said at once: a task that ignores its cancelation would keep the
        // report from ever coming.
        std.debug.print("odm conformance: {s} still runs after {f}: it hangs, and its task is canceled\n", .{ check.label(), limit });
        task.cancel(io);
    } else task.await(io);
    if (driver_name.len == 0 and job.driver_name.len > 0) driver_name.* = try arena.dupe(u8, job.driver_name);
    var why = job.failure;
    if (hung) {
        const late = try std.fmt.allocPrint(arena, "it did not end in {f}, and its task was canceled", .{limit});
        why = if (why) |then| try std.fmt.allocPrint(arena, "{s}; then: {s}", .{ late, then }) else late;
    }
    const leaked = counting.live.load(.acquire);
    if (leaked > 0) {
        const leak = try std.fmt.allocPrint(arena, "{d} bytes in {d} allocation(s) were still held after harness.tearDown", .{ counting.bytes.load(.acquire), leaked });
        return .{ .failed = if (why) |failure| try std.fmt.allocPrint(arena, "{s}; {s}", .{ failure, leak }) else leak };
    }
    if (why) |failure| return .{ .failed = failure };
    if (job.skipped) |reason| return .{ .skipped = reason };
    return .passed;
}

/// Waits until `done` is set, for `limit` at most; whether it was set.
fn awaitDone(io: Io, done: *Io.Event, limit: Io.Duration) bool {
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = limit, .clock = .awake });
    while (!done.isSet()) {
        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return false;
        // A wakeup before the deadline that finds `done` unset comes back
        // here.
        done.waitTimeout(io, .{ .deadline = deadline }) catch {};
    }
    return true;
}

fn bodyOf(check: Check) Job.Body {
    return switch (check) {
        .c1 => contract.c1,
        .c2 => contract.c2,
        .c3 => contract.c3,
        .c4 => contract.c4,
        .c5 => contract.c5,
        .c6 => contract.c6,
        .c7 => contract.c7,
        .c8 => contract.c8,
        .c9 => contract.c9,
        .c10 => contract.c10,
        .d1 => data.d1,
        .d2 => data.d2,
        .d3 => data.d3,
        .d4 => data.d4,
        .d5 => data.d5,
        .d6 => data.d6,
        .d7 => data.d7,
        .d8 => data.d8,
        .d9 => data.d9,
        .d10 => data.d10,
    };
}
