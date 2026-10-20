//! What the client holds at a moment, for tests and diagnostics:
//! `client.stats()` returns a snapshot.

/// Open connections: `idle` ones and those `in_use` by a call.
connections: usize,
idle: usize,
in_use: usize,
/// Connections being opened.
opening: usize,
/// Calls waiting for a connection.
waiting: usize,
/// The generation of the pool, and how many times it was cleared.
generation: u64,
clears: u64,
/// Cursors open on the server.
open_cursors: usize,
