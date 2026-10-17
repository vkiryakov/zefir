//! The backend of a server (design section 14): it owns the connections
//! and the bytes of HTTP/1.1, hands the server parsed requests and takes
//! their responses. `http.native.Backend` serves the network and
//! `http.testing.Backend` serves tests from memory; the server sees only
//! this interface, a pointer and a table of functions, like `std.Io`.
const Backend = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// What a backend can do; `Server.start` refuses a route that needs more.
pub const Capabilities = struct {
    http1: bool = true,
    /// A body sent while it is written: `stream`, `file`, static files.
    streaming_response: bool = false,
    /// Bytes sent at once: SSE.
    flush: bool = false,
};

pub const VTable = struct {
    capabilities: *const fn (ptr: *anyopaque) Capabilities,
};
