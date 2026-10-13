//! zefir-nats — a Core NATS client written against `std.Io` only: it runs
//! on any `std.Io` implementation with real concurrency, and zio is the one
//! meant for production. It speaks plaintext TCP with no auth or with user
//! and password; TLS and JetStream are not part of this version.
//!
//! Work in progress: this version has the options, server addresses, INFO,
//! message headers and the protocol layer underneath; the client comes next.

const std = @import("std");

pub const Options = @import("Options.zig");
pub const Auth = Options.Auth;
pub const ReconnectOptions = Options.ReconnectOptions;
pub const Limits = Options.Limits;
pub const ServerAddress = @import("ServerAddress.zig");
pub const ServerInfo = @import("ServerInfo.zig");
pub const Headers = @import("Headers.zig");
pub const Header = Headers.Header;

test {
    std.testing.refAllDecls(@This());
    _ = @import("Options.zig");
    _ = @import("ServerAddress.zig");
    _ = @import("ServerInfo.zig");
    _ = @import("Headers.zig");
    _ = @import("protocol/subject.zig");
    _ = @import("protocol/encoder.zig");
    _ = @import("protocol/Parser.zig");
    _ = @import("protocol/server_error.zig");
    _ = @import("protocol/golden.zig");
    _ = @import("protocol/fuzz.zig");
    _ = @import("engine/OwnedOptions.zig");
    _ = @import("engine/time.zig");
    _ = @import("engine/queue.zig");
    _ = @import("engine/connect.zig");
}
