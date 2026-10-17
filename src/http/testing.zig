//! zefir-http for tests (design section 18): `http.testing.Backend`, the
//! server's backend in memory, which serves the same server and the same
//! controllers without sockets.
const backend = @import("testing/Backend.zig");

pub const Backend = backend;
pub const Request = backend.Request;
pub const Response = backend.Response;
pub const RequestError = backend.RequestError;

test {
    _ = backend;
}
