//! Fuzzing of the OP_MSG readers. `zig build test` runs each corpus entry
//! once, as a regression test; `zig build test --fuzz=1M` runs the fuzzer.
//! The property: any bytes, read as a reply or as a request, give a
//! message, `error.ProtocolViolation` or `error.EndOfStream`, never a
//! panic, and every document a reader hands out is valid BSON. Each input
//! is tried again with its header set to its own length and to OP_MSG,
//! so that the fuzzer reaches the sections at once.

const std = @import("std");
const testing = std.testing;
const bson = @import("mongo-bson");
const codec = bson.codec;
const opmsg = @import("opmsg.zig");
const vectors = bson.testing.vectors;

fn fuzzReaders(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];
    try check(input);
    if (input.len >= opmsg.header_len) {
        std.mem.writeInt(i32, input[0..4], @intCast(input.len), .little);
        std.mem.writeInt(i32, input[12..16], opmsg.op_code, .little);
        try check(input);
    }
}

fn check(bytes: []const u8) !void {
    // The reply answers the request it says it answers.
    const answers: i32 = if (bytes.len >= 12) std.mem.readInt(i32, bytes[8..12], .little) else 0;
    var r: std.Io.Reader = .fixed(bytes);
    if (opmsg.readReply(&r, testing.allocator, .{ .request_id = answers, .max_message_size = 8192 }, null)) |reply| {
        defer reply.deinit();
        try codec.validateDepth(reply.bytes, codec.max_levels);
    } else |err| try testing.expect(err == error.ProtocolViolation or err == error.EndOfStream);

    r = .fixed(bytes);
    if (opmsg.readRequest(&r, testing.allocator, 8192, null)) |request| {
        defer request.deinit();
        try codec.validateDepth(request.body.bytes, codec.max_levels);
        var sequences = request.sequences();
        while (sequences.next()) |sequence| {
            var docs = sequence.documents();
            while (docs.next()) |doc| try codec.validateDepth(doc.bytes, codec.max_levels);
        }
    } else |err| try testing.expect(err == error.ProtocolViolation or err == error.EndOfStream);
}

/// A message that answers request 7, with the true length.
fn message(comptime op_code: i32, comptime flags: u32, comptime sections: []const u8) []const u8 {
    return comptime little(i32, opmsg.header_len + 4 + sections.len) ++ little(i32, 1) ++ little(i32, 7) ++
        little(i32, op_code) ++ little(u32, flags) ++ sections;
}

fn kind1(comptime identifier: []const u8, comptime docs: []const u8) []const u8 {
    return comptime "\x01" ++ little(i32, 4 + identifier.len + 1 + docs.len) ++ identifier ++ "\x00" ++ docs;
}

fn little(comptime T: type, comptime n: T) []const u8 {
    return comptime &std.mem.toBytes(std.mem.nativeToLittle(T, n));
}

/// A corpus entry: `Smith.slice` reads a little-endian u32 length first.
fn sample(comptime raw: []const u8) []const u8 {
    return comptime little(u32, raw.len) ++ raw;
}

const ok = bson.literal(.{ .ok = 1.0 }).bytes;
const insert = bson.literal(.{ .insert = "users", .@"$db" = "app" }).bytes;
const ann = bson.literal(.{ .name = "Ann" }).bytes;

const corpus = make: {
    @setEvalBranchQuota(100_000);
    const op = opmsg.op_code;
    break :make [_][]const u8{
        sample(message(op, 0, "\x00" ++ ok)),
        sample(message(op, 0, "\x00" ++ vectors.reply)),
        sample(message(op, 0, "\x00" ++ insert ++ kind1("documents", ann ++ ann))),
        sample(message(op, 0, kind1("documents", ann) ++ "\x00" ++ insert)),
        sample(message(op, opmsg.flag_more_to_come, "\x00" ++ ok)),
        sample(message(op, opmsg.flag_checksum_present, "\x00" ++ ok ++ "\x00\x00\x00\x00")),
        sample(message(op, 1 << 5, "\x00" ++ ok)),
        sample(message(op, 0, kind1("documents", ann))),
        sample(message(op, 0, "\x00" ++ ok ++ "\x00" ++ ok)),
        sample(message(op, 0, "\x00" ++ insert ++ "\x01\x09\x00\x00\x00docsX")),
        sample(message(op, 0, "\x00" ++ insert ++ kind1("documents", ann ++ "\x10\x00\x00"))),
        sample(message(op, 0, "\x00\x08\x00\x00\x00\x20a\x00\x00")),
        sample(message(op, 0, "\x02" ++ ok)),
        sample(message(2004, 0, "\x00" ++ ok)),
        sample(message(op, 0, "\x00" ++ ok)[0..20]),
        sample(little(i32, 25) ++ little(i32, 1) ++ little(i32, 7) ++ little(i32, op) ++ little(u32, 0) ++ "\x00" ++ ok),
        sample(""),
    };
};

test "fuzz the OP_MSG readers" {
    try testing.fuzz({}, fuzzReaders, .{ .corpus = &corpus });
}
