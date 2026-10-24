//! The PEM blocks of key files (RFC 7468): `-----BEGIN <label>-----`,
//! base64, `-----END <label>-----`. A PEM comes from the settings as they
//! hold it, so the markers are found anywhere and white space between the
//! lines of base64 is skipped: CRLF, indented lines and a PEM on one line
//! all read. Text outside the blocks is skipped, and so are blocks of other
//! labels, such as the `EC PARAMETERS` that `openssl ecparam -genkey`
//! writes before the key.

const std = @import("std");
const der = @import("der.zig");
const KeyError = @import("errors.zig").KeyError;

/// The kinds of blocks that hold a key of `security.jwt`.
pub const Label = enum {
    /// "PUBLIC KEY": SPKI.
    public_key,
    /// "PRIVATE KEY": PKCS#8.
    private_key,
    /// "EC PRIVATE KEY": SEC1.
    ec_private_key,
};

/// The most DER that `der.max_input_bytes` of PEM can hold.
pub const max_der_bytes = 12 * 1024;

/// The block of a key and its DER, which lies in the `out` of `decode`.
pub const Block = struct {
    label: Label,
    der: []const u8,
};

const names = std.StaticStringMap(Label).initComptime(.{
    .{ "PUBLIC KEY", .public_key },
    .{ "PRIVATE KEY", .private_key },
    .{ "EC PRIVATE KEY", .ec_private_key },
});

/// The blocks of keys `security.jwt` does not take: encrypted keys,
/// certificates, OpenSSH keys and RSA.
const unsupported = std.StaticStringMap(void).initComptime(.{
    .{"ENCRYPTED PRIVATE KEY"},
    .{"CERTIFICATE"},
    .{"OPENSSH PRIVATE KEY"},
    .{"RSA PUBLIC KEY"},
    .{"RSA PRIVATE KEY"},
});

const begin_marker = "-----BEGIN ";
const end_marker = "-----END ";
const dashes = "-----";

const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

/// Decodes the one block of `text` whose label is among `wanted` into
/// `out`. A caller that reads a private key wipes `out` afterwards, on an
/// error too. `InvalidKey`: input over `der.max_input_bytes`, a BEGIN
/// without its END or with another label at its END, no wanted block or
/// two of them, or bad base64. `UnsupportedKey`: the block has headers,
/// such as "Proc-Type: 4,ENCRYPTED" of the encrypted keys of OpenSSL, or
/// there is no wanted block but an unsupported one.
pub fn decode(out: *[max_der_bytes]u8, text: []const u8, wanted: []const Label) KeyError!Block {
    if (text.len > der.max_input_bytes) return error.InvalidKey;
    var found: ?Block = null;
    var refused = false;
    var pos: usize = 0;
    while (std.mem.findPos(u8, text, pos, begin_marker)) |begin| {
        const label_start = begin + begin_marker.len;
        const label_end = std.mem.findPos(u8, text, label_start, dashes) orelse return error.InvalidKey;
        const label = text[label_start..label_end];
        const body_start = label_end + dashes.len;
        const end = std.mem.findPos(u8, text, body_start, end_marker) orelse return error.InvalidKey;
        const end_label_start = end + end_marker.len;
        const end_label_end = std.mem.findPos(u8, text, end_label_start, dashes) orelse return error.InvalidKey;
        if (!std.mem.eql(u8, label, text[end_label_start..end_label_end])) return error.InvalidKey;
        pos = end_label_end + dashes.len;

        if (names.get(label)) |name| {
            if (std.mem.findScalar(Label, wanted, name) != null) {
                if (found != null) return error.InvalidKey;
                found = .{ .label = name, .der = text[body_start..end] };
                continue;
            }
        }
        if (unsupported.has(label)) refused = true;
    }
    const block = found orelse return if (refused) error.UnsupportedKey else error.InvalidKey;
    // No line of base64 has a ':'; a header line does.
    if (std.mem.findScalar(u8, block.der, ':') != null) return error.UnsupportedKey;
    const len = base64.decode(out, block.der) catch return error.InvalidKey;
    return .{ .label = block.label, .der = out[0..len] };
}

const testing = std.testing;

/// The Ed25519 public key of RFC 8410 §10.1, with its base64 in two lines.
const lines = [_][]const u8{
    "-----BEGIN PUBLIC KEY-----",
    "MCowBQYDK2VwAyEAGb9ECWmEzf6F",
    "QbrBZ9w7lshQhqowtrbLDFw4rXAxZuE=",
    "-----END PUBLIC KEY-----",
};
const spki_hex = "302a300506032b657003210019bf44096984cdfe8541bac167dc3b96c85086aa30b6b6cb0c5c38ad703166e1";

const public: []const Label = &.{.public_key};
const private: []const Label = &.{ .private_key, .ec_private_key };

/// `lines` with `before` in front of each one and `after` behind it.
fn joined(comptime before: []const u8, comptime after: []const u8) []const u8 {
    var text: []const u8 = "";
    for (lines) |line| text = text ++ before ++ line ++ after;
    return text;
}

const pem_lf = joined("", "\n");

fn expectDer(text: []const u8, wanted: []const Label, label: Label, der_hex: []const u8) !void {
    var out: [max_der_bytes]u8 = undefined;
    const block = try decode(&out, text, wanted);
    try testing.expectEqual(label, block.label);
    var expected: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, der_hex), block.der);
}

fn expectRefused(text: []const u8, wanted: []const Label, expected: KeyError) !void {
    var out: [max_der_bytes]u8 = undefined;
    if (decode(&out, text, wanted)) |block| {
        std.debug.print("decoded {t}: {x}\n", .{ block.label, block.der });
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(expected, err);
}

test "PEM as it comes from the settings" {
    const forms = comptime [_][]const u8{
        pem_lf,
        joined("", "\r\n"),
        joined("  ", "\n"),
        pem_lf[0 .. pem_lf.len - 1],
        joined("", " "),
        joined("\t", ""),
    };
    for (forms) |text| try expectDer(text, public, .public_key, spki_hex);
    // A backslash and an n, as a variable that was never expanded gives
    // them: the guide says how to put a PEM into the settings.
    try expectRefused(comptime joined("", "\\n"), public, error.InvalidKey);
}

test "other blocks are skipped" {
    const text =
        \\-----BEGIN EC PARAMETERS-----
        \\BggqhkjOPQMBBw==
        \\-----END EC PARAMETERS-----
        \\-----BEGIN EC PRIVATE KEY-----
        \\MAA=
        \\-----END EC PRIVATE KEY-----
        \\
    ;
    try expectDer(text, private, .ec_private_key, "3000");
    try expectDer("-----BEGIN PRIVATE KEY-----\nMAA=\n-----END PRIVATE KEY-----\n", private, .private_key, "3000");
    // Text around the blocks, and a certificate next to the key.
    try expectDer("key:\n" ++ pem_lf ++ "-----BEGIN CERTIFICATE-----\nMAA=\n-----END CERTIFICATE-----\n", public, .public_key, spki_hex);
}

test "exactly one key" {
    try expectRefused(pem_lf ++ pem_lf, public, error.InvalidKey);
    try expectRefused("-----BEGIN PRIVATE KEY-----\nMAA=\n-----END PRIVATE KEY-----\n-----BEGIN EC PRIVATE KEY-----\nMAA=\n-----END EC PRIVATE KEY-----\n", private, error.InvalidKey);
    try expectRefused("", public, error.InvalidKey);
    try expectRefused("MCowBQYDK2VwAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE=", public, error.InvalidKey);
    // A key of the other kind is no key here.
    try expectRefused(pem_lf, private, error.InvalidKey);
    try expectRefused("-----BEGIN PRIVATE KEY-----\nMAA=\n-----END PRIVATE KEY-----\n", public, error.InvalidKey);
}

test "BEGIN and END name the same label" {
    try expectRefused("-----BEGIN PUBLIC KEY-----\nMAA=\n-----END PRIVATE KEY-----\n", public, error.InvalidKey);
    try expectRefused("-----BEGIN PUBLIC KEY-----\nMAA=\n", public, error.InvalidKey);
    try expectRefused("-----BEGIN PUBLIC KEY-----\nMAA=\n-----END PUBLIC KEY----", public, error.InvalidKey);
    try expectRefused("-----BEGIN PUBLIC KEY\nMAA=\n", public, error.InvalidKey);
    // A block that lacks its END takes the END of the next one.
    try expectRefused("-----BEGIN EC PARAMETERS-----\nBggqhkjOPQMBBw==\n" ++ pem_lf, public, error.InvalidKey);
}

test "encrypted keys, certificates, OpenSSH and RSA are UnsupportedKey" {
    for ([_][]const u8{ "ENCRYPTED PRIVATE KEY", "CERTIFICATE", "OPENSSH PRIVATE KEY", "RSA PUBLIC KEY", "RSA PRIVATE KEY" }) |label| {
        var buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "-----BEGIN {s}-----\nMAA=\n-----END {s}-----\n", .{ label, label });
        try expectRefused(text, public, error.UnsupportedKey);
        try expectRefused(text, private, error.UnsupportedKey);
    }
    const encrypted =
        \\-----BEGIN EC PRIVATE KEY-----
        \\Proc-Type: 4,ENCRYPTED
        \\DEK-Info: AES-128-CBC,3F17F5316E2BAC89E1BB4E9C8E6B4A3E
        \\
        \\MAA=
        \\-----END EC PRIVATE KEY-----
        \\
    ;
    try expectRefused(encrypted, private, error.UnsupportedKey);
}

test "bad base64 is InvalidKey" {
    try expectRefused("-----BEGIN PUBLIC KEY-----\nMA*=\n-----END PUBLIC KEY-----\n", public, error.InvalidKey);
    try expectRefused("-----BEGIN PUBLIC KEY-----\nMAA\n-----END PUBLIC KEY-----\n", public, error.InvalidKey);
    try expectRefused("-----BEGIN PUBLIC KEY-----\nMAA=MAA=\n-----END PUBLIC KEY-----\n", public, error.InvalidKey);
    try expectRefused("-----BEGIN PUBLIC KEY-----\nMA-A\n-----END PUBLIC KEY-----\n", public, error.InvalidKey);
}

test "PEM over 16 KiB is InvalidKey" {
    const pem = pem_lf;
    var text: [16 * 1024 + 1]u8 = @splat(' ');
    @memcpy(text[text.len - pem.len ..], pem);
    try expectRefused(&text, public, error.InvalidKey);
    try expectDer(text[1..], public, .public_key, spki_hex);
}
