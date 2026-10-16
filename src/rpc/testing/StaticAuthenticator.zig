//! `rpc.testing.StaticAuthenticator`: an authenticator for tests. A call
//! with any credentials gets the identity it holds; a call without
//! credentials is anonymous. It checks nothing, so it is only for tests.
//!
//! ```zig
//! var auth: rpc.testing.StaticAuthenticator = .{ .identity = .{ .subject = "u1", .permissions = &.{"users.write"} } };
//! var t = try rpc.testing.Server.init(std.testing.allocator, std.testing.io, .{
//!     .handlers = .{&users},
//!     .authenticator = &auth,
//! });
//! ```
//!
//! A test may change `identity` between calls, not while one runs.

const std = @import("std");
const auth = @import("../auth.zig");

const StaticAuthenticator = @This();

/// The identity of every call with credentials. Null: those calls are
/// anonymous too. Its strings and arrays outlive the server.
identity: ?auth.IdentityView = null,

/// `identity` for a call with credentials of any kind; null, anonymous, for
/// a call without them.
pub fn authenticate(self: *StaticAuthenticator, ctx: *const auth.AuthContext) auth.AuthError!?auth.IdentityView {
    if (ctx.credentials == .none) return null;
    return self.identity;
}

const testing = std.testing;

test "any credentials get the identity, none get anonymous" {
    var static: StaticAuthenticator = .{ .identity = .{ .subject = "u1", .permissions = &.{"users.write"} } };
    const authenticator: auth.Authenticator = .init(&static);
    for ([_]@import("../credentials.zig").Credentials{
        .{ .bearer = "t" },
        .{ .basic = .{ .user = "u", .password = "p" } },
        .{ .custom = "ApiKey k" },
    }) |credentials| {
        const ctx: auth.AuthContext = .{ .credentials = credentials, .call = undefined };
        const identity = (try authenticator.authenticate(authenticator.ptr, &ctx)).?;
        try testing.expectEqualStrings("u1", identity.subject);
        try testing.expect(identity.hasPermission("users.write"));
    }
    const anonymous: auth.AuthContext = .{ .credentials = .none, .call = undefined };
    try testing.expectEqual(@as(?auth.IdentityView, null), try authenticator.authenticate(authenticator.ptr, &anonymous));

    // Without an identity, every call is anonymous.
    var empty: StaticAuthenticator = .{};
    const bearer: auth.AuthContext = .{ .credentials = .{ .bearer = "t" }, .call = undefined };
    try testing.expectEqual(@as(?auth.IdentityView, null), try empty.authenticate(&bearer));
}
