//! The details of one error, for logs: a text in a buffer of its own, at
//! most 256 bytes of UTF-8, and the store's code. Neither ever holds a
//! payload or a connection string. Pass a pointer where a call takes one
//! (`schedule.check(&d)`, `.{ .diagnostics = &d }`); after the error,
//! `d.message()` says what went wrong. A copy keeps its own text.

const std = @import("std");
const Diagnostics = @This();

/// The store's code of the error, as MongoDB's server code; null when the
/// error has none.
code: ?i32 = null,
text_buffer: [256]u8 = undefined,
text_len: u16 = 0,

/// What went wrong, in words; "" before the first `set`.
pub fn message(d: *const Diagnostics) []const u8 {
    return d.text_buffer[0..d.text_len];
}

/// For stores and the module itself: replaces the text with `format` and
/// `args`, and the code with `code`. A text longer than 256 bytes is cut
/// before the first character that does not fit whole, and a byte that is
/// not UTF-8 becomes '?', so the text is always valid UTF-8. `args` may
/// quote `d.message()`.
pub fn set(d: *Diagnostics, code: ?i32, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    // A text that does not fit stops at the end of the buffer.
    w.print(format, args) catch {};
    const len = wholeUtf8(buffer[0..w.end]);
    @memcpy(d.text_buffer[0..len], buffer[0..len]);
    d.text_len = @intCast(len);
    d.code = code;
}

/// Makes `bytes` valid UTF-8 in place, '?' for each byte that does not
/// start a character, and returns the length of the longest prefix that
/// ends on a whole character, so that a text cut at the end of the buffer
/// drops the character it split.
fn wholeUtf8(bytes: []u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            bytes[i] = '?';
            i += 1;
            continue;
        };
        if (bytes.len - i < len) {
            // Only continuation bytes up to the end: a character cut short.
            for (bytes[i + 1 ..]) |byte| {
                if (byte & 0xC0 != 0x80) break;
            } else return i;
            bytes[i] = '?';
            i += 1;
            continue;
        }
        if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| {
            i += len;
        } else |_| {
            bytes[i] = '?';
            i += 1;
        }
    }
    return i;
}
