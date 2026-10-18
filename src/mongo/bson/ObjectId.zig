//! An ObjectId: the 12-byte id that MongoDB gives documents by default.
//! The bytes are, as the ObjectId spec lays them out: the seconds since
//! the Unix epoch when it was made (4 bytes, big-endian), 5 random bytes
//! of the generator that made it, and that generator's counter (3 bytes,
//! big-endian).
//!
//! ```zig
//! var ids: bson.ObjectId.Generator = .init(io); // one for the application
//! const id = ids.next(io);
//! std.debug.print("{f}\n", .{id}); // 24 hex digits
//! ```

const std = @import("std");
const ObjectId = @This();

bytes: [12]u8,

/// The ObjectId that 24 hex digits spell, in either case.
pub fn parseHex(text: []const u8) error{InvalidObjectId}!ObjectId {
    if (text.len != 24) return error.InvalidObjectId;
    var id: ObjectId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, text) catch return error.InvalidObjectId;
    return id;
}

/// Prints the 24 hex digits, in lower case: `{f}`.
pub fn format(id: ObjectId, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(&std.fmt.bytesToHex(id.bytes, .lower));
}

/// When the id was made, in seconds since the Unix epoch.
pub fn timestamp(id: ObjectId) u32 {
    return std.mem.readInt(u32, id.bytes[0..4], .big);
}

/// Makes ObjectIds that no other generator makes: its 5 random bytes go
/// into each id it makes, and its counter tells apart ids of one second.
/// It holds no global state, so an application keeps one and passes a
/// pointer to it around; any number of tasks and threads may share it.
pub const Generator = struct {
    /// The same in every id this generator makes.
    random: [5]u8,
    /// The low 24 bits of it are the counter of the next id. It starts at
    /// a random value, as the spec asks.
    counter: std.atomic.Value(u32),

    pub fn init(io: std.Io) Generator {
        var seed: [8]u8 = undefined;
        io.random(&seed);
        return .{ .random = seed[0..5].*, .counter = .init(std.mem.readInt(u24, seed[5..8], .big)) };
    }

    /// A new id, with the seconds of the real-time clock of `io`.
    pub fn next(g: *Generator, io: std.Io) ObjectId {
        const seconds = std.Io.Clock.real.now(io).toSeconds();
        // The counter wraps around: past 0xFFFFFF the 24 bits start at 0.
        const count = g.counter.fetchAdd(1, .monotonic);
        var id: ObjectId = undefined;
        // After 2106 the seconds wrap around too, as the spec allows.
        std.mem.writeInt(u32, id.bytes[0..4], @truncate(@as(u64, @bitCast(seconds))), .big);
        id.bytes[4..9].* = g.random;
        std.mem.writeInt(u24, id.bytes[9..12], @truncate(count), .big);
        return id;
    }
};
