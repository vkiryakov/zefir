//! What the client holds at a moment, for tests and diagnostics:
//! `client.stats()` returns a snapshot.

/// The open connections of the pool: the `idle` ones and those `in_use`
/// by a call or a Conn.
connections: usize,
/// Open connections that no call or Conn holds.
idle: usize,
/// Open connections that a call or a `redis.Conn` holds.
in_use: usize,
/// Connections being opened.
opening: usize,
/// Calls waiting in line for a connection.
waiting: usize,
/// Open subscribers, on connections of their own outside the pool.
subscribers: usize,
/// The generation of the pool, and how many times it was cleared.
generation: u64,
/// How many times the pool was cleared: a connection that broke, or a
/// server that refused the user, clears it.
clears: u64,
