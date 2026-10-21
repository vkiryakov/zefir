//! Tests of the billing service without a network: `rpc.testing.Server`
//! runs its handler with the whole chain of `rpc.Server`, the
//! authenticator first, on a memory transport. The client of a test calls
//! as orders would, with the token of a user. The tokens come from a
//! signer with a key of orders made for the tests, and
//! `jwt.testing.FixedClock` sets the time.

const std = @import("std");
const jwt = @import("jwt");
const rpc = @import("rpc");
const api = @import("billing-api");
const BillingHandler = @import("BillingHandler.zig");
const JwtAuthenticator = @import("JwtAuthenticator.zig");

const testing = std.testing;

/// The time of the tests: 2026-10-22, 12:00 UTC, in seconds of Unix time.
const noon = 1_792_670_400;

/// Billing as its `main` builds it: the public key of orders, a verifier
/// of the audience billing, and the server with the authenticator.
const Billing = struct {
    clock: jwt.testing.FixedClock,
    /// The private key of orders, which billing never has: the tests sign
    /// with it, as orders would.
    orders_key: jwt.SigningKey,
    /// The public key of orders, as billing reads it from its settings.
    keys: [1]jwt.Key,
    verifier: jwt.Verifier,
    authenticator: JwtAuthenticator,
    handler: BillingHandler,
    server: rpc.testing.Server,
    client: rpc.Client,

    /// Starts billing; `b` stays where it is until `stop`.
    fn start(b: *Billing) !void {
        b.clock = try .init(testing.io, noon);
        errdefer b.clock.deinit();
        const io = b.clock.io();
        b.orders_key = try .generate(io, .EdDSA, .{ .id = "2026-10" });
        errdefer b.orders_key.deinit();
        b.keys = .{b.orders_key.verificationKey()};
        try b.useKeys(&b.keys);
        b.authenticator = .{ .verifier = &b.verifier };
        b.handler = .{};
        b.server = try .init(testing.allocator, io, .{ .handlers = .{&b.handler}, .authenticator = &b.authenticator });
        errdefer b.server.deinit();
        b.client = try b.server.client(.{});
    }

    fn stop(b: *Billing) void {
        b.client.deinit();
        b.server.deinit();
        b.keys[0].deinit();
        b.orders_key.deinit();
        b.clock.deinit();
    }

    /// The public keys of orders that billing takes, as its settings list
    /// them after a restart.
    fn useKeys(b: *Billing, keys: []const jwt.Key) !void {
        b.verifier = try .init(.{ .keys = keys, .issuer = "orders", .audiences = &.{"billing"} });
    }

    /// A token of orders for user-7, signed with `key` for `audiences`;
    /// the caller frees it.
    fn tokenOf(b: *Billing, key: *const jwt.SigningKey, audiences: []const []const u8) ![]u8 {
        const signer: jwt.Signer = try .init(key, .{ .issuer = "orders", .audiences = audiences });
        return signer.sign(JwtAuthenticator.Claims, b.clock.io(), testing.allocator, &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
    }

    /// billing.v1.charge of order 42, with `credentials`.
    fn charge(b: *Billing, credentials: rpc.Credentials) !rpc.Client.Result(api.Charge) {
        return b.client.call(b.clock.io(), .root, api.BillingApi.charge, .{ .order_id = 42, .amount_cents = 1250 }, .{ .credentials = credentials });
    }
};

test "billing takes the token of orders" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();
    const token = try b.tokenOf(&b.orders_key, &.{ "orders", "billing" });
    defer testing.allocator.free(token);

    var result = try b.charge(.{ .bearer = token });
    defer result.deinit();
    // The handler charged the user of the token.
    try testing.expectEqualStrings("user-7", result.outcome.ok.customer);
    try testing.expectEqual(42, result.outcome.ok.order_id);
}

test "a token without billing among its audiences is unauthenticated" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();
    const token = try b.tokenOf(&b.orders_key, &.{"orders"});
    defer testing.allocator.free(token);

    var result = try b.charge(.{ .bearer = token });
    defer result.deinit();
    try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
    try testing.expectEqualStrings("Invalid credentials", result.outcome.failure.message);
}

test "no token is anonymous, and a method that needs a user refuses it" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();

    var result = try b.charge(.none);
    defer result.deinit();
    try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
    try testing.expectEqualStrings("Authentication required", result.outcome.failure.message);
}

test "an expired token is unauthenticated" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();
    const token = try b.tokenOf(&b.orders_key, &.{ "orders", "billing" });
    defer testing.allocator.free(token);

    // 15 minutes of its life and the 60 seconds of leeway have passed.
    b.clock.set(noon + 16 * 60);
    var result = try b.charge(.{ .bearer = token });
    defer result.deinit();
    try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
}

test "while the key of orders changes, billing takes the tokens of both keys" {
    var b: Billing = undefined;
    try b.start();
    defer b.stop();
    var new_key: jwt.SigningKey = try .generate(b.clock.io(), .EdDSA, .{ .id = "2026-11" });
    defer new_key.deinit();
    const old_token = try b.tokenOf(&b.orders_key, &.{ "orders", "billing" });
    defer testing.allocator.free(old_token);
    const new_token = try b.tokenOf(&new_key, &.{ "orders", "billing" });
    defer testing.allocator.free(new_token);

    // Step 1: billing restarts with the old key and the new one, and
    // takes the tokens of both, each by its kid.
    const keys = [_]jwt.Key{ b.orders_key.verificationKey(), new_key.verificationKey() };
    try b.useKeys(&keys);
    for ([_][]const u8{ old_token, new_token }) |token| {
        var result = try b.charge(.{ .bearer = token });
        defer result.deinit();
        try testing.expectEqualStrings("user-7", result.outcome.ok.customer);
    }

    // Step 3: the old key is gone, and a token it signed is refused.
    try b.useKeys(keys[1..]);
    var result = try b.charge(.{ .bearer = old_token });
    defer result.deinit();
    try testing.expectEqual(.unauthenticated, result.outcome.failure.code);
}
