//! The fuzz test of the parsers of `security.jwt`. The first byte of an input
//! picks the target and the rest goes to it:
//!
//! - a token, to `Verifier.verify` with one HS256 key;
//! - the JSON of a header, to `header.parse`;
//! - the JSON of a payload, to `claims.readRegistered` and to
//!   `claims.decode` with claims of every type that jwt takes;
//! - PEM, to `Key.fromPem` and `SigningKey.fromPem`;
//! - DER, to `Key.fromDer` and `SigningKey.fromDer`.
//!
//! Every input ends in a value or in an error of the function's set, never
//! in a panic, and a call takes its memory from a bounded arena, as `verify`
//! takes it from the arena of a request. ECDSA and Ed25519 tokens are not a
//! target: their checks are slow and their inputs have fixed sizes, while
//! the key loaders do run on EC and Ed25519 keys. `zig build test-security`
//! runs the test on its corpus: the tokens of the RFCs and of the tests,
//! header and payload JSON, and every file of testdata/keys/. `zig build
//! fuzz-jwt --fuzz` runs the fuzzer (Linux, CI's fuzz.yml).

const std = @import("std");
const root = @import("root.zig");
const der = @import("der.zig");
const claims = @import("claims.zig");
const header = @import("header.zig");
const jws = @import("jws.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const Verifier = @import("Verifier.zig");
const keys = @import("testdata/keys.zig");
const rfc7515 = @import("testdata/rfc7515.zig");
const rfc7519 = @import("testdata/rfc7519.zig");
const rfc7520 = @import("testdata/rfc7520.zig");
const rfc8037 = @import("testdata/rfc8037.zig");

const testing = std.testing;
const Algorithm = root.Algorithm;

const Target = enum(u8) { token, header, payload, pem, der };
const target_count: u8 = @typeInfo(Target).@"enum".field_names.len;
/// The algorithms of the key loaders: the first byte also picks one.
const asymmetric = [_]Algorithm{ .ES256, .ES384, .EdDSA };

/// One byte of target and the largest key file and then one more, so
/// that every limit is in reach.
const max_input = 1 + der.max_input_bytes + 1;

/// The arena of a call (design 5.12): the memory `verify` may take for a
/// token of 8 KiB is a few times its size.
var call_memory: [64 * 1024]u8 = undefined;

const Line = struct {
    sku: []const u8,
    qty: u32 = 1,
};

/// Claims of every type of design 5.5, nested ones and names of
/// `claim_names` among them.
const FuzzClaims = struct {
    count: u32,
    flag: bool = false,
    small: i8 = 0,
    big: u64 = 0,
    signed: i64 = 0,
    ratio: f64 = 0,
    single: f32 = 0,
    level: enum { low, high } = .low,
    name: []const u8 = "",
    ids: []const u32 = &.{},
    roles: []const []const u8 = &.{},
    note: ?[]const u8 = null,
    order: ?struct { id: u64, lines: []const Line = &.{} } = null,
    is_root: bool = false,

    pub const claim_names = .{ .is_root = "http://example.com/is_root" };
};

const Context = struct {
    verifier: *const Verifier,
};

fn fuzzOne(context: Context, smith: *testing.Smith) anyerror!void {
    var buffer: [max_input]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    if (input.len == 0) return;
    const bytes = input[1..];
    const target: Target = @fromBackingInt(input[0] % target_count);
    const alg = asymmetric[input[0] / target_count % asymmetric.len];
    var memory: std.heap.FixedBufferAllocator = .init(&call_memory);
    const arena = memory.allocator();
    var details: root.Details = .{};
    switch (target) {
        .token => if (context.verifier.verify(void, testing.io, arena, bytes, .{ .details = &details })) |verified| {
            // Only a token MACed with the verifier's secret gets here.
            try testing.expectEqual(.HS256, verified.header.algorithm);
            try testing.expectEqualStrings("orders", verified.registered.issuer);
        } else |_| {},
        .header => if (header.parse(arena, bytes, &.{"JWT"}, &details)) |head| {
            try testing.expect(header.sameType(head.token_type, "JWT"));
        } else |_| {},
        .payload => {
            _ = claims.readRegistered(arena, bytes) catch {};
            _ = claims.decode(FuzzClaims, arena, bytes, &details) catch {};
        },
        .pem => {
            try expectLoaded(Key.fromPem(alg, bytes, .{}), alg);
            try expectLoaded(SigningKey.fromPem(alg, bytes, .{}), alg);
        },
        .der => {
            try expectLoaded(Key.fromDer(alg, bytes, .{}), alg);
            try expectLoaded(SigningKey.fromDer(alg, bytes, .{}), alg);
        },
    }
}

/// A key that loads is of the algorithm it was asked for; it is wiped.
fn expectLoaded(loaded: anytype, alg: Algorithm) !void {
    var key = loaded catch return;
    defer key.deinit();
    try testing.expectEqual(alg, key.algorithm);
}

/// The secret of the fuzz test's HS256 key.
const secret = "0123456789abcdef0123456789abcdef";
const hs256_header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

/// Payloads that the fuzz test's verifier accepts at any time before the
/// year 10000, sealed with its key: they reach the parts after the
/// signature.
const accepted_payloads = [_][]const u8{
    "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":253402300799}",
    "{\"iss\":\"orders\",\"sub\":\"user-7\",\"aud\":[\"billing\",\"orders\"],\"iat\":0,\"nbf\":1.5,\"exp\":2.534023e11,\"jti\":\"t-1\",\"roles\":[\"buyer\"]}",
    "{\"iss\":\"or\x5cu0064ers\",\"aud\":\"orders\",\"exp\":253402300799,\"x\":{\"y\":[1,2,{\"z\":null}]}}",
};

/// Header JSON: the rules of design 5.2 and the hostile headers of 7.3.
const headers = [_][]const u8{
    hs256_header,
    "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"2026-10\"}",
    "{\"typ\":\"JWT\",\r\n \"alg\":\"HS256\"}",
    "{\"alg\":\"EdDSA\",\"typ\":\"application/jwt\",\"cty\":\"text/plain\"}",
    "{\"alg\":\"ES256\",\"typ\":\"at+jwt\"}",
    "{\"alg\":\"none\",\"typ\":\"JWT\"}",
    "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"crit\":[\"exp\"]}",
    "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"cty\":\"JWT\"}",
    "{\"alg\":\"HS256\",\"alg\":\"HS256\",\"typ\":\"JWT\"}",
    "{\"alg\":5,\"typ\":5,\"kid\":5}",
    "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"jku\":\"https://evil.example/jwks.json\",\"jwk\":{\"kty\":\"oct\",\"k\":\"YmJi\"},\"x5c\":[\"MIIB\"],\"x5t#S256\":\"dGh1bWI\",\"b64\":false}",
    "{\"alg\":\"HS\x5cu0032\x5cu0035\x5cu0036\",\"typ\":\"\x5cu004aWT\"}",
    "{\"alg\":\"HS256\",\"typ\":\"\x5cud800\"}",
    "{\"alg\":\"HS256\",\"typ\":\"JWT\"} x",
    "\xef\xbb\xbf{\"alg\":\"HS256\",\"typ\":\"JWT\"}",
    "{\"a\":[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]}",
    "[]",
};

/// Payload JSON: the claims of design 5.5 and 5.6 and the hostile
/// payloads of 7.3.
const payloads = accepted_payloads ++ [_][]const u8{
    rfc7515.a1_payload,
    "{\"count\":1,\"flag\":true,\"small\":-128,\"big\":18446744073709551615,\"signed\":-9223372036854775808,\"ratio\":1.5e3,\"single\":3.25,\"level\":\"high\",\"name\":\"caf\xc3\xa9 \xf0\x9f\x98\x80\",\"ids\":[1,2],\"roles\":[\"buyer\",\"\x5cu00e9\"],\"note\":null,\"order\":{\"id\":7,\"lines\":[{\"sku\":\"a\"},{\"sku\":\"b\",\"qty\":2}]},\"http://example.com/is_root\":true}",
    "{\"count\":1.0,\"small\":128,\"big\":-1,\"ratio\":1e400,\"single\":1e39,\"level\":\"urgent\",\"ids\":[1,\"a\"],\"order\":{\"lines\":[{\"qty\":\"two\"}]}}",
    "{\"count\":1,\"count\":2}",
    "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1700000000,\"exp\":1760000900}",
    "{\"iss\":5,\"sub\":5,\"aud\":[],\"exp\":\"1700000000\",\"nbf\":-1,\"iat\":253402300800,\"jti\":[]}",
    "{\"aud\":[\"orders\",5],\"exp\":1760000060E0,\"nbf\":1.76e9}",
    "{\"iss\":\"or\xc3ders\"}",
    "{\"x\":\"\xff\"}",
    "{}",
    "[]",
    "null",
    "{\"count\":1}{\"count\":1}",
    "{\"count\":1,}",
};

/// A corpus entry: `Smith.slice` reads a little-endian u32 length first,
/// then the target byte and the bytes.
fn sample(arena: std.mem.Allocator, target: Target, alg: ?Algorithm, bytes: []const u8) ![]const u8 {
    const pick: u8 = @backingInt(target) + target_count * @as(u8, if (alg) |a| @intCast(std.mem.findScalar(Algorithm, &asymmetric, a).?) else 0);
    const entry = try arena.alloc(u8, 4 + 1 + bytes.len);
    std.mem.writeInt(u32, entry[0..4], @intCast(1 + bytes.len), .little);
    entry[4] = pick;
    @memcpy(entry[5..], bytes);
    return entry;
}

/// The corpus: tokens of the RFCs and tokens sealed with the test's key,
/// headers, payloads, and every key file with the algorithm of its key.
fn corpus(arena: std.mem.Allocator, signing: *const SigningKey) ![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{
        rfc7515.a1_token,   rfc7515.a2_token,   rfc7515.a3_token,  rfc7515.a4_token,
        rfc7515.a5_token,   rfc7515.e_token,    rfc7515.a6_json,   rfc7515.a7_json,
        rfc7519.s3_1_token, rfc7519.s6_1_token, rfc7520.token_4_1, rfc7520.token_4_2,
        rfc7520.token_4_3,  rfc7520.token_4_4,  rfc7520.token_4_5, rfc8037.token,
    }) |token| try entries.append(arena, try sample(arena, .token, null, token));
    for (payloads) |payload| {
        try entries.append(arena, try sample(arena, .token, null, try jws.seal(arena, testing.io, signing, hs256_header, payload)));
        try entries.append(arena, try sample(arena, .payload, null, payload));
    }
    for (headers) |head| {
        try entries.append(arena, try sample(arena, .token, null, try jws.seal(arena, testing.io, signing, head, accepted_payloads[0])));
        try entries.append(arena, try sample(arena, .header, null, head));
    }
    for (keys.all) |file| {
        try entries.append(arena, try sample(arena, if (file.isPem()) .pem else .der, file.algorithm, file.bytes));
    }
    return entries.items;
}

test "fuzz the parsers of tokens, headers, payloads and keys" {
    var signing: SigningKey = try .hmac(.HS256, secret, .{});
    defer signing.deinit();
    var own = [_]Key{signing.verificationKey()};
    defer own[0].deinit();
    const verifier: Verifier = try .init(.{ .keys = &own, .issuer = "orders", .audiences = &.{"orders"} });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const entries = try corpus(arena_state.allocator(), &signing);

    // The corpus reaches every target, and the accepted tokens verify.
    var memory: std.heap.FixedBufferAllocator = .init(&call_memory);
    for (accepted_payloads) |payload| {
        memory.reset();
        const token = try jws.seal(memory.allocator(), testing.io, &signing, hs256_header, payload);
        _ = try verifier.verify(void, testing.io, memory.allocator(), token, .{});
    }

    try testing.fuzz(Context{ .verifier = &verifier }, fuzzOne, .{ .corpus = entries });
}
