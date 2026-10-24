//! The fingerprints of connection settings: how the registry tells that a
//! `replaceConnection` or a provisioning brings the settings it has
//! already, without keeping the password. A fingerprint is HMAC-SHA256,
//! keyed by 32 random bytes of the registry, over the length and the bytes
//! of the uri, then those of the password; no password is a length of
//! `maxInt(u64)` and no bytes, so it differs from an empty one. The key
//! guards against tables computed in advance, not against a reader of the
//! process's memory, where the key lies too.

const std = @import("std");
const Io = std.Io;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Key = [HmacSha256.key_length]u8;
pub const Fingerprint = [HmacSha256.mac_length]u8;

/// A key of 32 bytes from `io.random`.
pub fn newKey(io: Io) Key {
    var key: Key = undefined;
    io.random(&key);
    return key;
}

/// The fingerprint of a uri and a password under `key`. The state of the
/// HMAC, which saw the password, is wiped before it returns.
pub fn of(key: *const Key, uri: []const u8, password: ?[]const u8) Fingerprint {
    var mac: HmacSha256 = .init(key);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&mac));
    feed(&mac, uri.len, uri);
    if (password) |p| feed(&mac, p.len, p) else feed(&mac, std.math.maxInt(u64), "");
    var out: Fingerprint = undefined;
    mac.final(&out);
    return out;
}

/// Whether two fingerprints are the same, in time that does not depend on
/// where they differ.
pub fn eql(a: *const Fingerprint, b: *const Fingerprint) bool {
    return std.crypto.timing_safe.eql(Fingerprint, a.*, b.*);
}

fn feed(mac: *HmacSha256, len: u64, bytes: []const u8) void {
    var prefix: [8]u8 = undefined;
    std.mem.writeInt(u64, &prefix, len, .little);
    mac.update(&prefix);
    mac.update(bytes);
}
