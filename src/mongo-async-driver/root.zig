//! zefir-mongo-async-driver — the native MongoDB driver of zefir-mongo,
//! written against `std.Io` only: it runs on any `std.Io` implementation
//! with real concurrency, and zio is the one meant for production. It is a
//! `mongo.Client`, so the code above it, the collection API of
//! `mongo.Database` and `mongo.Collection` among it, never names it.
//!
//! It talks to one standalone mongod of MongoDB 7.0 or later, over plain
//! TCP: there is no TLS, so it belongs on a trusted network only.

const std = @import("std");

pub const Client = @import("Client.zig");
pub const Options = @import("Options.zig");
pub const Stats = @import("Stats.zig");
pub const Uri = @import("uri.zig").Uri;

test {
    std.testing.refAllDecls(@This());
    _ = @import("uri.zig");
    _ = @import("uri_tests.zig");
    _ = @import("OwnedOptions.zig");
    _ = @import("engine/time.zig");
    _ = @import("engine/race.zig");
    _ = @import("engine/DeadlineStream.zig");
    _ = @import("engine/Connection.zig");
    _ = @import("engine/connect.zig");
    _ = @import("engine/handshake.zig");
    _ = @import("engine/scram.zig");
    _ = @import("testing/connection_tests.zig");
    _ = @import("testing/handshake_tests.zig");
    _ = @import("testing/auth_tests.zig");
}
