//! The end-to-end tests of zefir-http: servers on `http.native` over
//! loopback TCP, on zio with one executor and with four, and a raw client
//! (`client.zig`) that sends exact bytes and reads exact responses.

test {
    _ = @import("native.zig");
    _ = @import("bodies.zig");
    _ = @import("counting_allocator.zig");
}
