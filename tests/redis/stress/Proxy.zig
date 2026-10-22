//! A TCP proxy between clients and a Redis server that cuts every
//! connection through it on demand: the client sees the server hang up,
//! the server sees the client go, and the next connection goes through
//! again. It can also stall, forwarding nothing the clients send, so that
//! their calls wait for replies that do not come, and refuse new
//! connections for a while, closing each one at once. It runs on a
//! `std.Io` of its own, the test's, whatever runtime the clients use.
//! Initialize it in place with `start`: it must not move.
//!
//! Nothing here waits for cancelation alone: cutting shuts the sockets
//! down, which wakes their readers, and stopping wakes the accept with a
//! connection of its own.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Proxy = @This();

io: Io,
gpa: std.mem.Allocator,
listener: net.Server,
upstream: net.IpAddress,
/// Guards `pairs`, `stopping` and `cuts`.
mutex: Io.Mutex = .init,
/// The connections through the proxy now.
pairs: std.ArrayList(*Pair) = .empty,
stopping: bool = false,
/// Connections cut so far.
cuts: u32 = 0,
/// What the clients send waits in their sockets.
stalled: std.atomic.Value(bool) = .init(false),
/// A new connection is closed at once.
refusing: std.atomic.Value(bool) = .init(false),
acceptor: Io.Future(void) = undefined,
/// The tasks of the pairs.
group: Io.Group = .init,

const Pair = struct {
    client: net.Stream,
    server: net.Stream,
};

/// Listens on 127.0.0.1 on a free port and forwards to `upstream_port`
/// on 127.0.0.1.
pub fn start(p: *Proxy, io: Io, gpa: std.mem.Allocator, upstream_port: u16) !void {
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    p.* = .{
        .io = io,
        .gpa = gpa,
        .listener = try loopback.listen(io, .{ .reuse_address = true }),
        .upstream = try .parseIp4("127.0.0.1", upstream_port),
    };
    errdefer p.listener.deinit(io);
    p.acceptor = try io.concurrent(acceptLoop, .{p});
}

/// The URL of the proxy for `redis.Client.Options`.
pub fn url(p: *const Proxy, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "redis://127.0.0.1:{d}", .{p.listener.socket.address.getPort()});
}

/// Cuts every connection through the proxy now; returns how many.
pub fn cutAll(p: *Proxy) usize {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    for (p.pairs.items) |pair| shutDown(p.io, pair);
    p.cuts += @intCast(p.pairs.items.len);
    return p.pairs.items.len;
}

/// Stops, or starts again, forwarding what the clients send.
pub fn stall(p: *Proxy, on: bool) void {
    p.stalled.store(on, .release);
}

/// Starts, or stops, closing new connections at once.
pub fn refuse(p: *Proxy, on: bool) void {
    p.refusing.store(on, .release);
}

/// Connections through the proxy now.
pub fn count(p: *Proxy) usize {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    return p.pairs.items.len;
}

/// Stops accepting, cuts what is left and waits for every task.
pub fn stop(p: *Proxy) void {
    const io = p.io;
    {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        p.stopping = true;
    }
    // A stalled pump would not see its connection cut.
    p.stall(false);
    // Wakes the accept; it sees `stopping` and returns.
    if (p.listener.socket.address.connect(io, .{ .mode = .stream })) |wake| wake.close(io) else |_| {}
    p.acceptor.await(io);
    _ = p.cutAll();
    p.group.await(io) catch {};
    p.pairs.deinit(p.gpa);
    p.listener.deinit(io);
}

fn acceptLoop(p: *Proxy) void {
    const io = p.io;
    while (true) {
        const client = p.listener.accept(io) catch return;
        if (p.refusing.load(.acquire)) {
            client.close(io);
            p.mutex.lockUncancelable(io);
            const stopping = p.stopping;
            p.mutex.unlock(io);
            if (stopping) return;
            continue;
        }
        const server = p.upstream.connect(io, .{ .mode = .stream }) catch {
            client.close(io);
            continue;
        };
        const pair = p.gpa.create(Pair) catch {
            server.close(io);
            client.close(io);
            continue;
        };
        pair.* = .{ .client = client, .server = server };
        {
            p.mutex.lockUncancelable(io);
            defer p.mutex.unlock(io);
            if (p.stopping or !add(p, pair)) {
                closePair(p, pair);
                if (p.stopping) return;
                continue;
            }
        }
        p.group.concurrent(io, runPair, .{ p, pair }) catch {
            p.mutex.lockUncancelable(io);
            defer p.mutex.unlock(io);
            remove(p, pair);
            closePair(p, pair);
        };
    }
}

fn add(p: *Proxy, pair: *Pair) bool {
    p.pairs.append(p.gpa, pair) catch return false;
    return true;
}

fn remove(p: *Proxy, pair: *Pair) void {
    for (p.pairs.items, 0..) |item, i| {
        if (item == pair) {
            _ = p.pairs.swapRemove(i);
            return;
        }
    }
}

/// Forwards both ways until either side ends, then closes both sockets.
fn runPair(p: *Proxy, pair: *Pair) Io.Cancelable!void {
    const io = p.io;
    var back = io.concurrent(pump, .{ io, pair.server, pair.client, null }) catch null;
    pump(io, pair.client, pair.server, &p.stalled);
    if (back) |*b| b.await(io) else shutDown(io, pair);
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    remove(p, pair);
    closePair(p, pair);
}

/// Copies what `from` sends to `to` until one of them ends, then shuts
/// both down, so that the pump of the other way ends too. While `stalled`
/// is set, it forwards nothing: what it has read waits, also what came in
/// the read that was under way when the stall began, and the rest waits
/// in the socket.
fn pump(io: Io, from: net.Stream, to: net.Stream, stalled: ?*std.atomic.Value(bool)) void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = from.reader(io, &read_buffer);
    var writer = to.writer(io, &write_buffer);
    while (true) {
        _ = reader.interface.stream(&writer.interface, .unlimited) catch break;
        if (stalled) |s| while (s.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch break;
        writer.interface.flush() catch break;
    }
    from.shutdown(io, .both) catch {};
    to.shutdown(io, .both) catch {};
}

fn shutDown(io: Io, pair: *Pair) void {
    pair.client.shutdown(io, .both) catch {};
    pair.server.shutdown(io, .both) catch {};
}

fn closePair(p: *Proxy, pair: *Pair) void {
    pair.client.close(p.io);
    pair.server.close(p.io);
    p.gpa.destroy(pair);
}
