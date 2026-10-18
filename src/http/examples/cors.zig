// Application code (src/cors.zig of the example app): zefir-http ships none of these.
//! The CORS of the example app, as the Fetch standard defines it: what a
//! browser needs before a page of another origin may call the API. It sits
//! in the server's middleware, which runs before the route is chosen, so
//! the preflight of any path reaches it.
//!
//! ```zig
//! const origins = [_][]const u8{config.cors_origin};
//! var cors: Cors = .{ .origins = &origins };
//! // main: .middleware = .{ &cors, &token_auth },
//! ```

const std = @import("std");
const http = @import("http");

pub const Cors = struct {
    /// The origins whose pages may call the API, such as
    /// "https://app.example.com"; borrowed, they live as long as the
    /// server. "*" lets the page of any origin call it, and then never
    /// with credentials: a browser refuses `*` together with cookies or
    /// `Authorization`, and an API that echoed any origin with credentials
    /// would hand its users' sessions to every site.
    origins: []const []const u8,
    /// The methods and request headers a page may use.
    methods: []const u8 = "GET, HEAD, POST, PUT, PATCH, DELETE",
    headers: []const u8 = "authorization, content-type, idempotency-key",
    /// The response headers a page may read.
    expose: []const u8 = "x-request-id",
    /// Cookies and `Authorization` go with the calls.
    credentials: bool = true,

    /// A preflight, `OPTIONS` with `Origin` and
    /// `Access-Control-Request-Method`, of an origin it lets in: 204 with
    /// what the page may send, and nothing further runs. A status set is a
    /// response written, so `.handled` sends it without a body. Any other
    /// request goes on.
    pub fn run(self: *Cors, ctx: *http.Context) !http.MiddlewareResult {
        if (ctx.request.method != .OPTIONS or ctx.request.header("access-control-request-method") == null) return .next;
        const origin = ctx.request.header("origin") orelse return .next;
        if (!try self.allow(ctx, origin)) return .next;
        _ = ctx.response.status(204);
        try ctx.response.setHeader("access-control-allow-methods", self.methods);
        try ctx.response.setHeader("access-control-allow-headers", self.headers);
        return .handled;
    }

    /// Every response, the answers to errors too: `onResponse` runs for
    /// all, right before the head goes out. Unless any origin may call, the
    /// answer depends on `Origin`, so every one says `Vary: Origin`: else a
    /// cache could keep a response without `Access-Control-Allow-Origin`
    /// and give it to the page of an origin it lists.
    pub fn onResponse(self: *Cors, ctx: *http.Context) !void {
        if (!self.anyOrigin()) try ctx.response.setHeader("vary", "Origin");
        const origin = ctx.request.header("origin") orelse return;
        if (!try self.allow(ctx, origin)) return;
        try ctx.response.setHeader("access-control-expose-headers", self.expose);
    }

    /// Lets `origin` in when it is listed: `Access-Control-Allow-Origin`,
    /// and the credentials when they go with it; false for an origin it
    /// does not list.
    fn allow(self: *const Cors, ctx: *http.Context, origin: []const u8) !bool {
        for (self.origins) |listed| {
            if (std.mem.eql(u8, listed, "*")) {
                try ctx.response.setHeader("access-control-allow-origin", "*");
                return true;
            }
            if (!std.mem.eql(u8, listed, origin)) continue;
            try ctx.response.setHeader("access-control-allow-origin", origin);
            if (self.credentials) try ctx.response.setHeader("access-control-allow-credentials", "true");
            return true;
        }
        return false;
    }

    /// Whether the list has "*", which lets the page of any origin call.
    fn anyOrigin(self: *const Cors) bool {
        for (self.origins) |listed| {
            if (std.mem.eql(u8, listed, "*")) return true;
        }
        return false;
    }
};
