//! SCRAM, the client's side: SCRAM-SHA-256 by RFC 7677 and SCRAM-SHA-1 by
//! RFC 5802, as MongoDB's authentication specification adds to them. A
//! conversation is three messages of the client: `Conversation.start`
//! makes the first; `challenge` reads the server's answer and `prove`
//! answers it with the proof that the client knows the password; `verify`
//! checks the server's final message, its proof that it knows the password
//! too. The handshake carries the messages in saslStart and saslContinue.
//!
//! What MongoDB adds to the RFCs:
//!
//! - SCRAM-SHA-1 salts not the password but MongoDB's digest of the user
//!   and the password, hex(MD5("<user>:mongo:<password>")):
//!   `saltingPassword` makes it.
//! - SCRAM-SHA-256 takes the password through SASLprep. The driver does
//!   SASLprep for printable ASCII only, which it leaves as it is:
//!   `checkPassword` refuses any other byte before anything is sent.
//! - The user goes as it is, without SASLprep; a ',' or '=' in it is sent
//!   as "=2C" or "=3D".
//!
//! The checks of the client: the server's nonce extends the client's, the
//! server asks for 4096 iterations or more, and 1 000 000 at most, and its
//! signature, compared in constant time, is the one its keys give. Each
//! failure is `error.AuthenticationFailed`, with why in the diagnostics.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const base64 = std.base64.standard;
const mongo = @import("../root.zig");
const Diagnostics = mongo.Diagnostics;
const Uri = @import("../uri.zig").Uri;

pub const Mechanism = Uri.Mechanism;

/// The fewest iterations a server may ask for: fewer would make the keys
/// of a recorded conversation cheap to guess.
pub const min_iterations = 4096;

/// The most iterations a server may ask for: more would hold the thread
/// that derives the keys for long, minutes for the largest u32. mongod
/// asks for 15 000 of SCRAM-SHA-256 and 10 000 of SCRAM-SHA-1 by default.
pub const max_iterations = 1_000_000;

/// The length of the keys and signatures of SHA-256, the longer of the two.
pub const max_mac_length = 32;

/// The random bytes of the client's nonce: 32 characters of base64.
const nonce_bytes = 24;

fn Hash(comptime mechanism: Mechanism) type {
    return switch (mechanism) {
        .scram_sha_1 => crypto.hash.Sha1,
        .scram_sha_256 => crypto.hash.sha2.Sha256,
    };
}

fn Hmac(comptime mechanism: Mechanism) type {
    return crypto.auth.hmac.Hmac(Hash(mechanism));
}

/// The length of the keys and signatures of `mechanism`: 20 bytes for
/// SHA-1, 32 for SHA-256.
pub fn macLength(mechanism: Mechanism) usize {
    return switch (mechanism) {
        inline else => |m| Hmac(m).mac_length,
    };
}

/// ClientKey and ServerKey of a password, a salt and a count of
/// iterations: all that a conversation needs of the password. For SHA-1
/// the last 12 bytes of each stay 0.
pub const Keys = struct {
    client: [max_mac_length]u8 = @splat(0),
    server: [max_mac_length]u8 = @splat(0),

    pub fn wipe(keys: *Keys) void {
        crypto.secureZero(u8, &keys.client);
        crypto.secureZero(u8, &keys.server);
    }
};

/// The keys of `password`: SaltedPassword := Hi(password, salt,
/// iterations), PBKDF2 with the HMAC of the mechanism, then ClientKey and
/// ServerKey. This is the CPU work of authentication, so `KeyCache` keeps
/// the keys: mongod asks for 15 000 iterations of SCRAM-SHA-256 and
/// 10 000 of SCRAM-SHA-1 by default. `password` is the one
/// `saltingPassword` gives.
pub fn deriveKeys(mechanism: Mechanism, password: []const u8, salt: []const u8, iterations: u32) Keys {
    switch (mechanism) {
        inline else => |m| {
            const H = Hmac(m);
            var salted: [H.mac_length]u8 = undefined;
            defer crypto.secureZero(u8, &salted);
            // Neither error of pbkdf2 can happen: one round at least, one
            // block of output.
            crypto.pwhash.pbkdf2(&salted, password, salt, @max(iterations, 1), H) catch unreachable;
            var keys: Keys = .{};
            H.create(keys.client[0..H.mac_length], "Client Key", &salted);
            H.create(keys.server[0..H.mac_length], "Server Key", &salted);
            return keys;
        },
    }
}

/// The password that SCRAM salts. SCRAM-SHA-256 salts the password itself;
/// SCRAM-SHA-1 salts MongoDB's digest of the user and the password,
/// hex(MD5("<user>:mongo:<password>")), which goes into `buffer`.
pub fn saltingPassword(mechanism: Mechanism, username: []const u8, password: []const u8, buffer: *[32]u8) []const u8 {
    switch (mechanism) {
        .scram_sha_256 => return password,
        .scram_sha_1 => {
            var md5 = crypto.hash.Md5.init(.{});
            md5.update(username);
            md5.update(":mongo:");
            md5.update(password);
            var digest: [crypto.hash.Md5.digest_length]u8 = undefined;
            md5.final(&digest);
            buffer.* = std.fmt.bytesToHex(digest, .lower);
            crypto.secureZero(u8, &digest);
            crypto.secureZero(u8, std.mem.asBytes(&md5));
            return buffer;
        },
    }
}

/// Whether `mechanism` can take `password`. SCRAM-SHA-1 takes any bytes.
/// SCRAM-SHA-256 asks for the password prepared by SASLprep, which the
/// driver does for printable ASCII only: any other byte is
/// `error.Unsupported`, with what to do instead.
pub fn checkPassword(mechanism: Mechanism, password: []const u8, phase: ?Diagnostics.Phase, d: ?*Diagnostics) error{Unsupported}!void {
    if (mechanism == .scram_sha_1) return;
    for (password) |c| if (c < 0x20 or c > 0x7e) {
        if (d) |x| x.set(phase, null, "SCRAM-SHA-256 needs the password prepared by SASLprep, which v0.1 does for printable ASCII only: use a password of printable ASCII, or a user with SCRAM-SHA-1 credentials and authMechanism=SCRAM-SHA-1", .{});
        return error.Unsupported;
    };
}

/// The client's side of one conversation. It keeps its first message and,
/// after `prove`, the signature the server must answer with; `deinit`
/// wipes and frees them.
pub const Conversation = struct {
    gpa: Allocator,
    mechanism: Mechanism,
    /// client-first-message: the header "n,," of a client without channel
    /// binding, then client-first-message-bare, "n=<user>,r=<nonce>".
    first: []u8,
    /// The length of the client's nonce, the end of `first`.
    nonce_len: usize,
    /// ServerSignature, which server-final-message must hold; set by
    /// `prove`.
    server_signature: [max_mac_length]u8 = @splat(0),
    proved: bool = false,

    pub const StartError = Allocator.Error || Io.RandomSecureError;

    /// A conversation of `username`, with a nonce of 24 bytes fresh from
    /// the system, in base64.
    pub fn start(gpa: Allocator, io: Io, mechanism: Mechanism, username: []const u8) StartError!Conversation {
        var random: [nonce_bytes]u8 = undefined;
        try io.randomSecure(&random);
        var nonce: [base64.Encoder.calcSize(nonce_bytes)]u8 = undefined;
        return startWithNonce(gpa, mechanism, username, base64.Encoder.encode(&nonce, &random));
    }

    /// As `start`, with the nonce given, printable ASCII without ',': for
    /// the vectors of the RFCs.
    pub fn startWithNonce(gpa: Allocator, mechanism: Mechanism, username: []const u8, nonce: []const u8) Allocator.Error!Conversation {
        var escaped = username.len;
        for (username) |c| {
            if (c == ',' or c == '=') escaped += 2;
        }
        const first = try gpa.alloc(u8, "n,,n=".len + escaped + ",r=".len + nonce.len);
        var w: Io.Writer = .fixed(first);
        // The buffer has the exact length: no write fails.
        w.writeAll("n,,n=") catch unreachable;
        for (username) |c| switch (c) {
            ',' => w.writeAll("=2C") catch unreachable,
            '=' => w.writeAll("=3D") catch unreachable,
            else => w.writeByte(c) catch unreachable,
        };
        w.writeAll(",r=") catch unreachable;
        w.writeAll(nonce) catch unreachable;
        return .{ .gpa = gpa, .mechanism = mechanism, .first = first, .nonce_len = nonce.len };
    }

    pub fn deinit(c: *Conversation) void {
        crypto.secureZero(u8, c.first);
        crypto.secureZero(u8, &c.server_signature);
        c.gpa.free(c.first);
        c.* = undefined;
    }

    /// client-first-message, the payload of saslStart.
    pub fn message(c: *const Conversation) []const u8 {
        return c.first;
    }

    /// client-first-message-bare: the first message without its header.
    fn bare(c: *const Conversation) []const u8 {
        return c.first["n,,".len..];
    }

    fn clientNonce(c: *const Conversation) []const u8 {
        return c.first[c.first.len - c.nonce_len ..];
    }

    /// What server-first-message asks of the client.
    pub const Challenge = struct {
        /// The client's nonce and the server's after it: a slice of the
        /// message.
        nonce: []const u8,
        salt: []u8,
        iterations: u32,

        pub fn deinit(ch: Challenge, gpa: Allocator) void {
            gpa.free(ch.salt);
        }
    };

    /// Reads server-first-message, "r=<nonce>,s=<salt>,i=<count>", and
    /// checks it: the nonce must extend the client's, and the count must be
    /// from 4096 to 1 000 000. The salt comes from `gpa`: free it with
    /// `Challenge.deinit`.
    pub fn challenge(c: *const Conversation, gpa: Allocator, server_first: []const u8, d: ?*Diagnostics) error{ AuthenticationFailed, OutOfMemory }!Challenge {
        var attributes = std.mem.splitScalar(u8, server_first, ',');
        const head = attributes.next().?;
        if (attribute(head, 'm') != null) return fail(d, "the server requires an extension of SCRAM (m=) that the driver does not know", .{});
        const full_nonce = attribute(head, 'r') orelse return fail(d, "the server's first message of SCRAM has no nonce (r=)", .{});
        for (full_nonce) |byte| if (byte < 0x21 or byte > 0x7e) {
            return fail(d, "the nonce of the server's first message of SCRAM holds a byte that is not printable ASCII", .{});
        };
        if (full_nonce.len <= c.nonce_len or !std.mem.startsWith(u8, full_nonce, c.clientNonce())) {
            return fail(d, "the server's nonce does not extend the client's: the reply is not to this conversation", .{});
        }
        const salt_text = attribute(attributes.next() orelse "", 's') orelse return fail(d, "the server's first message of SCRAM has no salt (s=)", .{});
        const count_text = attribute(attributes.next() orelse "", 'i') orelse return fail(d, "the server's first message of SCRAM has no count of iterations (i=)", .{});
        const valid_count = count_text.len > 0 and for (count_text) |byte| {
            if (!std.ascii.isDigit(byte)) break false;
        } else true;
        const iterations = (if (valid_count) std.fmt.parseInt(u32, count_text, 10) catch null else null) orelse
            return fail(d, "the count of iterations of the server's first message of SCRAM is not a number", .{});
        if (iterations < min_iterations) return fail(d, "the server asks for {d} iterations of SCRAM, and 4096 is the least that is safe", .{iterations});
        if (iterations > max_iterations) return fail(d, "the server asks for {d} iterations of SCRAM, and 1000000 is the most that the client runs: more would hold its thread for long", .{iterations});
        const salt = try decode(gpa, salt_text) orelse return fail(d, "the salt of the server's first message of SCRAM is not base64", .{});
        return .{ .nonce = full_nonce, .salt = salt, .iterations = iterations };
    }

    /// The proof: client-final-message, "c=biws,r=<nonce>,p=<proof>", from
    /// the conversation's allocator, made with the keys of the password for
    /// the challenge's salt and count. `server_first` is the message that
    /// `challenge` read. The signature the server must answer with stays
    /// for `verify`.
    pub fn prove(c: *Conversation, server_first: []const u8, ch: Challenge, keys: Keys) Allocator.Error![]u8 {
        return switch (c.mechanism) {
            inline else => |m| c.proveWith(m, server_first, ch, keys),
        };
    }

    fn proveWith(c: *Conversation, comptime m: Mechanism, server_first: []const u8, ch: Challenge, keys: Keys) Allocator.Error![]u8 {
        const H = Hmac(m);
        const len = H.mac_length;
        // "biws" is the header "n,," in base64.
        const without_proof_len = "c=biws,r=".len + ch.nonce.len;
        const final = try c.gpa.alloc(u8, without_proof_len + ",p=".len + base64.Encoder.calcSize(len));
        @memcpy(final[0.."c=biws,r=".len], "c=biws,r=");
        @memcpy(final["c=biws,r=".len..without_proof_len], ch.nonce);
        const without_proof = final[0..without_proof_len];

        // AuthMessage := client-first-message-bare + "," +
        // server-first-message + "," + client-final-message-without-proof
        var stored: [len]u8 = undefined;
        Hash(m).hash(keys.client[0..len], &stored, .{});
        var client_signature: [len]u8 = undefined;
        authMessageMac(H, &stored, c.bare(), server_first, without_proof, &client_signature);
        var proof: [len]u8 = undefined;
        for (&proof, keys.client[0..len], client_signature) |*p, k, s| p.* = k ^ s;
        authMessageMac(H, keys.server[0..len], c.bare(), server_first, without_proof, c.server_signature[0..len]);
        c.proved = true;

        @memcpy(final[without_proof_len..][0..",p=".len], ",p=");
        _ = base64.Encoder.encode(final[without_proof_len + ",p=".len ..], &proof);
        crypto.secureZero(u8, &stored);
        crypto.secureZero(u8, &client_signature);
        crypto.secureZero(u8, &proof);
        return final;
    }

    /// Checks server-final-message, "v=<signature>": the server proves it
    /// holds the user's keys. "e=<error>", the server's refusal, and
    /// another signature are `error.AuthenticationFailed`.
    pub fn verify(c: *const Conversation, server_final: []const u8, d: ?*Diagnostics) error{AuthenticationFailed}!void {
        if (!c.proved) return fail(d, "the server's final message of SCRAM came before the client's proof", .{});
        var attributes = std.mem.splitScalar(u8, server_final, ',');
        const head = attributes.next().?;
        if (attribute(head, 'e')) |reason| return fail(d, "the server refused the proof of SCRAM: {s}", .{reason});
        const text = attribute(head, 'v') orelse return fail(d, "the server's final message of SCRAM holds no signature (v=)", .{});
        const len = macLength(c.mechanism);
        var signature: [max_mac_length]u8 = @splat(0);
        const size = base64.Decoder.calcSizeForSlice(text) catch 0;
        if (size != len) return fail(d, "the server's signature in SCRAM is not {d} bytes of base64", .{len});
        base64.Decoder.decode(signature[0..len], text) catch return fail(d, "the server's signature in SCRAM is not {d} bytes of base64", .{len});
        if (!crypto.timing_safe.eql([max_mac_length]u8, signature, c.server_signature)) {
            return fail(d, "the server's signature in SCRAM is wrong: the server does not hold the user's keys", .{});
        }
    }
};

/// HMAC(key, AuthMessage), where AuthMessage is the three messages joined
/// by ",", hashed in turn instead of joined.
fn authMessageMac(comptime H: type, key: []const u8, first_bare: []const u8, server_first: []const u8, final_without_proof: []const u8, out: *[H.mac_length]u8) void {
    var mac = H.init(key);
    mac.update(first_bare);
    mac.update(",");
    mac.update(server_first);
    mac.update(",");
    mac.update(final_without_proof);
    mac.final(out);
}

/// The value of `part`, an attribute "<name>=<value>", or null when it
/// names another attribute.
fn attribute(part: []const u8, name: u8) ?[]const u8 {
    if (part.len < 2 or part[0] != name or part[1] != '=') return null;
    return part[2..];
}

/// `text` decoded from base64, from `gpa`; null when it is not base64.
fn decode(gpa: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    const size = base64.Decoder.calcSizeForSlice(text) catch return null;
    const bytes = try gpa.alloc(u8, size);
    base64.Decoder.decode(bytes, text) catch {
        gpa.free(bytes);
        return null;
    };
    return bytes;
}

fn fail(d: ?*Diagnostics, comptime fmt: []const u8, args: anytype) error{AuthenticationFailed} {
    if (d) |x| x.set(.authenticate, null, fmt, args);
    return error.AuthenticationFailed;
}

const testing = std.testing;

/// One conversation of the client with given messages of the server, as
/// the RFCs print them: returns client-final-message, after checking the
/// first message and the server's final one.
fn converse(mechanism: Mechanism, nonce: []const u8, server_first: []const u8, server_final: []const u8, expected_first: []const u8) ![]u8 {
    var c: Conversation = try .startWithNonce(testing.allocator, mechanism, "user", nonce);
    defer c.deinit();
    try testing.expectEqualStrings(expected_first, c.message());
    const ch = try c.challenge(testing.allocator, server_first, null);
    defer ch.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4096), ch.iterations);
    const keys = deriveKeys(mechanism, "pencil", ch.salt, ch.iterations);
    const final = try c.prove(server_first, ch, keys);
    errdefer testing.allocator.free(final);
    try c.verify(server_final, null);
    return final;
}

test "the conversation of RFC 5802, section 5: SCRAM-SHA-1 with the password pencil" {
    const final = try converse(
        .scram_sha_1,
        "fyko+d2lbbFgONRv9qkxdawL",
        "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096",
        "v=rmF9pqV8S7suAoZWja4dJRkFsKQ=",
        "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL",
    );
    defer testing.allocator.free(final);
    try testing.expectEqualStrings("c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=", final);
}

test "the conversation of RFC 7677, section 3: SCRAM-SHA-256 with the password pencil" {
    const final = try converse(
        .scram_sha_256,
        "rOprNGfwEbeRWgbNEkqO",
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
        "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=",
        "n,,n=user,r=rOprNGfwEbeRWgbNEkqO",
    );
    defer testing.allocator.free(final);
    try testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", final);
}

test "SCRAM-SHA-1 salts MongoDB's digest of the user and the password, hex(MD5(user:mongo:password)); SCRAM-SHA-256 the password itself" {
    var buffer: [32]u8 = undefined;
    // md5 -s "app:mongo:secret"
    try testing.expectEqualStrings("13a21453049f532d1fc5c0ea59c6265e", saltingPassword(.scram_sha_1, "app", "secret", &buffer));
    // The user goes into the digest as it is, ',' and '=' among it.
    try testing.expectEqualStrings("8fcf50a7a33ca57753612a8752e5e80a", saltingPassword(.scram_sha_1, "a,b=c", "p@ss", &buffer));
    try testing.expectEqualStrings("secret", saltingPassword(.scram_sha_256, "app", "secret", &buffer));
}

test "every ',' and '=' of the user is escaped, as =2C and =3D" {
    var c: Conversation = try .startWithNonce(testing.allocator, .scram_sha_256, "a,b=c,,==", "n0nce");
    defer c.deinit();
    try testing.expectEqualStrings("n,,n=a=2Cb=3Dc=2C=2C=3D=3D,r=n0nce", c.message());
}

test "a conversation starts with a nonce of 24 random bytes in base64, a new one each time" {
    var one: Conversation = try .start(testing.allocator, testing.io, .scram_sha_256, "app");
    defer one.deinit();
    var two: Conversation = try .start(testing.allocator, testing.io, .scram_sha_256, "app");
    defer two.deinit();
    try testing.expect(std.mem.startsWith(u8, one.message(), "n,,n=app,r="));
    const nonce = one.message()["n,,n=app,r=".len..];
    try testing.expectEqual(@as(usize, 32), nonce.len);
    var bytes: [24]u8 = undefined;
    try std.base64.standard.Decoder.decode(&bytes, nonce);
    try testing.expect(!std.mem.eql(u8, one.message(), two.message()));
}

test "SCRAM-SHA-256 takes a password of printable ASCII only, and says what to do instead; SCRAM-SHA-1 takes any" {
    try checkPassword(.scram_sha_256, "pencil ~!@#$%^&*()_+{}|:\"<>?`-=[]\\;',./", null, null);
    for ([_][]const u8{ "Ⅳ", "I\u{00AD}X", "pässword", "tab\there", "del\x7f", "nul\x00" }) |password| {
        var d: Diagnostics = .{};
        try testing.expectError(error.Unsupported, checkPassword(.scram_sha_256, password, .authenticate, &d));
        try testing.expectEqualStrings("SCRAM-SHA-256 needs the password prepared by SASLprep, which v0.1 does for printable ASCII only: use a password of printable ASCII, or a user with SCRAM-SHA-1 credentials and authMechanism=SCRAM-SHA-1", d.message());
        try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
        try checkPassword(.scram_sha_1, password, null, null);
    }
}

/// The server's first message to a conversation started with the nonce
/// "abc" fails its check with `message`.
fn expectRefused(server_first: []const u8, message: []const u8) !void {
    var c: Conversation = try .startWithNonce(testing.allocator, .scram_sha_256, "user", "abc");
    defer c.deinit();
    var d: Diagnostics = .{};
    try testing.expectError(error.AuthenticationFailed, c.challenge(testing.allocator, server_first, &d));
    try testing.expectEqualStrings(message, d.message());
    try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
}

test "the server's nonce must extend the client's, and the server must ask for 4096 iterations or more" {
    const foreign = "the server's nonce does not extend the client's: the reply is not to this conversation";
    try expectRefused("r=xyzdef,s=c2FsdA==,i=4096", foreign);
    try expectRefused("r=abc,s=c2FsdA==,i=4096", foreign);
    try expectRefused("r=ab,s=c2FsdA==,i=4096", foreign);
    try expectRefused("r=abcdef,s=c2FsdA==,i=4095", "the server asks for 4095 iterations of SCRAM, and 4096 is the least that is safe");
    try expectRefused("r=abcdef,s=c2FsdA==,i=0", "the server asks for 0 iterations of SCRAM, and 4096 is the least that is safe");
}

test "the server may ask for 1 000 000 iterations at most: more would hold a thread of the client in PBKDF2 for long" {
    try expectRefused("r=abcdef,s=c2FsdA==,i=1000001", "the server asks for 1000001 iterations of SCRAM, and 1000000 is the most that the client runs: more would hold its thread for long");
    try expectRefused("r=abcdef,s=c2FsdA==,i=4294967295", "the server asks for 4294967295 iterations of SCRAM, and 1000000 is the most that the client runs: more would hold its thread for long");
    var c: Conversation = try .startWithNonce(testing.allocator, .scram_sha_256, "user", "abc");
    defer c.deinit();
    const ch = try c.challenge(testing.allocator, "r=abcdef,s=c2FsdA==,i=1000000", null);
    defer ch.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, max_iterations), ch.iterations);
}

test "a first message of the server that breaks SCRAM is refused with what is wrong" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "the server's first message of SCRAM has no nonce (r=)" },
        .{ "s=c2FsdA==,r=abcdef,i=4096", "the server's first message of SCRAM has no nonce (r=)" },
        .{ "m=ext,r=abcdef,s=c2FsdA==,i=4096", "the server requires an extension of SCRAM (m=) that the driver does not know" },
        .{ "r=abcdef", "the server's first message of SCRAM has no salt (s=)" },
        .{ "r=abcdef,s=c2Fsd,i=4096", "the salt of the server's first message of SCRAM is not base64" },
        .{ "r=abcdef,s=c2FsdA==", "the server's first message of SCRAM has no count of iterations (i=)" },
        .{ "r=abcdef,s=c2FsdA==,i=", "the count of iterations of the server's first message of SCRAM is not a number" },
        .{ "r=abcdef,s=c2FsdA==,i=+4096", "the count of iterations of the server's first message of SCRAM is not a number" },
        .{ "r=abcdef,s=c2FsdA==,i=99999999999", "the count of iterations of the server's first message of SCRAM is not a number" },
        .{ "r=abc de,s=c2FsdA==,i=4096", "the nonce of the server's first message of SCRAM holds a byte that is not printable ASCII" },
    };
    for (cases) |case| try expectRefused(case[0], case[1]);
}

test "extensions after the count of iterations are ignored" {
    var c: Conversation = try .startWithNonce(testing.allocator, .scram_sha_256, "user", "abc");
    defer c.deinit();
    const ch = try c.challenge(testing.allocator, "r=abcdef,s=c2FsdA==,i=4096,x=later", null);
    defer ch.deinit(testing.allocator);
    try testing.expectEqualStrings("abcdef", ch.nonce);
    try testing.expectEqualStrings("salt", ch.salt);
}

/// A conversation of RFC 7677 up to the proof, whose final message of the
/// server fails its check with `message`.
fn expectFinalRefused(server_final: []const u8, message: []const u8) !void {
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    var c: Conversation = try .startWithNonce(testing.allocator, .scram_sha_256, "user", "rOprNGfwEbeRWgbNEkqO");
    defer c.deinit();
    var d: Diagnostics = .{};
    // Before the proof there is no signature to compare with.
    try testing.expectError(error.AuthenticationFailed, c.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", &d));
    const ch = try c.challenge(testing.allocator, server_first, null);
    defer ch.deinit(testing.allocator);
    const final = try c.prove(server_first, ch, deriveKeys(.scram_sha_256, "pencil", ch.salt, ch.iterations));
    testing.allocator.free(final);
    try testing.expectError(error.AuthenticationFailed, c.verify(server_final, &d));
    try testing.expectEqualStrings(message, d.message());
    try testing.expectEqual(Diagnostics.Phase.authenticate, d.phase.?);
}

test "the server's signature must be the one its keys give, compared in constant time; e= is the server's refusal" {
    const wrong = "the server's signature in SCRAM is wrong: the server does not hold the user's keys";
    try expectFinalRefused("v=7rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", wrong);
    try expectFinalRefused("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=", "the server's signature in SCRAM is not 32 bytes of base64");
    try expectFinalRefused("v=", "the server's signature in SCRAM is not 32 bytes of base64");
    try expectFinalRefused("v=***", "the server's signature in SCRAM is not 32 bytes of base64");
    try expectFinalRefused("e=invalid-proof", "the server refused the proof of SCRAM: invalid-proof");
    try expectFinalRefused("", "the server's final message of SCRAM holds no signature (v=)");
}
