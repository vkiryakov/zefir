//! The authenticator of the billing service: who calls, by the token that
//! orders signed for its user. Billing has only public keys of orders,
//! from its settings: it checks tokens, and cannot make one.
//!
//! ```zig
//! // main of billing: the key of orders, APP_AUTH_ORDERS_KEY and
//! // APP_AUTH_ORDERS_KEY_ID, and while it changes the other one,
//! // APP_AUTH_OTHER_KEY and APP_AUTH_OTHER_KEY_ID, as in orders
//! var keys: [2]jwt.Key = undefined;
//! keys[0] = try .fromPem(.EdDSA, config.auth.orders_key, .{ .id = config.auth.orders_key_id });
//! var key_count: usize = 1;
//! if (config.auth.other) |other| {
//!     keys[1] = try .fromPem(.EdDSA, other.key, .{ .id = other.key_id });
//!     key_count = 2;
//! }
//! const verifier: jwt.Verifier = try .init(.{ .keys = keys[0..key_count], .issuer = "orders", .audiences = &.{"billing"} });
//! var authenticator: JwtAuthenticator = .{ .verifier = &verifier };
//! // .authenticator = &authenticator in the options of rpc.Server
//! ```

const jwt = @import("jwt");
const rpc = @import("rpc");
const v = @import("validator");

const JwtAuthenticator = @This();

/// Borrowed: it lives as long as the server.
verifier: *const jwt.Verifier,

/// The claims billing reads from a token of orders. The claims it does
/// not name are skipped.
pub const Claims = struct {
    roles: []const []const u8 = &.{},

    pub const field_rules = .{ .roles = v.maxItems(16) };
};

pub fn authenticate(self: *JwtAuthenticator, ctx: *const rpc.AuthContext) rpc.AuthError!?rpc.IdentityView {
    return switch (ctx.credentials) {
        // No token: an anonymous call, which a method with
        // `.auth = .required` refuses.
        .none => null,
        .bearer => |token| {
            // The claims live in the arena of the call, as the identity must.
            const verified = self.verifier.verify(Claims, ctx.io(), ctx.allocator(), token, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Expired, forged, or meant for another service: a wrong
                // token never passes as no token.
                else => return error.InvalidCredentials,
            };
            const subject = verified.registered.subject orelse return error.InvalidCredentials;
            return .{ .subject = subject, .roles = verified.claims.roles };
        },
        // Basic credentials or a scheme of another kind: billing takes none.
        else => error.InvalidCredentials,
    };
}
