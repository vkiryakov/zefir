//! The JOSE header of a token (RFC 7515 §4.1) and the rules `security.jwt`
//! holds it to. The whole object is read first: its syntax, its repeated
//! keys and the types of the members it knows ("alg", "kid", "typ", "cty",
//! "crit"); a problem there is `Malformed`. Then the rules run in this
//! order: "alg", "crit", "cty", "typ". The members that name a key ("jku",
//! "x5u", "jwk", "x5c", "x5t", "x5t#S256") are never read: the key comes
//! only from the verifier's keys (RFC 8725 §3.10).

const std = @import("std");
const Algorithm = @import("algorithm.zig").Algorithm;
const errors = @import("errors.zig");
const json = @import("json.zig");

const VerifyError = errors.VerifyError;
const Details = errors.Details;

/// The header of a token that passed its rules.
pub const Header = struct {
    algorithm: Algorithm,
    /// "kid" as the token gives it; null when it has none.
    key_id: ?[]const u8,
    /// "typ" as the token gives it; it matched one of the verifier's
    /// token types.
    token_type: []const u8,
};

/// Reads the decoded header `text` and applies its rules: "alg" names one
/// of the six algorithms, "crit" is absent, "cty" names no nested token,
/// and "typ" is one of `token_types` (compared by `sameType`). On an error
/// `details.claim` names the member it is about, if there is one. The
/// strings of the result point into `text` or into `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, token_types: []const []const u8, details: *Details) VerifyError!Header {
    var alg: ?[]const u8 = null;
    var kid: ?[]const u8 = null;
    var typ: ?[]const u8 = null;
    var cty: ?[]const u8 = null;
    var crit = false;

    var reader: json.Reader = .init(arena, text);
    try reader.beginObject();
    while (try reader.nextKey()) |key| {
        if (std.mem.eql(u8, key, "alg")) {
            alg = try member(&reader, alg, "alg", details);
        } else if (std.mem.eql(u8, key, "kid")) {
            kid = try member(&reader, kid, "kid", details);
        } else if (std.mem.eql(u8, key, "typ")) {
            typ = try member(&reader, typ, "typ", details);
        } else if (std.mem.eql(u8, key, "cty")) {
            cty = try member(&reader, cty, "cty", details);
        } else if (std.mem.eql(u8, key, "crit")) {
            // Any value: `security.jwt` understands no extension, so its mere
            // presence refuses the token.
            if (crit) return refuse(details, "crit", error.Malformed);
            crit = true;
            try reader.skip();
        } else {
            try reader.skip();
        }
    }
    try reader.finish();

    const algorithm = Algorithm.fromName(alg orelse "") orelse return refuse(details, "alg", error.UnsupportedAlgorithm);
    if (crit) return refuse(details, "crit", error.UnsupportedHeader);
    if (cty) |content_type| {
        if (sameType(content_type, "JWT")) return refuse(details, "cty", error.UnsupportedHeader);
    }
    const token_type = typ orelse return refuse(details, "typ", error.WrongType);
    for (token_types) |wanted| {
        if (sameType(token_type, wanted)) return .{ .algorithm = algorithm, .key_id = kid, .token_type = token_type };
    }
    return refuse(details, "typ", error.WrongType);
}

/// Whether two values of "typ" or "cty" name the same type, as RFC 7515
/// §4.1.9 compares media types: without the case of ASCII letters and
/// without a leading "application/".
pub fn sameType(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(withoutApplication(a), withoutApplication(b));
}

fn withoutApplication(media_type: []const u8) []const u8 {
    const prefix = "application/";
    return if (std.ascii.startsWithIgnoreCase(media_type, prefix)) media_type[prefix.len..] else media_type;
}

/// The string value of a known member; a second one or a value of another
/// type is `Malformed`.
fn member(reader: *json.Reader, seen: ?[]const u8, comptime name: []const u8, details: *Details) VerifyError![]const u8 {
    if (seen != null or try reader.peek() != .string) return refuse(details, name, error.Malformed);
    return reader.string();
}

fn refuse(details: *Details, claim: []const u8, err: VerifyError) VerifyError {
    details.claim = claim;
    return err;
}

const testing = std.testing;

const jwt_types: []const []const u8 = &.{"JWT"};

/// Parses `text` and expects `expected`, with `claim` in `Details`.
fn expectRefused(text: []const u8, token_types: []const []const u8, expected: VerifyError, claim: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var details: Details = .{};
    if (parse(arena_state.allocator(), text, token_types, &details)) |_| {
        std.debug.print("accepted: {s}\n", .{text});
        return error.TestUnexpectedResult;
    } else |err| {
        testing.expectEqual(expected, err) catch |e| {
            std.debug.print("{s}\n", .{text});
            return e;
        };
    }
    if (claim) |name| {
        try testing.expectEqualStrings(name, details.claim orelse "(none)");
    } else {
        try testing.expectEqual(null, details.claim);
    }
}

fn expectAccepted(arena: std.mem.Allocator, text: []const u8, token_types: []const []const u8) !Header {
    var details: Details = .{};
    return parse(arena, text, token_types, &details) catch |err| {
        std.debug.print("refused with {t} at {s}: {s}\n", .{ err, details.claim orelse "(none)", text });
        return err;
    };
}

test "alg is a string naming one of the six" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectRefused("{\"typ\":\"JWT\"}", jwt_types, error.UnsupportedAlgorithm, "alg");
    for ([_][]const u8{ "none", "None", "NONE", "RS256", "ES512", "Ed25519" }) |name| {
        const text = try std.fmt.allocPrint(arena, "{{\"alg\":\"{s}\",\"typ\":\"JWT\"}}", .{name});
        try expectRefused(text, jwt_types, error.UnsupportedAlgorithm, "alg");
    }
    try expectRefused("{\"alg\":5}", jwt_types, error.Malformed, "alg");
    try expectRefused("{\"alg\":\"HS256\",\"alg\":\"HS256\",\"typ\":\"JWT\"}", jwt_types, error.Malformed, "alg");

    for ([_]Algorithm{ .HS256, .HS384, .HS512, .ES256, .ES384, .EdDSA }) |alg| {
        const text = try std.fmt.allocPrint(arena, "{{\"alg\":\"{s}\",\"typ\":\"JWT\"}}", .{alg.name()});
        try testing.expectEqual(alg, (try expectAccepted(arena, text, jwt_types)).algorithm);
    }
}

test "typ is required and compared without ASCII case and application/" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectRefused("{\"alg\":\"HS256\"}", jwt_types, error.WrongType, "typ");
    try expectRefused("{\"alg\":\"HS256\",\"typ\":\"JWS\"}", jwt_types, error.WrongType, "typ");
    try expectRefused("{\"alg\":\"HS256\",\"typ\":\"JWT \"}", jwt_types, error.WrongType, "typ");
    for ([_][]const u8{ "jwt", "application/JWT", "Application/jwt" }) |typ| {
        const text = try std.fmt.allocPrint(arena, "{{\"alg\":\"HS256\",\"typ\":\"{s}\"}}", .{typ});
        try testing.expectEqualStrings(typ, (try expectAccepted(arena, text, jwt_types)).token_type);
    }

    const access: []const []const u8 = &.{"at+jwt"};
    const header = try expectAccepted(arena, "{\"alg\":\"HS256\",\"typ\":\"AT+JWT\"}", access);
    try testing.expectEqualStrings("AT+JWT", header.token_type);
    try expectRefused("{\"alg\":\"HS256\",\"typ\":\"JWT\"}", access, error.WrongType, "typ");
    try expectRefused("{\"alg\":\"HS256\",\"typ\":5}", jwt_types, error.Malformed, "typ");

    try testing.expect(sameType("application/at+JWT", "AT+jwt"));
    try testing.expect(sameType("jwt", "Application/JWT"));
    try testing.expect(!sameType("applicationJWT", "JWT"));
    try testing.expect(!sameType("JWT", "JWTX"));
}

test "crit in any form is UnsupportedHeader" {
    for ([_][]const u8{ "[\"exp\"]", "[]", "\"x\"", "{}" }) |crit| {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{{\"alg\":\"HS256\",\"typ\":\"JWT\",\"crit\":{s}}}", .{crit});
        try expectRefused(text, jwt_types, error.UnsupportedHeader, "crit");
    }
    try expectRefused("{\"alg\":\"HS256\",\"typ\":\"JWT\",\"crit\":[],\"crit\":[]}", jwt_types, error.Malformed, "crit");
}

test "cty JWT means a nested token" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "JWT", "jwt", "application/jwt" }) |cty| {
        const text = try std.fmt.allocPrint(arena, "{{\"alg\":\"HS256\",\"typ\":\"JWT\",\"cty\":\"{s}\"}}", .{cty});
        try expectRefused(text, jwt_types, error.UnsupportedHeader, "cty");
    }
    _ = try expectAccepted(arena, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"cty\":\"text/plain\"}", jwt_types);
    try expectRefused("{\"alg\":\"HS256\",\"typ\":\"JWT\",\"cty\":5}", jwt_types, error.Malformed, "cty");
}

test "kid is a string; the members that name a key are skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectRefused("{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":5}", jwt_types, error.Malformed, "kid");
    try expectRefused("{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"a\",\"kid\":\"a\"}", jwt_types, error.Malformed, "kid");
    const with_kid = try expectAccepted(arena, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"k1\"}", jwt_types);
    try testing.expectEqualStrings("k1", with_kid.key_id.?);

    const header = try expectAccepted(arena,
        \\{"alg":"HS256","typ":"JWT","jku":"https://evil.example/jwks.json",
        \\ "x5u":"https://evil.example/cert","jwk":{"kty":"oct","k":"c2VjcmV0"},
        \\ "x5c":["MIIB","MIIC"],"x5t":"dGh1bWI","x5t#S256":"dGh1bWI","b64":false,"zip":"DEF"}
    , jwt_types);
    try testing.expectEqual(.HS256, header.algorithm);
    try testing.expectEqual(null, header.key_id);
}

test "the rules run in the order alg, crit, cty, typ" {
    try expectRefused("{\"alg\":\"none\",\"crit\":[]}", jwt_types, error.UnsupportedAlgorithm, "alg");
    try expectRefused("{\"alg\":\"HS256\",\"typ\":\"x\",\"crit\":[]}", jwt_types, error.UnsupportedHeader, "crit");
    try expectRefused("{\"alg\":\"HS256\",\"cty\":\"JWT\"}", jwt_types, error.UnsupportedHeader, "cty");
    // The whole object is read first: a member of the wrong type comes
    // before every rule.
    try expectRefused("{\"alg\":\"none\",\"typ\":5}", jwt_types, error.Malformed, "typ");
}

test "a header is one JSON object, at most 32 levels deep" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "not json",
        "[]",
        "\"x\"",
        "5",
        "",
        "{\"alg\":\"HS256\",\"typ\":\"JWT\"} x",
        "\xef\xbb\xbf{\"alg\":\"HS256\",\"typ\":\"JWT\"}",
        "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"x\":\"\xff\"}",
        "{\"alg\":\"HS\xff\",\"typ\":\"JWT\"}",
        "{\"alg\":\"HS256\",\"typ\":\"JWT\",}",
    }) |text| {
        try expectRefused(text, jwt_types, error.Malformed, null);
    }

    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(arena, "{\"a\":");
    try deep.appendNTimes(arena, '[', 1000);
    try expectRefused(deep.items, jwt_types, error.Malformed, null);

    // The top object is level 1: 31 arrays inside an ignored member reach
    // level 32, and 32 arrays level 33.
    for ([_]struct { usize, bool }{ .{ 31, true }, .{ 32, false } }) |case| {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(arena, "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"x\":");
        try text.appendNTimes(arena, '[', case[0]);
        try text.appendNTimes(arena, ']', case[0]);
        try text.append(arena, '}');
        if (case[1]) {
            _ = try expectAccepted(arena, text.items, jwt_types);
        } else {
            try expectRefused(text.items, jwt_types, error.Malformed, null);
        }
    }
}

test "escaped strings count as they decode" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const header = try expectAccepted(arena,
        \\{"\u0061lg":"\u0048S256","typ":"\u004aWT","kid":"2026\u002d10"}
    , jwt_types);
    try testing.expectEqual(.HS256, header.algorithm);
    try testing.expectEqualStrings("2026-10", header.key_id.?);
    try testing.expectEqualStrings("JWT", header.token_type);
    try expectRefused(
        \\{"alg":"HS256","typ":"\ud800"}
    , jwt_types, error.Malformed, null);
    try expectRefused(
        \\{"alg":"HS256","typ":"JWT","kid":"\udc00"}
    , jwt_types, error.Malformed, null);
}
