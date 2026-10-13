//! A thread-safe, cooperative cancellation flag.
//!
//! The owner of an operation creates the token, hands contexts a pointer to it
//! (`Context.withCancellation`) and calls `cancel` when the operation should
//! stop. Code running the operation sees it through `Context.isCancelled` and
//! `Context.check`.
//!
//! `cancel` only sets the flag: it wakes no one and interrupts no I/O. Waking
//! a task that waits in `std.Io` is the job of `std.Io` task cancellation.
//! Use the token for explicit cancellation only (the client went away, the
//! server is stopping); a timeout is a deadline, not a cancellation.
//!
//! Everything a thread wrote before its `cancel` call is visible to a thread
//! that sees `isCancelled() == true`, for every `cancel` ordered before the
//! one it observed.
//!
//! The token must outlive every context that points to it, and must not be
//! copied once a context points to it: the copy is a separate token.

const std = @import("std");

const CancellationToken = @This();

/// Internal state; use `cancel` and `isCancelled`.
cancelled: std.atomic.Value(bool),

/// A token that is not cancelled.
pub const init: CancellationToken = .{ .cancelled = .init(false) };

/// Cancels the token. Safe to call again and from any thread.
pub fn cancel(token: *CancellationToken) void {
    // A read-modify-write keeps earlier `cancel` calls in the release
    // sequence, so the guarantee above holds with several cancelling threads.
    _ = token.cancelled.swap(true, .release);
}

/// Whether `cancel` has been called. Once true, stays true.
pub fn isCancelled(token: *const CancellationToken) bool {
    return token.cancelled.load(.acquire);
}

test "a new token is not cancelled" {
    const token: CancellationToken = .init;
    try std.testing.expect(!token.isCancelled());
}

test "cancel is permanent and idempotent" {
    var token: CancellationToken = .init;
    token.cancel();
    try std.testing.expect(token.isCancelled());
    token.cancel();
    try std.testing.expect(token.isCancelled());
}

test "writes made before cancel are visible to the thread that sees it" {
    const Shared = struct {
        token: CancellationToken = .init,
        payload: u64 = 0,

        fn produce(shared: *@This()) void {
            shared.payload = 42;
            shared.token.cancel();
        }
    };
    var shared: Shared = .{};
    const producer = try std.Thread.spawn(.{}, Shared.produce, .{&shared});
    while (!shared.token.isCancelled()) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u64, 42), shared.payload);
    producer.join();
}

test "many threads observe one cancel" {
    const Observer = struct {
        fn run(token: *const CancellationToken, seen: *std.atomic.Value(u32)) void {
            while (!token.isCancelled()) std.atomic.spinLoopHint();
            _ = seen.fetchAdd(1, .monotonic);
        }
    };
    var token: CancellationToken = .init;
    var seen: std.atomic.Value(u32) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Observer.run, .{ &token, &seen });
    token.cancel();
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, threads.len), seen.load(.monotonic));
}

test "many threads may cancel at once" {
    const Canceller = struct {
        fn run(token: *CancellationToken) void {
            token.cancel();
        }
    };
    var token: CancellationToken = .init;
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Canceller.run, .{&token});
    for (threads) |thread| thread.join();
    try std.testing.expect(token.isCancelled());
}
