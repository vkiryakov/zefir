//! An `Io` for tests that plays std's `Io.Threaded` on Windows, so that
//! the Windows path of the client runs on any system. Everything is
//! `std.testing.io` but for what Windows does otherwise:
//!
//! - A read or a write on a socket cannot be timed: `operateTimeout` says
//!   `error.ConcurrencyUnavailable`.
//! - A shutdown of a socket by its own side does not end the read that
//!   waits on it: that read waits on, for what the peer sends, for the end
//!   of the stream, or for the cancelation of its task. A read that comes
//!   after the shutdown fails at once. The peer sees the end of the stream.
//! - Where other systems end the stream, Windows answers NTSTATUS
//!   PIPE_DISCONNECTED or LOCAL_DISCONNECT, which std reports as
//!   `error.Unexpected`: every end of a stream reads so here.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;

/// The table of `std.testing.io` with those calls replaced. It points
/// into itself: `io` it in place.
pub const WindowsLike = struct {
    vtable: Io.VTable,

    pub fn io(w: *WindowsLike) Io {
        w.vtable = testing.io.vtable.*;
        w.vtable.operate = operate;
        w.vtable.batchAwaitConcurrent = batchAwaitConcurrent;
        w.vtable.netShutdown = netShutdown;
        w.vtable.netClose = netClose;
        // What earlier tests shut down is closed by now.
        shut.clear();
        return .{ .userdata = testing.io.userdata, .vtable = &w.vtable };
    }
};

/// The sockets that their own side shut down, until they close. The calls
/// of the table get the userdata of `std.testing.io`, so the set is the
/// file's: tests run one at a time, with a few sockets each.
var shut: Shut = .{};

const Shut = struct {
    mutex: Io.Mutex = .init,
    handles: [64]net.Socket.Handle = undefined,
    len: usize = 0,

    fn add(s: *Shut, handle: net.Socket.Handle) void {
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        for (s.handles[0..s.len]) |h| if (h == handle) return;
        // More than a test holds: the socket reads as if not shut down.
        if (s.len == s.handles.len) return;
        s.handles[s.len] = handle;
        s.len += 1;
    }

    fn has(s: *Shut, handle: net.Socket.Handle) bool {
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        for (s.handles[0..s.len]) |h| if (h == handle) return true;
        return false;
    }

    fn remove(s: *Shut, handle: net.Socket.Handle) void {
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        for (s.handles[0..s.len], 0..) |h, i| if (h == handle) {
            s.len -= 1;
            s.handles[i] = s.handles[s.len];
            return;
        };
    }

    fn clear(s: *Shut) void {
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        s.len = 0;
    }
};

/// The read of `std.testing.io`, failing at once on a socket that its own
/// side shut down, with the end of the stream turned into
/// `error.Unexpected`.
fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    switch (operation) {
        .net_read => |o| if (shut.has(o.socket_handle)) return .{ .net_read = error.Unexpected },
        else => {},
    }
    var result = try testing.io.vtable.operate(userdata, operation);
    switch (result) {
        .net_read => |*read| if (read.*) |r| {
            if (r.data_len == 0) read.* = error.Unexpected;
        } else |_| {},
        else => {},
    }
    return result;
}

/// No timed read or write on a socket, as std's `Io.Threaded` on Windows.
fn batchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    var index = batch.submitted.head;
    while (index != .none) {
        const submission = &batch.storage[index.toIndex()].submission;
        switch (submission.operation) {
            .net_read, .net_write => return error.ConcurrencyUnavailable,
            else => {},
        }
        index = submission.node.next;
    }
    return testing.io.vtable.batchAwaitConcurrent(userdata, batch, timeout);
}

/// Shuts the sending side down for real, so that the peer sees the end of
/// the stream, and only marks the receiving side: the read in progress
/// goes on, and the next one fails.
fn netShutdown(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    if (how != .send) shut.add(handle);
    if (how == .recv) return;
    return testing.io.vtable.netShutdown(userdata, handle, .send);
}

fn netClose(userdata: ?*anyopaque, sockets: []const net.Socket) void {
    for (sockets) |socket| shut.remove(socket.handle);
    testing.io.vtable.netClose(userdata, sockets);
}
