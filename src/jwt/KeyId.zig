//! The key id ("kid") of a `jwt.Key` or a `jwt.SigningKey`, kept inside
//! the key: 1 to `max_key_id_bytes` bytes of visible ASCII, or none.

const KeyId = @This();

const root = @import("root.zig");

bytes: [root.max_key_id_bytes]u8,
len: u8,

/// A key without an id.
pub const none: KeyId = .{ .bytes = @splat(0), .len = 0 };

/// A copy of `id`, or `none` for null. `InvalidKeyId`: empty, longer than
/// `max_key_id_bytes`, or a byte outside `!`…`~`.
pub fn init(id: ?[]const u8) error{InvalidKeyId}!KeyId {
    const text = id orelse return .none;
    if (text.len == 0 or text.len > root.max_key_id_bytes) return error.InvalidKeyId;
    for (text) |c| {
        if (c < '!' or c > '~') return error.InvalidKeyId;
    }
    var key_id: KeyId = .none;
    @memcpy(key_id.bytes[0..text.len], text);
    key_id.len = @intCast(text.len);
    return key_id;
}

/// The id, or null for a key without one.
pub fn get(key_id: *const KeyId) ?[]const u8 {
    return if (key_id.len == 0) null else key_id.bytes[0..key_id.len];
}
