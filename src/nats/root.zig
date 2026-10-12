//! zefir-nats — a Core NATS client written against `std.Io` only: it runs
//! on any `std.Io` implementation with real concurrency, and zio is the one
//! meant for production. It speaks plaintext TCP with no auth or with user
//! and password; TLS and JetStream are not part of this version.
//!
//! The client arrives phase by phase. Phase 1 brings the options, server
//! addresses and INFO, header handling and the protocol layer underneath.

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
