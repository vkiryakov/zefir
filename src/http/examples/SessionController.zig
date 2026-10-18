//! Signing a browser in and out: /api/session. The page posts a form with
//! a token; the answer sets the cookie `session`, which `TokenAuth` reads
//! from then on, and sends the browser back to the page. A cookie, since a
//! browser's `EventSource` cannot send `Authorization`.

const std = @import("std");
const http = @import("http");
const v = @import("validator");
const auth = @import("auth.zig");

const SessionController = @This();

token_auth: *auth.TokenAuth,
/// The streams of a user end when they sign out.
live: *http.sse.Manager,

pub const http_routes = http.routes(.{
    .prefix = "/session",
    .methods = .{
        // A form of one field: a small limit for its body.
        .login = http.post("", .{ .max_body_bytes = 1024 }),
        .logout = http.delete("", .{ .middleware = .{auth.requireUser} }),
    },
});

/// The form of the page, `application/x-www-form-urlencoded`: `token=…`.
pub const LoginForm = struct {
    token: []const u8,

    pub const field_rules = .{ .token = .{ v.trim, v.notBlank, v.maxLength(256) } };
};

pub fn login(self: *SessionController, ctx: *http.Context) !void {
    // A page of another site can post this form too, with a token of its
    // own, and sign the browser in as somebody else: login CSRF. 403.
    if (!fromThisSite(ctx)) return error.PermissionDenied;
    const form = try ctx.form(LoginForm);
    // A token nobody has: 401, as on any request.
    _ = self.token_auth.userOf(form.token) orelse return error.Unauthenticated;
    // HttpOnly: no script of a page reads it. SameSite=Lax: the requests
    // that other sites start go without it. Secure: only over HTTPS, and a
    // browser counts http://localhost as secure.
    try ctx.response.setCookie(.{
        .name = "session",
        .value = form.token,
        .http_only = true,
        .same_site = .lax,
        .secure = true,
        .max_age = .fromSeconds(8 * 60 * 60),
    });
    // 303: the browser goes on with a GET of the page.
    try ctx.response.status(303).redirect("/");
}

pub fn logout(self: *SessionController, ctx: *http.Context) !void {
    const user = try ctx.local(auth.CurrentUser);
    // The live updates of the user end too: their streams close.
    self.live.close(ctx.io(), user.id);
    // The cookie again, empty and expired: the browser deletes it.
    try ctx.response.setCookie(.{ .name = "session", .value = "", .http_only = true, .same_site = .lax, .secure = true, .max_age = .zero });
    // No body: 204 No Content.
}

/// Whether the request comes from a page of this site, as the browser
/// says. `Sec-Fetch-Site` is `same-origin` from a page of this site and
/// `none` from the user, from a bookmark say; `same-site` and `cross-site`
/// from other sites. An older browser sends only `Origin`, which then
/// names the host of `Host`. A request with neither comes from no browser,
/// curl say, and goes on.
fn fromThisSite(ctx: *http.Context) bool {
    if (ctx.request.header("sec-fetch-site")) |site| return std.mem.eql(u8, site, "same-origin") or std.mem.eql(u8, site, "none");
    const origin = ctx.request.header("origin") orelse return true;
    const host = ctx.request.header("host") orelse return false;
    // "http://localhost:8080": the host and the port after the scheme.
    const scheme_end = std.mem.find(u8, origin, "://") orelse return false;
    return std.ascii.eqlIgnoreCase(origin[scheme_end + 3 ..], host);
}
