//! The first half of the catalog of `redis.cmd` against the server that
//! REDIS_IMAGE names, on redis-plain: strings and counters, keys and their
//! time to live, SCAN, hashes, lists and sets, each function through its
//! result, the RESP3 forms of Redis and Valkey alike; binary values and
//! the empty string; and the blocking commands under deadlines, on a
//! server with the default `hz`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const core = @import("core");
const redis = @import("redis");
const cmd = redis.cmd;
const e2e = @import("root.zig");

fn within(io: Io, duration: Io.Duration) redis.OperationContext {
    return .of(core.Context.root.withDeadline(.after(Io.Clock.awake.now(io), duration)));
}

/// A client of redis-plain, with an arena for the replies. A call that
/// fails prints its error and diagnostics.
const Session = struct {
    io: Io,
    client: redis.Client,
    arena: std.heap.ArenaAllocator,

    fn open(s: *Session, io: Io) !void {
        s.* = .{ .io = io, .client = try .init(testing.allocator, io, .{ .url = "redis://127.0.0.1:16379" }), .arena = .init(testing.allocator) };
        errdefer s.close();
        var d: redis.Diagnostics = .{};
        s.client.connect(io, within(io, .fromSeconds(10)).ctx, &d) catch |err| {
            std.debug.print("connect: {t}: {s}\n", .{ err, d.message() });
            return err;
        };
    }

    fn close(s: *Session) void {
        s.client.deinit();
        s.arena.deinit();
    }

    fn run(s: *Session, command: anytype) !redis.Client.ReplyOf(@TypeOf(command)) {
        return s.runIn(within(s.io, .fromSeconds(10)), command);
    }

    fn runIn(s: *Session, op: redis.OperationContext, command: anytype) !redis.Client.ReplyOf(@TypeOf(command)) {
        var d: redis.Diagnostics = .{};
        return s.client.run(s.io, op, command, .{ .allocator = s.arena.allocator(), .diagnostics = &d }) catch |err| {
            std.debug.print("{s}: {t}: {s}\n", .{ command.name(), err, d.message() });
            return err;
        };
    }
};

/// A time to live of more than 0 and at most `at_most_ms`.
fn expectExpires(ttl: redis.Ttl, at_most_ms: i64) !void {
    switch (ttl) {
        .expires_in => |left| if (left.nanoseconds > 0 and left.toMilliseconds() <= at_most_ms) return,
        else => {},
    }
    std.debug.print("the time to live is {any}, where at most {d} ms was due\n", .{ ttl, at_most_ms });
    return error.TestUnexpectedResult;
}

/// The members of `got` are those of `expected`, in any order.
fn expectSet(expected: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected) |want| {
        for (got) |member| {
            if (std.mem.eql(u8, member, want)) break;
        } else {
            std.debug.print("{s} is missing\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
}

test "the string and counter commands: values, null and the empty string, binary values, times to live, NX and XX, counters" {
    try e2e.onZio(strings);
}

fn strings(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const k = "e2e:cmd:str:k";
    const n = "e2e:cmd:str:n";
    const f = "e2e:cmd:str:f";
    const a = "e2e:cmd:str:a";
    const b = "e2e:cmd:str:b";
    const bin = "e2e:cmd:str:bin";
    const empty = "e2e:cmd:str:empty";
    const none = "e2e:cmd:str:none";
    _ = try s.run(cmd.del(&.{ k, n, f, a, b, bin, empty, none }));

    try testing.expectEqualDeep(@as(?[]const u8, null), try s.run(cmd.get([]const u8, k)));
    try s.run(cmd.set(k, "v1", .{ .ttl = .fromSeconds(3600) }));
    try expectExpires(try s.run(cmd.ttl(k)), 3_600_000);
    try s.run(cmd.set(k, "v2", .{ .keep_ttl = true }));
    try expectExpires(try s.run(cmd.ttl(k)), 3_600_000);
    try testing.expectEqualDeep(@as(?[]const u8, "v2"), try s.run(cmd.get([]const u8, k)));
    try s.run(cmd.set(bin, "a\r\nb\x00c", .{}));
    try testing.expectEqualDeep(@as(?[]const u8, "a\r\nb\x00c"), try s.run(cmd.get([]const u8, bin)));
    try s.run(cmd.set(empty, "", .{}));
    try testing.expectEqualDeep(@as(?[]const u8, ""), try s.run(cmd.get([]const u8, empty)));

    try testing.expect(!try s.run(cmd.setNx(k, "v3", .{ .ttl = .fromSeconds(30) })));
    // XX without KEEPTTL drops the time to live.
    try testing.expect(try s.run(cmd.setXx(k, "v3", .{})));
    try testing.expectEqual(redis.Ttl.persistent, try s.run(cmd.ttl(k)));
    try testing.expect(!try s.run(cmd.setXx(none, "x", .{})));
    try testing.expect(try s.run(cmd.setNx(n, 7, .{})));
    try testing.expectEqualDeep(@as(?[]const u8, "v3"), try s.run(cmd.getdel([]const u8, k)));
    try testing.expectEqualDeep(@as(?[]const u8, null), try s.run(cmd.getdel([]const u8, k)));
    try testing.expectEqual(@as(?i64, 7), try s.run(cmd.getex(i64, n, .{ .ttl = .fromSeconds(60) })));
    try expectExpires(try s.run(cmd.ttl(n)), 60_000);
    try testing.expectEqual(@as(?i64, 7), try s.run(cmd.getex(i64, n, .{ .persist = true })));
    try testing.expectEqual(redis.Ttl.persistent, try s.run(cmd.ttl(n)));

    try s.run(cmd.mset(&.{ .{ .key = a, .value = "1" }, .{ .key = b, .value = "2" } }));
    try testing.expectEqualDeep(@as([]const ?[]const u8, &.{ "1", null, "2" }), try s.run(cmd.mget([]const u8, &.{ a, k, b })));
    try testing.expectEqual(@as(i64, 8), try s.run(cmd.incr(n)));
    try testing.expectEqual(@as(i64, 7), try s.run(cmd.decr(n)));
    try testing.expectEqual(@as(i64, 17), try s.run(cmd.incrby(n, 10)));
    try testing.expectEqual(@as(i64, 12), try s.run(cmd.decrby(n, 5)));
    try testing.expectEqual(@as(?i64, 12), try s.run(cmd.get(i64, n)));
    try testing.expectEqual(@as(f64, 0.5), try s.run(cmd.incrbyfloat(f, 0.5)));
    try testing.expectEqual(@as(f64, 1.75), try s.run(cmd.incrbyfloat(f, 1.25)));
}

test "the key commands: the type of each kind of key, counts, the time to live, PERSIST, RENAME, PING" {
    try e2e.onZio(keys);
}

fn keys(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const p = "e2e:cmd:keys:";
    const string = p ++ "string";
    const list = p ++ "list";
    const set = p ++ "set";
    const zset = p ++ "zset";
    const hash = p ++ "hash";
    const stream = p ++ "stream";
    const renamed = p ++ "renamed";
    const gone = p ++ "gone";
    _ = try s.run(cmd.del(&.{ string, list, set, zset, hash, stream, renamed, gone }));
    try s.run(cmd.set(string, "v", .{}));
    _ = try s.run(cmd.rpush(list, &.{"a"}));
    _ = try s.run(cmd.sadd(set, &.{"a"}));
    _ = try s.run(cmd.raw(u64, .{ "ZADD", zset, 1, "a" }));
    try s.run(cmd.hset(hash, &.{.{ .field = "f", .value = "v" }}));
    _ = try s.run(cmd.raw([]const u8, .{ "XADD", stream, "*", "f", "v" }));

    const kinds = [_]struct { []const u8, redis.KeyType }{
        .{ string, .string }, .{ list, .list }, .{ set, .set }, .{ zset, .zset }, .{ hash, .hash }, .{ stream, .stream }, .{ gone, .none },
    };
    for (kinds) |kind| try testing.expectEqual(kind[1], try s.run(cmd.keyType(kind[0])));
    try testing.expectEqual(@as(u64, 3), try s.run(cmd.exists(&.{ string, string, list, gone })));

    try testing.expectEqual(redis.Ttl.missing, try s.run(cmd.ttl(gone)));
    try testing.expectEqual(redis.Ttl.persistent, try s.run(cmd.ttl(string)));
    try testing.expect(try s.run(cmd.expire(string, .fromSeconds(100))));
    try expectExpires(try s.run(cmd.ttl(string)), 100_000);
    try testing.expect(!try s.run(cmd.expire(gone, .fromSeconds(100))));
    try testing.expect(try s.run(cmd.persist(string)));
    try testing.expect(!try s.run(cmd.persist(string)));
    try testing.expectEqual(redis.Ttl.persistent, try s.run(cmd.ttl(string)));

    try s.run(cmd.rename(string, renamed));
    try testing.expectEqual(@as(u64, 0), try s.run(cmd.exists(&.{string})));
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.ServerError, s.client.run(io, within(io, .fromSeconds(10)), cmd.rename(gone, renamed), .{ .diagnostics = &d }));
    try testing.expect(d.isCode("ERR"));
    try testing.expectEqual(@as(u64, 2), try s.run(cmd.del(&.{ renamed, list, gone })));
    try testing.expectEqual(@as(u64, 4), try s.run(cmd.unlink(&.{ set, zset, hash, stream })));
    try s.run(cmd.ping());
}

test "SCAN walks every key of a pattern a page at a time until its cursor is 0, and TYPE keeps only the keys of a type" {
    try e2e.onZio(scanning);
}

fn scanning(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const prefix = "e2e:cmd:scan:";
    const hash = prefix ++ "hash";
    var names: [30][32]u8 = undefined;
    var all: [30][]const u8 = undefined;
    var pairs: [30]redis.KeyValue = undefined;
    for (&all, &names, &pairs, 0..) |*key, *name, *pair, i| {
        key.* = try std.fmt.bufPrint(name, prefix ++ "{d}", .{i});
        pair.* = .{ .key = key.*, .value = "v" };
    }
    _ = try s.run(cmd.del(&all));
    _ = try s.run(cmd.del(&.{hash}));
    try s.run(cmd.mset(&pairs));
    try s.run(cmd.hset(hash, &.{.{ .field = "f", .value = "v" }}));

    var seen: [30]bool = @splat(false);
    var cursor: u64 = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages == 10_000) return error.TestUnexpectedResult;
        const page = try s.run(cmd.scan(.{ .cursor = cursor, .match = prefix ++ "*", .count = 10 }));
        for (page.items) |key| {
            try testing.expect(std.mem.startsWith(u8, key, prefix));
            const i = std.fmt.parseInt(usize, key[prefix.len..], 10) catch continue;
            if (i < seen.len) seen[i] = true;
        }
        cursor = page.cursor;
        if (cursor == 0) break;
    }
    for (seen) |found| try testing.expect(found);

    var found: usize = 0;
    cursor = 0;
    pages = 0;
    while (true) : (pages += 1) {
        if (pages == 10_000) return error.TestUnexpectedResult;
        const page = try s.run(cmd.scan(.{ .cursor = cursor, .match = prefix ++ "*", .count = 100, .type = .hash }));
        for (page.items) |key| try testing.expectEqualStrings(hash, key);
        found += page.items.len;
        cursor = page.cursor;
        if (cursor == 0) break;
    }
    try testing.expect(found >= 1);
}

const Profile = struct {
    name: []const u8,
    age: u8,
    plan: enum { free, pro },
    note: ?[]const u8 = null,
    @"created-at": i64 = 0,
};

test "the hash commands: a struct written and read back, an empty value, a binary field, the fields one by one, the counters, a page of HSCAN" {
    try e2e.onZio(hashes);
}

fn hashes(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const user = "e2e:cmd:hash:user";
    const missing = "e2e:cmd:hash:missing";
    const bin = "e2e:cmd:hash:bin";
    _ = try s.run(cmd.del(&.{ user, missing, bin }));

    try s.run(cmd.hset(user, Profile{ .name = "Ann", .age = 30, .plan = .pro, .note = "" }));
    try testing.expectEqualDeep(@as(?Profile, .{ .name = "Ann", .age = 30, .plan = .pro, .note = "" }), try s.run(cmd.hgetall(Profile, user)));
    try testing.expectEqualDeep(@as(?Profile, null), try s.run(cmd.hgetall(Profile, missing)));
    try testing.expectEqual(@as(?u8, 30), try s.run(cmd.hget(u8, user, "age")));
    try testing.expectEqualDeep(@as(?[]const u8, ""), try s.run(cmd.hget([]const u8, user, "note")));
    try testing.expect(try s.run(cmd.hsetnx(user, "city", "Oslo")));
    try testing.expect(!try s.run(cmd.hsetnx(user, "city", "Bergen")));
    try testing.expectEqualDeep(@as([]const ?[]const u8, &.{ "Ann", null, "Oslo" }), try s.run(cmd.hmget([]const u8, user, &.{ "name", "x", "city" })));
    try testing.expect(try s.run(cmd.hexists(user, "city")));
    try testing.expectEqual(@as(u64, 6), try s.run(cmd.hlen(user)));
    try testing.expectEqual(@as(i64, 31), try s.run(cmd.hincrby(user, "age", 1)));
    try testing.expectEqual(@as(f64, 2.5), try s.run(cmd.hincrbyfloat(user, "score", 2.5)));
    try testing.expectEqual(@as(u64, 2), try s.run(cmd.hdel(user, &.{ "city", "score", "x" })));
    try expectSet(&.{ "name", "age", "plan", "note", "created-at" }, try s.run(cmd.hkeys(user)));

    try s.run(cmd.hset(bin, &.{ .{ .field = "a\r\nb\x00c", .value = "" }, .{ .field = "k", .value = "v" } }));
    const fields = (try s.run(cmd.hgetall([]const redis.FieldValue, bin))) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), fields.len);
    for (fields) |pair| {
        if (std.mem.eql(u8, pair.field, "a\r\nb\x00c")) try testing.expectEqualStrings("", pair.value) else try testing.expectEqualStrings("v", pair.value);
    }
    var scanned: std.ArrayList([]const u8) = .empty;
    var cursor: u64 = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages == 10_000) return error.TestUnexpectedResult;
        const page = try s.run(cmd.hscan(bin, .{ .cursor = cursor, .count = 10 }));
        for (page.items) |pair| try scanned.append(s.arena.allocator(), pair.field);
        cursor = page.cursor;
        if (cursor == 0) break;
    }
    try expectSet(&.{ "a\r\nb\x00c", "k" }, scanned.items);
}

test "the list commands: pushes of strings and of other values, pops, the length, ranges, LTRIM, LREM, LINDEX, LMOVE" {
    try e2e.onZio(lists);
}

fn lists(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const q = "e2e:cmd:list:q";
    const dst = "e2e:cmd:list:dst";
    const none = "e2e:cmd:list:none";
    _ = try s.run(cmd.del(&.{ q, dst, none }));

    try testing.expectEqual(@as(u64, 3), try s.run(cmd.rpush(q, &.{ "a", "b", "c" })));
    try testing.expectEqual(@as(u64, 5), try s.run(cmd.lpush(q, .{ 42, "z" })));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "z", "42", "a", "b", "c" }), try s.run(cmd.lrange([]const u8, q, 0, -1)));
    try testing.expectEqual(@as(u64, 5), try s.run(cmd.llen(q)));
    try testing.expectEqual(@as(?i64, 42), try s.run(cmd.lindex(i64, q, 1)));
    try testing.expectEqualDeep(@as(?[]const u8, null), try s.run(cmd.lindex([]const u8, q, 99)));
    try testing.expectEqualDeep(@as(?[]const u8, "z"), try s.run(cmd.lpop([]const u8, q)));
    try testing.expectEqualDeep(@as(?[]const u8, "c"), try s.run(cmd.rpop([]const u8, q)));
    try testing.expectEqualDeep(@as(?[]const u8, null), try s.run(cmd.lpop([]const u8, none)));
    _ = try s.run(cmd.rpush(q, &.{ "a", "a" }));
    try testing.expectEqual(@as(u64, 2), try s.run(cmd.lrem(q, -2, "a")));
    try s.run(cmd.ltrim(q, 1, -1));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "a", "b" }), try s.run(cmd.lrange([]const u8, q, 0, -1)));
    try testing.expectEqualDeep(@as(?[]const u8, "a"), try s.run(cmd.lmove([]const u8, q, dst, .left, .right)));
    try testing.expectEqualDeep(@as(?[]const u8, null), try s.run(cmd.lmove([]const u8, none, dst, .left, .right)));
    try testing.expectEqualDeep(@as([]const []const u8, &.{"b"}), try s.run(cmd.lrange([]const u8, q, 0, -1)));
    try testing.expectEqualDeep(@as([]const []const u8, &.{"a"}), try s.run(cmd.lrange([]const u8, dst, 0, -1)));
}

test "the set commands: members added and removed, a set as its reply, intersection, union and difference, SPOP, a page of SSCAN" {
    try e2e.onZio(sets);
}

fn sets(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const a = "e2e:cmd:set:a";
    const b = "e2e:cmd:set:b";
    const none = "e2e:cmd:set:none";
    _ = try s.run(cmd.del(&.{ a, b, none }));

    try testing.expectEqual(@as(u64, 3), try s.run(cmd.sadd(a, &.{ "x", "y", "z" })));
    try testing.expectEqual(@as(u64, 1), try s.run(cmd.sadd(a, &.{ "x", "w" })));
    try testing.expectEqual(@as(u64, 2), try s.run(cmd.sadd(b, &.{ "y", "q" })));
    try testing.expect(try s.run(cmd.sismember(a, "x")));
    try testing.expect(!try s.run(cmd.sismember(a, "q")));
    try testing.expectEqual(@as(u64, 4), try s.run(cmd.scard(a)));
    try testing.expectEqual(@as(u64, 1), try s.run(cmd.srem(a, &.{ "w", "nope" })));
    try expectSet(&.{ "x", "y", "z" }, try s.run(cmd.smembers([]const u8, a)));
    try expectSet(&.{"y"}, try s.run(cmd.sinter([]const u8, &.{ a, b })));
    try expectSet(&.{ "x", "y", "z", "q" }, try s.run(cmd.sunion([]const u8, &.{ a, b })));
    try expectSet(&.{ "x", "z" }, try s.run(cmd.sdiff([]const u8, &.{ a, b })));
    try expectSet(&.{}, try s.run(cmd.smembers([]const u8, none)));

    const popped = (try s.run(cmd.spop([]const u8, b))) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.eql(u8, popped, "y") or std.mem.eql(u8, popped, "q"));
    try testing.expectEqual(@as(u64, 1), try s.run(cmd.scard(b)));
    try testing.expectEqualDeep(@as(?[]const u8, null), try s.run(cmd.spop([]const u8, none)));

    var scanned: std.ArrayList([]const u8) = .empty;
    var cursor: u64 = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages == 10_000) return error.TestUnexpectedResult;
        const page = try s.run(cmd.sscan(a, .{ .cursor = cursor, .match = "*", .count = 10 }));
        try scanned.appendSlice(s.arena.allocator(), page.items);
        cursor = page.cursor;
        if (cursor == 0) break;
    }
    try expectSet(&.{ "x", "y", "z" }, scanned.items);
}

/// The number after `prefix` in the text of INFO; null when it lacks it.
fn infoNumber(text: []const u8, comptime prefix: []const u8) ?u64 {
    const at = std.mem.find(u8, text, prefix) orelse return null;
    const start = at + prefix.len;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u64, text[start..end], 10) catch null;
}

/// How many BLPOP the server has run, by INFO commandstats.
fn blpopCalls(s: *Session) !u64 {
    return infoNumber(try s.run(cmd.raw([]const u8, .{ "INFO", "commandstats" })), "\r\ncmdstat_blpop:calls=") orelse 0;
}

/// A call of BLMOVE in a task of its own, with an arena of its own.
const Mover = struct {
    client: *redis.Client,
    arena: std.heap.ArenaAllocator,
    result: redis.Error!?[]const u8 = null,

    fn run(m: *Mover, io: Io) void {
        m.result = m.client.run(io, within(io, .fromSeconds(10)), cmd.blmove([]const u8, "e2e:cmd:block:src", "e2e:cmd:block:dst", .left, .right, .{ .at_most = .fromSeconds(5) }), .{ .allocator = m.arena.allocator() });
    }
};

test "blpop under a deadline returns null before it on a quiet server, and its connection stays; with too little left it is DeadlineExceeded and goes out not at all; brpop and blmove take what is there, or what another connection pushes" {
    try e2e.onZio(blocking);
}

fn blocking(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    const empty = "e2e:cmd:block:empty";
    const src = "e2e:cmd:block:src";
    const dst = "e2e:cmd:block:dst";
    _ = try s.run(cmd.del(&.{ empty, src, dst }));

    const before = s.client.stats();
    const began = Io.Clock.awake.now(io);
    try testing.expectEqualDeep(@as(?redis.Popped([]const u8), null), try s.runIn(within(io, .fromSeconds(1)), cmd.blpop([]const u8, &.{empty}, .{ .at_most = .fromSeconds(30) })));
    const took = began.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    if (took < 700 or took >= 1000) {
        std.debug.print("BLPOP under a deadline of 1 s took {d} ms\n", .{took});
        return error.TestUnexpectedResult;
    }
    const after = s.client.stats();
    try testing.expectEqual(before.connections, after.connections);
    try testing.expectEqual(@as(u64, 0), after.clears);

    const calls = try blpopCalls(&s);
    var d: redis.Diagnostics = .{};
    try testing.expectError(error.DeadlineExceeded, s.client.run(io, within(io, .fromMilliseconds(100)), cmd.blpop([]const u8, &.{empty}, .forever), .{ .allocator = s.arena.allocator(), .diagnostics = &d }));
    try testing.expect(std.mem.endsWith(u8, d.message(), "for a shorter wait, use redis.cmd.lpop"));
    try testing.expectEqual(calls, try blpopCalls(&s));

    _ = try s.run(cmd.rpush(src, &.{ "1", "2" }));
    const right: redis.Popped([]const u8) = .{ .key = src, .value = "2" };
    try testing.expectEqualDeep(@as(?redis.Popped([]const u8), right), try s.runIn(within(io, .fromSeconds(1)), cmd.brpop([]const u8, &.{ empty, src }, .{ .at_most = .fromSeconds(5) })));
    const left: redis.Popped([]const u8) = .{ .key = src, .value = "1" };
    try testing.expectEqualDeep(@as(?redis.Popped([]const u8), left), try s.runIn(within(io, .fromSeconds(1)), cmd.blpop([]const u8, &.{src}, .forever)));

    // BLMOVE waits on the empty list for what another connection pushes.
    var mover: Mover = .{ .client = &s.client, .arena = .init(testing.allocator) };
    defer mover.arena.deinit();
    var moving = try io.concurrent(Mover.run, .{ &mover, io });
    defer moving.cancel(io);
    try io.sleep(.fromMilliseconds(100), .awake);
    _ = try s.run(cmd.rpush(src, &.{"job"}));
    moving.await(io);
    try testing.expectEqualDeep(@as(?[]const u8, "job"), try mover.result);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"job"}), try s.run(cmd.lrange([]const u8, dst, 0, -1)));
}

/// Waits until the server holds a client blocked, or none, by INFO
/// clients: 10 s at most.
fn awaitBlocked(s: *Session, blocked: bool) !void {
    const give_up: core.Deadline = .after(Io.Clock.awake.now(s.io), .fromSeconds(10));
    while (true) {
        const n = infoNumber(try s.run(cmd.raw([]const u8, .{ "INFO", "clients" })), "\r\nblocked_clients:") orelse 0;
        if ((n > 0) == blocked) return;
        if (give_up.isExpired(Io.Clock.awake.now(s.io))) return error.TestTimedOut;
        try s.io.sleep(.fromMilliseconds(10), .awake);
    }
}

/// A call of BLPOP that waits forever, in a task of its own.
const Waiter = struct {
    client: *redis.Client,
    arena: std.heap.ArenaAllocator,
    result: redis.Error!?redis.Popped([]const u8) = null,
    d: redis.Diagnostics = .{},

    fn run(w: *Waiter, io: Io) void {
        w.result = w.client.run(io, .of(.root), cmd.blpop([]const u8, &.{"e2e:cmd:block:forever"}, .forever), .{ .allocator = w.arena.allocator(), .diagnostics = &w.d });
    }
};

test ".forever without a deadline waits until its task is canceled: Interrupted, and its connection closes" {
    try e2e.onZio(forever);
}

fn forever(io: Io) !void {
    var s: Session = undefined;
    try s.open(io);
    defer s.close();
    _ = try s.run(cmd.del(&.{"e2e:cmd:block:forever"}));

    // The blocked client of a run before may take the server a moment to
    // let go of.
    try awaitBlocked(&s, false);
    var waiter: Waiter = .{ .client = &s.client, .arena = .init(testing.allocator) };
    defer waiter.arena.deinit();
    var waiting = try io.concurrent(Waiter.run, .{ &waiter, io });
    defer waiting.cancel(io);
    try awaitBlocked(&s, true);
    const connections = s.client.stats().connections;
    try testing.expect(connections >= 2);
    waiting.cancel(io);
    testing.expectError(error.Interrupted, waiter.result) catch |err| {
        std.debug.print("the canceled BLPOP: {s}\n", .{waiter.d.message()});
        return err;
    };
    try testing.expectEqual(connections - 1, s.client.stats().connections);
}
