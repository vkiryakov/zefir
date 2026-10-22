//! Must not compile: a path of Docs that does not start with '/'.
const zefir = @import("zefir");

test {
    _ = zefir.openapi.Docs(.{ .json = "openapi.json" });
}
