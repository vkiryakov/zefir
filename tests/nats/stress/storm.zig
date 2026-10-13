//! A storm of cut connections. Eight clients reach the server through a
//! proxy that cuts every connection through it again and again, while the
//! clients publish, take messages and send requests; twice the proxy first
//! stalls until the clients' queues are full, and refuses them for a
//! while after the cut, so that their reconnect buffers overflow.
//! Afterwards every client is connected again with its subscription and
//! its inbox; no publish arrived twice; every publish that did not arrive
//! was published while a connection was lost, between two confirmations
//! of the server, and is counted as uncertain or dropped; and the
//! clients' memory stayed within its bound.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("e2e");
const stress = @import("root.zig");
const Proxy = @import("Proxy.zig");

const member_count = 8;
const cuts = 40;
/// The rounds of the storm that stall the proxy before they cut.
const stall_rounds = [_]usize{ 13, 26 };
/// Publishes per client, at most: the size of the record of what arrived.
const max_sequence = 1 << 20;
const plain_port = 14222;

/// A small reconnect buffer, so that a stalled queue overflows it.
const quick_reconnect: nats.ReconnectOptions = .{
    .min_delay = .fromMilliseconds(5),
    .max_delay = .fromMilliseconds(50),
    .buffer_bytes = 16 * 1024,
};
const member_limits: nats.Limits = .{ .outbound_bytes = 256 * 1024 };

/// What a client through the proxy did.
const Counts = struct {
    /// Publishes the client took: sequence numbers 0 up to this.
    accepted: std.atomic.Value(u32) = .init(0),
    buffer_full: std.atomic.Value(u32) = .init(0),
    requests_ok: std.atomic.Value(u32) = .init(0),
    /// Requests that failed as they may in a storm: Timeout,
    /// Disconnected, BufferFull.
    requests_lost: std.atomic.Value(u32) = .init(0),
    feed_received: std.atomic.Value(u32) = .init(0),
    /// Fill publishes that found the reconnect buffer full.
    fill_buffer_full: std.atomic.Value(u32) = .init(0),
    final_received: std.atomic.Value(bool) = .init(false),
    /// Anything else: a bug.
    unexpected: std.atomic.Value(u32) = .init(0),

    fn fail(c: *Counts, what: []const u8, err: anyerror) void {
        if (c.unexpected.fetchAdd(1, .monotonic) == 0) std.debug.print("  {s}: {t}\n", .{ what, err });
    }
};

/// Sequence numbers from `from` up to `to`, `to` excluded, that may be
/// lost: they were published while a connection was lost. At most
/// `lost_at_most` of them: what the client counted as uncertain or dropped
/// meanwhile.
const Window = struct { from: u32, to: u32, lost_at_most: u64 };

const Member = struct {
    client: nats.Client,
    feed: *nats.Subscription,
    counts: Counts = .{},
    index: usize,
    /// Every publish before this sequence number is settled: it arrived,
    /// or it lies in one of `windows`. Only the publisher writes these
    /// until it is done.
    confirmed: u32 = 0,
    /// `stats().reconnects` when `confirmed` was last moved.
    confirmed_reconnects: u64 = 0,
    /// Uncertain and dropped frames by then.
    confirmed_losses: u64 = 0,
    windows: std.ArrayList(Window) = .empty,

    /// The server confirmed every publish before `sequence`: those since the
    /// last confirmation arrived, unless the connection was lost meanwhile.
    fn confirm(m: *Member, sequence: u32) error{OutOfMemory}!void {
        const stats = m.client.stats();
        const losses = stats.uncertain_outbound_frames + stats.dropped_messages;
        if (stats.reconnects != m.confirmed_reconnects) {
            try m.windows.append(testing.allocator, .{ .from = m.confirmed, .to = sequence, .lost_at_most = losses - m.confirmed_losses });
            m.confirmed_reconnects = stats.reconnects;
        }
        m.confirmed = sequence;
        m.confirmed_losses = losses;
    }

    /// The window `sequence` lies in, if any.
    fn windowOf(m: *const Member, sequence: u32) ?usize {
        for (m.windows.items, 0..) |w, i| {
            if (sequence >= w.from and sequence < w.to) return i;
        }
        return null;
    }
};

/// The payload of publish `sequence`: its number, then padding.
fn sequencePayload(buffer: *[payload_len]u8, sequence: u32) []const u8 {
    const digits = std.fmt.printInt(buffer, sequence, 10, .lower, .{});
    buffer[digits] = ' ';
    @memset(buffer[digits + 1 ..], '.');
    return buffer;
}

const payload_len = 128;

fn publishLoop(member: *Member, stop: *std.atomic.Value(bool)) Io.Cancelable!void {
    var buffer: [32]u8 = undefined;
    const subject = std.fmt.bufPrint(&buffer, "stress.storm.pub.{d}", .{member.index}) catch unreachable;
    const io = member.client.io;
    var sequence: u32 = 0;
    while (!stop.load(.monotonic) and sequence < max_sequence) {
        var payload_buffer: [payload_len]u8 = undefined;
        const payload = sequencePayload(&payload_buffer, sequence);
        member.client.publish(subject, payload) catch |err| switch (err) {
            // The reconnect buffer is full while the client is away.
            error.BufferFull => {
                _ = member.counts.buffer_full.fetchAdd(1, .monotonic);
                try io.sleep(.fromMilliseconds(1), .awake);
                continue;
            },
            error.Canceled => return error.Canceled,
            else => {
                member.counts.fail("publish", err);
                return;
            },
        };
        sequence += 1;
        member.counts.accepted.store(sequence, .monotonic);
        if (sequence % 10 == 0) try io.sleep(.fromMilliseconds(1), .awake);
        // Now and then the server confirms what it has: only what was
        // written after the last confirmation is uncertain at a cut. The
        // wait is short, so that a stalled server does not stop the
        // publishing.
        if (sequence % 200 == 0) {
            if (member.client.flush(.{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } } })) {
                member.confirm(sequence) catch |err| return member.counts.fail("confirm", err);
            } else |err| switch (err) {
                error.Disconnected, error.Timeout => {},
                error.Canceled => return error.Canceled,
                else => {
                    member.counts.fail("flush", err);
                    return;
                },
            }
        }
    }
}

fn requestLoop(member: *Member, stop: *std.atomic.Value(bool)) Io.Cancelable!void {
    const io = member.client.io;
    while (!stop.load(.monotonic)) {
        if (member.client.request("stress.storm.rpc", "ping", .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } } })) |reply| {
            var r = reply;
            defer r.deinit();
            if (std.mem.eql(u8, r.payload, "ping")) {
                _ = member.counts.requests_ok.fetchAdd(1, .monotonic);
            } else member.counts.fail("request", error.TestWrongReply);
        } else |err| switch (err) {
            error.Timeout, error.Disconnected, error.BufferFull => _ = member.counts.requests_lost.fetchAdd(1, .monotonic),
            error.Canceled => return error.Canceled,
            else => member.counts.fail("request", err),
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

fn readFeed(member: *Member) Io.Cancelable!void {
    while (true) {
        var msg = (member.feed.next(.{}) catch |err| switch (err) {
            error.ConnectionClosed => return,
            error.Canceled => return error.Canceled,
            else => return member.counts.fail("next", err),
        }) orelse return;
        defer msg.deinit();
        _ = member.counts.feed_received.fetchAdd(1, .monotonic);
        if (std.mem.eql(u8, msg.payload, "final")) member.counts.final_received.store(true, .monotonic);
    }
}

/// Publishes large messages no one counts until the reconnect buffer is
/// full: during a stall they fill the queue, after the cut the buffer.
fn fill(member: *Member, payload: []const u8) Io.Cancelable!void {
    while (true) {
        member.client.publish("stress.storm.fill", payload) catch |err| switch (err) {
            error.BufferFull => {
                _ = member.counts.fill_buffer_full.fetchAdd(1, .monotonic);
                return;
            },
            error.Canceled => return error.Canceled,
            else => return member.counts.fail("fill", err),
        };
    }
}

/// Publishes to the members' subscriptions every 10 ms until `stop`.
fn feedLoop(client: *nats.Client, stop: *std.atomic.Value(bool), failures: *std.atomic.Value(u32)) Io.Cancelable!void {
    const io = client.io;
    while (!stop.load(.monotonic)) {
        client.publish("stress.storm.feed", "tick") catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                _ = failures.fetchAdd(1, .monotonic);
                return;
            },
        };
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

/// Answers every request with its payload.
fn answer(client: *nats.Client, sub: *nats.Subscription) Io.Cancelable!void {
    while (true) {
        var msg = (sub.next(.{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        }) orelse return;
        defer msg.deinit();
        client.respond(&msg, msg.payload) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
    }
}

/// What reached the server: the sequence numbers of every member, and
/// how many came twice.
const Arrivals = struct {
    seen: [member_count]std.DynamicBitSetUnmanaged,
    /// Messages recorded so far.
    total: std.atomic.Value(u64) = .init(0),
    duplicates: std.atomic.Value(u32) = .init(0),
    malformed: std.atomic.Value(u32) = .init(0),

    fn record(a: *Arrivals, sub: *nats.Subscription) Io.Cancelable!void {
        while (true) {
            var msg = (sub.next(.{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            }) orelse return;
            defer msg.deinit();
            const prefix = "stress.storm.pub.";
            const index = std.fmt.parseInt(usize, msg.subject[prefix.len..], 10) catch member_count;
            const digits = std.mem.findScalar(u8, msg.payload, ' ') orelse msg.payload.len;
            const sequence = std.fmt.parseInt(usize, msg.payload[0..digits], 10) catch max_sequence;
            if (index >= member_count or sequence >= max_sequence) {
                _ = a.malformed.fetchAdd(1, .monotonic);
                continue;
            }
            if (a.seen[index].isSet(sequence)) _ = a.duplicates.fetchAdd(1, .monotonic);
            a.seen[index].set(sequence);
            _ = a.total.fetchAdd(1, .monotonic);
        }
    }
};

fn storm(io: Io) !void {
    var proxy: Proxy = undefined;
    try proxy.start(testing.io, testing.allocator, plain_port);
    defer proxy.stop();
    var url_buffer: [64]u8 = undefined;
    const proxy_url = try proxy.url(&url_buffer);

    // The responder, the observer and the feeder talk to the server
    // directly.
    var responder: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain}, .name = "storm-responder" });
    defer responder.deinit();
    try responder.connect();
    const rpc = try responder.subscribe("stress.storm.rpc", .{});
    defer rpc.deinit();
    var answering = try io.concurrent(answer, .{ &responder, rpc });
    defer answering.cancel(io) catch {};

    var observer: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain}, .name = "storm-observer" });
    defer observer.deinit();
    try observer.connect();
    const published = try observer.subscribe("stress.storm.pub.>", .{ .pending = .{ .messages = 4 * max_sequence, .bytes = 1024 * 1024 * 1024 } });
    defer published.deinit();
    var arrivals: Arrivals = .{ .seen = undefined };
    var allocated: usize = 0;
    defer for (arrivals.seen[0..allocated]) |*set| set.deinit(testing.allocator);
    for (&arrivals.seen) |*set| {
        set.* = try .initEmpty(testing.allocator, max_sequence);
        allocated += 1;
    }
    var recording = try io.concurrent(Arrivals.record, .{ &arrivals, published });
    defer recording.cancel(io) catch {};
    try responder.flush(.{});
    try observer.flush(.{});

    var feeder: nats.Client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain}, .name = "storm-feeder" });
    defer feeder.deinit();
    try feeder.connect();

    // The members, through the proxy, on memory of their own.
    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var members: [member_count]Member = undefined;
    var joined: usize = 0;
    defer for (members[0..joined]) |*m| {
        m.feed.deinit();
        m.client.deinit();
        m.windows.deinit(testing.allocator);
    };
    for (&members, 0..) |*m, i| {
        m.* = .{ .client = undefined, .feed = undefined, .index = i };
        m.client = try .init(counting.allocator(), io, .{
            .servers = &.{proxy_url},
            .name = "storm-member",
            .connect_timeout = .fromSeconds(2),
            .reconnect = quick_reconnect,
            .limits = member_limits,
        });
        errdefer m.client.deinit();
        try m.client.connect();
        m.feed = try m.client.subscribe("stress.storm.feed", .{});
        joined += 1;
        try m.client.flush(.{});
    }

    var stop: std.atomic.Value(bool) = .init(false);
    var feed_failures: std.atomic.Value(u32) = .init(0);
    var feeding = try io.concurrent(feedLoop, .{ &feeder, &stop, &feed_failures });
    defer feeding.cancel(io) catch {};
    var readers: Io.Group = .init;
    defer readers.cancel(io);
    var workers: Io.Group = .init;
    defer workers.cancel(io);
    for (&members) |*m| {
        try readers.concurrent(io, readFeed, .{m});
        try workers.concurrent(io, publishLoop, .{ m, &stop });
        try workers.concurrent(io, requestLoop, .{ m, &stop });
    }

    // The storm.
    const random_source: std.Random.IoSource = .{ .io = io };
    const random = random_source.interface();
    const fill_payload = try testing.allocator.alloc(u8, 8 * 1024);
    defer testing.allocator.free(fill_payload);
    @memset(fill_payload, 'f');
    var cut_connections: usize = 0;
    const began = Io.Clock.awake.now(io);
    for (0..cuts) |round| {
        try io.sleep(.fromMilliseconds(random.intRangeAtMost(i64, 20, 150)), .awake);
        if (std.mem.findScalar(usize, &stall_rounds, round) == null) {
            cut_connections += proxy.cutAll();
            continue;
        }
        // The proxy stops forwarding; large publishes fill the sockets, then
        // every client's queue. The cut leaves more unsent than the
        // reconnect buffer holds, and while the proxy refuses the clients,
        // new publishes find the buffer full.
        proxy.stall(true);
        var fills: Io.Group = .init;
        defer fills.cancel(io);
        for (&members) |*m| try fills.concurrent(io, fill, .{ m, fill_payload });
        for (&members) |*m| {
            const since = Io.Clock.awake.now(io);
            while (m.client.stats().pending_outbound_bytes < member_limits.outbound_bytes) {
                if (stress.elapsedSince(io, since).toSeconds() >= 30) return error.TestQueueNeverFull;
                try io.sleep(.fromMilliseconds(5), .awake);
            }
        }
        proxy.refuse(true);
        cut_connections += proxy.cutAll();
        proxy.stall(false);
        try fills.await(io);
        try io.sleep(.fromMilliseconds(200), .awake);
        proxy.refuse(false);
    }
    const storm_took = stress.elapsedSince(io, began);
    stop.store(true, .monotonic);
    try workers.await(io);

    // Everyone is back, with the subscription and the inbox.
    for (&members) |*m| {
        const since = Io.Clock.awake.now(io);
        while (m.client.state() != .connected) {
            if (stress.elapsedSince(io, since).toSeconds() >= 15) return error.TestNeverReconnected;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        try m.client.flush(.{});
        var reply = try m.client.request("stress.storm.rpc", "ping", .{});
        reply.deinit();
    }
    try feeding.await(io);
    try feeder.publish("stress.storm.feed", "final");
    try feeder.flush(.{});
    for (&members) |*m| {
        const since = Io.Clock.awake.now(io);
        while (!m.counts.final_received.load(.monotonic)) {
            if (stress.elapsedSince(io, since).toSeconds() >= 5) return error.TestSubscriptionNotRestored;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
    }
    // Everything the server got from the members has reached the observer,
    // and the observer has recorded it: the count stops changing.
    try observer.flush(.{});
    const settle = Io.Clock.awake.now(io);
    var recorded = arrivals.total.load(.monotonic);
    var still_since = Io.Clock.awake.now(io);
    while (published.pending().messages > 0 or stress.elapsedSince(io, still_since).toMilliseconds() < 100) {
        if (stress.elapsedSince(io, settle).toSeconds() >= 10) return error.TestObserverBehind;
        try io.sleep(.fromMilliseconds(5), .awake);
        const now = arrivals.total.load(.monotonic);
        if (now != recorded) {
            recorded = now;
            still_since = Io.Clock.awake.now(io);
        }
    }

    const peak = counting.peak.load(.monotonic);
    const bound = member_count * (member_limits.outbound_bytes + quick_reconnect.buffer_bytes + 2 * 1024 * 1024);
    var accepted_all: u64 = 0;
    var arrived_all: u64 = 0;
    var reconnects: u64 = 0;
    var requests_ok: u64 = 0;
    var requests_lost: u64 = 0;
    var uncertain: u64 = 0;
    var dropped: u64 = 0;
    var buffer_full: u64 = 0;
    var missing_all: u64 = 0;
    var accounted_all: u64 = 0;
    var windows: u64 = 0;
    for (&members) |*m| {
        const stats = m.client.stats();
        const accepted = m.counts.accepted.load(.monotonic);
        const arrived = arrivals.seen[m.index].count();
        // The flush above confirmed the publishes since the publisher's
        // last confirmation.
        try m.confirm(accepted);
        // Every missing publish was published while a connection was lost,
        // and no window misses more than the client counted as uncertain
        // or dropped in it.
        const missing_in = try testing.allocator.alloc(u64, m.windows.items.len);
        defer testing.allocator.free(missing_in);
        @memset(missing_in, 0);
        var missing: u64 = 0;
        for (0..accepted) |sequence| {
            if (arrivals.seen[m.index].isSet(sequence)) continue;
            missing += 1;
            const window = m.windowOf(@intCast(sequence)) orelse {
                std.debug.print("  client {d}: publish {d} is missing, and no connection was lost around it\n", .{ m.index, sequence });
                return error.TestPublishLost;
            };
            missing_in[window] += 1;
        }
        for (m.windows.items, missing_in) |w, n| {
            if (n > w.lost_at_most) {
                std.debug.print("  client {d}: publishes {d}..{d} miss {d}, the client counted {d} uncertain or dropped\n", .{ m.index, w.from, w.to, n, w.lost_at_most });
                return error.TestLossNotCounted;
            }
            accounted_all += w.lost_at_most;
        }
        missing_all += missing;
        windows += m.windows.items.len;
        buffer_full += m.counts.buffer_full.load(.monotonic) + m.counts.fill_buffer_full.load(.monotonic);
        accepted_all += accepted;
        arrived_all += arrived;
        reconnects += stats.reconnects;
        requests_ok += m.counts.requests_ok.load(.monotonic);
        requests_lost += m.counts.requests_lost.load(.monotonic);
        uncertain += stats.uncertain_outbound_frames;
        dropped += stats.dropped_messages;
        try testing.expectEqual(0, m.counts.unexpected.load(.monotonic));
        // Only what the client took arrives, at most once, and what did
        // not arrive is accounted for.
        try testing.expect(arrived <= accepted);
        try testing.expect(accepted - arrived <= stats.uncertain_outbound_frames + stats.dropped_messages);
        try testing.expect(stats.reconnects >= 5);
    }
    std.debug.print("  storm: {d} rounds ({d} stalled) over {d} ms, {d} connections cut, {d} reconnects; publishes {d} taken, {d} arrived, {d} missing, all within {d} windows of a lost connection that counted {d} as uncertain or dropped; {d} uncertain, {d} dropped, {d} found the buffer full; requests {d} ok, {d} lost; client heap peak {d} KiB (bound {d} KiB)\n", .{
        cuts,         stall_rounds.len, storm_took.toMilliseconds(), cut_connections,
        reconnects,   accepted_all,     arrived_all,                 missing_all,
        windows,      accounted_all,    uncertain,                   dropped,
        buffer_full,  requests_ok,      requests_lost,               peak / 1024,
        bound / 1024,
    });
    try testing.expectEqual(0, arrivals.duplicates.load(.monotonic));
    try testing.expectEqual(0, arrivals.malformed.load(.monotonic));
    try testing.expectEqual(0, feed_failures.load(.monotonic));
    try testing.expectEqual(0, published.stats().dropped);
    try testing.expect(peak <= bound);
    try testing.expect(requests_ok > 0);
    // The stalls made the reconnect buffers overflow.
    try testing.expect(dropped > 0);
    try testing.expect(buffer_full > 0);

    // The readers end with their clients.
    for (&members) |*m| m.client.close();
    try readers.await(io);
}

test "a storm of cut connections: clients come back whole, nothing arrives twice, losses are counted" {
    try stress.onZio(storm);
}
