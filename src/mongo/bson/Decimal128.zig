//! A Decimal128: a 128-bit decimal floating-point number of IEEE 754-2008
//! in its binary integer encoding, kept as its 16 bytes, little-endian.
//! zefir does no arithmetic on it: it reads, writes and prints it.

const std = @import("std");
const Decimal128 = @This();

bytes: [16]u8,

/// The largest coefficient: 34 nines. A larger one reads as 0.
const max_coefficient: u128 = std.math.pow(u128, 10, 34) - 1;
const exponent_bias = 6176;

/// Prints the number as the spec's scientific string: "1.5", "-0",
/// "0.001234", "1.234E-7", "1E+3", "Infinity", "NaN".
pub fn format(d: Decimal128, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const bits = std.mem.readInt(u128, &d.bytes, .little);
    const negative = bits >> 127 == 1;
    switch (@as(u5, @truncate(bits >> 122))) {
        0b11111 => return w.writeAll("NaN"),
        0b11110 => return w.writeAll(if (negative) "-Infinity" else "Infinity"),
        else => {},
    }
    var exponent: i32 = undefined;
    var coefficient: u128 = undefined;
    if ((bits >> 125) & 0b11 == 0b11) {
        // The coefficient would begin with the bits 100 and exceed 34
        // digits: the number is 0.
        exponent = @intCast((bits >> 111) & 0x3fff);
        coefficient = 0;
    } else {
        exponent = @intCast((bits >> 113) & 0x3fff);
        coefficient = bits & ((1 << 113) - 1);
        if (coefficient > max_coefficient) coefficient = 0;
    }
    exponent -= exponent_bias;

    if (negative) try w.writeByte('-');
    var buffer: [34]u8 = undefined;
    const digits = std.fmt.bufPrint(&buffer, "{d}", .{coefficient}) catch unreachable;
    const count: i32 = @intCast(digits.len);
    // The exponent of the number written with one digit before the point.
    const adjusted = exponent + count - 1;
    if (exponent <= 0 and adjusted >= -6) {
        if (exponent == 0) return w.writeAll(digits);
        const before_point = count + exponent;
        if (before_point > 0) {
            const at: usize = @intCast(before_point);
            try w.writeAll(digits[0..at]);
            try w.writeByte('.');
            try w.writeAll(digits[at..]);
        } else {
            try w.writeAll("0.");
            try w.splatByteAll('0', @intCast(-before_point));
            try w.writeAll(digits);
        }
        return;
    }
    try w.writeByte(digits[0]);
    if (digits.len > 1) {
        try w.writeByte('.');
        try w.writeAll(digits[1..]);
    }
    try w.print("E{c}{d}", .{ @as(u8, if (adjusted < 0) '-' else '+'), @abs(adjusted) });
}
