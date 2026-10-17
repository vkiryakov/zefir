//! `http.native.Backend` (design sections 14 and 15): the server on the
//! network, over `std.Io` (zio in production). It listens on an address,
//! serves each connection on a task of its own and reads its requests one
//! after another (keep-alive and pipelining), within the limits of
//! `Limits` and the times of `Timeouts`.
//!
//! ```zig
//! var native = try http.native.Backend.init(gpa, .{ .port = 8080 });
//! defer native.deinit();
//! var server = try http.Server.init(gpa, .{ .backend = native.backend(), .controllers = .{&todos_v1} });
//! defer server.deinit(io);
//! try server.run(io);
//! ```
//!
//! At most `.max_connections` connections are open at once: a client over
//! it waits in the kernel's queue until one closes. When the server stops,
//! the backend stops listening; a connection that waits for a request
//! closes at once, a busy one after its response, which says
//! `Connection: close`. A backend serves one server, once.
//!
//! A port taken by another server: on Windows the server's `start` is
//! `error.AddressInUse`. On Linux and macOS it starts, and the two share
//! the connections of the port, or the new one takes them all: the backend
//! listens with SO_REUSEADDR, so that a server that restarts does not wait
//! out the connections of its last run in TIME_WAIT, and std.Io sets it
//! only together with SO_REUSEPORT there. One instance per port is the
//! business of the process manager (systemd, Kubernetes).
const std = @import("std");
const builtin = @import("builtin");
const Interface = @import("../Backend.zig");
const Connection = @import("Connection.zig");

const Backend = @This();
const Duration = std.Io.Duration;
const net = std.Io.net;
const log = std.log.scoped(.http);

gpa: std.mem.Allocator,
address: net.IpAddress,
limits: Limits,
timeouts: Timeouts,
/// The server, from `start` on.
handler: Interface.Handler = undefined,
listener: ?net.Server = null,
/// The task that accepts connections, from `start` to `stopAccepting`.
accept_task: ?std.Io.Future(void) = null,
/// The tasks of the connections; only the server's stop cancels or awaits
/// it.
connections: std.Io.Group = .init,
/// A permit for each connection that may open; the accept task takes one
/// before it accepts, a connection gives it back when it closes.
slots: std.Io.Semaphore,
/// Between `start` and `stopAccepting`.
accepting: std.atomic.Value(bool) = .init(false),
/// From `stopAccepting` on: each response says `Connection: close`.
stopping: std.atomic.Value(bool) = .init(false),
/// Set by `stopAccepting`: wakes the connections that wait for a request.
stop_event: std.Io.Event = .unset,

/// The limits of a connection and its requests (design section 15).
pub const Limits = struct {
    /// The head of a request: its request line and fields. Over it: 431.
    /// Each connection reads into a buffer of this size.
    max_head_bytes: u32 = 16 << 10,
    /// The fields of a head. Over it: 431.
    max_header_fields: u16 = 100,
    /// The target of a request, its URL. Over it: 414.
    max_target_bytes: u32 = 8 << 10,
    /// The extensions of chunks and the trailer fields of a body. Over it:
    /// 400.
    max_chunk_meta_bytes: u32 = 4 << 10,
    /// Connections open at once; the next ones wait in the kernel's queue.
    max_connections: u32 = 10_000,
};

/// The times of a connection (design section 15).
pub const Timeouts = struct {
    /// A new connection sends its first byte within it, else it is closed
    /// without an answer; from the first byte, the whole head comes within
    /// it, else 408 and close.
    header: Duration = .fromSeconds(10),
    /// Between two reads of a request body: 408 and close.
    body: Duration = .fromSeconds(30),
    /// A connection kept alive waits for its next request this long, then
    /// closes.
    idle: Duration = .fromSeconds(60),
    /// A write that sends nothing for this long closes the connection: a
    /// client that does not read.
    write: Duration = .fromSeconds(30),
};

pub const Options = struct {
    /// An IPv4 or IPv6 address, such as "127.0.0.1" or "::"; "0.0.0.0"
    /// takes every IPv4 interface.
    address: []const u8 = "0.0.0.0",
    /// 0 takes a free port: `port()` gives it after `start`.
    port: u16,
    limits: Limits = .{},
    timeouts: Timeouts = .{},
};

/// `InvalidConfiguration`: an address that is not an IP address, a limit
/// of 0 (but `max_chunk_meta_bytes`, which then refuses every extension and
/// trailer), or a timeout that is not above 0.
pub const InitError = error{ InvalidConfiguration, OutOfMemory };

/// Checks `options`, without I/O; nothing listens before the server's
/// `start`.
pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Backend {
    const address = net.IpAddress.parse(options.address, options.port) catch return error.InvalidConfiguration;
    const limits = options.limits;
    if (limits.max_head_bytes == 0 or limits.max_header_fields == 0 or limits.max_target_bytes == 0 or limits.max_connections == 0)
        return error.InvalidConfiguration;
    const t = options.timeouts;
    for ([_]Duration{ t.header, t.body, t.idle, t.write }) |d| {
        if (d.nanoseconds <= 0) return error.InvalidConfiguration;
    }
    return .{
        .gpa = gpa,
        .address = address,
        .limits = limits,
        .timeouts = t,
        .slots = .{ .permits = limits.max_connections },
    };
}

/// After the server's `deinit`.
pub fn deinit(b: *Backend) void {
    b.* = undefined;
}

/// The backend for `http.Server.init`'s `.backend`. From the server's
/// `start` on, the backend stays where it is.
pub fn backend(b: *Backend) Interface {
    return .{ .ptr = b, .vtable = &vtable };
}

/// The port the backend listens on: the one of the options, or, for 0, the
/// one the system gave once the server has started.
pub fn port(b: *const Backend) u16 {
    return b.address.getPort();
}

const vtable: Interface.VTable = .{
    .capabilities = capabilities,
    .start = start,
    .stopAccepting = stopAccepting,
    .cancelAll = cancelAll,
    .wait = wait,
    .isReady = isReady,
};

fn of(ptr: *anyopaque) *Backend {
    return @ptrCast(@alignCast(ptr));
}

fn capabilities(_: *anyopaque) Interface.Capabilities {
    return .{ .http1 = true, .streaming_response = true, .flush = true };
}

fn start(ptr: *anyopaque, io: std.Io, handler: Interface.Handler) Interface.StartError!void {
    const b = of(ptr);
    b.handler = handler;
    // SO_REUSEADDR alone, as std.Io sets it on Windows, would let a second
    // server take the port there: off. Elsewhere it comes with SO_REUSEPORT
    // (see the top of this file).
    var listener = b.address.listen(io, .{ .reuse_address = builtin.os.tag != .windows }) catch |err| return switch (err) {
        error.AddressInUse, error.AccessDenied, error.SystemResources, error.Canceled => |e| e,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => error.SystemResources,
        else => |e| {
            log.warn("cannot listen on {f}: {t}", .{ b.address, e });
            return error.Unexpected;
        },
    };
    b.address = listener.socket.address;
    b.listener = listener;
    b.accept_task = io.concurrent(acceptLoop, .{ b, io }) catch |err| {
        listener.deinit(io);
        b.listener = null;
        return err;
    };
    b.accepting.store(true, .release);
}

/// Takes a slot, then accepts a connection and serves it on a task of the
/// connections, until `stopAccepting` cancels it.
fn acceptLoop(b: *Backend, io: std.Io) void {
    while (true) {
        b.slots.wait(io) catch return;
        const stream = b.listener.?.accept(io) catch |err| {
            b.slots.post(io);
            switch (err) {
                error.Canceled, error.SocketNotListening => return,
                error.ConnectionAborted, error.WouldBlock => continue,
                else => {
                    // Out of descriptors or memory, or the network is down:
                    // the next attempt comes after a pause.
                    log.warn("accepting a connection failed with error.{t}; the next attempt in 100 ms", .{err});
                    io.sleep(.fromMilliseconds(100), .awake) catch return;
                    continue;
                },
            }
        };
        b.connections.concurrent(io, Connection.serve, .{ b, io, stream }) catch {
            log.warn("the runtime gave no task for a new connection; it is closed", .{});
            stream.close(io);
            b.slots.post(io);
        };
    }
}

fn stopAccepting(ptr: *anyopaque, io: std.Io) void {
    const b = of(ptr);
    b.accepting.store(false, .release);
    b.stopping.store(true, .release);
    b.stop_event.set(io);
    if (b.accept_task) |*task| {
        task.cancel(io);
        b.accept_task = null;
    }
    if (b.listener) |*listener| {
        listener.deinit(io);
        b.listener = null;
    }
}

fn cancelAll(ptr: *anyopaque, io: std.Io) void {
    of(ptr).connections.cancel(io);
}

fn wait(ptr: *anyopaque, io: std.Io) void {
    const b = of(ptr);
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    // Cancelation is blocked: the wait ends when the connections have.
    b.connections.await(io) catch {};
}

fn isReady(ptr: *anyopaque) bool {
    return of(ptr).accepting.load(.acquire);
}

const testing = std.testing;

test "init checks the options without I/O" {
    var b = try init(testing.allocator, .{ .address = "127.0.0.1", .port = 8080 });
    defer b.deinit();
    try testing.expectEqual(8080, b.port());
    try testing.expect(!b.backend().isReady());
    const can = b.backend().capabilities();
    try testing.expect(can.http1 and can.streaming_response and can.flush);
    var any = try init(testing.allocator, .{ .address = "::", .port = 0, .limits = .{ .max_chunk_meta_bytes = 0 } });
    defer any.deinit();
    try testing.expectEqual(0, any.port());

    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .address = "localhost", .port = 80 }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .address = "127.0.0.1:80", .port = 80 }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .port = 80, .limits = .{ .max_head_bytes = 0 } }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .port = 80, .limits = .{ .max_header_fields = 0 } }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .port = 80, .limits = .{ .max_target_bytes = 0 } }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .port = 80, .limits = .{ .max_connections = 0 } }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .port = 80, .timeouts = .{ .header = .zero } }));
    try testing.expectError(error.InvalidConfiguration, init(testing.allocator, .{ .port = 80, .timeouts = .{ .write = .fromSeconds(-1) } }));
}

test {
    _ = Connection;
}
