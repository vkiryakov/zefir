//! The key files of testdata/keys/, embedded, each with what it holds.
//! keys/README.md lists the commands that made them; the keys are public
//! and serve the tests alone.

const std = @import("std");
const Algorithm = @import("../algorithm.zig").Algorithm;

/// Which loaders take a file: `Key.fromPem` and `Key.fromDer` take the
/// public ones, the loaders of `SigningKey` the private ones.
pub const Part = enum { public, private };

pub const File = struct {
    /// The name in testdata/keys/.
    name: []const u8,
    bytes: []const u8,
    part: Part,
    /// The algorithm of the key; null for a key that `security.jwt` refuses
    /// with `UnsupportedKey`.
    algorithm: ?Algorithm,

    /// Whether the file is PEM; the others are DER.
    pub fn isPem(file: File) bool {
        return !std.mem.endsWith(u8, file.name, ".der");
    }
};

fn embed(comptime name: []const u8, part: Part, algorithm: ?Algorithm) File {
    return .{ .name = name, .bytes = @embedFile("keys/" ++ name), .part = part, .algorithm = algorithm };
}

/// One key of each algorithm in every form that `security.jwt` reads (design
/// 5.8). The files of one algorithm hold one and the same key.
pub const supported = [_]File{
    embed("ed25519.pk8.pem", .private, .EdDSA),
    embed("ed25519.pk8.der", .private, .EdDSA),
    embed("ed25519.pub.pem", .public, .EdDSA),
    embed("ed25519.pub.der", .public, .EdDSA),
    // SEC1, in PEM after an EC PARAMETERS block.
    embed("p256.sec1.pem", .private, .ES256),
    embed("p256.sec1.der", .private, .ES256),
    embed("p256.pk8.pem", .private, .ES256),
    embed("p256.pk8.der", .private, .ES256),
    embed("p256.pub.pem", .public, .ES256),
    embed("p256.pub.der", .public, .ES256),
    embed("p256.pub.compressed.pem", .public, .ES256),
    embed("p256.pub.compressed.der", .public, .ES256),
    embed("p384.sec1.pem", .private, .ES384),
    embed("p384.sec1.der", .private, .ES384),
    embed("p384.pk8.pem", .private, .ES384),
    embed("p384.pk8.der", .private, .ES384),
    embed("p384.pub.pem", .public, .ES384),
    embed("p384.pub.der", .public, .ES384),
    embed("p384.pub.compressed.pem", .public, .ES384),
    embed("p384.pub.compressed.der", .public, .ES384),
};

/// Keys that `security.jwt` refuses with `UnsupportedKey`, whatever the
/// algorithm: RSA in every form, P-521, Ed448, encrypted keys, a
/// certificate and an OpenSSH key.
pub const unsupported = [_]File{
    embed("rsa.pk8.pem", .private, null),
    embed("rsa.pk8.der", .private, null),
    embed("rsa.pub.pem", .public, null),
    embed("rsa.pub.der", .public, null),
    embed("rsa.pkcs1.pem", .private, null),
    embed("rsa.pkcs1.pub.pem", .public, null),
    embed("p521.sec1.pem", .private, null),
    embed("p521.pk8.pem", .private, null),
    embed("p521.pub.pem", .public, null),
    embed("ed448.pk8.pem", .private, null),
    embed("ed448.pub.pem", .public, null),
    embed("ed25519.encrypted.pem", .private, null),
    // SEC1 with "Proc-Type: 4,ENCRYPTED".
    embed("p256.sec1.encrypted.pem", .private, null),
    embed("p256.cert.pem", .public, null),
    embed("openssh.key", .private, null),
};

pub const all = supported ++ unsupported;

/// The file called `name`.
pub fn get(comptime name: []const u8) File {
    inline for (all) |file| {
        if (comptime std.mem.eql(u8, file.name, name)) return file;
    }
    @compileError("no key file " ++ name);
}

/// One element of DER, for the keys that tests build by hand: `tag`, the
/// length of `body` and `body`.
pub fn tlv(comptime tag: u8, comptime body: []const u8) []const u8 {
    comptime {
        const head: []const u8 = if (body.len < 0x80)
            &.{ tag, body.len }
        else if (body.len < 0x100)
            &.{ tag, 0x81, body.len }
        else
            &.{ tag, 0x82, body.len >> 8, body.len & 0xff };
        return head ++ body;
    }
}

/// `text` in hex as bytes.
pub fn hex(comptime text: []const u8) []const u8 {
    comptime {
        var bytes: [text.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch @compileError("not hex: " ++ text);
        const final = bytes;
        return &final;
    }
}
