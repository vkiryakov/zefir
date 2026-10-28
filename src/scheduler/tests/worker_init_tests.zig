//! Tests of scheduler.Worker before its start: the settings `init`
//! refuses, each with a text that names the option, and the worker it
//! makes, which has touched no store yet.

const std = @import("std");
const testing = std.testing;
const scheduler = @import("../root.zig");

const io = testing.io;

const SendInvoiceJob = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "send-invoice" };
    pub const Payload = struct { order_id: u64 };

    pub fn run(self: *SendInvoiceJob, ctx: *scheduler.Context, payload: Payload) !void {
        _ = self;
        _ = ctx;
        _ = payload;
    }
};

const NightlyCleanup = struct {
    pub const scheduler_job: scheduler.Job = .{ .name = "nightly-cleanup", .repeat = .dailyAt(3, 30, 0, .am) };

    pub fn run(self: *NightlyCleanup, ctx: *scheduler.Context) !void {
        _ = self;
        _ = ctx;
    }
};

const Jobs = struct { invoices: *SendInvoiceJob, cleanup: *NightlyCleanup };
const Worker = scheduler.Worker(Jobs);

test "init refuses settings that cannot work, with a text" {
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    var invoices: SendInvoiceJob = .{};
    var cleanup: NightlyCleanup = .{};
    const jobs: Jobs = .{ .invoices = &invoices, .cleanup = &cleanup };
    const long: [65]u8 = @splat('w');
    const cases = [_]struct { options: Worker.Options, text: []const u8 }{
        .{ .options = .{ .lease = .fromSeconds(40) }, .text = "lease: 40s; it must be more than 2 × renew_every (20s)" },
        .{ .options = .{ .lease = .fromSeconds(5), .renew_every = .fromMilliseconds(2500) }, .text = "lease: 5s; it must be more than 2 × renew_every (2.5s)" },
        .{ .options = .{ .workers = 0 }, .text = "workers: 0; a worker runs 1 or more jobs at once" },
        .{ .options = .{ .poll_every = .zero }, .text = "poll_every: 0ns; it must be more than zero" },
        .{ .options = .{ .store_timeout = .fromSeconds(-1) }, .text = "store_timeout: -1s; it must be more than zero" },
        .{ .options = .{ .shutdown_grace = .zero }, .text = "shutdown_grace: 0ns; it must be more than zero" },
        .{ .options = .{ .start_timeout = .zero }, .text = "start_timeout: 0ns; it must be more than zero" },
        .{ .options = .{ .max_backoff = .zero }, .text = "max_backoff: 0ns; it must be more than zero" },
        .{ .options = .{ .unreadable_limit = .zero }, .text = "unreadable_limit: 0ns; it must be more than zero" },
        .{ .options = .{ .renew_every = .zero }, .text = "renew_every: 0ns; it must be more than zero" },
        .{ .options = .{ .instance = "" }, .text = "instance: empty; an instance is 1–64 bytes of UTF-8 without NUL" },
        .{ .options = .{ .instance = &long }, .text = "instance: 65 bytes; an instance is 1–64 bytes of UTF-8 without NUL" },
        .{ .options = .{ .instance = "shop\x00" }, .text = "instance: it holds a NUL; an instance is 1–64 bytes of UTF-8 without NUL" },
        .{ .options = .{ .instance = "shop\xff" }, .text = "instance: not UTF-8; an instance is 1–64 bytes of UTF-8 without NUL" },
    };
    for (cases) |case| {
        var d: scheduler.Diagnostics = .{};
        var options = case.options;
        options.diagnostics = &d;
        try testing.expectError(error.InvalidArgument, Worker.init(testing.allocator, io, memory.store(), jobs, options));
        try testing.expectEqualStrings(case.text, d.message());
    }
    // The edges that work: 64 bytes, a lease just over two renewals.
    var w: Worker = try .init(testing.allocator, io, memory.store(), jobs, .{
        .instance = long[0..64],
        .lease = .fromMilliseconds(2001),
        .renew_every = .fromSeconds(1),
    });
    w.deinit(io);
}

test "init does no I/O" {
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    var faulty: scheduler.testing.FaultyStore = .init(memory.store());
    var invoices: SendInvoiceJob = .{};
    var cleanup: NightlyCleanup = .{};
    var w: Worker = try .init(testing.allocator, io, faulty.store(), .{ .invoices = &invoices, .cleanup = &cleanup }, .{});
    defer w.deinit(io);
    for (std.enums.values(scheduler.testing.Op)) |op| try testing.expectEqual(@as(u32, 0), faulty.calls(io, op));
}

test "a new worker is configured, not ready, with zero stats" {
    var memory: scheduler.MemoryStore = .init(testing.allocator, io, .{});
    defer memory.deinit();
    var invoices: SendInvoiceJob = .{};
    var cleanup: NightlyCleanup = .{};
    var w: Worker = try .init(testing.allocator, io, memory.store(), .{ .invoices = &invoices, .cleanup = &cleanup }, .{ .workers = 3 });
    defer w.deinit(io);
    try testing.expectEqual(Worker.State.configured, w.state());
    try testing.expect(!w.isReady());
    try testing.expectEqualDeep(scheduler.Stats{
        .workers = 3,
        .running = 0,
        .claimed = 0,
        .succeeded = 0,
        .failed = 0,
        .timed_out = 0,
        .gave_up = 0,
        .lost = 0,
        .removed = 0,
        .taken_over = 0,
        .coalesced = 0,
        .skipped = 0,
        .unreadable = 0,
        .undeclared = 0,
        .store_errors = 0,
        .store_down = false,
    }, w.stats());
    // A stop before the start stops it for good.
    w.requestStop(io);
    try testing.expectEqual(Worker.State.stopped, w.state());
    try w.wait(io);
}
