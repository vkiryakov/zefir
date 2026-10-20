//! The client's cache of SCRAM keys, as MongoDB's authentication
//! specification asks: PBKDF2, the CPU work of authentication, runs once
//! per password, salt, count of iterations and mechanism, and every later
//! connection of the client reuses the keys. It keeps one entry per
//! mechanism; a new salt or count, as after the user's password changed
//! on the server, replaces it. Connections opened at once may each derive
//! the keys the first time: PBKDF2 runs outside the lock. `deinit` wipes
//! the cache.

const std = @import("std");
const Io = std.Io;
const crypto = std.crypto;
const scram = @import("scram.zig");
const Mechanism = scram.Mechanism;
const KeyCache = @This();

mutex: Io.Mutex = .init,
entries: std.enums.EnumArray(Mechanism, ?Entry) = .initFill(null),
/// How many times PBKDF2 ran, for tests.
derivations: u32 = 0,

const Entry = struct {
    /// What the keys are of: SHA-256 of the mechanism, the count, the salt
    /// and the password.
    fingerprint: [32]u8,
    keys: scram.Keys,
};

/// The keys of `password`, the one `scram.saltingPassword` gives, for
/// `salt` and `iterations`: kept from a connection before, or derived now
/// and kept.
pub fn get(cache: *KeyCache, io: Io, mechanism: Mechanism, password: []const u8, salt: []const u8, iterations: u32) scram.Keys {
    var mark = fingerprint(mechanism, password, salt, iterations);
    defer crypto.secureZero(u8, &mark);
    {
        cache.mutex.lockUncancelable(io);
        defer cache.mutex.unlock(io);
        if (cache.entries.get(mechanism)) |entry| {
            if (crypto.timing_safe.eql([32]u8, entry.fingerprint, mark)) return entry.keys;
        }
    }
    const keys = scram.deriveKeys(mechanism, password, salt, iterations);
    cache.mutex.lockUncancelable(io);
    defer cache.mutex.unlock(io);
    if (cache.entries.getPtr(mechanism).*) |*old| old.keys.wipe();
    cache.entries.set(mechanism, .{ .fingerprint = mark, .keys = keys });
    cache.derivations += 1;
    return keys;
}

/// Wipes the keys and frees nothing: the cache lives in its client.
pub fn deinit(cache: *KeyCache) void {
    cache.wipe();
    cache.* = undefined;
}

fn wipe(cache: *KeyCache) void {
    crypto.secureZero(u8, std.mem.asBytes(&cache.entries));
}

fn fingerprint(mechanism: Mechanism, password: []const u8, salt: []const u8, iterations: u32) [32]u8 {
    var h = crypto.hash.sha2.Sha256.init(.{});
    var numbers: [13]u8 = undefined;
    numbers[0] = @backingInt(mechanism);
    std.mem.writeInt(u32, numbers[1..5], iterations, .little);
    std.mem.writeInt(u64, numbers[5..13], salt.len, .little);
    h.update(&numbers);
    h.update(salt);
    h.update(password);
    defer crypto.secureZero(u8, std.mem.asBytes(&h));
    return h.finalResult();
}

const testing = std.testing;

test "a password, a salt, a count and a mechanism derive their keys once; another of any of them derives again" {
    const io = testing.io;
    var cache: KeyCache = .{};
    defer cache.deinit();
    const keys = cache.get(io, .scram_sha_256, "secret", "salt-one", 4096);
    try testing.expectEqual(scram.deriveKeys(.scram_sha_256, "secret", "salt-one", 4096), keys);
    try testing.expectEqual(keys, cache.get(io, .scram_sha_256, "secret", "salt-one", 4096));
    try testing.expectEqual(@as(u32, 1), cache.derivations);

    _ = cache.get(io, .scram_sha_256, "secret", "salt-two", 4096);
    _ = cache.get(io, .scram_sha_256, "secret", "salt-two", 5000);
    _ = cache.get(io, .scram_sha_256, "other", "salt-two", 5000);
    try testing.expectEqual(@as(u32, 4), cache.derivations);
    // The keys of a mechanism replace its keys before them.
    _ = cache.get(io, .scram_sha_256, "secret", "salt-one", 4096);
    try testing.expectEqual(@as(u32, 5), cache.derivations);
}

test "each mechanism keeps its own keys" {
    const io = testing.io;
    var cache: KeyCache = .{};
    defer cache.deinit();
    const sha1 = cache.get(io, .scram_sha_1, "secret", "salt", 4096);
    const sha256 = cache.get(io, .scram_sha_256, "secret", "salt", 4096);
    try testing.expectEqual(sha1, cache.get(io, .scram_sha_1, "secret", "salt", 4096));
    try testing.expectEqual(sha256, cache.get(io, .scram_sha_256, "secret", "salt", 4096));
    try testing.expectEqual(@as(u32, 2), cache.derivations);
    try testing.expect(!std.meta.eql(sha1, sha256));
}

test "deinit wipes the keys" {
    const io = testing.io;
    var cache: KeyCache = .{};
    defer cache.deinit();
    _ = cache.get(io, .scram_sha_256, "secret", "salt", 4096);
    // deinit wipes first; the wipe is checked on its own, before the
    // memory is undefined.
    cache.wipe();
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&cache.entries), 0));
}
