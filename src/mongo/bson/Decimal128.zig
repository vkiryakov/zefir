//! A Decimal128: a 128-bit decimal floating-point number of IEEE 754-2008,
//! kept as its 16 bytes, little-endian.

const Decimal128 = @This();

bytes: [16]u8,
