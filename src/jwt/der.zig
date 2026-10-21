//! A reader of DER (X.690) for the key files of zefir-jwt, with every
//! length checked against what is left of its parent before anything is
//! sliced: input that lies about its lengths is `InvalidKey`, never a read
//! past the end.

const std = @import("std");

/// The longest key file, in DER or in PEM, that zefir-jwt reads.
pub const max_input_bytes = 16 * 1024;

pub const Error = error{InvalidKey};

/// One element: its tag, such as 0x30 for a SEQUENCE, and its contents.
pub const Element = struct {
    tag: u8,
    body: []const u8,
};

/// Reads the elements of a sequence of DER one after another.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    /// The next element, or null after the last one. `InvalidKey`: a tag
    /// of more than one byte, a length that is indefinite, not minimal or
    /// longer than four bytes, or contents that reach past `bytes`.
    pub fn next(r: *Reader) Error!?Element {
        const rest = r.bytes[r.pos..];
        if (rest.len == 0) return null;
        if (rest.len < 2) return error.InvalidKey;
        const tag = rest[0];
        if (tag & 0x1f == 0x1f) return error.InvalidKey;
        var header_len: usize = 2;
        var len: usize = rest[1];
        if (len >= 0x80) {
            // The long form: the low bits count the bytes of the length.
            // 0x80, the indefinite length, is BER, not DER.
            const count = len & 0x7f;
            if (count == 0 or count > 4 or rest.len < 2 + count) return error.InvalidKey;
            const digits = rest[2..][0..count];
            if (digits[0] == 0) return error.InvalidKey;
            len = 0;
            for (digits) |digit| len = len << 8 | digit;
            if (len < 0x80) return error.InvalidKey;
            header_len += count;
        }
        if (len > rest.len - header_len) return error.InvalidKey;
        r.pos += header_len + len;
        return .{ .tag = tag, .body = rest[header_len..][0..len] };
    }

    /// The next element, which must have `tag`.
    pub fn expect(r: *Reader, tag: u8) Error!Element {
        const element = try r.next() orelse return error.InvalidKey;
        if (element.tag != tag) return error.InvalidKey;
        return element;
    }

    /// Whether every element has been read.
    pub fn done(r: *const Reader) bool {
        return r.pos == r.bytes.len;
    }
};

/// The one element of `der`, which has `tag` and nothing after it.
/// `InvalidKey` too for input over `max_input_bytes`.
pub fn top(der: []const u8, tag: u8) Error!Element {
    if (der.len > max_input_bytes) return error.InvalidKey;
    var reader: Reader = .init(der);
    const element = try reader.expect(tag);
    if (!reader.done()) return error.InvalidKey;
    return element;
}

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var bytes: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
    return bytes;
}

test "a DER element and its children" {
    const bytes = hex("3003020105");
    const sequence = try top(&bytes, 0x30);
    try testing.expectEqual(0x30, sequence.tag);
    var reader: Reader = .init(sequence.body);
    const integer = try reader.expect(0x02);
    try testing.expectEqualSlices(u8, &.{0x05}, integer.body);
    try testing.expect(reader.done());
    try testing.expectEqual(null, try reader.next());
}

test "lengths are minimal and definite" {
    var long: [3 + 128]u8 = @splat(0xab);
    long[0..3].* = hex("048180");
    try testing.expectEqual(128, (try top(&long, 0x04)).body.len);

    var short_in_long_form: [3 + 127]u8 = @splat(0xab);
    short_in_long_form[0..3].* = hex("04817f");
    try testing.expectError(error.InvalidKey, top(&short_in_long_form, 0x04));
    var leading_zero: [4 + 128]u8 = @splat(0xab);
    leading_zero[0..4].* = hex("04820080");
    try testing.expectError(error.InvalidKey, top(&leading_zero, 0x04));
    try testing.expectError(error.InvalidKey, top(&hex("3080020105" ++ "0000"), 0x30));
    try testing.expectError(error.InvalidKey, top(&hex("04850000000001" ++ "00"), 0x04));
}

test "an element never reaches past its parent" {
    try testing.expectError(error.InvalidKey, top(&hex("3005020105"), 0x30));
    const sequence = try top(&hex("3003020505"), 0x30);
    var reader: Reader = .init(sequence.body);
    try testing.expectError(error.InvalidKey, reader.next());
    // A length byte promised but not there.
    var cut: Reader = .init(&hex("0482"));
    try testing.expectError(error.InvalidKey, cut.next());
    var lone_tag: Reader = .init(&hex("30"));
    try testing.expectError(error.InvalidKey, lone_tag.next());
}

test "nothing comes after the top element" {
    try testing.expectError(error.InvalidKey, top(&hex("300302010500"), 0x30));
    // Nor is the top element of another kind.
    try testing.expectError(error.InvalidKey, top(&hex("3003020105"), 0x04));
}

test "empty input, a multi-byte tag and input over 16 KiB are InvalidKey" {
    try testing.expectError(error.InvalidKey, top("", 0x30));
    try testing.expectError(error.InvalidKey, top(&hex("1f0100"), 0x1f));
    var reader: Reader = .init(&hex("1f0100"));
    try testing.expectError(error.InvalidKey, reader.next());

    // 16384 bytes: an OCTET STRING of 16380 bytes, the largest input.
    var largest: [max_input_bytes]u8 = @splat(0);
    largest[0..4].* = hex("04823ffc");
    try testing.expectEqual(16380, (try top(&largest, 0x04)).body.len);
    var over: [max_input_bytes + 1]u8 = @splat(0);
    over[0..4].* = hex("04823ffd");
    try testing.expectError(error.InvalidKey, top(&over, 0x04));
}
