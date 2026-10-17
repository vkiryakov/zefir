//! zefir-http for tests (design section 18): `http.testing.Backend`, the
//! server's backend in memory, which serves the same server and the same
//! controllers without sockets.
const backend = @import("testing/Backend.zig");
const Server = @import("Server.zig");

pub const Backend = backend;
pub const Request = backend.Request;
pub const Response = backend.Response;
pub const RequestError = backend.RequestError;

/// The requests of `server` at work now, those `.max_in_flight` counts: 0
/// once every request has ended, whatever its outcome.
pub fn inFlight(server: *const Server) u32 {
    return server.in_flight.load(.acquire);
}

test {
    _ = backend;
}
