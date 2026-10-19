//! The checks S and L of zefir-mongo's client: a test module of its own,
//! over the public API of `mongo` alone, as an application sees it.
//!
//! - S, against a scripted server. For each check a `mongo.testing.Script`
//!   says what the server answers, after which delays, with which failures
//!   and limits; `mongo.testing.FakeServer` serves it on loopback, and a
//!   fresh client connects to `mongodb://127.0.0.1:<port>`. No MongoDB is
//!   needed, and hello can declare tiny limits, so that a write of a few
//!   items splits into batches.
//! - L, against a live mongod, given in `Options.live`: real error codes,
//!   cursors and limits. With `fail_points`, on a mongod started with
//!   `enableTestCommands=1`, the checks L7–L10 make the server fail
//!   through the fail point `failCommand`.
//!
//! `zig build test-mongo` runs this file's tests, the checks of layer S, on
//! std's test `Io`. The package tests/mongo takes the same file through
//! `dependency.path` and runs every check, S and L with fail points, on
//! zio with one executor and with four:
//!
//! ```zig
//! for (std.enums.values(checks.Check)) |check| {
//!     try checks.run(io, gpa, check, .{ .live = .{ .uri = "mongodb://127.0.0.1:27117", .fail_points = true } });
//! }
//! ```
//!
//! Each check runs in a task of its own, on a fresh client whose memory an
//! allocator counts: memory still held after `deinit` of the client fails
//! the check as a leak. Every wait has a deadline, and every delay of a
//! script is a `mongo.testing.sleepAtLeast`; `Options.time_scale` stretches
//! them for a slow machine.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Job = @import("checks/Job.zig");
const scripted = @import("checks/scripted.zig");
const live = @import("checks/live.zig");

pub const Options = struct {
    /// Stretches the deadlines, delays and tolerances the checks rely on:
    /// raise it for a slow machine or a remote server.
    time_scale: u32 = 1,
    /// The mongod of layer L; without it, a check of layer L is skipped.
    live: ?Live = null,

    pub const Live = struct {
        /// The URI of the mongod, such as "mongodb://127.0.0.1:27017". The
        /// checks write to the database "zefir_checks" and drop what they
        /// made.
        uri: []const u8,
        /// Runs L7–L10, which configure the fail point `failCommand`: the
        /// mongod must run with `enableTestCommands=1`, and nothing else
        /// may use it meanwhile. Without it, they are skipped.
        fail_points: bool = false,
    };
};

/// The checks of design §5.3; S19, the capabilities of a driver, went
/// with them in design 1.4.
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
            .s16 => "a reply that breaks OP_MSG is ProtocolViolation, and its connection is dropped",
            .s17 => "closing the client: calls out end, new ones are Closed, open cursors are killed, twice is harmless",
            .s18 => "memory: replies only from the options' allocator, the caller's buffers free after return",
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
};

/// `CheckFailed`: the check failed, and `run` printed why.
/// `SkipZigTest`: a check of layer L without `Options.live`, or L7–L10
/// without `fail_points`. `Canceled`: the caller's task was canceled
/// before the check began.
pub const Error = error{ CheckFailed, SkipZigTest, OutOfMemory, Canceled };

/// Runs `check` in a task of its own, on a fresh client whose memory comes
/// from `gpa` through an allocator that counts it. A check that fails, or
/// leaves memory held after `deinit` of its client, prints its label and
/// why to stderr and returns `error.CheckFailed`. `gpa` must be
/// thread-safe, such as `std.testing.allocator`, and `io` must offer
/// concurrency, as std's test `Io` and zio do: every check runs the server
/// and its calls in tasks of their own.
pub fn run(io: Io, gpa: Allocator, check: Check, options: Options) Error!void {
    if (check.layer() == .live) {
        const l = options.live orelse return error.SkipZigTest;
        if (check.needsFailPoints() and !l.fail_points) return error.SkipZigTest;
    }
    try io.checkCancel();
    // A Debug allocator may take a cancelable lock: blocked, the work of
    // `run` cannot swallow a cancelation of the caller.
    const outer = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(outer);

    var messages: std.heap.ArenaAllocator = .init(gpa);
    defer messages.deinit();
    const why = (try runBody(io, gpa, messages.allocator(), bodyOf(check), options)) orelse return;
    std.debug.print("{s} ({s}) failed: {s}\n", .{ check.label(), check.title(), why });
    return error.CheckFailed;
}

/// What a check does, in its task.
const Body = *const fn (job: *Job) Job.Error!void;

/// Runs `body` as `run` runs a check: in a task of its own, on a job whose
/// client allocator counts what it holds. Returns why the body failed, in
/// `arena`, or null when it passed. The tests at the end of this file give
/// it bodies that break the rules of a check.
fn runBody(io: Io, gpa: Allocator, arena: Allocator, body: Body, options: Options) error{OutOfMemory}!?[]const u8 {
    var counting: Job.Counting = .{ .parent = gpa };
    var job: Job = .{
        .io = io,
        .gpa = gpa,
        .client_gpa = counting.allocator(),
        .arena = arena,
        .options = options,
    };
    var task = io.concurrent(go, .{ &job, body }) catch
        return "no task for the check: io.concurrent returned error.ConcurrencyUnavailable; the checks need an std.Io with concurrency";
    task.await(io);
    const leaked = counting.live.load(.acquire);
    if (leaked > 0) {
        const leak = try std.fmt.allocPrint(arena, "{d} bytes in {d} allocation(s) were still held after the client's deinit", .{ counting.bytes.load(.acquire), leaked });
        return if (job.failure) |why| try std.fmt.allocPrint(arena, "{s}; {s}", .{ why, leak }) else leak;
    }
    return job.failure;
}

fn go(job: *Job, body: Body) void {
    body(job) catch |err| switch (err) {
        error.CheckFailed => {},
        error.OutOfMemory => if (job.failure == null) {
            job.failure = "out of memory";
        },
    };
}

fn bodyOf(check: Check) Body {
    return switch (check) {
        .s1 => scripted.s1,
        .s2 => scripted.s2,
        .s3 => scripted.s3,
        .s4 => scripted.s4,
        .s5 => scripted.s5,
        .s6 => scripted.s6,
        .s7 => scripted.s7,
        .s8 => scripted.s8,
        .s9 => scripted.s9,
        .s10 => scripted.s10,
        .s11 => scripted.s11,
        .s12 => scripted.s12,
        .s13 => scripted.s13,
        .s14 => scripted.s14,
        .s15 => scripted.s15,
        .s16 => scripted.s16,
        .s17 => scripted.s17,
        .s18 => scripted.s18,
        .s20 => scripted.s20,
        .s21 => scripted.s21,
        .l1 => live.l1,
        .l2 => live.l2,
        .l3 => live.l3,
        .l4 => live.l4,
        .l5 => live.l5,
        .l6 => live.l6,
        .l7 => live.l7,
        .l8 => live.l8,
        .l9 => live.l9,
        .l10 => live.l10,
    };
}

fn expectPasses(check: Check) Error!void {
    return run(std.testing.io, std.testing.allocator, check, .{});
}

test {
    std.testing.refAllDecls(@This());
    _ = Job;
}

test "S1: a command goes out as it is, with $db; its reply comes back byte for byte" {
    try expectPasses(.s1);
}

test "S2: the driver's fields: maxTimeMS within the deadline, none in getMore and killCursors, no sessions" {
    try expectPasses(.s2);
}

test "S3: ok: 0 is CommandFailed with the server's error and reply; code 50 is Timeout" {
    try expectPasses(.s3);
}

test "S4: not sent: a past deadline, a canceled token and a bad request reach no server" {
    try expectPasses(.s4);
}

test "S5: a deadline in flight: Timeout on time; the late reply is not seen" {
    try expectPasses(.s5);
}

test "S6: cancelation in flight: Interrupted, and the task keeps its cancelation" {
    try expectPasses(.s6);
}

test "S7: 64 calls at once with random delays get their own replies; a cursor moves between tasks" {
    try expectPasses(.s7);
}

test "S8: a cursor: firstBatch and three getMore in its namespace, then null and null again" {
    try expectPasses(.s8);
}

test "S9: close and deinit of a cursor: one killCursors, none at the end, one past the deadline" {
    try expectPasses(.s9);
}

test "S10: errors of a cursor: a lost getMore ends it, a deadline before getMore does not" {
    try expectPasses(.s10);
}

test "S11: batches by count: a maxWriteBatchSize of 3 splits 10 items as 3+3+3+1, in sections of kind 1" {
    try expectPasses(.s11);
}

test "S12: batches by size: each message within maxMessageSizeBytes; an item no message holds is not sent" {
    try expectPasses(.s12);
}

test "S13: merging: the indexes of writeErrors and upserted shifted, counts summed, ordered stops" {
    try expectPasses(.s13);
}

test "S14: a write cut at its third batch: IncompleteWrite with the two batches before in partial" {
    try expectPasses(.s14);
}

test "S15: the connection: closed after a request, refused, and back again" {
    try expectPasses(.s15);
}

test "S16: a reply that breaks OP_MSG is ProtocolViolation, and its connection is dropped" {
    try expectPasses(.s16);
}

test "S17: closing the client: calls out end, new ones are Closed, open cursors are killed, twice is harmless" {
    try expectPasses(.s17);
}

test "S18: memory: replies only from the options' allocator, the caller's buffers free after return" {
    try expectPasses(.s18);
}

test "S20: cancelation is never swallowed: close, deinit and paths of errors keep it" {
    try expectPasses(.s20);
}

test "S21: a token canceled after the second batch: IncompleteWrite for Cancelled; before sending: Cancelled" {
    try expectPasses(.s21);
}

test "a check of layer L is skipped without a live mongod, and L7 to L10 without fail points" {
    for (std.enums.values(Check)) |check| {
        if (check.layer() != .live) continue;
        try std.testing.expectError(error.SkipZigTest, run(std.testing.io, std.testing.allocator, check, .{}));
        if (check.needsFailPoints()) {
            // Skipped before it connects: nothing listens at this port.
            try std.testing.expectError(error.SkipZigTest, run(std.testing.io, std.testing.allocator, check, .{ .live = .{ .uri = "mongodb://127.0.0.1:1" } }));
        }
    }
}

/// Why `body` failed, as `run` would print it; null when it passed. Free
/// the text with `arena`.
fn reasonOf(arena: *std.heap.ArenaAllocator, body: Body, options: Options) !?[]const u8 {
    return runBody(std.testing.io, std.testing.allocator, arena.allocator(), body, options);
}

/// What `leaks` took and did not give back: the test frees it, from the
/// allocator under the check's.
var leaked_block: []u8 = &.{};

/// Takes memory of the client's allocator and keeps it.
fn leaks(job: *Job) Job.Error!void {
    leaked_block = try job.client_gpa.alloc(u8, 24);
}

test "a check that leaves memory of its client held fails, and says how much" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const why = try reasonOf(&arena, leaks, .{});
    defer std.testing.allocator.free(leaked_block);
    try std.testing.expectEqualStrings("24 bytes in 1 allocation(s) were still held after the client's deinit", why orelse return error.TestExpectedFailure);
}

/// Connects to the mongod of `Options.live`, and passes if it can.
fn connectsLive(job: *Job) Job.Error!void {
    _ = try job.live();
    job.end();
}

test "a check whose client cannot connect fails with why, and leaves nothing held" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Nothing listens at this port.
    const why = (try reasonOf(&arena, connectsLive, .{ .live = .{ .uri = "mongodb://127.0.0.1:1" } })) orelse return error.TestExpectedFailure;
    try std.testing.expectStringStartsWith(why, "connect to mongodb://127.0.0.1:1 returned error.Unavailable: ");
}
