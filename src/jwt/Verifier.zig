//! Checks the tokens of one issuer: their size and form, the header, the
//! key by "kid" among the verifier's keys, the signature by that key's
//! algorithm, the registered claims and then the application's claims and
//! their rules (RFC 8725). A verifier is immutable and owns nothing: one of
//! them serves every task of a service at once.
//!
//! ```zig
//! const keys = [_]jwt.Key{signing_key.verificationKey()};
//! const verifier: jwt.Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"} });
//! const verified = try verifier.verify(Claims, ctx.io(), ctx.allocator(), bearer_token, .{});
//! // verified.registered.subject, verified.claims.roles
//! ```

const Verifier = @This();

const std = @import("std");
const v = @import("validator");
const root = @import("root.zig");
const claims = @import("claims.zig");
const header = @import("header.zig");
const jws = @import("jws.zig");
const crypto = @import("crypto.zig");
const base64url = @import("base64url.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");

const Details = root.Details;
const VerifyError = root.VerifyError;

options: Options,

pub const Options = struct {
    /// The keys that verify tokens (5.3): at least one; their ids differ;
    /// a key without an id only when it is the only one. A token picks its
    /// key by "kid", and that key's algorithm checks it.
    keys: []const Key,
    /// The issuer the verifier trusts: "iss" equals it byte for byte.
    issuer: []const u8,
    /// The names of this service: "aud" of a token holds one of them; at
    /// least one.
    audiences: []const []const u8,
    /// The accepted values of "typ", at least one; compared without the
    /// case of ASCII letters and without a leading "application/", so
    /// "at+jwt" takes "application/AT+JWT".
    token_types: []const []const u8 = &.{"JWT"},
    /// How far the clocks of the issuer and of this service may disagree,
    /// for "exp", "nbf" and "iat": 0 to 300 seconds.
    leeway: std.Io.Duration = .fromSeconds(60),
};

/// A verifier of `options`, whose keys and strings it borrows: they live
/// as long as the verifier and do not move. `InvalidOptions`: no keys, a
/// key that `deinit` wiped, two keys with one id, a key without an id next
/// to another one, an empty issuer, no audiences or token types or an empty
/// one among them, or a leeway outside 0 to 300 seconds.
pub fn init(options: Options) error{InvalidOptions}!Verifier {
    if (options.keys.len == 0) return error.InvalidOptions;
    for (options.keys, 0..) |*key, i| {
        if (!crypto.holdsKey(key)) return error.InvalidOptions;
        const id = key.id() orelse {
            if (options.keys.len > 1) return error.InvalidOptions;
            continue;
        };
        for (options.keys[0..i]) |*earlier| {
            if (std.mem.eql(u8, earlier.id() orelse continue, id)) return error.InvalidOptions;
        }
    }
    if (options.issuer.len == 0) return error.InvalidOptions;
    if (!allNamed(options.audiences)) return error.InvalidOptions;
    if (!allNamed(options.token_types)) return error.InvalidOptions;
    // "application/" alone would name the empty type.
    for (options.token_types) |token_type| {
        if (header.sameType(token_type, "")) return error.InvalidOptions;
    }
    const leeway = options.leeway.toNanoseconds();
    if (leeway < 0 or leeway > 300 * std.time.ns_per_s) return error.InvalidOptions;
    return .{ .options = options };
}

/// At least one name, and none of them empty.
fn allNamed(names: []const []const u8) bool {
    if (names.len == 0) return false;
    for (names) |name| {
        if (name.len == 0) return false;
    }
    return true;
}

/// Checks `token` and gives its header, its registered claims and its
/// claims as a `Claims`, which `jwt.assertClaims` describes; `void` takes
/// the registered claims alone. Memory comes from `arena`, the arena of
/// the request: the result lives as long as it and does not point into
/// `token`. From `io` only the clock is read (`Clock.real`). On an error
/// `options.details`, if given, says what the refusal was about; it holds
/// no bytes of the token. Many tasks may call one verifier at once.
pub fn verify(
    verifier: *const Verifier,
    comptime Claims: type,
    io: std.Io,
    arena: std.mem.Allocator,
    token: []const u8,
    options: root.VerifyOptions,
) VerifyError!root.Verified(Claims) {
    comptime claims.check(Claims);
    var local: Details = .{};
    const details = options.details orelse &local;
    details.* = .{};

    const opened = try jws.open(arena, token, verifier.options.keys, verifier.options.token_types, details);
    // The payload is JSON that only the holder of a key could write: it is
    // read only now that the signature verified.
    const input = try claims.readRegistered(arena, opened.payload);
    const registered = try claims.checkRegistered(input, .{
        .issuer = verifier.options.issuer,
        .audiences = verifier.options.audiences,
        .leeway_seconds = verifier.options.leeway.toSeconds(),
    }, std.Io.Clock.real.now(io).toSeconds(), details);
    const value = try claims.decode(Claims, arena, opened.payload, details);
    if (Claims != void) {
        if (v.check(&value, &details.path_buf)) |violation| {
            details.violation = violation;
            return error.ClaimsRejected;
        }
    }
    return .{ .header = opened.header, .registered = registered, .claims = value };
}

const testing = std.testing;
const FixedClock = root.testing.FixedClock;
const rfc7515 = @import("testdata/rfc7515.zig");
const rfc7519 = @import("testdata/rfc7519.zig");

const t0 = 1_760_000_000;
const secret = "0123456789abcdef0123456789abcdef";
const header_k1 = "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"k1\"}";
const good_payload = "{\"iss\":\"orders\",\"sub\":\"user-7\",\"aud\":\"orders\",\"iat\":1760000000,\"exp\":1760000900}";

fn sealed(key: *const SigningKey, header_json: []const u8, payload_json: []const u8) ![]u8 {
    return jws.seal(testing.allocator, testing.io, key, header_json, payload_json);
}

/// Verifies `token` and expects `expected`, with `claim` in `Details`.
fn expectRefused(verifier: *const Verifier, comptime Claims: type, io: std.Io, token: []const u8, expected: VerifyError, claim: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var details: Details = .{};
    if (verifier.verify(Claims, io, arena_state.allocator(), token, .{ .details = &details })) |_| {
        std.debug.print("verified: {s}\n", .{token});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(expected, err);
    if (claim) |name| {
        try testing.expectEqualStrings(name, details.claim orelse "(none)");
    } else {
        try testing.expectEqual(null, details.claim);
    }
}

/// One HS256 key "k1" and its verifier for the issuer and audience
/// "orders".
const Setup = struct {
    signing: SigningKey,
    keys: [1]Key,
    verifier: Verifier,

    fn init(s: *Setup) !void {
        s.signing = try .hmac(.HS256, secret, .{ .id = "k1" });
        s.keys = .{s.signing.verificationKey()};
        s.verifier = try .init(.{ .keys = &s.keys, .issuer = "orders", .audiences = &.{"orders"} });
    }

    fn deinit(s: *Setup) void {
        s.keys[0].deinit();
        s.signing.deinit();
    }
};

test "Verifier.init refuses options it could never verify with" {
    var a: SigningKey = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer a.deinit();
    var b: SigningKey = try .hmac(.HS512, secret ++ secret, .{ .id = "k1" });
    defer b.deinit();
    var c: SigningKey = try .hmac(.HS256, secret, .{});
    defer c.deinit();
    var d: SigningKey = try .hmac(.HS256, secret, .{ .id = "k2" });
    defer d.deinit();
    const one = [_]Key{a.verificationKey()};
    const two = [_]Key{ a.verificationKey(), d.verificationKey() };
    const same_id = [_]Key{ a.verificationKey(), b.verificationKey() };
    const without_id = [_]Key{ a.verificationKey(), c.verificationKey() };
    const only_without_id = [_]Key{c.verificationKey()};

    const good: Options = .{ .keys = &one, .issuer = "orders", .audiences = &.{"orders"} };
    _ = try Verifier.init(good);
    _ = try Verifier.init(.{ .keys = &two, .issuer = "orders", .audiences = &.{ "orders", "billing" }, .token_types = &.{ "JWT", "at+jwt" } });
    _ = try Verifier.init(.{ .keys = &only_without_id, .issuer = "orders", .audiences = &.{"orders"} });
    _ = try Verifier.init(.{ .keys = &one, .issuer = "orders", .audiences = &.{"orders"}, .leeway = .zero });
    _ = try Verifier.init(.{ .keys = &one, .issuer = "orders", .audiences = &.{"orders"}, .leeway = .fromSeconds(300) });

    for ([_]Options{
        .{ .keys = &.{}, .issuer = "orders", .audiences = &.{"orders"} },
        .{ .keys = &same_id, .issuer = "orders", .audiences = &.{"orders"} },
        .{ .keys = &without_id, .issuer = "orders", .audiences = &.{"orders"} },
        .{ .keys = &one, .issuer = "", .audiences = &.{"orders"} },
        .{ .keys = &one, .issuer = "orders", .audiences = &.{} },
        .{ .keys = &one, .issuer = "orders", .audiences = &.{ "orders", "" } },
        .{ .keys = &one, .issuer = "orders", .audiences = &.{"orders"}, .token_types = &.{} },
        .{ .keys = &one, .issuer = "orders", .audiences = &.{"orders"}, .token_types = &.{""} },
        .{ .keys = &one, .issuer = "orders", .audiences = &.{"orders"}, .token_types = &.{ "JWT", "application/" } },
        .{ .keys = &one, .issuer = "orders", .audiences = &.{"orders"}, .leeway = .fromNanoseconds(-1) },
        .{ .keys = &one, .issuer = "orders", .audiences = &.{"orders"}, .leeway = .fromNanoseconds(300 * std.time.ns_per_s + 1) },
    }) |options| {
        try testing.expectError(error.InvalidOptions, Verifier.init(options));
    }
}

test "a zero-filled Key is refused by Verifier.init" {
    // Zeroes read as an HS256 key with an empty secret, whose MAC anybody
    // can compute.
    var zero: Key = undefined;
    @memset(std.mem.asBytes(&zero), 0);
    try testing.expectError(error.InvalidOptions, Verifier.init(.{ .keys = &.{zero}, .issuer = "orders", .audiences = &.{"orders"} }));
    // A key wiped by deinit is such a key too.
    var signing: SigningKey = try .generate(testing.io, .ES256, .{});
    defer signing.deinit();
    var wiped = signing.verificationKey();
    wiped.deinit();
    try testing.expectError(error.InvalidOptions, Verifier.init(.{ .keys = &.{wiped}, .issuer = "orders", .audiences = &.{"orders"} }));
}

test "5.9: keys rotate by kid" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var old: SigningKey = try .hmac(.HS256, secret, .{ .id = "2026-09" });
    defer old.deinit();
    var new: SigningKey = try .hmac(.HS256, "abcdefghijklmnopqrstuvwxyz012345", .{ .id = "2026-10" });
    defer new.deinit();
    const old_token = try sealed(&old, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"2026-09\"}", good_payload);
    defer testing.allocator.free(old_token);
    const new_token = try sealed(&new, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"2026-10\"}", good_payload);
    defer testing.allocator.free(new_token);

    // Step 1: the verifiers take both keys.
    const both = [_]Key{ old.verificationKey(), new.verificationKey() };
    const during: Verifier = try .init(.{ .keys = &both, .issuer = "orders", .audiences = &.{"orders"} });
    try testing.expectEqualStrings("2026-09", (try during.verify(void, clock.io(), arena, old_token, .{})).header.key_id.?);
    try testing.expectEqualStrings("2026-10", (try during.verify(void, clock.io(), arena, new_token, .{})).header.key_id.?);
    // Step 3: the old key leaves, and so do its tokens.
    const only_new = [_]Key{new.verificationKey()};
    const after: Verifier = try .init(.{ .keys = &only_new, .issuer = "orders", .audiences = &.{"orders"} });
    _ = try after.verify(void, clock.io(), arena, new_token, .{});
    try expectRefused(&after, void, clock.io(), old_token, error.UnknownKey, "kid");
}

test "RFC 7515 A.1 and RFC 7519 §3.1: through the Verifier, MissingClaim aud" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    try testing.expectEqualStrings(rfc7515.a1_token, rfc7519.s3_1_token);
    const secret_a1 = try base64url.decodeAlloc(testing.allocator, rfc7515.a1_key);
    defer testing.allocator.free(secret_a1);
    const keys = [_]Key{try .hmac(.HS256, secret_a1, .{})};
    const verifier: Verifier = try .init(.{ .keys = &keys, .issuer = "joe", .audiences = &.{"orders"} });
    // The header, the key and the signature pass; the claims have no "aud".
    try expectRefused(&verifier, void, clock.io(), rfc7519.s3_1_token, error.MissingClaim, "aud");
}

test "RFC 7519 §6.1: an unsecured JWT is UnsupportedAlgorithm" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    try testing.expectEqualStrings(rfc7515.a5_token, rfc7519.s6_1_token);
    try expectRefused(&setup.verifier, void, testing.io, rfc7519.s6_1_token, error.UnsupportedAlgorithm, "alg");
}

const Roles = struct {
    roles: []const []const u8 = &.{},
    level: u8 = 0,

    pub const field_rules = .{ .roles = v.maxItems(2) };
};

test "a token passes with void claims and with the application's claims" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = try sealed(&setup.signing, header_k1, "{\"iss\":\"orders\",\"sub\":\"user-7\",\"aud\":[\"orders\",\"billing\"],\"iat\":1760000000,\"nbf\":1760000000,\"exp\":1760000900,\"jti\":\"t-1\",\"roles\":[\"buyer\"],\"level\":3}");
    defer testing.allocator.free(token);

    const plain = try setup.verifier.verify(void, clock.io(), arena, token, .{});
    try testing.expectEqual(.HS256, plain.header.algorithm);
    try testing.expectEqualStrings("k1", plain.header.key_id.?);
    try testing.expectEqualStrings("JWT", plain.header.token_type);
    try testing.expectEqualStrings("orders", plain.registered.issuer);
    try testing.expectEqualStrings("user-7", plain.registered.subject.?);
    try testing.expectEqual(2, plain.registered.audience.len);
    try testing.expectEqualStrings("billing", plain.registered.audience[1]);
    try testing.expectEqual(1760000900, plain.registered.expires_at);
    try testing.expectEqual(1760000000, plain.registered.not_before.?);
    try testing.expectEqual(1760000000, plain.registered.issued_at.?);
    try testing.expectEqualStrings("t-1", plain.registered.id.?);

    const typed = try setup.verifier.verify(Roles, clock.io(), arena, token, .{});
    try testing.expectEqual(1, typed.claims.roles.len);
    try testing.expectEqualStrings("buyer", typed.claims.roles[0]);
    try testing.expectEqual(3, typed.claims.level);

    clock.set(t0 + 3600);
    try expectRefused(&setup.verifier, Roles, clock.io(), token, error.Expired, "exp");
}

test "a broken rule is ClaimsRejected with its path" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const token = try sealed(&setup.signing, header_k1, "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,\"roles\":[\"a\",\"b\",\"c\"]}");
    defer testing.allocator.free(token);
    var details: Details = .{};
    try testing.expectError(error.ClaimsRejected, setup.verifier.verify(Roles, clock.io(), arena_state.allocator(), token, .{ .details = &details }));
    const violation = details.violation.?;
    try testing.expectEqualStrings("validation.max_items", violation.code);
    try testing.expectEqualStrings("roles", violation.field.?);
    try testing.expectEqual(null, details.claim);
    // Without rules to break, the same token passes.
    _ = try setup.verifier.verify(void, clock.io(), arena_state.allocator(), token, .{});
}

test "a reused Details keeps nothing of the last failure" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const expired = try sealed(&setup.signing, header_k1, "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1700000000}");
    defer testing.allocator.free(expired);
    const good = try sealed(&setup.signing, header_k1, good_payload);
    defer testing.allocator.free(good);
    const too_many = try sealed(&setup.signing, header_k1, "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,\"roles\":[\"a\",\"b\",\"c\"]}");
    defer testing.allocator.free(too_many);
    const wrong_type = try sealed(&setup.signing, header_k1, "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,\"level\":\"x\"}");
    defer testing.allocator.free(wrong_type);

    var details: Details = .{};
    try testing.expectError(error.Expired, setup.verifier.verify(Roles, clock.io(), arena, expired, .{ .details = &details }));
    try testing.expectEqualStrings("exp", details.claim.?);
    _ = try setup.verifier.verify(Roles, clock.io(), arena, good, .{ .details = &details });
    try testing.expectEqual(null, details.claim);
    try testing.expectEqual(null, details.violation);
    try testing.expectError(error.ClaimsRejected, setup.verifier.verify(Roles, clock.io(), arena, too_many, .{ .details = &details }));
    try testing.expectEqual(null, details.claim);
    try testing.expectEqualStrings("roles", details.violation.?.field.?);
    try testing.expectError(error.InvalidClaims, setup.verifier.verify(Roles, clock.io(), arena, wrong_type, .{ .details = &details }));
    try testing.expectEqualStrings("level", details.violation.?.field.?);
    try testing.expectError(error.Expired, setup.verifier.verify(Roles, clock.io(), arena, expired, .{ .details = &details }));
    try testing.expectEqualStrings("exp", details.claim.?);
    try testing.expectEqual(null, details.violation);
}

test "iss and aud with escapes are compared as they decode" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const token = try sealed(&setup.signing, header_k1, "{\"iss\":\"\x5cu006frders\",\"aud\":[\"\x5cu006F\x5cu0072ders\"],\"exp\":1760000900}");
    defer testing.allocator.free(token);
    const got = try setup.verifier.verify(void, clock.io(), arena_state.allocator(), token, .{});
    try testing.expectEqualStrings("orders", got.registered.issuer);
    try testing.expectEqualStrings("orders", got.registered.audience[0]);
    // An unpaired surrogate is no string.
    const broken = try sealed(&setup.signing, header_k1, "{\"iss\":\"\x5cud800\",\"aud\":\"orders\",\"exp\":1760000900}");
    defer testing.allocator.free(broken);
    try expectRefused(&setup.verifier, void, clock.io(), broken, error.Malformed, null);
}

const Secretive = struct {
    count: u32 = 0,
    mood: enum { calm, busy } = .calm,
};

test "Details never holds bytes of the token" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const payloads = [_][]const u8{
        "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,\"count\":\"SECRET-VALUE-123\"}",
        "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,\"mood\":\"SECRET-ENUM\"}",
        "{\"iss\":\"SECRET-ISSUER\",\"aud\":\"orders\",\"exp\":1760000900}",
        "{\"iss\":\"orders\",\"aud\":\"SECRET-AUDIENCE\",\"exp\":1760000900}",
        "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":\"SECRET-TIME\"}",
    };
    for (payloads) |payload| {
        const token = try sealed(&setup.signing, header_k1, payload);
        defer testing.allocator.free(token);
        var details: Details = .{};
        _ = setup.verifier.verify(Secretive, clock.io(), arena_state.allocator(), token, .{ .details = &details }) catch {};
        try expectNoSecret(&details);
    }
    const unknown_kid = try sealed(&setup.signing, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"SECRET-KID\"}", good_payload);
    defer testing.allocator.free(unknown_kid);
    var details: Details = .{};
    try testing.expectError(error.UnknownKey, setup.verifier.verify(void, clock.io(), arena_state.allocator(), unknown_kid, .{ .details = &details }));
    try expectNoSecret(&details);
}

fn expectNoSecret(details: *const Details) !void {
    const texts = [_]?[]const u8{
        details.claim,
        if (details.violation) |violation| violation.code else null,
        if (details.violation) |violation| violation.message else null,
        if (details.violation) |violation| violation.field else null,
    };
    for (texts) |text| {
        try testing.expect(std.mem.find(u8, text orelse "", "SECRET") == null);
    }
    try testing.expect(details.claim != null or details.violation != null);
}

test "the result does not point into the token" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const token = try sealed(&setup.signing, header_k1, "{\"iss\":\"orders\",\"sub\":\"user-7\",\"aud\":\"orders\",\"exp\":1760000900,\"roles\":[\"buyer\"]}");
    defer testing.allocator.free(token);
    const copy = try testing.allocator.dupe(u8, token);
    defer testing.allocator.free(copy);
    const got = try setup.verifier.verify(Roles, clock.io(), arena_state.allocator(), copy, .{});
    @memset(copy, 0);
    try testing.expectEqualStrings("orders", got.registered.issuer);
    try testing.expectEqualStrings("user-7", got.registered.subject.?);
    try testing.expectEqualStrings("orders", got.registered.audience[0]);
    try testing.expectEqualStrings("buyer", got.claims.roles[0]);
    try testing.expectEqualStrings("k1", got.header.key_id.?);
    try testing.expectEqualStrings("JWT", got.header.token_type);
}
