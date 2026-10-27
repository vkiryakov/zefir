//! For the tests of `mongo.SchedulerStore`: a `mongo.testing.Script` that
//! answers in the order given, served on loopback, a client connected to
//! it, the store on the client, and helpers that read what the store sent.
//! Its parts point into it: start it in place.
//!
//! ```zig
//! var f: Fixture = .{};
//! try f.start(&.{.{ .reply = ok }});
//! defer f.stop();
//! ```

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const bson = @import("mongo-bson");
const core = @import("core");
const scheduler = @import("scheduler");
const mongo = @import("../root.zig");
const Script = mongo.testing.Script;
const Served = @import("Served.zig");
const SchedulerStore = mongo.SchedulerStore;

pub const Fixture = struct {
    answers: [24]Script.Answer = undefined,
    queue: Script.Queue = undefined,
    served: Served = undefined,
    store: SchedulerStore = undefined,
    /// The memory of the replies that tests build, and of the results of
    /// the store's calls.
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    diagnostics: scheduler.Diagnostics = .{},

    /// Serves `answers`, one per command in their order, and makes the
    /// store on database "app" with the default collections.
    pub fn start(f: *Fixture, answers: []const Script.Answer) !void {
        @memcpy(f.answers[0..answers.len], answers);
        f.queue = .{ .answers = f.answers[0..answers.len] };
        try f.served.start(testing.io, f.queue.handler(), .{});
        errdefer f.served.stop(testing.io);
        f.store = try .init(testing.allocator, testing.io, f.served.client(), .{ .database = "app" });
    }

    pub fn stop(f: *Fixture) void {
        f.store.deinit();
        f.served.stop(testing.io);
        f.arena.deinit();
    }

    pub fn a(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }

    /// The options of a call: the arena and the diagnostics.
    pub fn call(f: *Fixture) scheduler.Store.CallOptions {
        return .{ .allocator = f.a(), .diagnostics = &f.diagnostics };
    }

    /// Command `i` of the journal, from 0.
    pub fn entry(f: *Fixture, i: usize) !Script.Entry {
        return f.served.script.entry(testing.io, i);
    }

    /// Fails unless the journal holds exactly the commands `names`.
    pub fn expectCommands(f: *Fixture, names: []const []const u8) !void {
        const got = f.served.script.received(testing.io);
        for (names, 0..) |want, i| {
            const e = f.entry(i) catch {
                std.debug.print("the journal holds {d} commands, not {d}\n", .{ got, names.len });
                return error.TestUnexpectedResult;
            };
            if (!std.mem.eql(u8, e.name, want)) {
                std.debug.print("command {d} is '{s}', not '{s}'\n", .{ i, e.name, want });
                return error.TestUnexpectedResult;
            }
        }
        try testing.expectEqual(names.len, got);
    }
};

/// A context without a deadline: the client sends no `maxTimeMS`, so the
/// bodies compare whole.
pub const no_deadline: core.Context = .root;

/// Fails unless `actual` is `expected` byte for byte; prints both as
/// Extended JSON.
pub fn expectDoc(expected: bson.RawDocument, actual: bson.RawDocument) !void {
    if (std.mem.eql(u8, expected.bytes, actual.bytes)) return;
    std.debug.print("expected {f}\n     got {f}\n", .{ expected, actual });
    return error.TestUnexpectedResult;
}

/// The document at `path` of `doc`; another value fails the test.
pub fn docAt(doc: bson.RawDocument, path: []const u8) !bson.RawDocument {
    const value = (try doc.getPath(path)) orelse {
        std.debug.print("no {s} in {f}\n", .{ path, doc });
        return error.TestUnexpectedResult;
    };
    return switch (value) {
        .document, .array => |d| d,
        else => error.TestUnexpectedResult,
    };
}

/// The one item of the write in `entry`, in its section `identifier`.
pub fn item(entry: Script.Entry, identifier: []const u8) !bson.RawDocument {
    const sequence = entry.sequence orelse return error.TestNoSequence;
    try testing.expectEqualStrings(identifier, sequence.identifier);
    var docs = sequence.documents();
    const doc = docs.next() orelse return error.TestNoItem;
    try testing.expect(docs.next() == null);
    return doc;
}

/// The reply of a findAndModify that found `value`, or none.
pub fn modified(a: std.mem.Allocator, value: ?bson.RawDocument) !bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.beginDocument("lastErrorObject");
    try b.putInt32("n", if (value != null) 1 else 0);
    try b.putBoolean("updatedExisting", value != null);
    try b.end();
    if (value) |doc| try b.putDocument("value", doc) else try b.putNull("value");
    try b.putDouble("ok", 1);
    return (try b.finish()).raw();
}

/// The reply of a find or an aggregate whose cursor holds `docs`, all in
/// its first batch.
pub fn found(a: std.mem.Allocator, ns: []const u8, docs: []const bson.RawDocument) !bson.RawDocument {
    return Script.cursorReply(a, ns, 0, .first, docs);
}

/// A record of the collection of jobs as the store writes it, pending;
/// `extra` adds fields at the end.
pub fn pendingDoc(a: std.mem.Allocator, job: []const u8, key: []const u8, life_text: []const u8, extra: anytype) !bson.RawDocument {
    var b: bson.Builder = .init(a);
    try b.putString("_id", try std.fmt.allocPrint(a, "{s}/{s}", .{ job, key }));
    try b.putString("job", job);
    try b.putString("key", key);
    try b.putString("life", life_text);
    try b.putString("plan", "");
    try b.putString("payload", "{}");
    try b.putString("state", "pending");
    try b.putDateTime("scheduled_at", .{ .milliseconds = 1_793_000_000_000 });
    try b.putDateTime("run_at", .{ .milliseconds = 1_793_000_000_000 });
    try b.putDateTime("wake_at", .{ .milliseconds = 1_793_000_000_000 });
    try b.putInt32("attempt", 0);
    try b.putInt64("fence", 0);
    try b.putInt64("revision", 0);
    try b.putDateTime("created_at", .{ .milliseconds = 1_792_999_000_000 });
    try b.putDateTime("updated_at", .{ .milliseconds = 1_792_999_000_000 });
    inline for (@typeInfo(@TypeOf(extra)).@"struct".field_names) |field| try b.put(field, @field(extra, field));
    return (try b.finish()).raw();
}

/// A life of 16 bytes and its 32 hex digits.
pub const life: scheduler.Life = .{ 0x9f, 0x1c, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0xff };
pub const life_hex = "9f1c000102030405060708090a0b0cff";
/// A tag of a write and its 32 hex digits.
pub const tag: scheduler.Store.Tag = @splat(0xab);
pub const tag_hex = "abababababababababababababababab";

/// `{w: 1, j: true}`: the write concern of the store by default.
pub const journal = bson.literal(.{ .w = 1, .j = true });
