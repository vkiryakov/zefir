//! Must not compile: a key of the texts of a middleware written wrong.
const zefir = @import("zefir");
const http = zefir.http;

const requireUser = struct {
    pub const openapi: zefir.openapi.MiddlewareDoc = .{ .securty = .any };

    pub fn run(_: *http.Context) !http.MiddlewareResult {
        return .next;
    }
};

test {
    _ = requireUser.openapi;
}
