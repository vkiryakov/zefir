//! Tests of the result types of the catalog, each read from the frame its
//! command answers (design §4), and of `StreamId.parse` on bad input.

const std = @import("std");
const testing = std.testing;
const resp = @import("../resp.zig");
const types = @import("types.zig");
const Diagnostics = @import("../errors.zig").Diagnostics;

const StreamId = types.StreamId;

const Profile = struct { name: []const u8, age: u8 = 0 };

/// Reads the reply of `bytes` into `T` in `arena`; the reply must end
/// where `bytes` do.
fn read(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) !T {
    var in: std.Io.Reader = .fixed(bytes);
    var reader: resp.Reader = .init(&in, 1 << 20);
    var diagnostics: Diagnostics = .{};
    const result = resp.decode(T, &reader, arena, &diagnostics) catch |err| {
        std.debug.print("{s} into {s}: {t}: {s}\n", .{ bytes, @typeName(T), err, diagnostics.message() });
        return err;
    };
    try testing.expectEqual(bytes.len, in.seek);
    return result;
}

/// Expects UnexpectedReply for the reply of `bytes`, read to its end, and
/// returns the text of the diagnostics.
fn expectUnexpected(comptime T: type, bytes: []const u8) !Diagnostics {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: std.Io.Reader = .fixed(bytes);
    var reader: resp.Reader = .init(&in, 1 << 20);
    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.UnexpectedReply, resp.decode(T, &reader, arena.allocator(), &diagnostics));
    try testing.expectEqual(bytes.len, in.seek);
    return diagnostics;
}

test "Ttl: -2 is missing, -1 persistent, and milliseconds the time left" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(types.Ttl.missing, try read(types.Ttl, a, ":-2\r\n"));
    try testing.expectEqual(types.Ttl.persistent, try read(types.Ttl, a, ":-1\r\n"));
    try testing.expectEqual(types.Ttl{ .expires_in = .fromMilliseconds(1500) }, try read(types.Ttl, a, ":1500\r\n"));
    try testing.expectEqual(types.Ttl{ .expires_in = .zero }, try read(types.Ttl, a, ":0\r\n"));
    const d = try expectUnexpected(types.Ttl, ":-3\r\n");
    try testing.expectEqualStrings("the reply is an integer, and the call asked for cmd.types.Ttl", d.message());
    _ = try expectUnexpected(types.Ttl, "$3\r\nabc\r\n");
}

test "KeyType: the names of TYPE, and other for the types of modules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(types.KeyType.string, try read(types.KeyType, a, "+string\r\n"));
    try testing.expectEqual(types.KeyType.none, try read(types.KeyType, a, "+none\r\n"));
    try testing.expectEqual(types.KeyType.zset, try read(types.KeyType, a, "+zset\r\n"));
    try testing.expectEqual(types.KeyType.stream, try read(types.KeyType, a, "+stream\r\n"));
    try testing.expectEqual(types.KeyType.hash, try read(types.KeyType, a, "$4\r\nhash\r\n"));
    try testing.expectEqual(types.KeyType.other, try read(types.KeyType, a, "+ReJSON-RL\r\n"));
    try testing.expectEqual(types.KeyType.other, try read(types.KeyType, a, "+vectorset\r\n"));
    try testing.expectEqual(types.KeyType.other, try read(types.KeyType, a, "+\r\n"));
    _ = try expectUnexpected(types.KeyType, ":1\r\n");
}

test "StreamId.parse takes <ms>-<seq>, and anything else is an error, never a panic" {
    try testing.expectEqual(StreamId{ .ms = 1526919030474, .seq = 55 }, try StreamId.parse("1526919030474-55"));
    try testing.expectEqual(StreamId.zero, try StreamId.parse("0-0"));
    try testing.expectEqual(StreamId{ .ms = std.math.maxInt(u64), .seq = std.math.maxInt(u64) }, try StreamId.parse("18446744073709551615-18446744073709551615"));
    for ([_][]const u8{ "1526919030474", "18446744073709551616-0", "0-18446744073709551616", "1-", "-1-0", "-", "a-b", "", "1-2-3", "01-0", "1-02", " 1-0", "1-0 ", "+1-0", "1--0", "*", "$", ">" }) |text| {
        testing.expectError(error.InvalidStreamId, StreamId.parse(text)) catch |err| {
            std.debug.print("parsed: {s}\n", .{text});
            return err;
        };
    }
}

test "StreamId prints as the server writes it" {
    var buffer: [64]u8 = undefined;
    const id: StreamId = .{ .ms = 1526919030474, .seq = 55 };
    try testing.expectEqualStrings("1526919030474-55", try std.fmt.bufPrint(&buffer, "{f}", .{id}));
    try testing.expectEqualStrings("0-0", try std.fmt.bufPrint(&buffer, "{f}", .{StreamId.zero}));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(id, try read(StreamId, arena.allocator(), "$16\r\n1526919030474-55\r\n"));
    _ = try expectUnexpected(StreamId, "$3\r\n1-x\r\n");
    _ = try expectUnexpected(StreamId, ":1\r\n");
}

test "Popped, Scored and ScanPage: pairs and pages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const popped = (try read(?types.Popped([]const u8), a, "*2\r\n$5\r\nqueue\r\n$3\r\njob\r\n")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("queue", popped.key);
    try testing.expectEqualStrings("job", popped.value);
    try testing.expectEqual(@as(?types.Popped(i64), null), try read(?types.Popped(i64), a, "_\r\n"));
    const d = try expectUnexpected(types.Popped([]const u8), "*3\r\n$1\r\na\r\n$1\r\nb\r\n$1\r\nc\r\n");
    try testing.expectEqualStrings("the reply is an array of 3 elements, and the call asked for cmd.types.Popped([]const u8)", d.message());

    const scored = try read(types.Scored([]const u8), a, "*2\r\n$3\r\nann\r\n,12.5\r\n");
    try testing.expectEqualStrings("ann", scored.member);
    try testing.expectEqual(@as(f64, 12.5), scored.score);
    // ZRANGE … WITHSCORES in RESP3: an array of pairs.
    const range = try read([]const types.Scored([]const u8), a, "*2\r\n*2\r\n$3\r\nann\r\n,12.5\r\n*2\r\n$3\r\nbob\r\n:1\r\n");
    try testing.expectEqual(@as(usize, 2), range.len);
    try testing.expectEqualStrings("bob", range[1].member);
    try testing.expectEqual(@as(f64, 1), range[1].score);

    // The cursor is a bulk string on the wire.
    const keys = try read(types.ScanPage([]const u8), a, "*2\r\n$2\r\n17\r\n*2\r\n$1\r\na\r\n$1\r\nb\r\n");
    try testing.expectEqual(@as(u64, 17), keys.cursor);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b" }), keys.items);
    // ZSCAN and HSCAN: a flat array of pairs, scores as bulk strings.
    const members = try read(types.ScanPage(types.Scored([]const u8)), a, "*2\r\n$1\r\n0\r\n*4\r\n$3\r\nann\r\n$4\r\n12.5\r\n$3\r\nbob\r\n$3\r\ninf\r\n");
    try testing.expectEqual(@as(u64, 0), members.cursor);
    try testing.expectEqual(@as(usize, 2), members.items.len);
    try testing.expectEqualStrings("ann", members.items[0].member);
    try testing.expectEqual(@as(f64, 12.5), members.items[0].score);
    try testing.expectEqual(std.math.inf(f64), members.items[1].score);
    const fields = try read(types.ScanPage(types.FieldValue), a, "*2\r\n$1\r\n5\r\n*4\r\n$1\r\nf\r\n$1\r\nv\r\n$1\r\ng\r\n$0\r\n\r\n");
    try testing.expectEqualDeep(@as([]const types.FieldValue, &.{ .{ .field = "f", .value = "v" }, .{ .field = "g", .value = "" } }), fields.items);
    _ = try expectUnexpected(types.ScanPage(types.FieldValue), "*2\r\n$1\r\n0\r\n*3\r\n$1\r\nf\r\n$1\r\nv\r\n$1\r\ng\r\n");
    _ = try expectUnexpected(types.ScanPage([]const u8), "*2\r\n$1\r\nx\r\n*0\r\n");
}

test "Entry: an id and the fields as a struct, null when the entry was deleted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry = try read(types.Entry(Profile), a, "*2\r\n$15\r\n1526919030474-0\r\n*4\r\n$4\r\nname\r\n$3\r\nAnn\r\n$3\r\nage\r\n$2\r\n30\r\n");
    try testing.expectEqual(StreamId{ .ms = 1526919030474, .seq = 0 }, entry.id);
    const ann = entry.fields orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Ann", ann.name);
    try testing.expectEqual(@as(u8, 30), ann.age);
    const deleted = try read(types.Entry(Profile), a, "*2\r\n$15\r\n1526919030474-0\r\n_\r\n");
    try testing.expect(deleted.fields == null);
    const any = try read(types.Entry([]const types.FieldValue), a, "*2\r\n$3\r\n1-1\r\n*2\r\n$1\r\nk\r\n$1\r\nv\r\n");
    try testing.expectEqualDeep(@as(?[]const types.FieldValue, &.{.{ .field = "k", .value = "v" }}), any.fields);
}

test "PendingSummary, Pending and Claimed: the replies of XPENDING and XAUTOCLAIM" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const summary = try read(types.PendingSummary, a, "*4\r\n:2\r\n$15\r\n1526919030474-0\r\n$15\r\n1526919030474-1\r\n*1\r\n*2\r\n$5\r\nalice\r\n$1\r\n2\r\n");
    try testing.expectEqual(@as(u64, 2), summary.count);
    try testing.expectEqual(@as(?StreamId, .{ .ms = 1526919030474, .seq = 0 }), summary.first);
    try testing.expectEqual(@as(?StreamId, .{ .ms = 1526919030474, .seq = 1 }), summary.last);
    try testing.expectEqual(@as(usize, 1), summary.consumers.len);
    try testing.expectEqualStrings("alice", summary.consumers[0].name);
    try testing.expectEqual(@as(u64, 2), summary.consumers[0].count);
    const empty = try read(types.PendingSummary, a, "*4\r\n:0\r\n_\r\n_\r\n_\r\n");
    try testing.expectEqualDeep(types.PendingSummary{ .count = 0, .first = null, .last = null, .consumers = &.{} }, empty);

    const pending = try read(types.Pending, a, "*4\r\n$15\r\n1526919030474-0\r\n$5\r\nalice\r\n:1500\r\n:3\r\n");
    try testing.expectEqual(StreamId{ .ms = 1526919030474, .seq = 0 }, pending.id);
    try testing.expectEqualStrings("alice", pending.consumer);
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(1500), pending.idle);
    try testing.expectEqual(@as(u64, 3), pending.deliveries);
    _ = try expectUnexpected(types.Pending, "*4\r\n$3\r\n1-0\r\n$5\r\nalice\r\n:-1\r\n:3\r\n");

    const claimed = try read(types.Claimed(Profile), a, "*3\r\n$3\r\n0-0\r\n*1\r\n*2\r\n$3\r\n5-1\r\n*2\r\n$4\r\nname\r\n$3\r\nBob\r\n*1\r\n$3\r\n4-0\r\n");
    try testing.expectEqual(StreamId.zero, claimed.next);
    try testing.expectEqual(@as(usize, 1), claimed.entries.len);
    try testing.expectEqual(StreamId{ .ms = 5, .seq = 1 }, claimed.entries[0].id);
    const bob = claimed.entries[0].fields orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Bob", bob.name);
    try testing.expectEqualDeep(@as([]const StreamId, &.{.{ .ms = 4, .seq = 0 }}), claimed.deleted);
}

test "the result types pass the comptime check, and say whether they take memory" {
    comptime {
        resp.checkReply(types.Ttl, "test");
        resp.checkReply(types.KeyType, "test");
        resp.checkReply(?types.Popped([]const u8), "test");
        resp.checkReply([]const types.Scored([]const u8), "test");
        resp.checkReply(types.ScanPage(types.FieldValue), "test");
        resp.checkReply([]const types.Entry(Profile), "test");
        resp.checkReply(types.PendingSummary, "test");
        resp.checkReply([]const types.Pending, "test");
        resp.checkReply(types.Claimed(Profile), "test");
        std.debug.assert(!resp.needsAllocator(types.Ttl));
        std.debug.assert(!resp.needsAllocator(types.KeyType));
        std.debug.assert(!resp.needsAllocator(StreamId));
        std.debug.assert(!resp.needsAllocator(types.Scored(i64)));
        std.debug.assert(resp.needsAllocator(types.Scored([]const u8)));
        std.debug.assert(resp.needsAllocator(types.Popped(i64)));
        std.debug.assert(resp.needsAllocator(types.ScanPage(i64)));
        std.debug.assert(resp.needsAllocator(types.Pending));
    }
}
