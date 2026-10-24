//! Signs the tokens of a service with one key: the registered claims that
//! `jwt.Verifier` checks ("iss", "aud", "iat", "exp", and "sub", "nbf" and
//! "jti" when given), then the application's claims. A signer is
//! immutable and owns nothing: one of them serves every task of a service
//! at once.
//!
//! ```zig
//! const signer: jwt.Signer = try .init(&signing_key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
//! const token = try signer.sign(Claims, ctx.io(), ctx.allocator(), &.{ .roles = &.{"buyer"} }, .{ .subject = "user-7" });
//! ```

const Signer = @This();

const std = @import("std");
const root = @import("root.zig");
const claims = @import("claims.zig");
const header = @import("header.zig");
const jws = @import("jws.zig");
const base64url = @import("base64url.zig");
const compact = @import("compact.zig");
const crypto = @import("crypto.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const Verifier = @import("Verifier.zig");

const SignError = root.SignError;

key: *const SigningKey,
options: Options,

pub const Options = struct {
    /// "iss" of every token: the name of this service.
    issuer: []const u8,
    /// "aud" of every token, the services it is meant for: one is written
    /// as "aud":"x", several as an array.
    audiences: []const []const u8,
    /// How long a token lives: "exp" is "iat" + lifetime, at least one
    /// second.
    lifetime: std.Io.Duration = .fromSeconds(15 * 60),
    /// "typ" of every token, which verifiers check: one signer per kind of
    /// token, such as "at+jwt" for access tokens.
    token_type: []const u8 = "JWT",
};

/// A signer with `key` and `options`, which it borrows: they live as long
/// as the signer and do not change. `InvalidOptions`: a key that `deinit`
/// wiped, an empty issuer or token type ("application/" alone too, which no
/// verifier takes), no audiences or an empty one among them, or a lifetime
/// under one second.
pub fn init(key: *const SigningKey, options: Options) error{InvalidOptions}!Signer {
    if (!crypto.holdsKey(key)) return error.InvalidOptions;
    if (options.issuer.len == 0 or header.sameType(options.token_type, "")) return error.InvalidOptions;
    if (options.audiences.len == 0) return error.InvalidOptions;
    for (options.audiences) |audience| {
        if (audience.len == 0) return error.InvalidOptions;
    }
    if (wholeSeconds(options.lifetime) < 1) return error.InvalidOptions;
    return .{ .key = key, .options = options };
}

/// Signs a token with the registered claims and `value`, which
/// `jwt.assertClaims` describes; `void` signs the registered claims alone.
/// "iat" is now, by the clock of `io`; `io` also gives the noise of ECDSA.
/// The token comes from `allocator`, and the caller frees it; the memory
/// of the work is freed before return. `InvalidClaims`: a string that is
/// not UTF-8, a float that is not finite, a lifetime under one second, or
/// a time that a NumericDate cannot hold (before 1970 or after 9999).
/// `TokenTooLarge`: the token would be longer than `max_token_bytes`,
/// which no verifier takes. `BadSignature`: the key can make no signature
/// that verifies, since `deinit` wiped it while the signer still used it.
pub fn sign(
    signer: *const Signer,
    comptime Claims: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    value: *const Claims,
    options: root.SignOptions,
) SignError![]u8 {
    comptime claims.check(Claims);
    const now = std.Io.Clock.real.now(io).toSeconds();
    const lifetime = wholeSeconds(options.lifetime orelse signer.options.lifetime);
    if (lifetime < 1) return error.InvalidClaims;
    const issued_at = try numericDate(now);
    const expires_at = try numericDate(@as(i96, now) + lifetime);
    const not_before = if (options.not_before) |nbf| try numericDate(nbf) else null;

    // A header or a payload that fills its half could not fit a token.
    const buffer = try allocator.alloc(u8, 2 * root.max_token_bytes);
    defer allocator.free(buffer);
    var head: std.Io.Writer = .fixed(buffer[0..root.max_token_bytes]);
    var body: std.Io.Writer = .fixed(buffer[root.max_token_bytes..]);
    signer.writeHeader(&head) catch |err| return tooLarge(err);
    signer.writePayload(Claims, &body, value, options, issued_at, not_before, expires_at) catch |err| return tooLarge(err);
    return jws.seal(allocator, io, signer.key, head.buffered(), body.buffered());
}

/// A full buffer means a token over `max_token_bytes`.
fn tooLarge(err: claims.EncodeError) SignError {
    return switch (err) {
        error.WriteFailed => error.TokenTooLarge,
        error.InvalidClaims => error.InvalidClaims,
    };
}

/// `{"alg":…,"typ":…,"kid":…}`, with "kid" when the key has an id.
fn writeHeader(signer: *const Signer, w: *std.Io.Writer) claims.EncodeError!void {
    try w.print("{{\"alg\":\"{s}\",\"typ\":", .{signer.key.algorithm.name()});
    try claims.writeString(w, signer.options.token_type);
    if (signer.key.id()) |kid| {
        try w.writeAll(",\"kid\":");
        try claims.writeString(w, kid);
    }
    try w.writeByte('}');
}

/// The registered claims in a fixed order, then the application's.
fn writePayload(
    signer: *const Signer,
    comptime Claims: type,
    w: *std.Io.Writer,
    value: *const Claims,
    options: root.SignOptions,
    issued_at: i64,
    not_before: ?i64,
    expires_at: i64,
) claims.EncodeError!void {
    try w.writeAll("{\"iss\":");
    try claims.writeString(w, signer.options.issuer);
    if (options.subject) |subject| {
        try w.writeAll(",\"sub\":");
        try claims.writeString(w, subject);
    }
    try w.writeAll(",\"aud\":");
    const audiences = signer.options.audiences;
    if (audiences.len == 1) {
        try claims.writeString(w, audiences[0]);
    } else {
        try w.writeByte('[');
        for (audiences, 0..) |audience, i| {
            if (i > 0) try w.writeByte(',');
            try claims.writeString(w, audience);
        }
        try w.writeByte(']');
    }
    try w.print(",\"iat\":{d}", .{issued_at});
    if (not_before) |nbf| try w.print(",\"nbf\":{d}", .{nbf});
    try w.print(",\"exp\":{d}", .{expires_at});
    if (options.id) |id| {
        try w.writeAll(",\"jti\":");
        try claims.writeString(w, id);
    }
    try claims.encode(Claims, w, value);
    try w.writeByte('}');
}

/// The whole seconds of `duration`, rounded toward zero.
fn wholeSeconds(duration: std.Io.Duration) i96 {
    return @divTrunc(duration.toNanoseconds(), std.time.ns_per_s);
}

/// `seconds` as a NumericDate. `InvalidClaims`: before 1970 or after the
/// end of 9999, which `verify` would refuse.
fn numericDate(seconds: i96) SignError!i64 {
    if (seconds < 0 or seconds > claims.max_numeric_date) return error.InvalidClaims;
    return @intCast(seconds);
}

const testing = std.testing;
const FixedClock = root.testing.FixedClock;

const t0 = 1_760_000_000;
const secret = "0123456789abcdef0123456789abcdef";
const nothing: void = {};

/// The header and the payload of `token`, decoded into `arena`.
fn decodedParts(arena: std.mem.Allocator, token: []const u8) !struct { []const u8, []const u8 } {
    const parts = try compact.split(token);
    return .{ try base64url.decodeAlloc(arena, parts.header), try base64url.decodeAlloc(arena, parts.payload) };
}

/// The payload of what `signer` signs for `value` with `options`.
fn signedPayload(arena: std.mem.Allocator, signer: *const Signer, comptime Claims: type, io: std.Io, value: *const Claims, options: root.SignOptions) ![]const u8 {
    const token = try signer.sign(Claims, io, testing.allocator, value, options);
    defer testing.allocator.free(token);
    _, const payload = try decodedParts(arena, token);
    return payload;
}

test "sign writes the header and the registered claims in a fixed order" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var key: SigningKey = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer key.deinit();

    const signer: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const token = try signer.sign(void, clock.io(), testing.allocator, &nothing, .{ .subject = "user-7" });
    defer testing.allocator.free(token);
    const header_json, const payload_json = try decodedParts(arena, token);
    try testing.expectEqualStrings("{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"k1\"}", header_json);
    try testing.expectEqualStrings("{\"iss\":\"orders\",\"sub\":\"user-7\",\"aud\":\"orders\",\"iat\":1760000000,\"exp\":1760000900}", payload_json);

    const two: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
    try testing.expectEqualStrings(
        "{\"iss\":\"orders\",\"aud\":[\"orders\",\"billing\"],\"iat\":1760000000,\"nbf\":1760000100,\"exp\":1760000900,\"jti\":\"t-1\"}",
        try signedPayload(arena, &two, void, clock.io(), &nothing, .{ .not_before = 1760000100, .id = "t-1" }),
    );
    try testing.expectEqualStrings(
        "{\"iss\":\"orders\",\"aud\":\"orders\",\"iat\":1760000000,\"exp\":1760000060}",
        try signedPayload(arena, &signer, void, clock.io(), &nothing, .{ .lifetime = .fromSeconds(60) }),
    );

    var anonymous: SigningKey = try .hmac(.HS256, secret, .{});
    defer anonymous.deinit();
    const plain: Signer = try .init(&anonymous, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const plain_token = try plain.sign(void, clock.io(), testing.allocator, &nothing, .{});
    defer testing.allocator.free(plain_token);
    const plain_header, _ = try decodedParts(arena, plain_token);
    try testing.expectEqualStrings("{\"alg\":\"HS256\",\"typ\":\"JWT\"}", plain_header);
}

const Grant = struct {
    roles: []const []const u8,
    level: ?u8 = null,
    is_root: bool,

    pub const claim_names = .{ .is_root = "http://example.com/is_root" };
};

test "the application's claims follow, by their claim names" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var key: SigningKey = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer key.deinit();
    const signer: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const payload = try signedPayload(arena_state.allocator(), &signer, Grant, clock.io(), &.{ .roles = &.{"buyer"}, .is_root = true }, .{});
    try testing.expectStringEndsWith(payload, ",\"exp\":1760000900,\"roles\":[\"buyer\"],\"http://example.com/is_root\":true}");
}

const Kind = enum { buyer, seller, @"two words" };
const Address = struct { city: []const u8, zip: ?u32 = null };
const Everything = struct {
    ratio: f64,
    single: f32,
    smallest: i64,
    largest: u64,
    tiny: i8,
    flag: bool,
    kind: Kind,
    kinds: []const Kind,
    address: Address,
    addresses: []const Address,
    tags: []const []const u8,
    matrix: []const []const i32,
    maybe: []const ?u16,
    note: ?[]const u8 = null,
    level: ?u8 = 7,
    text: []const u8,
    is_root: bool = false,

    pub const claim_names = .{ .is_root = "http://example.com/is_root" };
};

test "what sign issues, verify accepts" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var key: SigningKey = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer key.deinit();
    const keys = [_]Key{key.verificationKey()};
    const signer: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" } });
    const verifier: Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"billing"} });

    const plain = try signer.sign(void, clock.io(), testing.allocator, &nothing, .{ .subject = "user-7", .id = "t-1", .not_before = t0 - 5 });
    defer testing.allocator.free(plain);
    const registered = (try verifier.verify(void, clock.io(), arena, plain, .{})).registered;
    try testing.expectEqualDeep(root.Registered{
        .issuer = "orders",
        .subject = "user-7",
        .audience = &.{ "orders", "billing" },
        .expires_at = t0 + 900,
        .not_before = t0 - 5,
        .issued_at = t0,
        .id = "t-1",
    }, registered);

    const value: Everything = .{
        .ratio = 3.25,
        .single = 0.1,
        .smallest = std.math.minInt(i64),
        .largest = std.math.maxInt(u64),
        .tiny = -128,
        .flag = true,
        .kind = .@"two words",
        .kinds = &.{ .buyer, .seller },
        .address = .{ .city = "Kyiv", .zip = 1001 },
        .addresses = &.{ .{ .city = "Lviv" }, .{ .city = "Odesa", .zip = 65000 } },
        .tags = &.{ "a", "", "line\nbreak \"quoted\" \\ ünïcode 😀" },
        .matrix = &.{ &.{ 1, -2 }, &.{}, &.{3} },
        .maybe = &.{ 1, null, 3 },
        .level = null,
        .text = "\x00\x1f\x7f",
        .is_root = true,
    };
    const token = try signer.sign(Everything, clock.io(), testing.allocator, &value, .{});
    defer testing.allocator.free(token);
    try testing.expectEqualDeep(value, (try verifier.verify(Everything, clock.io(), arena, token, .{})).claims);
}

test "typ tells kinds of tokens apart" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var key: SigningKey = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer key.deinit();
    const keys = [_]Key{key.verificationKey()};
    const signer: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"}, .token_type = "at+jwt" });
    const token = try signer.sign(void, clock.io(), testing.allocator, &nothing, .{});
    defer testing.allocator.free(token);

    const access: Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"}, .token_types = &.{"at+jwt"} });
    try testing.expectEqualStrings("at+jwt", (try access.verify(void, clock.io(), arena_state.allocator(), token, .{})).header.token_type);
    const plain: Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"} });
    try testing.expectError(error.WrongType, plain.verify(void, clock.io(), arena_state.allocator(), token, .{}));
}

const Text = struct { text: []const u8 };
const Ratio = struct { ratio: f64 };

test "sign refuses what it cannot write as a token verify accepts" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var key: SigningKey = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer key.deinit();
    const signer: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const io = clock.io();
    const gpa = testing.allocator;

    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{ .subject = "\xff" }));
    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{ .id = "t-\xc3" }));
    try testing.expectError(error.InvalidClaims, signer.sign(Text, io, gpa, &.{ .text = "\xc3" }, .{}));
    const bad_issuer: Signer = try .init(&key, .{ .issuer = "or\xffders", .audiences = &.{"orders"} });
    try testing.expectError(error.InvalidClaims, bad_issuer.sign(void, io, gpa, &nothing, .{}));
    const bad_audience: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{ "orders", "\xff" } });
    try testing.expectError(error.InvalidClaims, bad_audience.sign(void, io, gpa, &nothing, .{}));
    const bad_type: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"}, .token_type = "\xff" });
    try testing.expectError(error.InvalidClaims, bad_type.sign(void, io, gpa, &nothing, .{}));

    try testing.expectError(error.InvalidClaims, signer.sign(Ratio, io, gpa, &.{ .ratio = std.math.nan(f64) }, .{}));
    try testing.expectError(error.InvalidClaims, signer.sign(Ratio, io, gpa, &.{ .ratio = std.math.inf(f64) }, .{}));
    try testing.expectError(error.InvalidClaims, signer.sign(Ratio, io, gpa, &.{ .ratio = -std.math.inf(f64) }, .{}));

    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{ .lifetime = .fromSeconds(0) }));
    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{ .lifetime = .fromSeconds(-1) }));
    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{ .lifetime = .fromMilliseconds(999) }));
    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{ .lifetime = .max }));
    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{ .not_before = 253402300800 }));
    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{ .not_before = -1 }));

    // exp would be 253402300900, after the end of 9999.
    clock.set(253402300000);
    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{}));
    const last = try signer.sign(void, io, gpa, &nothing, .{ .lifetime = .fromSeconds(799) });
    gpa.free(last);
    // And before 1970 nothing is a NumericDate.
    clock.set(-1);
    try testing.expectError(error.InvalidClaims, signer.sign(void, io, gpa, &nothing, .{}));
}

const Filler = struct { s: []const u8 };

test "the longest token sign issues is 8192 bytes, and verify accepts it" {
    var clock: FixedClock = try .init(testing.io, t0);
    defer clock.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // Without an id the header is {"alg":"HS256","typ":"JWT"}: 36
    // characters of base64url.
    var key: SigningKey = try .hmac(.HS256, secret, .{});
    defer key.deinit();
    const keys = [_]Key{key.verificationKey()};
    const signer: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    const verifier: Verifier = try .init(.{ .keys = &keys, .issuer = "orders", .audiences = &.{"orders"} });

    const text: [root.max_token_bytes]u8 = @splat('x');
    var longest: ?[]u8 = null;
    defer if (longest) |token| testing.allocator.free(token);
    var len: usize = 6000;
    while (len < text.len) : (len += 1) {
        const token = signer.sign(Filler, clock.io(), testing.allocator, &.{ .s = text[0..len] }, .{}) catch |err| {
            try testing.expectEqual(error.TokenTooLarge, err);
            break;
        };
        if (longest) |previous| testing.allocator.free(previous);
        longest = token;
    }
    // 36 + 1 + 8111 + 1 + 43: a payload of 6083 bytes.
    try testing.expectEqual(root.max_token_bytes, longest.?.len);
    const verified = try verifier.verify(Filler, clock.io(), arena_state.allocator(), longest.?, .{});
    try testing.expectEqual(len - 1, verified.claims.s.len);
    // Far too much: the payload alone is over max_token_bytes.
    const huge: [3 * root.max_token_bytes]u8 = @splat('y');
    try testing.expectError(error.TokenTooLarge, signer.sign(Filler, clock.io(), testing.allocator, &.{ .s = &huge }, .{}));
}

test "a wiped signing key signs nothing" {
    var key: SigningKey = try .generate(testing.io, .ES256, .{ .id = "k1" });
    const signer: Signer = try .init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    // Against the rule of deinit, the signer still holds the key: zeroes,
    // which read as HS256 with an empty secret.
    key.deinit();
    try testing.expectError(error.BadSignature, signer.sign(void, testing.io, testing.allocator, &nothing, .{}));
    try testing.expectError(error.InvalidOptions, Signer.init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} }));
    var zero: SigningKey = undefined;
    @memset(std.mem.asBytes(&zero), 0);
    try testing.expectError(error.InvalidOptions, Signer.init(&zero, .{ .issuer = "orders", .audiences = &.{"orders"} }));
}

test "Signer.init refuses options it could not sign with" {
    var key: SigningKey = try .hmac(.HS256, secret, .{ .id = "k1" });
    defer key.deinit();
    _ = try Signer.init(&key, .{ .issuer = "orders", .audiences = &.{"orders"} });
    _ = try Signer.init(&key, .{ .issuer = "orders", .audiences = &.{ "orders", "billing" }, .lifetime = .fromSeconds(1), .token_type = "at+jwt" });
    for ([_]Options{
        .{ .issuer = "", .audiences = &.{"orders"} },
        .{ .issuer = "orders", .audiences = &.{} },
        .{ .issuer = "orders", .audiences = &.{ "orders", "" } },
        .{ .issuer = "orders", .audiences = &.{"orders"}, .token_type = "" },
        .{ .issuer = "orders", .audiences = &.{"orders"}, .token_type = "Application/" },
        .{ .issuer = "orders", .audiences = &.{"orders"}, .lifetime = .zero },
        .{ .issuer = "orders", .audiences = &.{"orders"}, .lifetime = .fromSeconds(-60) },
        .{ .issuer = "orders", .audiences = &.{"orders"}, .lifetime = .fromMilliseconds(500) },
    }) |options| {
        try testing.expectError(error.InvalidOptions, Signer.init(&key, options));
    }
}
