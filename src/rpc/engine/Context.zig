//! `rpc.Context`: the context of one call on the server.

/// The context of one call on the server. The engine creates it for each
/// call; handlers and middleware get a borrowed pointer and must not keep it
/// after they return or hand it to background tasks.
pub const Context = opaque {};
