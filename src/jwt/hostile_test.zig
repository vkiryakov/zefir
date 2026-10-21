//! `verify` against hostile payloads and damaged tokens (design 7.3):
//! each case is its own error of 5.11, never a panic and never a pass.
//! The tokens are sealed around the payload as written, so its JSON
//! reaches the parts that run after the signature.

const std = @import("std");
const v = @import("validator");
const root = @import("root.zig");
const jws = @import("jws.zig");
const Key = @import("Key.zig");
const SigningKey = @import("SigningKey.zig");
const Verifier = @import("Verifier.zig");

const testing = std.testing;
const FixedClock = root.testing.FixedClock;
const Details = root.Details;
const VerifyError = root.VerifyError;

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
