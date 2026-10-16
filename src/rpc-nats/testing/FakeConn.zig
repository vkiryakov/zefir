//! An in-memory NATS server and one connection to it, for tests of the
//! NATS transport without a network. `fake.conn()` is the `rpc_nats.Conn`
//! to hand to `rpc_nats.Transport`; the server side and the client side of
//! a transport may share it, as one connection of an application does.
//!
//! ```zig
//! var fake: rpc_nats.testing.FakeConn = .init(gpa, .{});
//! defer fake.deinit(io); // after the transport's deinit
//! var bus: rpc_nats.Transport = try .init(gpa, fake.conn(), .{});
//! defer bus.deinit(io);
//! ```
//!
//! What it does as NATS does:
//!
//! - subjects with `*` and a final `>`;
//! - queue groups: each message goes to one member, in turn;
//! - no responders: a message with a reply subject that no subscription
//!   takes gets `NATS/1.0 503` and no payload on its reply subject;
//! - `max_payload`: a larger message, headers included, fails with
//!   PayloadTooLarge;
//! - permissions: a publish to a denied subject fails with
//!   PermissionDenied; a denied subscription fails the next `flush` with
//!   PermissionDenied, its `next` too, and gets nothing;
//! - drain and unsubscribe of a subscription.
//!
//! Hooks for failures: `disconnect` and `reconnect` (the link drops and
//! comes back), `close` (the connection ends for good), `setDelay` (every
//! message arrives later), `failNext` (one `next` returns an error),
//! `publishRaw` (a message from another client, with a block of headers as
//! given, such as a status line) and `hangFlush`.
//!
//! Thread-safe. One task at a time waits in `next` of a subscription, as
//! the interface says; a second one is a panic. The allocator must be
//! thread-safe too: messages are freed from the tasks that release them.

const std = @import("std");
const Conn = @import("../Conn.zig");

const FakeConn = @This();

gpa: std.mem.Allocator,
options: Options,
mutex: std.Io.Mutex = .init,
/// The open subscriptions, `Sub` nodes.
subs: std.DoublyLinkedList = .{},
/// Written under `mutex`; `isConnected` reads it without.
link: std.atomic.Value(Link) = .init(.connected),
/// The fields below are guarded by `mutex`.
delay: std.Io.Duration = .zero,
hang_flush: bool = false,
/// A denied subscription since the last `flush`.
denied_since_flush: bool = false,
next_sid: u64 = 1,
counts: Stats = .{},

pub const Options = struct {
    /// The largest message, its headers and payload together; NATS's
    /// default is 1 MiB.
    max_payload: usize = 1024 * 1024,
    /// Subjects (wildcards allowed) this connection may not publish to.
    deny_publish: []const []const u8 = &.{},
    /// Subjects (wildcards allowed) this connection may not subscribe to.
    deny_subscribe: []const []const u8 = &.{},
};

pub const Link = enum(u8) { connected, disconnected, closed };

/// What the server has seen.
pub const Stats = struct {
    /// Messages published, raw ones included.
    published: u64 = 0,
    /// Copies handed to subscriptions.
    delivered: u64 = 0,
    /// Replies `NATS/1.0 503` for requests no one took.
    no_responders: u64 = 0,
};

const Sub = struct {
    fake: *FakeConn,
    node: std.DoublyLinkedList.Node = .{},
    sid: u64,
    subject: []u8,
    queue: ?[]u8,
    /// `Msg` nodes, oldest first.
    messages: std.DoublyLinkedList = .{},
    /// Wakes the task in `next`.
    cond: std.Io.Condition = .init,
    waiting: bool = false,
    state: State = .active,
    denied: bool,
    /// The link dropped: the next `next` says so once.
    disconnect_notice: bool = false,
    /// For queue groups: how many messages it took.
    turn: u64 = 0,
    failure: ?Conn.Error = null,

    const State = enum { active, draining };
};

const Msg = struct {
    gpa: std.mem.Allocator,
    node: std.DoublyLinkedList.Node = .{},
    visible_at: std.Io.Timestamp,
    bytes: []u8,
    subject: []const u8,
    reply_to: ?[]const u8,
    header_block: []const u8,
    payload: []const u8,

    fn create(gpa: std.mem.Allocator, visible_at: std.Io.Timestamp, subject: []const u8, reply_to: ?[]const u8, header_block: []const u8, payload: []const u8) error{OutOfMemory}!*Msg {
        const reply_len = if (reply_to) |r| r.len else 0;
        const bytes = try gpa.alloc(u8, subject.len + reply_len + header_block.len + payload.len);
        errdefer gpa.free(bytes);
        const m = try gpa.create(Msg);
        var at: usize = 0;
        const parts = [_][]const u8{ subject, reply_to orelse "", header_block, payload };
        var copies: [4][]const u8 = undefined;
        for (parts, &copies) |part, *copy| {
            @memcpy(bytes[at..][0..part.len], part);
            copy.* = bytes[at..][0..part.len];
            at += part.len;
        }
        m.* = .{
            .gpa = gpa,
            .visible_at = visible_at,
            .bytes = bytes,
            .subject = copies[0],
            .reply_to = if (reply_to != null) copies[1] else null,
            .header_block = copies[2],
            .payload = copies[3],
        };
        return m;
    }

    fn destroy(m: *Msg) void {
        const gpa = m.gpa;
        gpa.free(m.bytes);
        gpa.destroy(m);
    }

    fn release(context: *anyopaque) void {
        const m: *Msg = @ptrCast(@alignCast(context));
        m.destroy();
    }

    fn inMsg(m: *Msg) Conn.InMsg {
        return .{
            .subject = m.subject,
            .reply_to = m.reply_to,
            .header_block = m.header_block,
            .payload = m.payload,
            .context = m,
            .release_fn = release,
        };
    }
};

/// A fake server without subscriptions, and a connection to it that is up.
/// The slices of `options` are borrowed for the life of the fake.
pub fn init(gpa: std.mem.Allocator, options: Options) FakeConn {
    return .{ .gpa = gpa, .options = options };
}

/// Frees the subscriptions that are still open and their messages; after
/// the transport's `deinit` and after every message was released.
pub fn deinit(f: *FakeConn, io: std.Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    f.mutex.lockUncancelable(io);
    while (f.subs.popFirst()) |node| {
        const sub: *Sub = @fieldParentPtr("node", node);
        if (sub.waiting) @panic("rpc_nats.testing.FakeConn: deinit while a task waits in next");
        f.destroySub(sub);
    }
    f.mutex.unlock(io);
    f.* = undefined;
}

/// The connection, for the transport.
pub fn conn(f: *FakeConn) Conn {
    return .init(f);
}

/// `rpc_nats.Conn.publish`: the copies reach the subscriptions at once, or
/// `setDelay` later; it never waits for room.
pub fn publish(f: *FakeConn, io: std.Io, msg: Conn.OutMsg, timeout: std.Io.Timeout) Conn.Error!void {
    _ = timeout;
    // It never waits; blocked, a Debug allocator cannot swallow a
    // cancelation of the caller.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    switch (f.link.load(.monotonic)) {
        .connected => {},
        .disconnected => return error.Disconnected,
        .closed => return error.ConnectionClosed,
    }
    if (!isPublishSubject(msg.subject)) return error.InvalidSubject;
    if (msg.reply_to) |reply_to| if (!isPublishSubject(reply_to)) return error.InvalidSubject;
    for (f.options.deny_publish) |pattern| {
        if (matches(pattern, msg.subject)) return error.PermissionDenied;
    }
    const block_len = blockLen(msg.headers);
    if (block_len + msg.payload.len > f.options.max_payload) return error.PayloadTooLarge;
    var stack: [1024]u8 = undefined;
    var buffer_first: std.heap.BufferFirstAllocator = .init(&stack, f.gpa);
    const scratch = buffer_first.allocator();
    const block = try scratch.alloc(u8, block_len);
    defer scratch.free(block);
    writeBlock(block, msg.headers);
    try f.deliverLocked(io, msg.subject, msg.reply_to, block, msg.payload);
}

/// `rpc_nats.Conn.subscribe`: a denied subject fails the next `flush` and
/// every `next` of the subscription.
pub fn subscribe(f: *FakeConn, io: std.Io, subject: []const u8, queue: ?[]const u8, timeout: std.Io.Timeout) Conn.Error!Conn.Sub {
    _ = timeout;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    switch (f.link.load(.monotonic)) {
        .connected => {},
        .disconnected => return error.Disconnected,
        .closed => return error.ConnectionClosed,
    }
    if (!isSubscribeSubject(subject)) return error.InvalidSubject;
    if (queue) |q| if (q.len == 0 or std.mem.findAny(u8, q, " \t\r\n") != null) return error.InvalidSubject;
    var denied = false;
    for (f.options.deny_subscribe) |pattern| {
        if (matches(pattern, subject)) denied = true;
    }
    const subject_copy = try f.gpa.dupe(u8, subject);
    errdefer f.gpa.free(subject_copy);
    const queue_copy: ?[]u8 = if (queue) |q| try f.gpa.dupe(u8, q) else null;
    errdefer if (queue_copy) |q| f.gpa.free(q);
    const sub = try f.gpa.create(Sub);
    sub.* = .{ .fake = f, .sid = f.next_sid, .subject = subject_copy, .queue = queue_copy, .denied = denied };
    f.next_sid += 1;
    f.subs.append(&sub.node);
    if (denied) f.denied_since_flush = true;
    return sub;
}

/// `rpc_nats.Conn.next`: one task at a time per subscription, as the
/// interface says.
pub fn next(f: *FakeConn, io: std.Io, handle: Conn.Sub, timeout: std.Io.Timeout) Conn.Error!?Conn.InMsg {
    const sub: *Sub = @ptrCast(@alignCast(handle));
    const deadline = awakeDeadline(io, timeout);
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    if (sub.waiting) @panic("rpc_nats.testing.FakeConn: two tasks wait in next of one subscription; one at a time");
    sub.waiting = true;
    defer sub.waiting = false;
    while (true) {
        if (sub.failure) |err| {
            sub.failure = null;
            return err;
        }
        if (f.link.load(.monotonic) == .closed) return error.ConnectionClosed;
        if (sub.denied) return error.PermissionDenied;
        if (sub.disconnect_notice) {
            sub.disconnect_notice = false;
            return error.Disconnected;
        }
        const now = std.Io.Clock.awake.now(io);
        var wake_at: ?std.Io.Timestamp = null;
        if (sub.messages.first) |node| {
            const m: *Msg = @alignCast(@fieldParentPtr("node", node));
            if (m.visible_at.nanoseconds <= now.nanoseconds) {
                _ = sub.messages.popFirst();
                return m.inMsg();
            }
            wake_at = m.visible_at;
        } else if (sub.state == .draining) {
            return null;
        }
        if (deadline) |d| {
            if (now.nanoseconds >= d.nanoseconds) return error.Timeout;
            if (wake_at == null or d.nanoseconds < wake_at.?.nanoseconds) wake_at = d;
        }
        // At most an hour at a time: a far deadline never reaches the
        // futex of the OS.
        const hour: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds + std.time.ns_per_hour };
        const until = if (wake_at) |w| (if (w.nanoseconds < hour.nanoseconds) w else hour) else hour;
        sub.cond.waitTimeout(io, &f.mutex, .{ .deadline = until.withClock(.awake) }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // Woken by the clock or spuriously: look again.
            error.Timeout => {},
        };
    }
}

/// `rpc_nats.Conn.drain`: `next` hands out what is queued, then null.
pub fn drain(f: *FakeConn, io: std.Io, handle: Conn.Sub) Conn.Error!void {
    const sub: *Sub = @ptrCast(@alignCast(handle));
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    if (f.link.load(.monotonic) == .closed) return error.ConnectionClosed;
    sub.state = .draining;
    sub.cond.signal(io);
}

/// `rpc_nats.Conn.unsubscribe`: the queued messages are dropped.
pub fn unsubscribe(f: *FakeConn, io: std.Io, handle: Conn.Sub) void {
    const sub: *Sub = @ptrCast(@alignCast(handle));
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    if (sub.waiting) @panic("rpc_nats.testing.FakeConn: unsubscribe while a task waits in next; stop the reader first");
    f.subs.remove(&sub.node);
    f.destroySub(sub);
}

/// `rpc_nats.Conn.flush`: PermissionDenied once after a denied
/// subscription; with `hangFlush`, it waits out its timeout.
pub fn flush(f: *FakeConn, io: std.Io, timeout: std.Io.Timeout) Conn.Error!void {
    const hang = hang: {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        switch (f.link.load(.monotonic)) {
            .connected => {},
            .disconnected => return error.Disconnected,
            .closed => return error.ConnectionClosed,
        }
        if (f.denied_since_flush) {
            f.denied_since_flush = false;
            return error.PermissionDenied;
        }
        break :hang f.hang_flush;
    };
    if (!hang) return;
    // No PONG comes: wait out the timeout.
    const deadline = awakeDeadline(io, timeout) orelse {
        // Without a timeout the only way out is a cancelation.
        while (true) try io.sleep(.fromSeconds(3600), .awake);
    };
    while (true) {
        const now = std.Io.Clock.awake.now(io);
        if (now.nanoseconds >= deadline.nanoseconds) return error.Timeout;
        try io.sleep(.fromNanoseconds(@min(deadline.nanoseconds - now.nanoseconds, std.time.ns_per_hour)), .awake);
    }
}

/// Whether the link is up.
pub fn isConnected(f: *FakeConn) bool {
    return f.link.load(.acquire) == .connected;
}

/// The link drops: `isConnected` turns false, `publish`, `subscribe` and
/// `flush` fail with Disconnected, and the next `next` of every
/// subscription returns Disconnected once, as a library that reconnects
/// reports it. Messages on their way (`setDelay`) are lost; the
/// subscriptions stay, as they do through a reconnect.
pub fn disconnect(f: *FakeConn, io: std.Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    if (f.link.load(.monotonic) != .connected) return;
    f.link.store(.disconnected, .release);
    const now = std.Io.Clock.awake.now(io);
    var node = f.subs.first;
    while (node) |n| : (node = n.next) {
        const sub: *Sub = @fieldParentPtr("node", n);
        sub.disconnect_notice = true;
        var message = sub.messages.first;
        while (message) |m_node| {
            message = m_node.next;
            const m: *Msg = @alignCast(@fieldParentPtr("node", m_node));
            if (m.visible_at.nanoseconds > now.nanoseconds) {
                sub.messages.remove(m_node);
                m.destroy();
            }
        }
        sub.cond.signal(io);
    }
}

/// The link is back.
pub fn reconnect(f: *FakeConn, io: std.Io) void {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    if (f.link.load(.monotonic) == .disconnected) f.link.store(.connected, .release);
}

/// The connection closes for good: every operation fails with
/// ConnectionClosed, a task that waits in `next` too.
pub fn close(f: *FakeConn, io: std.Io) void {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    f.link.store(.closed, .release);
    var node = f.subs.first;
    while (node) |n| : (node = n.next) {
        const sub: *Sub = @fieldParentPtr("node", n);
        sub.cond.signal(io);
    }
}

/// Every message published from now on reaches its subscriptions `delay`
/// later; `.zero` turns it off.
pub fn setDelay(f: *FakeConn, io: std.Io, delay: std.Io.Duration) void {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    f.delay = delay;
}

/// The next `next` of the subscription to exactly `subject` returns `err`.
/// False when no subscription has that subject.
pub fn failNext(f: *FakeConn, io: std.Io, subject: []const u8, err: Conn.Error) bool {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    var node = f.subs.first;
    while (node) |n| : (node = n.next) {
        const sub: *Sub = @fieldParentPtr("node", n);
        if (!std.mem.eql(u8, sub.subject, subject)) continue;
        sub.failure = err;
        sub.cond.signal(io);
        return true;
    }
    return false;
}

/// A message from another client: its block of headers goes as given
/// (a status line, headers of a foreign service, garbage), without the
/// permissions, the link and the `max_payload` of this connection. A reply
/// subject no one takes gets no responders as usual.
pub fn publishRaw(f: *FakeConn, io: std.Io, subject: []const u8, reply_to: ?[]const u8, header_block: []const u8, payload: []const u8) error{OutOfMemory}!void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    try f.deliverLocked(io, subject, reply_to, header_block, payload);
}

/// `flush` waits for its timeout and fails with Timeout, as with a server
/// that does not answer PING.
pub fn hangFlush(f: *FakeConn, io: std.Io, hang: bool) void {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    f.hang_flush = hang;
}

/// How many subscriptions are open.
pub fn subscriptionCount(f: *FakeConn, io: std.Io) usize {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    return f.subs.len();
}

/// Whether a subscription to exactly `subject` is open, in the queue group
/// `queue` (null: none).
pub fn hasSubscription(f: *FakeConn, io: std.Io, subject: []const u8, queue: ?[]const u8) bool {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    var node = f.subs.first;
    while (node) |n| : (node = n.next) {
        const sub: *Sub = @fieldParentPtr("node", n);
        if (!std.mem.eql(u8, sub.subject, subject)) continue;
        const same_queue = if (queue) |q| (if (sub.queue) |sq| std.mem.eql(u8, q, sq) else false) else sub.queue == null;
        if (same_queue) return true;
    }
    return false;
}

/// What the server has seen so far.
pub fn stats(f: *FakeConn, io: std.Io) Stats {
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    return f.counts;
}

/// Hands copies of a message to the subscriptions it matches: every plain
/// one, and one member of each queue group in turn. A message with a reply
/// subject that no one takes gets a 503 on that subject. Under `mutex`.
fn deliverLocked(f: *FakeConn, io: std.Io, subject: []const u8, reply_to: ?[]const u8, block: []const u8, payload: []const u8) error{OutOfMemory}!void {
    f.counts.published += 1;
    const taken = try f.fanOut(io, subject, reply_to, block, payload);
    if (taken == 0) if (reply_to) |reply| {
        f.counts.no_responders += 1;
        _ = try f.fanOut(io, reply, null, "NATS/1.0 503\r\n\r\n", "");
    };
}

/// The copies of one message; how many subscriptions took it.
fn fanOut(f: *FakeConn, io: std.Io, subject: []const u8, reply_to: ?[]const u8, block: []const u8, payload: []const u8) error{OutOfMemory}!usize {
    // The member of each queue group that takes the message: the one that
    // took the fewest so far, the first among equals.
    var chosen: [16]*Sub = undefined;
    var groups: usize = 0;
    var taken: usize = 0;
    const visible_at = std.Io.Clock.awake.now(io).addDuration(f.delay);
    var node = f.subs.first;
    while (node) |n| : (node = n.next) {
        const sub: *Sub = @fieldParentPtr("node", n);
        if (sub.state != .active or sub.denied or !matches(sub.subject, subject)) continue;
        const queue = sub.queue orelse {
            try f.enqueue(io, sub, visible_at, subject, reply_to, block, payload);
            taken += 1;
            continue;
        };
        for (chosen[0..groups]) |*member| {
            if (std.mem.eql(u8, member.*.queue.?, queue)) {
                if (sub.turn < member.*.turn) member.* = sub;
                break;
            }
        } else {
            if (groups == chosen.len) @panic("rpc_nats.testing.FakeConn: more than 16 queue groups take one subject");
            chosen[groups] = sub;
            groups += 1;
        }
    }
    for (chosen[0..groups]) |member| {
        member.turn += 1;
        try f.enqueue(io, member, visible_at, subject, reply_to, block, payload);
        taken += 1;
    }
    return taken;
}

fn enqueue(f: *FakeConn, io: std.Io, sub: *Sub, visible_at: std.Io.Timestamp, subject: []const u8, reply_to: ?[]const u8, block: []const u8, payload: []const u8) error{OutOfMemory}!void {
    const m = try Msg.create(f.gpa, visible_at, subject, reply_to, block, payload);
    sub.messages.append(&m.node);
    f.counts.delivered += 1;
    sub.cond.signal(io);
}

/// Frees a subscription that has left the list, with its messages.
fn destroySub(f: *FakeConn, sub: *Sub) void {
    while (sub.messages.popFirst()) |node| {
        const m: *Msg = @alignCast(@fieldParentPtr("node", node));
        m.destroy();
    }
    f.gpa.free(sub.subject);
    if (sub.queue) |q| f.gpa.free(q);
    f.gpa.destroy(sub);
}

/// Whether `subject` matches `pattern`, where `*` stands for one token and
/// a final `>` for one or more.
pub fn matches(pattern: []const u8, subject: []const u8) bool {
    var p = std.mem.splitScalar(u8, pattern, '.');
    var s = std.mem.splitScalar(u8, subject, '.');
    while (p.next()) |token| {
        if (std.mem.eql(u8, token, ">")) return s.next() != null;
        const other = s.next() orelse return false;
        if (!std.mem.eql(u8, token, "*") and !std.mem.eql(u8, token, other)) return false;
    }
    return s.next() == null;
}

/// Tokens that are not empty, without wildcards, spaces or control
/// characters.
fn isPublishSubject(subject: []const u8) bool {
    var it = std.mem.splitScalar(u8, subject, '.');
    while (it.next()) |token| {
        if (token.len == 0) return false;
        for (token) |c| switch (c) {
            0...' ', 0x7f, '*', '>' => return false,
            else => {},
        };
    }
    return true;
}

/// The same, where a token may be `*`, and the last one `>`.
fn isSubscribeSubject(subject: []const u8) bool {
    var it = std.mem.splitScalar(u8, subject, '.');
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, "*")) continue;
        if (std.mem.eql(u8, token, ">")) return it.next() == null;
        if (!isPublishSubject(token)) return false;
    }
    return true;
}

/// The length of the `NATS/1.0` block of `headers`; 0 without headers.
fn blockLen(headers: []const Conn.Header) usize {
    if (headers.len == 0) return 0;
    var n: usize = "NATS/1.0\r\n".len + "\r\n".len;
    for (headers) |h| {
        checkHeader(h);
        n += h.name.len + ": ".len + h.value.len + "\r\n".len;
    }
    return n;
}

/// A header that would break the block is a bug of the transport.
fn checkHeader(h: Conn.Header) void {
    if (h.name.len == 0) @panic("rpc_nats.testing.FakeConn: a header without a name");
    for (h.name) |c| {
        if (c <= ' ' or c >= 0x7f or c == ':') @panic("rpc_nats.testing.FakeConn: a header name with a space, a colon or a byte outside printable ASCII");
    }
    if (std.mem.findAny(u8, h.value, "\r\n") != null) @panic("rpc_nats.testing.FakeConn: a header value with CR or LF");
}

fn writeBlock(out: []u8, headers: []const Conn.Header) void {
    if (headers.len == 0) return;
    var w: std.Io.Writer = .fixed(out);
    w.writeAll("NATS/1.0\r\n") catch unreachable;
    for (headers) |h| w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch unreachable;
    w.writeAll("\r\n") catch unreachable;
}

/// When `timeout` ends, on the awake clock; null for none. Saturates: a
/// far deadline does not overflow.
fn awakeDeadline(io: std.Io, timeout: std.Io.Timeout) ?std.Io.Timestamp {
    const left: std.Io.Duration = switch (timeout) {
        .none => return null,
        .duration => |d| d.raw,
        .deadline => |d| d.durationFromNow(io).raw,
    };
    const now = std.Io.Clock.awake.now(io);
    return .{ .nanoseconds = now.nanoseconds +| @max(left.nanoseconds, 0) };
}

const testing = std.testing;

fn waitFor(duration: std.Io.Duration) std.Io.Timeout {
    return .{ .duration = .{ .raw = duration, .clock = .awake } };
}

fn expectMessage(f: *FakeConn, sub: Conn.Sub, subject: []const u8, payload: []const u8) !void {
    const msg = (try f.next(testing.io, sub, waitFor(.fromSeconds(5)))).?;
    defer msg.release();
    try testing.expectEqualStrings(subject, msg.subject);
    try testing.expectEqualStrings(payload, msg.payload);
}

test "messages reach the subscriptions their subjects match, wildcards included" {
    const io = testing.io;
    var f: FakeConn = .init(testing.allocator, .{});
    defer f.deinit(io);
    const exact = try f.subscribe(io, "users.v1.getUser", null, .none);
    const star = try f.subscribe(io, "users.*.getUser", null, .none);
    const tail = try f.subscribe(io, "users.>", null, .none);
    const other = try f.subscribe(io, "orders.>", null, .none);
    try f.publish(io, .{ .subject = "users.v1.getUser", .payload = "1" }, .none);
    try f.publish(io, .{ .subject = "users.v2.list", .payload = "2" }, .none);
    try expectMessage(&f, exact, "users.v1.getUser", "1");
    try expectMessage(&f, star, "users.v1.getUser", "1");
    try expectMessage(&f, tail, "users.v1.getUser", "1");
    try expectMessage(&f, tail, "users.v2.list", "2");
    try testing.expectError(error.Timeout, f.next(io, other, waitFor(.fromMilliseconds(5))));
    try testing.expectError(error.Timeout, f.next(io, exact, waitFor(.fromMilliseconds(5))));
    try testing.expect(matches("a.>", "a.b.c"));
    try testing.expect(!matches("a.>", "a"));
    try testing.expect(!matches("a.*", "a.b.c"));
    try testing.expect(matches("*.b", "a.b"));
    try testing.expectEqual(@as(u64, 4), f.stats(io).delivered);
    try testing.expectEqual(@as(usize, 4), f.subscriptionCount(io));
}

test "a queue group takes each message once, its members in turn" {
    const io = testing.io;
    var f: FakeConn = .init(testing.allocator, .{});
    defer f.deinit(io);
    const a = try f.subscribe(io, "users.v1.get", "q", .none);
    const b = try f.subscribe(io, "users.v1.get", "q", .none);
    const plain = try f.subscribe(io, "users.v1.get", null, .none);
    for (0..4) |_| try f.publish(io, .{ .subject = "users.v1.get" }, .none);
    for ([_]Conn.Sub{ a, a, b, b, plain, plain, plain, plain }) |sub| try expectMessage(&f, sub, "users.v1.get", "");
    try testing.expectError(error.Timeout, f.next(io, a, waitFor(.fromMilliseconds(5))));
    try testing.expectError(error.Timeout, f.next(io, b, waitFor(.fromMilliseconds(5))));
}

test "headers become a NATS/1.0 block; a request no one takes gets a 503" {
    const io = testing.io;
    var f: FakeConn = .init(testing.allocator, .{});
    defer f.deinit(io);
    const inbox = try f.subscribe(io, "_INBOX.t.*", null, .none);
    const service = try f.subscribe(io, "svc", null, .none);
    try f.publish(io, .{ .subject = "svc", .reply_to = "_INBOX.t.1", .headers = &.{ .{ .name = "A", .value = "1" }, .{ .name = "b", .value = "" } }, .payload = "x" }, .none);
    const msg = (try f.next(io, service, .none)).?;
    try testing.expectEqualStrings("NATS/1.0\r\nA: 1\r\nb: \r\n\r\n", msg.header_block);
    try testing.expectEqualStrings("_INBOX.t.1", msg.reply_to.?);
    msg.release();

    try f.publish(io, .{ .subject = "nobody.home", .reply_to = "_INBOX.t.2" }, .none);
    const status = (try f.next(io, inbox, .none)).?;
    defer status.release();
    try testing.expectEqualStrings("_INBOX.t.2", status.subject);
    try testing.expectEqualStrings("NATS/1.0 503\r\n\r\n", status.header_block);
    try testing.expectEqualStrings("", status.payload);
    try testing.expectEqual(@as(u64, 1), f.stats(io).no_responders);
}

test "drain hands out what is queued, then null; unsubscribe ends at once" {
    const io = testing.io;
    var f: FakeConn = .init(testing.allocator, .{});
    defer f.deinit(io);
    const sub = try f.subscribe(io, "a", null, .none);
    try f.publish(io, .{ .subject = "a", .payload = "kept" }, .none);
    try f.drain(io, sub);
    try f.publish(io, .{ .subject = "a", .payload = "not taken" }, .none);
    try expectMessage(&f, sub, "a", "kept");
    try testing.expectEqual(@as(?Conn.InMsg, null), try f.next(io, sub, .none));
    f.unsubscribe(io, sub);
    try testing.expectEqual(@as(usize, 0), f.subscriptionCount(io));

    // Messages still queued are freed with the subscription.
    const other = try f.subscribe(io, "b", null, .none);
    try f.publish(io, .{ .subject = "b", .payload = "dropped" }, .none);
    f.unsubscribe(io, other);
}

test "permissions, max_payload and bad subjects" {
    const io = testing.io;
    var f: FakeConn = .init(testing.allocator, .{ .max_payload = 32, .deny_publish = &.{"secret.>"}, .deny_subscribe = &.{"users.v1.*"} });
    defer f.deinit(io);
    try testing.expectError(error.PermissionDenied, f.publish(io, .{ .subject = "secret.x" }, .none));
    try testing.expectError(error.PayloadTooLarge, f.publish(io, .{ .subject = "a", .payload = &@as([33]u8, @splat('x')) }, .none));
    // Headers count against max_payload too.
    try testing.expectError(error.PayloadTooLarge, f.publish(io, .{ .subject = "a", .headers = &.{.{ .name = "X", .value = "0123456789" }}, .payload = "0123456789" }, .none));
    try f.publish(io, .{ .subject = "a", .payload = &@as([32]u8, @splat('x')) }, .none);
    for ([_][]const u8{ "", "a..b", "a.*", "a.>", "a b" }) |subject| {
        try testing.expectError(error.InvalidSubject, f.publish(io, .{ .subject = subject }, .none));
    }
    try testing.expectError(error.InvalidSubject, f.subscribe(io, "a.>.b", null, .none));

    const denied = try f.subscribe(io, "users.v1.getUser", null, .none);
    try testing.expectError(error.PermissionDenied, f.flush(io, .none));
    try f.flush(io, .none);
    try testing.expectError(error.PermissionDenied, f.next(io, denied, .none));
    f.unsubscribe(io, denied);
}

test "the link drops and comes back; a closed connection ends everything" {
    const io = testing.io;
    var f: FakeConn = .init(testing.allocator, .{});
    defer f.deinit(io);
    const sub = try f.subscribe(io, "a", null, .none);
    try f.publish(io, .{ .subject = "a", .payload = "before" }, .none);
    f.disconnect(io);
    try testing.expect(!f.isConnected());
    try testing.expectError(error.Disconnected, f.publish(io, .{ .subject = "a" }, .none));
    try testing.expectError(error.Disconnected, f.flush(io, .none));
    try testing.expectError(error.Disconnected, f.subscribe(io, "b", null, .none));
    // Once, then what came before the drop.
    try testing.expectError(error.Disconnected, f.next(io, sub, .none));
    try expectMessage(&f, sub, "a", "before");
    f.reconnect(io);
    try testing.expect(f.isConnected());
    try f.publish(io, .{ .subject = "a", .payload = "after" }, .none);
    try expectMessage(&f, sub, "a", "after");

    f.close(io);
    try testing.expect(!f.isConnected());
    try testing.expectError(error.ConnectionClosed, f.next(io, sub, .none));
    try testing.expectError(error.ConnectionClosed, f.publish(io, .{ .subject = "a" }, .none));
    try testing.expectError(error.ConnectionClosed, f.drain(io, sub));
    f.reconnect(io);
    try testing.expect(!f.isConnected());
    f.unsubscribe(io, sub);
}

const Waiter = struct {
    f: *FakeConn,
    sub: Conn.Sub,
    result: Conn.Error!?Conn.InMsg = null,

    fn run(w: *Waiter) void {
        w.result = w.f.next(testing.io, w.sub, .none);
    }
};

test "a task waiting in next wakes for a message, a drop, the end and a cancelation" {
    const io = testing.io;
    var f: FakeConn = .init(testing.allocator, .{});
    defer f.deinit(io);
    const sub = try f.subscribe(io, "a", null, .none);

    var waiter: Waiter = .{ .f = &f, .sub = sub };
    var task = try io.concurrent(Waiter.run, .{&waiter});
    try io.sleep(.fromMilliseconds(10), .awake);
    try f.publish(io, .{ .subject = "a", .payload = "woke" }, .none);
    task.await(io);
    const msg = (try waiter.result).?;
    try testing.expectEqualStrings("woke", msg.payload);
    msg.release();

    task = try io.concurrent(Waiter.run, .{&waiter});
    try io.sleep(.fromMilliseconds(10), .awake);
    f.disconnect(io);
    task.await(io);
    try testing.expectError(error.Disconnected, waiter.result);
    f.reconnect(io);

    task = try io.concurrent(Waiter.run, .{&waiter});
    try io.sleep(.fromMilliseconds(10), .awake);
    try f.drain(io, sub);
    task.await(io);
    try testing.expectEqual(@as(?Conn.InMsg, null), try waiter.result);

    const other = try f.subscribe(io, "b", null, .none);
    var canceled: Waiter = .{ .f = &f, .sub = other };
    task = try io.concurrent(Waiter.run, .{&canceled});
    try io.sleep(.fromMilliseconds(10), .awake);
    task.cancel(io);
    try testing.expectError(error.Canceled, canceled.result);
    f.unsubscribe(io, other);
    f.unsubscribe(io, sub);
}

test "a delay holds messages back; failNext, publishRaw and hangFlush" {
    const io = testing.io;
    var f: FakeConn = .init(testing.allocator, .{});
    defer f.deinit(io);
    const sub = try f.subscribe(io, "a", null, .none);
    f.setDelay(io, .fromMilliseconds(100));
    const sent = std.Io.Clock.awake.now(io);
    try f.publish(io, .{ .subject = "a", .payload = "late" }, .none);
    try testing.expectError(error.Timeout, f.next(io, sub, waitFor(.fromMilliseconds(20))));
    try expectMessage(&f, sub, "a", "late");
    try testing.expect(sent.durationTo(std.Io.Clock.awake.now(io)).nanoseconds >= 100 * std.time.ns_per_ms);
    f.setDelay(io, .zero);

    try testing.expect(f.failNext(io, "a", error.SlowConsumer));
    try testing.expect(!f.failNext(io, "nobody", error.SlowConsumer));
    try testing.expectError(error.SlowConsumer, f.next(io, sub, .none));

    try f.publishRaw(io, "a", null, "NATS/1.0 503\r\n\r\n", "body");
    const raw = (try f.next(io, sub, .none)).?;
    try testing.expectEqualStrings("NATS/1.0 503\r\n\r\n", raw.header_block);
    try testing.expectEqualStrings("body", raw.payload);
    raw.release();

    f.hangFlush(io, true);
    try testing.expectError(error.Timeout, f.flush(io, waitFor(.fromMilliseconds(20))));
    f.hangFlush(io, false);
    try f.flush(io, .none);
    f.unsubscribe(io, sub);
}
