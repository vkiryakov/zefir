//! Types whose values must never be printed: passwords, tokens, keys.
//!
//! A type marks itself with one public declaration:
//!
//! ```zig
//! const Password = struct {
//!     value: []const u8,
//!     pub const zefir_sensitive = true;
//! };
//! ```
//!
//! Modules that write values out (the logger, error details, query logs)
//! check `isSensitive` and write a placeholder instead. The marker must be
//! `pub`: a private one is invisible to the check, so test each sensitive
//! type with `comptime std.debug.assert(core.isSensitive(T))`.

const std = @import("std");

/// Whether `T` declares `pub const zefir_sensitive = true;`. Only structs,
/// unions, enums and opaque types can declare it; a pointer or an optional
/// is not sensitive itself, whatever it points to. A marker that is not a
/// `bool` is a compile error.
pub fn isSensitive(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(T, "zefir_sensitive")) return false;
    const marker = T.zefir_sensitive;
    if (@TypeOf(marker) != bool)
        @compileError("zefir: " ++ @typeName(T) ++ ".zefir_sensitive must be a bool: pub const zefir_sensitive = true;");
    return marker;
}

test "a type with the marker is sensitive" {
    const Password = struct {
        value: []const u8,
        pub const zefir_sensitive = true;
    };
    const Mode = enum {
        a,
        pub const zefir_sensitive = true;
    };
    const Key = union(enum) {
        raw: [32]u8,
        pub const zefir_sensitive = true;
    };
    try std.testing.expect(isSensitive(Password));
    try std.testing.expect(isSensitive(Mode));
    try std.testing.expect(isSensitive(Key));
}

test "a marker set to false, a private marker or no marker is not sensitive" {
    const Off = struct {
        pub const zefir_sensitive = false;
    };
    const Private = struct {
        const zefir_sensitive = true;
    };
    const Plain = struct { value: []const u8 };
    try std.testing.expect(!isSensitive(Off));
    try std.testing.expect(!isSensitive(Private));
    try std.testing.expect(!isSensitive(Plain));
}

test "types that cannot declare anything are not sensitive" {
    try std.testing.expect(!isSensitive(u8));
    try std.testing.expect(!isSensitive([]const u8));
    try std.testing.expect(!isSensitive(?u32));
    try std.testing.expect(!isSensitive(*const struct {
        pub const zefir_sensitive = true;
    })); // the pointer, not the type it points to
}
