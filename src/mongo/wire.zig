//! `wire`: the wire protocol of MongoDB, inside zefir-mongo. The client
//! and `mongo.testing.FakeServer` use it; nothing outside the module sees
//! it. It holds no network code: it reads from a `std.Io.Reader` and
//! writes to a `std.Io.Writer`.
//!
//! - `opmsg` — OP_MSG for both sides: the client writes requests and reads
//!   replies, the test server reads requests and writes replies.
//! - `Hello` — what a server says about itself in its reply to hello: its
//!   type, its wire versions and its limits.
//! - `batch` — the items of a write in batches that fit the server's
//!   limits, and the merge of their replies.
//! - `checkReply` — the `ok` of a reply as the client's errors: ok 0 is
//!   `CommandFailed`, code 50 `Timeout`, with the server's error in
//!   `mongo.Diagnostics`.

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
