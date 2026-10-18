//! `mongo.wire`: what every driver that speaks MongoDB's wire protocol
//! needs, in one implementation for the native driver, the example
//! driver, the test server of `mongo.testing` and drivers outside zefir.
//! It holds no network code: it reads from a `std.Io.Reader` and writes
//! to a `std.Io.Writer`.
//!
//! - `opmsg` — OP_MSG for both sides: a driver writes requests and reads
//!   replies, a test server reads requests and writes replies.
//! - `Hello` — what a server says about itself in its reply to hello: its
//!   type, its wire versions and its limits.
//! - `batch` — the items of a write in batches that fit the server's
//!   limits.
//! - `checkReply` — the `ok` of a reply as the contract's errors: ok 0 is
//!   `CommandFailed`, code 50 `Timeout`, with the server's error in
//!   `mongo.Diagnostics`.
//!
//! Experimental until zefir 1.0, like the transport interfaces of rpc.

const std = @import("std");

pub const opmsg = @import("wire/opmsg.zig");
pub const Hello = @import("wire/Hello.zig");
pub const batch = @import("wire/batch.zig");
pub const checkReply = @import("wire/reply.zig").checkReply;

test {
    std.testing.refAllDecls(@This());
    _ = @import("wire/opmsg_tests.zig");
    _ = @import("wire/fuzz.zig");
    _ = @import("wire/hello_tests.zig");
    _ = @import("wire/reply.zig");
    _ = @import("wire/batch_tests.zig");
}
