//! The rate limit of `emergency`: a token bucket that lets 100 records out
//! at once and 100 per second after that.

const std = @import("std");
const testing = std.testing;

/// Records the bucket lets out at once.
pub const burst = 100;
/// Records it lets out per second after that.
pub const per_second = 100;
const period_ns = std.time.ns_per_s / per_second;

pub const Bucket = struct {
    /// A spin lock: taking a token is a few instructions.
    lock: std.atomic.Mutex = .unlocked,
    tokens: u32 = burst,
    /// When the bucket last earned a token, in nanoseconds of the awake
    /// clock; long ago at first, so the bucket starts full.
    earned_at: i96 = 0,
    /// Records left out since the last one let out.
    refused: u64 = 0,

    /// Takes a token at `now` (nanoseconds of the awake clock) and returns
    /// how many records were left out since the last one let out; null when
    /// the bucket is empty, and this record is left out too.
    pub fn take(b: *Bucket, now: i96) ?u64 {
        b.acquire();
        defer b.lock.unlock();
        const earned = @divFloor(now - b.earned_at, period_ns);
        if (earned > 0) {
            b.tokens = @intCast(@min(burst, @as(i96, b.tokens) + earned));
            b.earned_at = if (b.tokens == burst) now else b.earned_at + earned * period_ns;
        }
        if (b.tokens == 0) {
            b.refused += 1;
            return null;
        }
        b.tokens -= 1;
        defer b.refused = 0;
        return b.refused;
    }

    /// Counts a record left out for another reason: the next record let
    /// out tells of it too.
    pub fn refuse(b: *Bucket) void {
        b.giveBack(1);
    }

    /// Counts `n` more records as left out: those `take` reported for a
    /// record that was not written after all.
    pub fn giveBack(b: *Bucket, n: u64) void {
        b.acquire();
        defer b.lock.unlock();
        b.refused += n;
    }

    fn acquire(b: *Bucket) void {
        while (!b.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

test "the bucket lets 100 records out at once, then 100 per second" {
    var b: Bucket = .{};
    const t0: i96 = 5 * std.time.ns_per_s;
    for (0..burst) |_| try testing.expectEqual(@as(?u64, 0), b.take(t0));
    try testing.expectEqual(@as(?u64, null), b.take(t0));
    try testing.expectEqual(@as(?u64, null), b.take(t0 + period_ns - 1));
    // One token earned: the record goes out and tells of the two refused.
    try testing.expectEqual(@as(?u64, 2), b.take(t0 + period_ns));
    try testing.expectEqual(@as(?u64, null), b.take(t0 + period_ns));
    // A long pause fills the bucket up to 100, not more.
    const later = t0 + 60 * std.time.ns_per_s;
    try testing.expectEqual(@as(?u64, 1), b.take(later));
    for (1..burst) |_| try testing.expectEqual(@as(?u64, 0), b.take(later));
    try testing.expectEqual(@as(?u64, null), b.take(later));
}

test "records left out for another reason count toward the next one too" {
    var b: Bucket = .{};
    b.refuse();
    b.refuse();
    try testing.expectEqual(@as(?u64, 2), b.take(0));
    try testing.expectEqual(@as(?u64, 0), b.take(0));
}
