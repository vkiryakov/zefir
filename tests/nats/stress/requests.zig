//! 50,000 requests at once from one client: all of them wait for their
//! replies together, through one inbox subscription, and the client's
//! memory stays within a bound.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const nats = @import("nats");
const e2e = @import("e2e");
const stress = @import("root.zig");

const count = 50_000;

/// The client's heap may hold at most its outbound queue, one chunk of it,
/// and this much per waiting request: its entry in the pending map, its
/// reply, and the growth of both.
const bytes_per_request = 256;

/// A client of its own that answers every request to `stress.50k`, once
/// all of them came: until then they all wait.
const Responder = struct {
    client: nats.Client,
    sub: *nats.Subscription,
    task: Io.Future(anyerror!void),

    fn start(r: *Responder, io: Io) !void {
        r.client = try .init(testing.allocator, io, .{ .servers = &.{e2e.servers.plain}, .name = "stress-50k-responder" });
        errdefer r.client.deinit();
        try r.client.connect();
        r.sub = try r.client.subscribe("stress.50k", .{ .pending = .{ .messages = count, .bytes = 64 * 1024 * 1024 } });
        errdefer r.sub.deinit();
        try r.client.flush(.{});
        r.task = try io.concurrent(serve, .{ io, &r.client, r.sub });
    }

    fn deinit(r: *Responder, io: Io) void {
        r.task.cancel(io) catch {};
        r.sub.deinit();
        r.client.deinit();
    }

    fn serve(io: Io, client: *nats.Client, sub: *nats.Subscription) anyerror!void {
        const began = Io.Clock.awake.now(io);
        while (sub.stats().received < count) {
            if (stress.elapsedSince(io, began).toSeconds() >= 120) return error.TestRequestsNeverCame;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
        while (true) {
            var msg = (try sub.next(.{})) orelse return;
            defer msg.deinit();
            try client.respond(&msg, msg.payload);
        }
    }
};

fn requestNumber(client: *nats.Client, i: usize, ok: *std.atomic.Value(u32), failed: *std.atomic.Value(u32)) Io.Cancelable!void {
    var buffer: [20]u8 = undefined;
    const payload = buffer[0..std.fmt.printInt(&buffer, i, 10, .lower, .{})];
    var reply = client.request("stress.50k", payload, .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } } }) catch |err| {
        if (failed.fetchAdd(1, .monotonic) == 0) std.debug.print("request {d}: {t}\n", .{ i, err });
        return;
    };
    defer reply.deinit();
    if (std.mem.eql(u8, reply.payload, payload)) {
        _ = ok.fetchAdd(1, .monotonic);
    } else {
        _ = failed.fetchAdd(1, .monotonic);
    }
}

/// The server's view of the connection named `name`: one subscription,
/// the inbox.
fn expectOneSubscription(name: []const u8) !void {
    const json = try e2e.dockerOutput(&.{ "exec", e2e.servers.plain_container, "wget", "-q", "-O", "-", "http://127.0.0.1:8222/connz?subs=1" });
    defer testing.allocator.free(json);
    const Connection = struct { name: ?[]const u8 = null, subscriptions: u32 = 0 };
    const Connz = struct { connections: []const Connection = &.{} };
    const parsed = try std.json.parseFromSlice(Connz, testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.connections) |connection| {
        if (std.mem.eql(u8, connection.name orelse continue, name)) return testing.expectEqual(1, connection.subscriptions);
    }
    return error.TestConnectionNotFound;
}

fn fiftyThousand(io: Io) !void {
    var responder: Responder = undefined;
    try responder.start(io);
    defer responder.deinit(io);

    var counting: stress.CountingAllocator = .{ .child = testing.allocator };
    var client: nats.Client = try .init(counting.allocator(), io, .{ .servers = &.{e2e.servers.plain}, .name = "stress-50k" });
    defer client.deinit();
    try client.connect();
    const before = counting.resetPeak();

    var ok: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(u32) = .init(0);
    const began = Io.Clock.awake.now(io);
    {
        var group: Io.Group = .init;
        defer group.cancel(io);
        for (0..count) |i| try group.concurrent(io, requestNumber, .{ &client, i, &ok, &failed });
        try group.await(io);
    }
    const took = stress.elapsedSince(io, began);
    const peak = counting.peak.load(.monotonic) - before;
    const held = counting.current.load(.monotonic) - before;
    const limits: nats.Limits = .{};
    const bound = limits.outbound_bytes + 64 * 1024 + count * bytes_per_request;
    std.debug.print("  50,000 requests: {d} ms; client heap: peak {d} KiB (bound {d} KiB), {d} KiB held after; process max RSS {?d} MiB\n", .{
        took.toMilliseconds(), peak / 1024, bound / 1024, held / 1024, stress.maxRssMiB(),
    });
    if (ok.load(.monotonic) != count) {
        std.debug.print("  {d} ok, {d} failed\n", .{ ok.load(.monotonic), failed.load(.monotonic) });
        return error.TestRequestsFailed;
    }
    try testing.expect(peak <= bound);
    // What stays is the capacity the pending map grew to, no more.
    try testing.expect(held <= peak);
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try testing.expectEqual(0, client.stats().late_responses);
    try expectOneSubscription("stress-50k");
}

test "50,000 requests at once: one inbox subscription, the client's memory within its bound" {
    try stress.onZio(fiftyThousand);
}
