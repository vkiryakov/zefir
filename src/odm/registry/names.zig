//! The rules of the names that the registry takes. Each check returns the
//! problem as a text, or null for a name that passes; the text never quotes
//! the name, which may hold anything, a connection string with its password
//! included.

/// A connection id: 1 to 64 bytes of A–Z a–z 0–9 _ - . :, a set that is
/// safe in logs.
pub fn connectionId(id: []const u8) ?[]const u8 {
    if (id.len == 0) return "the connection id is empty";
    if (id.len > 64) return "the connection id is longer than 64 bytes";
    for (id) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.', ':' => {},
        else => return "the connection id holds a byte other than A-Z a-z 0-9 _ - . :",
    };
    return null;
}
