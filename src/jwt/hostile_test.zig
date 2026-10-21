//! `verify` against hostile payloads, damaged tokens and forged
//! signatures, and the key loaders against hostile key files (design 7.3):
//! each case is its own error of 5.11, never a panic and never a pass.
//! The tokens are sealed around the payload as written, so its JSON
//! reaches the parts that run after the signature.

const std = @import("std");
const v = @import("validator");
const root = @import("root.zig");
const jws = @import("jws.zig");
const algorithm = @import("algorithm.zig");
const base64url = @import("base64url.zig");
const crypto = @import("crypto.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const Signer = @import("Signer.zig");
const Verifier = @import("Verifier.zig");
const keys = @import("testdata/keys.zig");

const testing = std.testing;
const FixedClock = root.testing.FixedClock;
const Details = root.Details;
const VerifyError = root.VerifyError;
const KeyError = root.KeyError;
const Algorithm = root.Algorithm;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const Ed25519 = std.crypto.sign.Ed25519;
const tlv = keys.tlv;
const hex = keys.hex;

const t0 = 1_760_000_000;
const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

/// One HS256 key without an id, its verifier, and the clock at `t0`.
const Bench = struct {
    signing: SigningKey,
    keys: [1]Key,
    verifier: Verifier,
    clock: FixedClock,

    fn init(b: *Bench) !void {
        b.signing = try .hmac(.HS256, "0123456789abcdef0123456789abcdef", .{});
        b.keys = .{b.signing.verificationKey()};
        b.verifier = try .init(.{ .keys = &b.keys, .issuer = "orders", .audiences = &.{"orders"} });
        b.clock = try .init(testing.io, t0);
    }

    fn deinit(b: *Bench) void {
        b.clock.deinit();
        b.keys[0].deinit();
        b.signing.deinit();
    }

    fn seal(b: *const Bench, payload: []const u8) ![]u8 {
        return jws.seal(testing.allocator, testing.io, &b.signing, header_json, payload);
    }

    /// Verifies a token around `payload` and expects `expected`, with
    /// `claim` in `Details`.
    fn expectRefused(b: *const Bench, comptime Claims: type, payload: []const u8, expected: VerifyError, claim: ?[]const u8) !void {
        const token = try b.seal(payload);
        defer testing.allocator.free(token);
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        var details: Details = .{};
        if (b.verifier.verify(Claims, b.clock.io(), arena_state.allocator(), token, .{ .details = &details })) |_| {
            std.debug.print("verified: {s}\n", .{payload});
            return error.TestUnexpectedResult;
        } else |err| {
            testing.expectEqual(expected, err) catch |e| {
                std.debug.print("{s}\n", .{payload});
                return e;
            };
        }
        if (claim) |name| {
            try testing.expectEqualStrings(name, details.claim orelse "(none)");
        } else {
            try testing.expectEqual(null, details.claim);
        }
    }
};

const Count = struct { count: u32 = 0 };

test "a payload that is not an object is Malformed" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    for ([_][]const u8{ "[]", "\"x\"", "5", "null", "true", "[{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900}]" }) |payload| {
        // The checks of exp and iss must not be skipped without a word.
        try bench.expectRefused(void, payload, error.Malformed, null);
        try bench.expectRefused(Count, payload, error.Malformed, null);
    }
}

test "a registered claim twice is Malformed" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    try bench.expectRefused(void, "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1700000000,\"exp\":1760000900}", error.Malformed, null);
    try bench.expectRefused(void, "{\"iss\":\"orders\",\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900}", error.Malformed, null);
    try bench.expectRefused(Count, "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,\"count\":1,\"count\":2}", error.Malformed, null);
}

test "exp of the wrong kind" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    for ([_][]const u8{ "\"1700000000\"", "1e400", "-1", "null", "[1760000900]" }) |exp| {
        var buf: [128]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "{{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":{s}}}", .{exp});
        try bench.expectRefused(void, payload, error.InvalidClaims, "exp");
    }
    try bench.expectRefused(void, "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1.5}", error.Expired, "exp");
}

test "aud of the wrong kind" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    try bench.expectRefused(void, "{\"iss\":\"orders\",\"aud\":5,\"exp\":1760000900}", error.InvalidClaims, "aud");
    try bench.expectRefused(void, "{\"iss\":\"orders\",\"aud\":[],\"exp\":1760000900}", error.InvalidClaims, "aud");

    // 2000 empty strings: the memory of the call stays within a few sizes
    // of the token.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, "{\"iss\":\"orders\",\"aud\":[");
    for (0..2000) |i| try payload.appendSlice(testing.allocator, if (i == 0) "\"\"" else ",\"\"");
    try payload.appendSlice(testing.allocator, "],\"exp\":1760000900}");
    const token = try bench.seal(payload.items);
    defer testing.allocator.free(token);
    const memory = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(memory);
    var bounded: std.heap.FixedBufferAllocator = .init(memory);
    var details: Details = .{};
    try testing.expectError(error.WrongAudience, bench.verifier.verify(void, bench.clock.io(), bounded.allocator(), token, .{ .details = &details }));
    try testing.expectEqualStrings("aud", details.claim.?);
}

test "text that is not one JSON object of UTF-8" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const good = "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900}";
    for ([_][]const u8{
        "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,\"x\":\"\xff\"}",
        "{\"iss\":\"or\xc3ders\",\"aud\":\"orders\",\"exp\":1760000900}",
        "\xef\xbb\xbf" ++ good,
        good ++ " x",
        good ++ good,
        "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900",
        "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,}",
        "{'iss':'orders'}",
    }) |payload| {
        try bench.expectRefused(void, payload, error.Malformed, null);
    }
}

const Line = struct { sku: []const u8, qty: u32 = 1 };
const Basket = struct {
    lines: []const Line = &.{},

    pub const field_rules = .{ .lines = v.maxItems(2) };
};

test "claims that do not fit the struct, and a broken rule" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const head = "{\"iss\":\"orders\",\"aud\":\"orders\",\"exp\":1760000900,";

    const misfit = try bench.seal(head ++ "\"lines\":[{\"sku\":\"a\"},{\"sku\":\"b\",\"qty\":\"two\"}]}");
    defer testing.allocator.free(misfit);
    var details: Details = .{};
    try testing.expectError(error.InvalidClaims, bench.verifier.verify(Basket, bench.clock.io(), arena_state.allocator(), misfit, .{ .details = &details }));
    try testing.expectEqualStrings("jwt.invalid_type", details.violation.?.code);
    try testing.expectEqualStrings("lines[1].qty", details.violation.?.field.?);
    try testing.expectEqualStrings("must be an integer", details.violation.?.message);

    const too_many = try bench.seal(head ++ "\"lines\":[{\"sku\":\"a\"},{\"sku\":\"b\"},{\"sku\":\"c\"}]}");
    defer testing.allocator.free(too_many);
    try testing.expectError(error.ClaimsRejected, bench.verifier.verify(Basket, bench.clock.io(), arena_state.allocator(), too_many, .{ .details = &details }));
    try testing.expectEqualStrings("validation.max_items", details.violation.?.code);
    try testing.expectEqualStrings("lines", details.violation.?.field.?);
}

test "no flipped bit makes a token pass" {
    var bench: Bench = undefined;
    try bench.init();
    defer bench.deinit();
    const token = try bench.seal("{\"iss\":\"orders\",\"sub\":\"user-7\",\"aud\":\"orders\",\"iat\":1760000000,\"exp\":1760000900}");
    defer testing.allocator.free(token);
    {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        _ = try bench.verifier.verify(void, bench.clock.io(), arena_state.allocator(), token, .{});
    }
    const header_end = std.mem.findScalar(u8, token, '.').?;
    const damaged = try testing.allocator.alloc(u8, token.len);
    defer testing.allocator.free(damaged);
    for (0..token.len) |i| {
        for (0..8) |bit| {
            @memcpy(damaged, token);
            damaged[i] ^= @as(u8, 1) << @intCast(bit);
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            if (bench.verifier.verify(void, bench.clock.io(), arena_state.allocator(), damaged, .{})) |_| {
                std.debug.print("bit {d} of byte {d} passes\n", .{ bit, i });
                return error.TestUnexpectedResult;
            } else |err| {
                // A damaged header may say anything; past it, the signature
                // or the base64url refuses the token.
                if (i > header_end and err != error.BadSignature and err != error.Malformed) {
                    std.debug.print("bit {d} of byte {d}: {t}\n", .{ bit, i, err });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

// Forged signatures.

const every_algorithm = [_]Algorithm{ .HS256, .HS384, .HS512, .ES256, .ES384, .EdDSA };
const asymmetric = [_]Algorithm{ .ES256, .ES384, .EdDSA };

/// A token signed by a fresh key of one algorithm, the verifier of that
/// key, and the clock at `t0`, at which the token is valid: only the
/// signature can refuse it.
const Signed = struct {
    signing: SigningKey,
    keys: [1]Key,
    verifier: Verifier,
    clock: FixedClock,
    token: []u8,

    fn init(s: *Signed, alg: Algorithm) !void {
        s.clock = try .init(testing.io, t0);
        errdefer s.clock.deinit();
        s.signing = try .generate(testing.io, alg, .{});
        errdefer s.signing.deinit();
        s.keys = .{s.signing.verificationKey()};
        errdefer s.keys[0].deinit();
        s.verifier = try .init(.{ .keys = &s.keys, .issuer = "orders", .audiences = &.{"orders"} });
        const signer: Signer = try .init(&s.signing, .{ .issuer = "orders", .audiences = &.{"orders"} });
        s.token = try signer.sign(void, s.clock.io(), testing.allocator, &{}, .{});
        errdefer testing.allocator.free(s.token);
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        _ = try s.verifier.verify(void, s.clock.io(), arena_state.allocator(), s.token, .{});
    }

    fn deinit(s: *Signed) void {
        testing.allocator.free(s.token);
        s.keys[0].deinit();
        s.signing.deinit();
        s.clock.deinit();
    }

    fn signingInput(s: *const Signed) []const u8 {
        return s.token[0..std.mem.findScalarLast(u8, s.token, '.').?];
    }

    /// The signature of the token, decoded into `out`.
    fn signature(s: *const Signed, out: *[crypto.max_signature_bytes]u8) ![]u8 {
        const text = s.token[s.signingInput().len + 1 ..];
        const len = try base64url.decodedLen(text);
        try base64url.decode(out[0..len], text);
        return out[0..len];
    }

    /// The token with the base64url `text` in place of its signature is
    /// `BadSignature`.
    fn expectRefusedText(s: *const Signed, text: []const u8) !void {
        var buf: [root.max_token_bytes]u8 = undefined;
        const token = try std.fmt.bufPrint(&buf, "{s}.{s}", .{ s.signingInput(), text });
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        try testing.expectError(error.BadSignature, s.verifier.verify(void, s.clock.io(), arena_state.allocator(), token, .{}));
    }

    /// The token with `forged` in place of its signature is `BadSignature`.
    fn expectBadSignature(s: *const Signed, forged: []const u8) !void {
        var text: [256]u8 = undefined;
        try s.expectRefusedText(base64url.encode(&text, forged));
    }
};

test "CVE-2022-21449: r = s = 0 is BadSignature" {
    const zeros: [128]u8 = @splat('A');
    for ([_]Algorithm{ .ES256, .ES384 }, [_]usize{ 86, 128 }) |alg, len| {
        var signed: Signed = undefined;
        try signed.init(alg);
        defer signed.deinit();
        // 'A' is 0 in base64url: 64 or 96 zero bytes.
        try testing.expectEqual(algorithm.signatureBytes(alg), try base64url.decodedLen(zeros[0..len]));
        try signed.expectRefusedText(zeros[0..len]);
    }
}

/// r = n, s = n and both, with n the order of the curve's group, as std has
/// it, and the other half of a valid signature.
fn expectOrderRefused(comptime Scheme: type, alg: Algorithm, n: []const u8) !void {
    const Int = @Int(.unsigned, 8 * Scheme.Curve.scalar.encoded_length);
    try testing.expectEqual(Scheme.Curve.scalar.field_order, std.mem.readInt(Int, n[0..Scheme.Curve.scalar.encoded_length], .big));
    var signed: Signed = undefined;
    try signed.init(alg);
    defer signed.deinit();
    var out: [crypto.max_signature_bytes]u8 = undefined;
    const valid = try signed.signature(&out);
    const half = valid.len / 2;
    var forged: [crypto.max_signature_bytes]u8 = undefined;
    for ([_][2]bool{ .{ true, false }, .{ false, true }, .{ true, true } }) |order_in| {
        @memcpy(forged[0..valid.len], valid);
        if (order_in[0]) @memcpy(forged[0..half], n);
        if (order_in[1]) @memcpy(forged[half..valid.len], n);
        try signed.expectBadSignature(forged[0..valid.len]);
    }
}

test "r = n and s = n are BadSignature" {
    try expectOrderRefused(EcdsaP256Sha256, .ES256, comptime hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551"));
    try expectOrderRefused(EcdsaP384Sha384, .ES384, comptime hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973"));
}

test "the high-s twin of an ECDSA signature is BadSignature" {
    // ECDSA takes (r, s) and (r, n − s) alike: anybody can turn one valid
    // token into a second string. zefir signs with the lower s only and
    // takes only that one.
    inline for (.{ .{ Algorithm.ES256, EcdsaP256Sha256 }, .{ Algorithm.ES384, EcdsaP384Sha384 } }) |pair| {
        const Scheme = pair[1];
        const half = Scheme.Curve.scalar.encoded_length;
        var signed: Signed = undefined;
        try signed.init(pair[0]);
        defer signed.deinit();
        var out: [crypto.max_signature_bytes]u8 = undefined;
        const valid = try signed.signature(&out);
        var twin: [2 * half]u8 = valid[0 .. 2 * half].*;
        twin[half..].* = try Scheme.Curve.scalar.neg(twin[half..].*, .big);
        try signed.expectBadSignature(&twin);
    }
}

test "an ECDSA signature in DER is BadSignature" {
    inline for (.{ .{ Algorithm.ES256, EcdsaP256Sha256 }, .{ Algorithm.ES384, EcdsaP384Sha384 } }) |pair| {
        const Scheme = pair[1];
        var signed: Signed = undefined;
        try signed.init(pair[0]);
        defer signed.deinit();
        var out: [crypto.max_signature_bytes]u8 = undefined;
        const valid = try signed.signature(&out);
        var der: [Scheme.Signature.der_encoded_length_max]u8 = undefined;
        try signed.expectBadSignature(Scheme.Signature.fromBytes(valid[0..Scheme.Signature.encoded_length].*).toDer(&der));
    }
}

test "an Ed25519 signature with s ≥ L is BadSignature" {
    var signed: Signed = undefined;
    try signed.init(.EdDSA);
    defer signed.deinit();
    var out: [crypto.max_signature_bytes]u8 = undefined;
    const valid = try signed.signature(&out);
    // L = 2^252 + 27742317777372353535851937790883648493, the order of the
    // group: s + L names the same scalar, but not canonically.
    const order = Ed25519.Curve.scalar.field_order;
    try testing.expectEqual((1 << 252) + 27742317777372353535851937790883648493, order);
    var forged: [64]u8 = undefined;
    @memcpy(forged[0..32], valid[0..32]);
    std.mem.writeInt(u256, forged[32..64], std.mem.readInt(u256, valid[32..64], .little) + order, .little);
    try signed.expectBadSignature(&forged);
}

test "an Ed25519 signature that only a cofactored check takes is BadSignature" {
    var signed: Signed = undefined;
    try signed.init(.EdDSA);
    defer signed.deinit();
    const pair = &signed.signing.material.ed25519;
    const message = signed.signingInput();
    const Sha512 = std.crypto.hash.sha2.Sha512;
    const scalar = Ed25519.Curve.scalar;

    // The secret scalar a of the key, from its seed (RFC 8032 §5.1.5).
    const seed = pair.secret_key.seed();
    var digest: [64]u8 = undefined;
    Sha512.hash(&seed, &digest, .{});
    var a: [32]u8 = digest[0..32].*;
    scalar.clamp(&a);
    // R = rB + T with T of order 8, and s = r + k·a with k = H(R‖A‖m):
    // then [s]B − [k]A − R = −T, which [8] takes to the identity.
    const r = scalar.reduce(@splat(0x2a));
    const order_8 = try Ed25519.Curve.fromBytes(comptime hex("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a")[0..32].*);
    const big_r = (try Ed25519.Curve.basePoint.mul(r)).add(order_8).toBytes();
    var h: Sha512 = .init(.{});
    h.update(&big_r);
    h.update(&pair.public_key.toBytes());
    h.update(message);
    var k: [64]u8 = undefined;
    h.final(&k);
    const forged = big_r ++ scalar.mulAdd(scalar.reduce64(k), a, r);

    // The cofactored check of std takes the signature; zefir checks
    // without the cofactor, and does not (design Р33).
    try Ed25519.Signature.fromBytes(forged).verify(message, pair.public_key);
    try signed.expectBadSignature(&forged);
}

test "a signature one byte short or long is BadSignature, for every algorithm" {
    for (every_algorithm) |alg| {
        var signed: Signed = undefined;
        try signed.init(alg);
        defer signed.deinit();
        var out: [crypto.max_signature_bytes + 1]u8 = undefined;
        const valid = try signed.signature(out[0..crypto.max_signature_bytes]);
        try signed.expectBadSignature(valid[0 .. valid.len - 1]);
        out[valid.len] = 0;
        try signed.expectBadSignature(out[0 .. valid.len + 1]);
    }
}

// Hostile key files.

/// `bytes` through the loader of `part` and `pem` with `alg`; a key that
/// loads is wiped.
fn load(part: keys.Part, pem: bool, alg: Algorithm, bytes: []const u8) KeyError!void {
    switch (part) {
        .public => {
            var key = try if (pem) Key.fromPem(alg, bytes, .{}) else Key.fromDer(alg, bytes, .{});
            key.deinit();
        },
        .private => {
            var key = try if (pem) SigningKey.fromPem(alg, bytes, .{}) else SigningKey.fromDer(alg, bytes, .{});
            key.deinit();
        },
    }
}

fn expectLoadError(part: keys.Part, alg: Algorithm, der: []const u8, expected: KeyError) !void {
    errdefer std.debug.print("{t} key of {t}: {x}\n", .{ part, alg, der });
    try testing.expectError(expected, load(part, false, alg, der));
}

/// Where the last END marker of a PEM ends: a prefix up to there holds the
/// whole key.
fn pemEnd(text: []const u8) usize {
    const end = std.mem.findLast(u8, text, "-----END ").?;
    return std.mem.findPos(u8, text, end + "-----END ".len, "-----").? + "-----".len;
}

test "every prefix of a key file is an error, never a key" {
    for (keys.all) |file| {
        const whole = if (file.isPem()) pemEnd(file.bytes) else file.bytes.len;
        for (0..whole) |len| {
            for (asymmetric) |alg| {
                if (load(file.part, file.isPem(), alg, file.bytes[0..len])) {
                    std.debug.print("{s}: the first {d} bytes load as a key of {t}\n", .{ file.name, len, alg });
                    return error.TestUnexpectedResult;
                } else |err| switch (err) {
                    error.InvalidKey, error.UnsupportedKey => {},
                    else => {
                        std.debug.print("{s}: the first {d} bytes as a key of {t}: {t}\n", .{ file.name, len, alg, err });
                        return error.TestUnexpectedResult;
                    },
                }
            }
        }
    }
}

/// Bytes the corruptions put in: those of PEM and of DER.
const interesting = "-\n\r \t=:+/AM0\x00\x01\x02\x03\x04\x06\x30\x7f\x80\x81\x82\x84\xa0\xa1\xff";

/// One corruption of `buffer[0..len]` in place, as `mutate` of the fuzz
/// test of http does: a bit flipped, a byte replaced, inserted or deleted.
/// The new length.
fn corrupt(random: std.Random, buffer: []u8, len: usize) usize {
    if (len == 0) {
        buffer[0] = interesting[random.uintLessThan(usize, interesting.len)];
        return 1;
    }
    const at = random.uintLessThan(usize, len);
    switch (random.uintLessThan(u8, 4)) {
        0 => buffer[at] ^= @as(u8, 1) << random.int(u3),
        1 => buffer[at] = interesting[random.uintLessThan(usize, interesting.len)],
        2 => if (len < buffer.len) {
            std.mem.copyBackwards(u8, buffer[at + 1 .. len + 1], buffer[at..len]);
            buffer[at] = interesting[random.uintLessThan(usize, interesting.len)];
            return len + 1;
        },
        else => {
            std.mem.copyForwards(u8, buffer[at .. len - 1], buffer[at + 1 .. len]);
            return len - 1;
        },
    }
    return len;
}

test "1000 corruptions with a fixed seed give a key or an error, never a panic" {
    var prng: std.Random.DefaultPrng = .init(0x6a77_7400);
    const random = prng.random();
    var buffer: [4096]u8 = undefined;
    for (0..1000) |_| {
        const file = keys.all[random.uintLessThan(usize, keys.all.len)];
        var len = file.bytes.len;
        @memcpy(buffer[0..len], file.bytes);
        for (0..random.intRangeAtMost(u8, 1, 4)) |_| len = corrupt(random, &buffer, len);
        for ([_]keys.Part{ .public, .private }) |part| {
            for ([_]bool{ true, false }) |pem| {
                for (asymmetric) |alg| load(part, pem, alg, buffer[0..len]) catch {};
            }
        }
    }
}

test "DER lengths that lie are InvalidKey" {
    const spki = comptime keys.get("p256.pub.der").bytes;
    const pkcs8 = comptime keys.get("p256.pk8.der").bytes;
    try testing.expectEqualSlices(u8, comptime hex("3059"), spki[0..2]);
    try testing.expectEqualSlices(u8, comptime hex("308187"), pkcs8[0..3]);
    const public = comptime [_][]const u8{
        // The outer length reaches past the end, or stops a byte short of
        // it.
        hex("305a") ++ spki[2..],
        hex("3058") ++ spki[2..],
        // A length of five bytes, and BER's indefinite length.
        hex("30850000000059") ++ spki[2..],
        hex("3080") ++ spki[2..] ++ hex("0000"),
        // The AlgorithmIdentifier reaches into the key, or ends in its
        // curve.
        spki[0..2] ++ hex("3014") ++ spki[4..],
        spki[0..2] ++ hex("3012") ++ spki[4..],
    };
    for (public) |der| try expectLoadError(.public, .ES256, der, error.InvalidKey);
    const private = comptime [_][]const u8{
        hex("308188") ++ pkcs8[3..],
        hex("308186") ++ pkcs8[3..],
        hex("30820087") ++ pkcs8[3..],
    };
    for (private) |der| try expectLoadError(.private, .ES256, der, error.InvalidKey);
}

test "EC points and scalars that are no keys" {
    const spki = comptime keys.get("p256.pub.der").bytes;
    // The AlgorithmIdentifier of P-256.
    const p256_id = spki[2..23];
    var off_curve = spki[0..91].*;
    // y + 1, big-endian.
    var i: usize = off_curve.len;
    while (i > 59) {
        i -= 1;
        off_curve[i] +%= 1;
        if (off_curve[i] != 0) break;
    }
    try expectLoadError(.public, .ES256, &off_curve, error.InvalidKey);

    const points = comptime [_][]const u8{
        // The identity.
        tlv(0x30, p256_id ++ tlv(0x03, hex("0000"))),
        // x = 1, for which x³ − 3x + b is no square mod p: no point.
        tlv(0x30, p256_id ++ tlv(0x03, hex("0002") ++ hex("0000000000000000000000000000000000000000000000000000000000000001"))),
        // x = p: no field element.
        tlv(0x30, p256_id ++ tlv(0x03, hex("0002") ++ hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"))),
        // A point a byte short.
        tlv(0x30, p256_id ++ tlv(0x03, hex("00") ++ spki[26..90])),
    };
    for (points) |der| try expectLoadError(.public, .ES256, der, error.InvalidKey);

    const p256_oid = comptime tlv(0xa0, tlv(0x06, hex("2a8648ce3d030107")));
    const p384_oid = comptime tlv(0xa0, tlv(0x06, hex("2b81040022")));
    const scalars = comptime [_]struct { Algorithm, []const u8 }{
        // 0, n, and the largest number of the curve's size.
        .{ .ES256, tlv(0x30, hex("020101") ++ tlv(0x04, &@as([32]u8, @splat(0))) ++ p256_oid) },
        .{ .ES256, tlv(0x30, hex("020101") ++ tlv(0x04, hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")) ++ p256_oid) },
        .{ .ES256, tlv(0x30, hex("020101") ++ tlv(0x04, &@as([32]u8, @splat(0xff))) ++ p256_oid) },
        .{ .ES384, tlv(0x30, hex("020101") ++ tlv(0x04, &@as([48]u8, @splat(0))) ++ p384_oid) },
        .{ .ES384, tlv(0x30, hex("020101") ++ tlv(0x04, hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973")) ++ p384_oid) },
    };
    for (scalars) |case| try expectLoadError(.private, case[0], case[1], error.InvalidKey);
}

test "an Ed25519 public key of small order or non-canonical is InvalidKey" {
    const ed25519_id = comptime tlv(0x30, tlv(0x06, hex("2b6570")));
    const encodings = comptime [_][]const u8{
        // The identity, of order 1.
        hex("01") ++ &@as([31]u8, @splat(0)),
        // (0, −1), of order 2.
        hex("ec") ++ &@as([30]u8, @splat(0xff)) ++ hex("7f"),
        // y = 0, of order 4.
        &@as([32]u8, @splat(0)),
        // Points of order 8.
        hex("c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a"),
        hex("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05"),
        // y = p: not canonical.
        hex("ed") ++ &@as([30]u8, @splat(0xff)) ++ hex("7f"),
        // y = 2: no point on the curve.
        hex("02") ++ &@as([31]u8, @splat(0)),
    };
    inline for (encodings) |encoding| {
        try expectLoadError(.public, .EdDSA, comptime tlv(0x30, ed25519_id ++ tlv(0x03, hex("00") ++ encoding)), error.InvalidKey);
    }
}
