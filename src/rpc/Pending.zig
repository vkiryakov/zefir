//! Slots for calls that wait for their responses, for transports that
//! match responses to requests themselves: AMQP by correlation_id, a
//! protocol over a socket by call number, NATS by inbox. Each slot has its
//! own event, so a waiting call wakes only for its own response, its
//! deadline or its cancelation.
//!
//! ```zig
//! // In `call`, in the caller's task:
//! const slot = try pending.acquire(io); // error.TooManyPendingRequests
//! defer pending.release(io, slot); // exactly once
//! try sendRequest(io, request, slot.id); // the id goes on the wire
//! const delivery = try pending.wait(io, slot, request.ctx.deadline.?);
//! defer delivery.release(delivery.context);
//! return copyResponse(options.allocator, delivery.response);
//!
//! // In the transport's receiving task:
//! const delivery: rpc.transport.Pending.Delivery = .{ .response = response, .context = message, .release = freeMessage };
//! if (!pending.complete(io, id, delivery)) freeMessage(message); // late or foreign
//! ```
//!
//! `call` copies the response into `options.allocator` in the caller's task
//! and then releases the transport's message, so the caller's allocator is
//! never used from another task.
//!
//! `init` takes the memory for `max_pending` slots; nothing is allocated
//! after it. All functions are thread-safe, and only `wait` waits for long.
//! A `Pending` stays at one address from its first use until `deinit`.

const std = @import("std");
const core = @import("core");
const model = @import("model.zig");
const untilSet = @import("wait.zig").untilSet;

const Pending = @This();

gpa: std.mem.Allocator,
mutex: std.Io.Mutex = .init,
/// The slots in use: the id of each, and the index of its waiter.
table: std.AutoArrayHashMapUnmanaged(u64, u32),
waiters: []Waiter,
/// The indexes of the free waiters: a stack, `free_len` deep.
free: []u32,
free_len: usize,
/// Ids never repeat, so a late response can never reach a later call.
next_id: u64 = 1,

/// A response handed to a slot as the transport received it. Its memory
/// stays the transport's until `release(context)`.
pub const Delivery = struct {
    response: model.Response,
    context: *anyopaque,
    release: *const fn (context: *anyopaque) void,
};

/// A call's place among the pending ones. `id` goes on the wire, as the
/// call number or the correlation id.
pub const Slot = struct { id: u64 };

pub const Options = struct {
    /// The most calls that wait for their responses at once.
    max_pending: u32,
};

pub const WaitError = std.Io.Cancelable || std.Io.Timeout.Error || FailError;

/// What `failAll` tells the waiting calls: the link broke, or the
/// transport was closed.
pub const FailError = error{ ConnectionLost, Closed };

const Waiter = struct {
    event: std.Io.Event = .unset,
    state: State = .free,

    const State = union(enum) {
        free,
        /// Acquired, with no response yet.
        waiting,
        /// `complete` handed over a response that `wait` has not taken.
        delivered: Delivery,
        /// `wait` took the response; the transport releases it.
        taken,
        /// `failAll` came before a response.
        failed: FailError,
    };
};

pub fn init(gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!Pending {
    const waiters = try gpa.alloc(Waiter, options.max_pending);
    errdefer gpa.free(waiters);
    @memset(waiters, .{});
    const free = try gpa.alloc(u32, options.max_pending);
    errdefer gpa.free(free);
    for (free, 0..) |*index, i| index.* = @intCast(free.len - 1 - i);
    var table: std.AutoArrayHashMapUnmanaged(u64, u32) = .empty;
    try table.ensureTotalCapacity(gpa, options.max_pending);
    return .{ .gpa = gpa, .table = table, .waiters = waiters, .free = free, .free_len = free.len };
}

/// Frees the slots. Every acquired slot must have been released.
pub fn deinit(p: *Pending) void {
    std.debug.assert(p.table.count() == 0);
    p.table.deinit(p.gpa);
    p.gpa.free(p.free);
    p.gpa.free(p.waiters);
    p.* = undefined;
}

/// Takes a slot for a call, before the request is sent. Never waits for
/// room: with `max_pending` slots taken it fails at once.
pub fn acquire(p: *Pending, io: std.Io) error{TooManyPendingRequests}!Slot {
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    if (p.free_len == 0) return error.TooManyPendingRequests;
    p.free_len -= 1;
    const index = p.free[p.free_len];
    const waiter = &p.waiters[index];
    waiter.event.reset();
    waiter.state = .waiting;
    const id = p.next_id;
    p.next_id += 1;
    p.table.putAssumeCapacity(id, index);
    return .{ .id = id };
}

/// Hands a response to the slot `id`, from the transport's receiving task.
/// False when there is no such slot waiting: a late response (the slot was
/// released), a foreign one, a second one for the same call, or one after
/// `failAll`. Then the transport frees its message itself. Never waits.
pub fn complete(p: *Pending, io: std.Io, id: u64, delivery: Delivery) bool {
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    const index = p.table.get(id) orelse return false;
    const waiter = &p.waiters[index];
    if (waiter.state != .waiting) return false;
    waiter.state = .{ .delivered = delivery };
    waiter.event.set(io);
    return true;
}

/// Waits for the response of `slot`, in the caller's task, no longer than
/// `deadline`; once per slot. The rules of cancelation are those of
/// `rpc.ClientTransport.call`: `error.Canceled` if and only if the task is
/// canceled, never swallowed. `error.Timeout` never comes before the
/// deadline. A response that is already there is returned even past the
/// deadline. After an error, a response that still comes is freed by
/// `release`.
pub fn wait(p: *Pending, io: std.Io, slot: Slot, deadline: core.Deadline) WaitError!Delivery {
    const waiter = p.waiterOf(io, slot);
    try untilSet(&waiter.event, io, deadline);
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    switch (waiter.state) {
        .delivered => |delivery| {
            waiter.state = .taken;
            return delivery;
        },
        .failed => |err| return err,
        // The event is set only together with a response or an error, and
        // a slot is waited for once.
        .free, .waiting, .taken => unreachable,
    }
}

fn waiterOf(p: *Pending, io: std.Io, slot: Slot) *Waiter {
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    const index = p.table.get(slot.id) orelse unreachable; // waited for after release
    return &p.waiters[index];
}

/// Gives the slot back: exactly once for each `acquire`, after `wait` or
/// when sending failed. A response that came but was not taken is freed
/// here, and a response that comes later is refused by `complete`.
pub fn release(p: *Pending, io: std.Io, slot: Slot) void {
    const untaken: ?Delivery = untaken: {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        const entry = p.table.fetchSwapRemove(slot.id);
        std.debug.assert(entry != null); // a slot is released exactly once
        const index = (entry orelse return).value;
        const waiter = &p.waiters[index];
        const found: ?Delivery = switch (waiter.state) {
            .delivered => |delivery| delivery,
            else => null,
        };
        waiter.state = .free;
        p.free[p.free_len] = index;
        p.free_len += 1;
        break :untaken found;
    };
    // Outside the lock: the transport's release may take locks of its own.
    if (untaken) |delivery| delivery.release(delivery.context);
}

/// The link broke or the transport was closed: every slot still waiting
/// for a response gets `err`, its `wait` wakes up. Slots acquired later are
/// not affected.
pub fn failAll(p: *Pending, io: std.Io, err: FailError) void {
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    for (p.table.values()) |index| {
        const waiter = &p.waiters[index];
        if (waiter.state != .waiting) continue;
        waiter.state = .{ .failed = err };
        waiter.event.set(io);
    }
}

const testing = std.testing;

/// The transport's messages in the tests: counts the ones freed.
const Messages = struct {
    freed: std.atomic.Value(u32) = .init(0),

    fn delivery(messages: *Messages, body: []const u8) Delivery {
        return .{ .response = .{ .status = .ok, .body = body }, .context = messages, .release = free };
    }

    fn free(context: *anyopaque) void {
        const messages: *Messages = @ptrCast(@alignCast(context));
        _ = messages.freed.fetchAdd(1, .monotonic);
    }

    fn count(messages: *const Messages) u32 {
        return messages.freed.load(.monotonic);
    }
};

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn inSeconds(io: std.Io, seconds: i64) core.Deadline {
    return .after(now(io), .fromSeconds(seconds));
}

fn completeLater(p: *Pending, io: std.Io, id: u64, delivery: Delivery) std.Io.Cancelable!bool {
    try io.sleep(.fromMilliseconds(20), .awake);
    return p.complete(io, id, delivery);
}

fn waitFor(p: *Pending, io: std.Io, slot: Slot) WaitError!Delivery {
    return p.wait(io, slot, inSeconds(io, 10));
}

test "a response completed before the wait is there at once" {
    const io = testing.io;
    var p: Pending = try .init(testing.allocator, .{ .max_pending = 4 });
    defer p.deinit();
    var messages: Messages = .{};

    const slot = try p.acquire(io);
    try testing.expect(p.complete(io, slot.id, messages.delivery("one")));
    const delivery = try p.wait(io, slot, inSeconds(io, 10));
    try testing.expectEqualStrings("one", delivery.response.body);
    delivery.release(delivery.context);
    p.release(io, slot);
    try testing.expectEqual(@as(u32, 1), messages.count());
}

test "a response from another task wakes a wait with a far deadline" {
    const io = testing.io;
    var p: Pending = try .init(testing.allocator, .{ .max_pending = 4 });
    defer p.deinit();
    var messages: Messages = .{};

    const slot = try p.acquire(io);
    defer p.release(io, slot);
    var completer = try io.concurrent(completeLater, .{ &p, io, slot.id, messages.delivery("two") });
    defer _ = completer.cancel(io) catch false;
    // About 35 000 years: past what one wait of std.Io.Threaded on Windows
    // can take.
    const delivery = try p.wait(io, slot, inSeconds(io, 1 << 40));
    try testing.expectEqualStrings("two", delivery.response.body);
    delivery.release(delivery.context);
    try testing.expect(try completer.await(io));
}

test "the deadline gives Timeout, not before it; a later response is dropped" {
    const io = testing.io;
    var p: Pending = try .init(testing.allocator, .{ .max_pending = 4 });
    defer p.deinit();
    var messages: Messages = .{};

    const slot = try p.acquire(io);
    const deadline: core.Deadline = .after(now(io), .fromMilliseconds(30));
    try testing.expectError(error.Timeout, p.wait(io, slot, deadline));
    try testing.expect(deadline.isExpired(now(io)));

    // A response after the timeout, before the release: release frees it.
    try testing.expect(p.complete(io, slot.id, messages.delivery("late")));
    p.release(io, slot);
    try testing.expectEqual(@as(u32, 1), messages.count());
    // After the release the id is unknown: the transport frees the message.
    try testing.expect(!p.complete(io, slot.id, messages.delivery("later")));
}

fn waitUntilCanceled(p: *Pending, io: std.Io, messages: *Messages) !void {
    const slot = try p.acquire(io);
    if (p.wait(io, slot, inSeconds(io, 1 << 40))) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.Canceled => {},
        else => return error.TestUnexpectedResult,
    }
    // Re-arm the cancelation that `wait` returned; in Debug, `recancel`
    // checks that it was real. The functions without error.Canceled must
    // keep it for the next cancelation point.
    io.recancel();
    p.release(io, slot);
    const next = try p.acquire(io);
    if (!p.complete(io, next.id, messages.delivery("never taken"))) return error.TestUnexpectedResult;
    p.failAll(io, error.ConnectionLost);
    p.release(io, next);
    return io.checkCancel();
}

test "canceling the waiting task gives Canceled once, and the functions after it keep it" {
    const io = testing.io;
    var p: Pending = try .init(testing.allocator, .{ .max_pending = 4 });
    defer p.deinit();
    var messages: Messages = .{};

    var task = try io.concurrent(waitUntilCanceled, .{ &p, io, &messages });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, task.cancel(io));
    // The response nobody waited for was freed by its release.
    try testing.expectEqual(@as(u32, 1), messages.count());
}

test "failAll wakes every waiting call with its error" {
    const io = testing.io;
    var p: Pending = try .init(testing.allocator, .{ .max_pending = 4 });
    defer p.deinit();
    var messages: Messages = .{};

    const a = try p.acquire(io);
    const b = try p.acquire(io);
    var wait_a = try io.concurrent(waitFor, .{ &p, io, a });
    defer _ = wait_a.cancel(io) catch null;
    var wait_b = try io.concurrent(waitFor, .{ &p, io, b });
    defer _ = wait_b.cancel(io) catch null;
    try io.sleep(.fromMilliseconds(10), .awake);
    p.failAll(io, error.ConnectionLost);
    try testing.expectError(error.ConnectionLost, wait_a.await(io));
    try testing.expectError(error.ConnectionLost, wait_b.await(io));
    // A response for a failed call is refused.
    try testing.expect(!p.complete(io, a.id, messages.delivery("too late")));
    p.release(io, a);
    p.release(io, b);

    // A slot taken after failAll waits as usual.
    const c = try p.acquire(io);
    try testing.expect(p.complete(io, c.id, messages.delivery("after")));
    const delivery = try p.wait(io, c, inSeconds(io, 10));
    delivery.release(delivery.context);
    p.release(io, c);

    // failAll before the wait: the wait returns the error at once.
    const d = try p.acquire(io);
    p.failAll(io, error.Closed);
    try testing.expectError(error.Closed, p.wait(io, d, inSeconds(io, 10)));
    p.release(io, d);
    try testing.expectEqual(@as(u32, 1), messages.count());
}

test "max_pending slots at most; ids never repeat" {
    const io = testing.io;
    var p: Pending = try .init(testing.allocator, .{ .max_pending = 2 });
    defer p.deinit();

    const a = try p.acquire(io);
    const b = try p.acquire(io);
    try testing.expectError(error.TooManyPendingRequests, p.acquire(io));
    p.release(io, a);
    const c = try p.acquire(io);
    try testing.expect(a.id < b.id and b.id < c.id);
    p.release(io, b);
    p.release(io, c);
}

test "a second response for one call is refused" {
    const io = testing.io;
    var p: Pending = try .init(testing.allocator, .{ .max_pending = 1 });
    defer p.deinit();
    var messages: Messages = .{};

    const slot = try p.acquire(io);
    try testing.expect(p.complete(io, slot.id, messages.delivery("first")));
    try testing.expect(!p.complete(io, slot.id, messages.delivery("second")));
    const delivery = try p.wait(io, slot, inSeconds(io, 10));
    try testing.expectEqualStrings("first", delivery.response.body);
    delivery.release(delivery.context);
    p.release(io, slot);
}

test "50 000 calls through a full window keep the table's size and speed" {
    const io = testing.io;
    const window = 512;
    var p: Pending = try .init(testing.allocator, .{ .max_pending = window });
    defer p.deinit();
    var messages: Messages = .{};

    var ring: [window]Slot = undefined;
    for (&ring) |*slot| slot.* = try p.acquire(io);
    defer for (ring) |slot| if (p.table.contains(slot.id)) p.release(io, slot);
    const capacity = p.table.capacity();

    // The oldest call gets its response and goes, a new one comes: the
    // table stays full while ids keep growing.
    var block_ns: [50]i96 = undefined;
    var oldest: usize = 0;
    var refused: usize = 0;
    for (&block_ns) |*ns| {
        const start = now(io);
        for (0..1000) |_| {
            if (!p.complete(io, ring[oldest].id, messages.delivery("x"))) refused += 1;
            p.release(io, ring[oldest]);
            ring[oldest] = try p.acquire(io);
            oldest = (oldest + 1) % window;
        }
        ns.* = start.durationTo(now(io)).nanoseconds;
    }
    try testing.expectEqual(@as(usize, 0), refused);
    try testing.expectEqual(capacity, p.table.capacity());
    try testing.expectEqual(@as(u32, 50_000), messages.count());

    // The last thousand calls cost about what the first did. The fastest of
    // five blocks at each end keeps out the noise of a busy machine.
    const first = std.mem.min(i96, block_ns[0..5]);
    const last = std.mem.min(i96, block_ns[45..]);
    try testing.expect(last <= first * 4 + std.time.ns_per_ms * 2);
}
