//! The rules of the names that the registry takes. Each check returns the
//! problem as a text, or null for a name that passes; the text never quotes
//! the name, which may hold anything, a connection string with its password
//! included.

const std = @import("std");

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

/// A tenant id: 1 to 128 bytes of visible ASCII, 0x21 to 0x7E.
pub fn tenantId(id: []const u8) ?[]const u8 {
    if (id.len == 0) return "the tenant id is empty";
    if (id.len > 128) return "the tenant id is longer than 128 bytes";
    for (id) |byte| switch (byte) {
        0x21...0x7E => {},
        else => return "the tenant id holds a byte outside visible ASCII, 0x21 to 0x7E",
    };
    return null;
}

/// The database of a tenant, by the rules of MongoDB: 1 to 63 bytes of
/// UTF-8 without / \ . " $, a space or NUL. Never admin, local or config,
/// in any case: a tenant never gets a system database.
pub fn database(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "the database name is empty";
    if (name.len > 63) return "the database name is longer than 63 bytes";
    if (!std.unicode.utf8ValidateSlice(name)) return "the database name is not UTF-8";
    for (name) |byte| switch (byte) {
        '/', '\\', '.', '"', '$', ' ', 0 => return "the database name holds one of / \\ . \" $, a space or NUL",
        else => {},
    };
    for ([_][]const u8{ "admin", "local", "config" }) |system| {
        if (std.ascii.eqlIgnoreCase(name, system)) return "the database name is a system one: admin, local or config";
    }
    return null;
}
