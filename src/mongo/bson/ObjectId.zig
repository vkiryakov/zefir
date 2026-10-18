//! An ObjectId: the 12-byte id that MongoDB gives documents by default.

const ObjectId = @This();

bytes: [12]u8,
