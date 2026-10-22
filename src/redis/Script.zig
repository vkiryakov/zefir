//! `redis.Script`: a Lua script and its SHA1, for `cmd.evalScript`. Made
//! at comptime, as a constant of a file, it has its SHA1 computed then; a
//! text read at run time gets it at run time.
//!
//! ```zig
//! /// Takes a ticket while some are left: -1 when none is, else how many are left.
//! const take_ticket: redis.Script = .init(
//!     \\local left = tonumber(redis.call('GET', KEYS[1]) or '0')
//!     \\if left <= 0 then return -1 end
//!     \\return redis.call('DECR', KEYS[1])
//! );
//! const left = try client.run(io, op, redis.cmd.evalScript(i64, &take_ticket, &.{"tickets:concert"}, .{}), .{});
//! ```
//!
//! Why the object: `cmd.eval` sends the text of a script with every call,
//! while `client.run` sends a script of this type by its SHA1 alone,
//! EVALSHA. A server that lacks the script, after a restart, a failover or
//! SCRIPT FLUSH, answers NOSCRIPT and runs nothing, and the client then
//! sends the text, EVAL, on the same connection: the call goes on without
//! an error, and the script runs once.

const std = @import("std");
const Script = @This();

/// The text of the script, borrowed: it must outlive the script.
source: []const u8,
/// The SHA1 of `source` in lower-case hex, as EVALSHA takes it.
sha1: [40]u8,

/// A script of `source`, which it borrows, and its SHA1: computed at
/// comptime for a constant, at run time otherwise.
pub fn init(source: []const u8) Script {
    // At comptime the hash of a script of a few KiB takes this many steps.
    @setEvalBranchQuota(1_000_000);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(source, &digest, .{});
    return .{ .source = source, .sha1 = std.fmt.bytesToHex(digest, .lower) };
}
