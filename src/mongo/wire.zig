//! `mongo.wire`: what every driver that speaks MongoDB's wire protocol
//! needs, in one implementation for the native driver, the example
//! driver, the test server of `mongo.testing` and drivers outside zefir.
//! It holds no network code: it reads from a `std.Io.Reader` and writes
//! to a `std.Io.Writer`.
//!
//! - `opmsg` — OP_MSG for both sides: a driver writes requests and reads
//!   replies, a test server reads requests and writes replies.
//!
//! Experimental until zefir 1.0, like the transport interfaces of rpc.

const std = @import("std");

pub const opmsg = @import("wire/opmsg.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("wire/opmsg_tests.zig");
    _ = @import("wire/fuzz.zig");
}
