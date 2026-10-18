//! An `Io` for tests that reads as Windows does from a socket that its own
//! side shut down: where other systems end the stream, Windows answers
//! NTSTATUS PIPE_DISCONNECTED or LOCAL_DISCONNECT, which std reports as
//! `error.Unexpected`. Everything else is `std.testing.io`, so the Windows
//! path of the driver runs on any system.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

/// The table of `std.testing.io` with its `operate` replaced. It points
/// into itself: `io` it in place.
pub const WindowsLike = struct {
    vtable: Io.VTable,

    pub fn io(w: *WindowsLike) Io {
        w.vtable = testing.io.vtable.*;
        w.vtable.operate = operate;
        return .{ .userdata = testing.io.userdata, .vtable = &w.vtable };
    }
};

/// The read of `std.testing.io`, with the end of the stream turned into
/// `error.Unexpected`.
fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    var result = try testing.io.vtable.operate(userdata, operation);
    switch (result) {
        .net_read => |*read| if (read.*) |r| {
            if (r.data_len == 0) read.* = error.Unexpected;
        } else |_| {},
        else => {},
    }
    return result;
}
