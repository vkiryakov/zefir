//! A TCP proxy between the clients of the tests and a mongod that forwards
//! whole messages of the wire protocol, and on demand:
//!
//! - cuts every connection through it: the client sees the server hang
//!   up, the server sees the client go, and the next connection goes
//!   through again;
//! - freezes: nothing goes either way until it thaws, so that the calls of
//!   its clients wait for replies that do not come, and so do the new
//!   connections they open;
//! - loses a reply: armed with `loseReply(n)`, it lets the n-th request
//!   that carries a write command (`insert`, `update`, `delete`,
//!   `findAndModify`: the first key of the body of an OP_MSG) reach mongod,
//!   which runs it, and cuts the connection instead of forwarding the
//!   reply;
//! - keeps a copy of the body of the next command of a name, for `explain`.
//!
//! A copy of tests/mongo/stress/Proxy.zig that reads whole messages
//! instead of bytes. It runs on a `std.Io` of its own, the test's,
//! whatever runtime the clients use. Initialize it in place with `start`:
//! it must not move. Nothing here waits for cancelation alone: cutting
//! shuts the sockets down, which wakes their readers, and stopping wakes
//! the accept with a connection of its own.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Proxy = @This();

io: Io,
gpa: std.mem.Allocator,
listener: net.Server,
upstream: net.IpAddress,
/// Guards `pairs` and the fields after it, up to `copy`.
mutex: Io.Mutex = .init,
/// The connections through the proxy now.
pairs: std.ArrayList(*Pair) = .empty,
stopping: bool = false,
/// Connections cut so far: by `cutAll`, and instead of a lost reply.
cuts: u32 = 0,
/// Replies lost so far.
lost: u32 = 0,
/// When a connection last came or was cut, on the awake clock of `io`.
changed: Io.Timestamp,
/// How many more requests with a write command pass before the one
/// whose reply is lost; 0 when the proxy is not armed.
lose_after: u32 = 0,
/// The command whose body to copy next; "" when none.
wanted: []const u8 = "",
copy: ?[]u8 = null,
/// Nothing goes either way.
frozen: std.atomic.Value(bool) = .init(false),
acceptor: Io.Future(void) = undefined,
/// The tasks of the pairs.
group: Io.Group = .init,

const Pair = struct {
    client: net.Stream,
    server: net.Stream,
    /// The reply of the request on its way to mongod is lost.
    lose: std.atomic.Value(bool) = .init(false),
};

/// The commands whose reply `loseReply` may lose.
const writes = [_][]const u8{ "insert", "update", "delete", "findAndModify" };
const op_msg = 2013;
/// The bytes the proxy reads ahead of a message, and so the longest
/// message it copies.
const buffer_len = 64 * 1024;

/// Listens on 127.0.0.1 on a free port and forwards to `upstream_port`
/// on 127.0.0.1.
pub fn start(p: *Proxy, io: Io, gpa: std.mem.Allocator, upstream_port: u16) !void {
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    p.* = .{
        .io = io,
        .gpa = gpa,
        .listener = try loopback.listen(io, .{ .reuse_address = true }),
        .upstream = try .parseIp4("127.0.0.1", upstream_port),
        .changed = Io.Clock.awake.now(io),
    };
    errdefer p.listener.deinit(io);
    p.acceptor = try io.concurrent(acceptLoop, .{p});
}

/// The connection string of the proxy, with `query` as its options.
pub fn uri(p: *const Proxy, buffer: []u8, query: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "mongodb://127.0.0.1:{d}/?{s}", .{ p.listener.socket.address.getPort(), query });
}

/// Cuts every connection through the proxy now; returns how many.
pub fn cutAll(p: *Proxy) usize {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    for (p.pairs.items) |pair| shutDown(p.io, pair);
    p.cuts += @intCast(p.pairs.items.len);
    p.changed = Io.Clock.awake.now(p.io);
    return p.pairs.items.len;
}

/// Forwards nothing either way until `thaw`: what a side sends waits.
pub fn freeze(p: *Proxy) void {
    p.frozen.store(true, .release);
}

pub fn thaw(p: *Proxy) void {
    p.frozen.store(false, .release);
}

/// The n-th request with a write command from now on, n from 1, reaches
/// mongod, and its reply is lost: the proxy cuts its connection instead.
pub fn loseReply(p: *Proxy, n: u32) void {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    p.lose_after = n;
}

/// Replies lost so far.
pub fn lostReplies(p: *Proxy) u32 {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    return p.lost;
}

/// Waits on `io`, the caller's, until `quiet` has passed since a
/// connection last came or was cut. After a cut the client's pool opens a
/// connection at most every 500 ms, its probe, and a call in between finds
/// it paused: a lost reply 600 ms after the last connection came lets the
/// call that reads the record again open the next one.
pub fn settle(p: *Proxy, io: Io, quiet: Io.Duration) Io.Cancelable!void {
    while (true) {
        const since = since: {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            break :since p.changed;
        };
        const passed = since.durationTo(Io.Clock.awake.now(p.io));
        if (passed.nanoseconds >= quiet.nanoseconds) return;
        try io.sleep(.fromNanoseconds(quiet.nanoseconds - passed.nanoseconds), .awake);
    }
}

/// Keeps a copy of the body of the next command named `name` that a client
/// sends, for `takeCopy`.
pub fn copyNext(p: *Proxy, name: []const u8) void {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    p.wanted = name;
}

/// The body that `copyNext` asked for, BSON from the proxy's allocator,
/// which the caller frees; null until it came.
pub fn takeCopy(p: *Proxy) ?[]u8 {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    defer p.copy = null;
    return p.copy;
}

/// Stops accepting, cuts what is left and waits for every task.
pub fn stop(p: *Proxy) void {
    const io = p.io;
    {
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        p.stopping = true;
    }
    // A frozen pump would not see its connection cut.
    p.thaw();
    // Wakes the accept; it sees `stopping` and returns.
    if (p.listener.socket.address.connect(io, .{ .mode = .stream })) |wake| wake.close(io) else |_| {}
    p.acceptor.await(io);
    _ = p.cutAll();
    p.group.await(io) catch {};
    p.pairs.deinit(p.gpa);
    if (p.copy) |bytes| p.gpa.free(bytes);
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
            p.changed = Io.Clock.awake.now(io);
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
    var back = io.concurrent(pump, .{ p, pair, Way.down }) catch null;
    pump(p, pair, .up);
    if (back) |*b| b.await(io) else shutDown(io, pair);
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    remove(p, pair);
    closePair(p, pair);
}

const Way = enum { up, down };

/// Forwards whole messages from one side of `pair` to the other until
/// either side ends, then shuts both down, so that the pump of the other
/// way ends too. A message waits while the proxy is frozen. Going up, a
/// request may arm the loss of its reply; going down, that reply is read
/// and dropped, and the connection cut.
fn pump(p: *Proxy, pair: *Pair, way: Way) void {
    const io = p.io;
    const from, const to = switch (way) {
        .up => .{ pair.client, pair.server },
        .down => .{ pair.server, pair.client },
    };
    var read_buffer: [buffer_len]u8 = undefined;
    var write_buffer: [buffer_len]u8 = undefined;
    var reader = from.reader(io, &read_buffer);
    var writer = to.writer(io, &write_buffer);
    const in = &reader.interface;
    const out = &writer.interface;
    while (true) {
        const header = in.peekArray(16) catch break;
        const length = std.mem.readInt(u32, header[0..4], .little);
        if (length < 16) break;
        if (way == .up) p.inspect(pair, in, length);
        if (!p.awaitThaw()) break;
        if (way == .down and pair.lose.load(.acquire)) {
            in.discardAll(length) catch {};
            p.lostOne();
            break;
        }
        in.streamExact(out, length) catch break;
        out.flush() catch break;
    }
    from.shutdown(io, .both) catch {};
    to.shutdown(io, .both) catch {};
}

/// False once the task is canceled.
fn awaitThaw(p: *Proxy) bool {
    while (p.frozen.load(.acquire)) p.io.sleep(.fromMilliseconds(1), .awake) catch return false;
    return true;
}

/// A request on its way up: a write command counts toward `loseReply`,
/// and the body of the command that `copyNext` waits for is copied.
fn inspect(p: *Proxy, pair: *Pair, in: *Io.Reader, length: u32) void {
    const head = in.peek(@min(length, 64)) catch return;
    const name = commandName(head) orelse return;
    const wanted = wanted: {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.lose_after > 0 and isWrite(name)) {
            p.lose_after -= 1;
            if (p.lose_after == 0) pair.lose.store(true, .release);
        }
        break :wanted p.copy == null and p.wanted.len > 0 and std.mem.eql(u8, name, p.wanted);
    };
    if (!wanted or length > buffer_len) return;
    const message = in.peek(length) catch return;
    const body = bodyOf(message) orelse return;
    const bytes = p.gpa.dupe(u8, body) catch return;
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    if (p.copy == null and p.wanted.len > 0) {
        p.copy = bytes;
        p.wanted = "";
    } else p.gpa.free(bytes);
}

fn lostOne(p: *Proxy) void {
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    p.lost += 1;
    p.cuts += 1;
    p.changed = Io.Clock.awake.now(p.io);
}

fn isWrite(name: []const u8) bool {
    for (writes) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

/// The name of the command of an OP_MSG whose body comes first, as the
/// client writes it: the first key of the body. `head` is the start of the
/// message.
fn commandName(head: []const u8) ?[]const u8 {
    // The header (16 bytes), flagBits (4), the kind of the section (1),
    // the length of the body (4), the type of its first element (1).
    if (head.len < 27) return null;
    if (std.mem.readInt(i32, head[12..16], .little) != op_msg or head[20] != 0) return null;
    const key = head[26..];
    return key[0 .. std.mem.findScalar(u8, key, 0) orelse return null];
}

/// The body of an OP_MSG whose body comes first.
fn bodyOf(message: []const u8) ?[]const u8 {
    if (message.len < 26) return null;
    const length = std.mem.readInt(u32, message[21..25], .little);
    if (length < 5 or 21 + length > message.len) return null;
    return message[21..][0..length];
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
