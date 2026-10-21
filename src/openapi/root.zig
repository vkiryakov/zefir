//! zefir-openapi: the OpenAPI document of a zefir-http server, which the
//! compiler builds from the same types the server works with: the routes of
//! its controllers and what they declare, the DTOs and their `field_rules`,
//! the errors of every route as the error handler's `mapError` answers
//! them, and the middleware of each chain. It reads the server through
//! `http.describe` and the rules through `v.schemaOf`.
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
