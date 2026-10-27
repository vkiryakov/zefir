//! The context, its deadline and its token at times the test sets, and a
//! type that marks itself sensitive. core never reads the clock: every call
//! that needs the time takes it, so a test passes fixed times.

const std = @import("std");
const core = @import("core");

const testing = std.testing;

/// A time on the awake clock: `ms` milliseconds after it started.
fn at(ms: i64) std.Io.Timestamp {
    return .fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms);
}

test "a deadline expires when now reaches it" {
    const deadline: core.Deadline = .after(at(1_000), .fromMilliseconds(500));
    try testing.expect(!deadline.isExpired(at(1_499)));
    try testing.expect(deadline.isExpired(at(1_500))); // from the moment now reaches it
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(200), deadline.remaining(at(1_300)));
    try testing.expectEqual(std.Io.Duration.zero, deadline.remaining(at(1_800))); // never negative

    // For the calls of std.Io that take a timeout: the same moment, on the
    // awake clock.
    switch (deadline.toTimeout()) {
        .deadline => |timeout| {
            try testing.expectEqual(std.Io.Clock.awake, timeout.clock);
            try testing.expectEqual(at(1_500), timeout.raw);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a check fails once the token is cancelled or the deadline has passed" {
    var token: core.CancellationToken = .init;
    const ctx = core.Context.root
        .withDeadline(.after(at(0), .fromMilliseconds(300)))
        .withCancellation(&token);
    try ctx.check(at(299));
    try testing.expectError(error.DeadlineExceeded, ctx.check(at(300)));

    token.cancel();
    try testing.expectError(error.Cancelled, ctx.check(at(299)));
    // When both hold, cancellation wins.
    try testing.expectError(error.Cancelled, ctx.check(at(300)));
    try testing.expectEqual(core.ErrorCode.cancelled, core.ErrorCode.fromContextError(error.Cancelled));
}

test "a call's own timeout never outlives the request" {
    var token: core.CancellationToken = .init;
    const request = core.Context.root
        .withDeadline(.after(at(0), .fromSeconds(2)))
        .withCancellation(&token);

    // Early in the request, a call gets the 500 ms it asks for...
    const early = request.withDeadline(.after(at(100), .fromMilliseconds(500)));
    try testing.expectEqual(@as(?std.Io.Duration, .fromMilliseconds(500)), early.remaining(at(100)));
    // ...and late in it, only what the request has left.
    const late = request.withDeadline(.after(at(1_800), .fromMilliseconds(500)));
    try testing.expectEqual(@as(?std.Io.Duration, .fromMilliseconds(200)), late.remaining(at(1_800)));

    // The request keeps its own deadline, and its token reaches the calls.
    try testing.expectEqual(@as(?std.Io.Duration, .fromSeconds(2)), request.remaining(at(0)));
    token.cancel();
    try testing.expectError(error.Cancelled, early.check(at(100)));
}

test "the budget crosses the wire in milliseconds, and the receiver sets its own deadline" {
    // The caller is at 1.25 s on its clock, and its deadline is at 2 s.
    const caller = core.Context.root.withDeadline(.at(at(2_000)));
    const budget = caller.remaining(at(1_250)) orelse return error.TestUnexpectedResult;
    const budget_ms = budget.toMilliseconds();
    try testing.expectEqual(@as(i64, 750), budget_ms);

    // The receiver's clock says 90 s: its deadline is 750 ms from there.
    const receiver = core.Context.root.withDeadline(.after(at(90_000), .fromMilliseconds(budget_ms)));
    try testing.expectEqual(@as(?core.Deadline, .at(at(90_750))), receiver.deadline);
}

test "a budget from the wire cannot overflow, and a negative one has expired" {
    const huge: core.Deadline = .after(at(1_000), .max);
    try testing.expect(!huge.isExpired(at(1_000_000_000)));
    const negative: core.Deadline = .after(at(1_000), .fromMilliseconds(-5));
    try testing.expect(negative.isExpired(at(1_000)));
}

test "a job that outlives the request starts from root" {
    var request_token: core.CancellationToken = .init;
    const request = core.Context.root
        .withDeadline(.after(at(0), .fromMilliseconds(300)))
        .withCancellation(&request_token);

    // Replacing the token is not enough: the request's deadline stays.
    var job_token: core.CancellationToken = .init;
    const derived = request.withCancellation(&job_token);
    try testing.expectError(error.DeadlineExceeded, derived.check(at(300)));

    // From root, the job has a token and a deadline of its own.
    const job = core.Context.root
        .withDeadline(.after(at(100), .fromSeconds(30)))
        .withCancellation(&job_token);
    request_token.cancel();
    try testing.expectError(error.Cancelled, request.check(at(200)));
    try job.check(at(300));
}

const ApiKey = struct {
    value: []const u8,
    pub const zefir_sensitive = true;
};

comptime {
    std.debug.assert(core.isSensitive(ApiKey));
}

test "std.fmt does not check the marker: {any} prints the bytes" {
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{any}", .{ApiKey{ .value = "k-1" }});
    try testing.expectEqualStrings(".{ .value = { 107, 45, 49 } }", text);
}
