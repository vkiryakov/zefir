//! A TCP proxy between clients and a NATS server that cuts every
//! connection through it on demand: the client sees the server hang up,
//! the server sees the client go, and the next connection goes through
//! again. It runs on a `std.Io` of its own, the test's, whatever runtime
//! the clients use. Initialize it in place with `start`: it must not move.
//!
//! Nothing here waits for cancellation alone: cutting shuts the sockets
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
/// Guards `pairs` and `stopping`.
mutex: Io.Mutex = .init,
/// The connections through the proxy now.
pairs: std.ArrayList(*Pair) = .empty,
stopping: bool = false,
/// Connections cut so far.
cuts: u32 = 0,
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

/// The `nats://` URL of the proxy.
pub fn url(p: *const Proxy, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "nats://127.0.0.1:{d}", .{p.listener.socket.address.getPort()});
}

/// Cuts every connection through the proxy now; returns how many.
pub fn cutAll(p: *Proxy) usize {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    for (p.pairs.items) |pair| shutDown(p.io, pair);
    p.cuts += @intCast(p.pairs.items.len);
    return p.pairs.items.len;
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
    var back = io.concurrent(pump, .{ io, pair.server, pair.client }) catch null;
    pump(io, pair.client, pair.server);
    if (back) |*b| b.await(io) else shutDown(io, pair);
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    remove(p, pair);
    closePair(p, pair);
}

/// Copies what `from` sends to `to` until one of them ends, then shuts
/// both down, so that the pump of the other way ends too.
fn pump(io: Io, from: net.Stream, to: net.Stream) void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = from.reader(io, &read_buffer);
    var writer = to.writer(io, &write_buffer);
    while (true) {
        _ = reader.interface.stream(&writer.interface, .unlimited) catch break;
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
