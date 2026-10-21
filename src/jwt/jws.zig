//! The JWS layer: `open` checks a compact token up to its signature and
//! gives its payload, still unparsed; `seal` signs a header and a payload
//! into a token. `Verifier` and `Signer` stand on it, and the RFC vectors
//! test it directly, since their payloads are no claims and their headers
//! often have no "typ".

const std = @import("std");
const root = @import("root.zig");
const algorithm = @import("algorithm.zig");
const base64url = @import("base64url.zig");
const compact = @import("compact.zig");
const crypto = @import("crypto.zig");
const header = @import("header.zig");
const errors = @import("errors.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");

const Algorithm = algorithm.Algorithm;
const Header = header.Header;
const VerifyError = errors.VerifyError;
const Details = errors.Details;

/// A token whose header passed its rules and whose signature verified.
pub const Opened = struct {
    header: Header,
    /// The decoded payload, not parsed yet: JSON only the holder of a key
    /// could have written.
    payload: []const u8,
};

/// Checks `token` in the order of RFC 8725: its size and parts, the
/// header, the key by "kid" among `keys`, the signature by the key's
/// algorithm; then decodes the payload. Everything comes from `arena`,
/// and nothing of the result points into `token`.
pub fn open(arena: std.mem.Allocator, token: []const u8, keys: []const Key, token_types: []const []const u8, details: *Details) VerifyError!Opened {
    const parts = try compact.split(token);
    const header_json = try base64url.decodeAlloc(arena, parts.header);
    const head = try header.parse(arena, header_json, token_types, details);
    const key = try pickKey(keys, head, details);

    const signature_len = try base64url.decodedLen(parts.signature);
    if (signature_len != algorithm.signatureBytes(head.algorithm)) return error.BadSignature;
    var signature: [crypto.max_signature_bytes]u8 = undefined;
    try base64url.decode(signature[0..signature_len], parts.signature);
    try crypto.verify(key, parts.signing_input, signature[0..signature_len]);

    return .{ .header = head, .payload = try base64url.decodeAlloc(arena, parts.payload) };
}

/// The key of a token among `keys` (design 5.3): the one whose id is the
/// token's "kid"; without a "kid", the only key, if there is one. The key
/// must be of the token's algorithm. On an error `details.claim` is "kid"
/// or "alg".
pub fn pickKey(keys: []const Key, head: Header, details: *Details) VerifyError!*const Key {
    const key: *const Key = if (head.key_id) |kid| find: {
        for (keys) |*candidate| {
            const id = candidate.id() orelse continue;
            if (std.mem.eql(u8, id, kid)) break :find candidate;
        }
        details.claim = "kid";
        return error.UnknownKey;
    } else if (keys.len == 1) &keys[0] else {
        details.claim = "kid";
        return error.UnknownKey;
    };
    if (key.algorithm != head.algorithm) {
        details.claim = "alg";
        return error.AlgorithmMismatch;
    }
    return key;
}

/// Signs `header_json` and `payload_json` with `key` into a compact token
/// in memory of `allocator`, which the caller frees. `TokenTooLarge`: the
/// token would be longer than `max_token_bytes`.
pub fn seal(allocator: std.mem.Allocator, io: std.Io, key: *const SigningKey, header_json: []const u8, payload_json: []const u8) error{ TokenTooLarge, OutOfMemory }![]u8 {
    if (header_json.len > root.max_token_bytes or payload_json.len > root.max_token_bytes) return error.TokenTooLarge;
    const header_len = base64url.encodedLen(header_json.len);
    const signing_len = header_len + 1 + base64url.encodedLen(payload_json.len);
    const token_len = signing_len + 1 + base64url.encodedLen(algorithm.signatureBytes(key.algorithm));
    if (token_len > root.max_token_bytes) return error.TokenTooLarge;

    const token = try allocator.alloc(u8, token_len);
    _ = base64url.encode(token[0..header_len], header_json);
    token[header_len] = '.';
    _ = base64url.encode(token[header_len + 1 .. signing_len], payload_json);
    token[signing_len] = '.';
    var signature: [crypto.max_signature_bytes]u8 = undefined;
    _ = base64url.encode(token[signing_len + 1 ..], crypto.sign(key, io, token[0..signing_len], &signature));
    return token;
}

const testing = std.testing;
const jwt_types: []const []const u8 = &.{"JWT"};

const secret_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const secret_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn sealed(signing: *const SigningKey, header_json: []const u8, payload_json: []const u8) ![]u8 {
    return seal(testing.allocator, testing.io, signing, header_json, payload_json);
}

/// Opens `token` with `keys` and expects `expected`, with `claim` in `Details`.
fn expectRefused(token: []const u8, keys: []const Key, expected: VerifyError, claim: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var details: Details = .{};
    if (open(arena_state.allocator(), token, keys, jwt_types, &details)) |_| {
        std.debug.print("opened: {s}\n", .{token});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(expected, err);
    if (claim) |name| {
        try testing.expectEqualStrings(name, details.claim orelse "(none)");
    } else {
        try testing.expectEqual(null, details.claim);
    }
}

fn wipe(keys: []Key) void {
    for (keys) |*key| key.deinit();
}

test "seal and open give the payload back with HS256, HS384 and HS512" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]Algorithm{ .HS256, .HS384, .HS512 }) |alg| {
        var signing: SigningKey = try .hmac(alg, secret_a, .{ .id = "k1" });
        defer signing.deinit();
        var keys = [_]Key{signing.verificationKey()};
        defer wipe(&keys);
        const header_json = try std.fmt.allocPrint(arena, "{{\"alg\":\"{s}\",\"typ\":\"JWT\",\"kid\":\"k1\"}}", .{alg.name()});
        const token = try sealed(&signing, header_json, "{\"sub\":\"user-7\"}");
        defer testing.allocator.free(token);

        var details: Details = .{};
        const opened = try open(arena, token, &keys, jwt_types, &details);
        try testing.expectEqualStrings("{\"sub\":\"user-7\"}", opened.payload);
        try testing.expectEqual(alg, opened.header.algorithm);
        try testing.expectEqualStrings("k1", opened.header.key_id.?);
        try testing.expectEqualStrings("JWT", opened.header.token_type);
    }
}

test "5.3: the key is chosen by kid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var details: Details = .{};

    var k1: SigningKey = try .hmac(.HS256, secret_a, .{ .id = "k1" });
    defer k1.deinit();
    var k2: SigningKey = try .hmac(.HS256, secret_b, .{ .id = "k2" });
    defer k2.deinit();
    var both = [_]Key{ k1.verificationKey(), k2.verificationKey() };
    defer wipe(&both);
    var only_k1 = [_]Key{k1.verificationKey()};
    defer wipe(&only_k1);

    const by_k2 = try sealed(&k2, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"k2\"}", "{}");
    defer testing.allocator.free(by_k2);
    try testing.expectEqualStrings("k2", (try open(arena, by_k2, &both, jwt_types, &details)).header.key_id.?);

    const unknown = try sealed(&k2, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"k3\"}", "{}");
    defer testing.allocator.free(unknown);
    try expectRefused(unknown, &both, error.UnknownKey, "kid");

    // Without a kid, a key is taken only when it is the only one.
    const no_kid = try sealed(&k1, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}", "{}");
    defer testing.allocator.free(no_kid);
    try expectRefused(no_kid, &both, error.UnknownKey, "kid");
    _ = try open(arena, no_kid, &only_k1, jwt_types, &details);

    var anonymous: SigningKey = try .hmac(.HS256, secret_a, .{});
    defer anonymous.deinit();
    var only_anonymous = [_]Key{anonymous.verificationKey()};
    defer wipe(&only_anonymous);
    const kid_k1 = try sealed(&anonymous, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"k1\"}", "{}");
    defer testing.allocator.free(kid_k1);
    try expectRefused(kid_k1, &only_anonymous, error.UnknownKey, "kid");

    const long_kid = "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"" ++ @as([129]u8, @splat('k')) ++ "\"}";
    const too_long = try sealed(&k1, long_kid, "{}");
    defer testing.allocator.free(too_long);
    try expectRefused(too_long, &only_k1, error.UnknownKey, "kid");

    // The key decides the algorithm: a token of another one is refused.
    var k1_hs384: SigningKey = try .hmac(.HS384, secret_a, .{ .id = "k1" });
    defer k1_hs384.deinit();
    const hs384 = try sealed(&k1_hs384, "{\"alg\":\"HS384\",\"typ\":\"JWT\",\"kid\":\"k1\"}", "{}");
    defer testing.allocator.free(hs384);
    try expectRefused(hs384, &only_k1, error.AlgorithmMismatch, "alg");

    var anonymous_hs512: SigningKey = try .hmac(.HS512, secret_a, .{});
    defer anonymous_hs512.deinit();
    const hs512 = try sealed(&anonymous_hs512, "{\"alg\":\"HS512\",\"typ\":\"JWT\"}", "{}");
    defer testing.allocator.free(hs512);
    try expectRefused(hs512, &only_anonymous, error.AlgorithmMismatch, "alg");
}

test "a signature of the wrong length is BadSignature" {
    var signing: SigningKey = try .hmac(.HS256, secret_a, .{});
    defer signing.deinit();
    var keys = [_]Key{signing.verificationKey()};
    defer wipe(&keys);
    const token = try sealed(&signing, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}", "{}");
    defer testing.allocator.free(token);
    const signing_input = token[0 .. std.mem.findScalarLast(u8, token, '.').? + 1];

    // An empty signature, as "alg": "none" has.
    try expectRefused(signing_input, &keys, error.BadSignature, null);
    for ([_]usize{ 31, 33 }) |len| {
        const sig: [33]u8 = @splat(7);
        var text: [44]u8 = undefined;
        var buf: [256]u8 = undefined;
        const wrong = try std.fmt.bufPrint(&buf, "{s}{s}", .{ signing_input, base64url.encode(&text, sig[0..len]) });
        try expectRefused(wrong, &keys, error.BadSignature, null);
    }
}

test "jku, x5u and jwk never choose the key" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var real: SigningKey = try .hmac(.HS256, secret_a, .{ .id = "k1" });
    defer real.deinit();
    var keys = [_]Key{real.verificationKey()};
    defer wipe(&keys);
    const pointers =
        \\{"alg":"HS256","typ":"JWT","kid":"k1","jku":"https://evil.example/jwks.json",
        \\ "x5u":"https://evil.example/cert","jwk":{"kty":"oct","k":"YmJiYmJi"}}
    ;
    const honest = try sealed(&real, pointers, "{}");
    defer testing.allocator.free(honest);
    var details: Details = .{};
    _ = try open(arena, honest, &keys, jwt_types, &details);

    // An attacker signs with a secret of their own and puts it in "jwk".
    var attacker: SigningKey = try .hmac(.HS256, secret_b, .{ .id = "k1" });
    defer attacker.deinit();
    var k_buf: [128]u8 = undefined;
    const header_json = try std.fmt.allocPrint(arena, "{{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"k1\",\"jwk\":{{\"kty\":\"oct\",\"k\":\"{s}\"}}}}", .{base64url.encode(&k_buf, secret_b)});
    const forged = try sealed(&attacker, header_json, "{}");
    defer testing.allocator.free(forged);
    try expectRefused(forged, &keys, error.BadSignature, null);
}

test "seal refuses a token over 8 KiB" {
    var signing: SigningKey = try .hmac(.HS256, secret_a, .{});
    defer signing.deinit();
    const payload: [7000]u8 = @splat('x');
    try testing.expectError(error.TokenTooLarge, sealed(&signing, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}", &payload));
    const huge: [20000]u8 = @splat('x');
    try testing.expectError(error.TokenTooLarge, sealed(&signing, &huge, "{}"));
}
