//! The plan of a claim on mongod (8.5 of the design): the `findAndModify`
//! of a claim, as `mongo.SchedulerStore` sent it through the proxy,
//! explained with the verbosity `queryPlanner`. The range on `wake_at`
//! gives both branches of its `$or` the index `scan`, on 7.0, where
//! `$expr` with `$$NOW` takes no index, as on the later versions: the
//! winning plan holds no COLLSCAN, and every IXSCAN of it, one for each
//! branch at least, is on `scan`.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const scheduler = @import("scheduler");
const mongo = @import("mongo");
const bson = @import("mongo-bson");
const e2e = @import("root.zig");
const Proxy = @import("Proxy.zig");

test "the claim uses the index scan in both branches" {
    try e2e.onZio(claimPlan);
}

fn claimPlan(io: Io) !void {
    var admin: e2e.Admin = undefined;
    try admin.open(io, e2e.servers.plain);
    defer admin.close();
    var proxy: Proxy = undefined;
    try proxy.start(testing.io, testing.allocator, e2e.servers.plain_port);
    defer proxy.stop();
    var uri_buffer: [96]u8 = undefined;
    var client: mongo.Client = try .init(testing.allocator, io, .{ .uri = try proxy.uri(&uri_buffer, "appName=scheduler-e2e-explain") });
    defer client.deinit();
    try client.connect(io, e2e.within(io, .fromSeconds(30)), null);
    var name_buffer: [64]u8 = undefined;
    const database = try e2e.freshName(&name_buffer, "explain");
    try admin.dropDatabase(io, database);
    defer admin.dropDatabase(io, database) catch |err| std.debug.print("drop of {s}: {t}\n", .{ database, err });
    var store: mongo.SchedulerStore = try .init(testing.allocator, io, &client, .{ .database = database });
    defer store.deinit();
    try store.ensureIndexes(io, e2e.within(io, .fromSeconds(30)));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = store.store();

    // Records of both branches and of a job the claim does not name, half
    // of them due; the declared record of the job of any key too.
    for ([_][]const u8{ "e2e-every", "e2e-keyed", "e2e-other" }) |job| {
        for (0..41) |i| {
            var key_buffer: [8]u8 = undefined;
            const key = if (i == 40) "" else try std.fmt.bufPrint(&key_buffer, "k{d}", .{i});
            var life: scheduler.Life = undefined;
            io.random(&life);
            const when: scheduler.Store.Moment = .{ .after = if (i % 2 == 0) .zero else .fromSeconds(3600) };
            _ = try s.create(io, e2e.within(io, .fromSeconds(30)), &.{ .job = job, .key = key, .life = life, .plan = "", .payload = "{}", .run_at = when }, .{ .allocator = arena });
        }
    }

    proxy.copyNext("findAndModify");
    var tag: scheduler.Store.Tag = undefined;
    io.random(&tag);
    const claimed = try s.claim(io, e2e.within(io, .fromSeconds(30)), &.{
        .owner = "e2e-explain/0",
        .any_key = &.{"e2e-every"},
        .keyed_only = &.{"e2e-keyed"},
        .max = 1,
        .lease = .fromSeconds(60),
        .tag = tag,
    }, .{ .allocator = arena });
    try testing.expectEqual(@as(usize, 1), claimed.claimed.len);
    const sent = proxy.takeCopy() orelse {
        std.debug.print("the proxy saw no findAndModify of the claim\n", .{});
        return error.TestUnexpectedResult;
    };
    defer testing.allocator.free(sent);

    // The command as the store wrote it, without what the client adds and
    // explain does not take.
    var b: bson.Builder = .init(arena);
    try b.beginDocument("explain");
    var it = (try bson.RawDocument.init(sent)).iterator();
    while (try it.next()) |element| {
        const added = for ([_][]const u8{ "$db", "maxTimeMS", "writeConcern" }) |name| {
            if (std.mem.eql(u8, element.key, name)) break true;
        } else false;
        if (!added) try b.putValue(element.key, element.value);
    }
    try b.end();
    try b.putString("verbosity", "queryPlanner");
    const reply = try admin.reply(io, database, (try b.finish()).raw());
    defer reply.deinit();
    const plan = (try reply.raw().getPath("queryPlanner.winningPlan")) orelse {
        std.debug.print("explain gave no queryPlanner.winningPlan: {f}\n", .{reply.raw()});
        return error.TestUnexpectedResult;
    };
    if (plan != .document) return error.TestUnexpectedResult;
    var stages: Stages = .{};
    try stages.walk(arena, plan.document);
    std.debug.print("  the winning plan of the claim: {s}\n", .{stages.summary.items});
    if (stages.wrong or stages.ixscans < 2) {
        std.debug.print("a COLLSCAN, another index or a branch without an IXSCAN: {f}\n", .{plan.document});
        return error.TestUnexpectedResult;
    }
}

/// The stages of a plan, whatever the form of its explain: every document
/// in it with a `stage`, in order.
const Stages = struct {
    summary: std.ArrayList(u8) = .empty,
    ixscans: u32 = 0,
    /// A COLLSCAN, or an IXSCAN on another index than `scan`.
    wrong: bool = false,

    fn walk(s: *Stages, a: std.mem.Allocator, doc: bson.RawDocument) !void {
        if (try doc.get("stage")) |stage| if (stage == .string) {
            const index = if (try doc.get("indexName")) |name| (if (name == .string) name.string else "?") else "";
            if (s.summary.items.len > 0) try s.summary.appendSlice(a, ", ");
            try s.summary.print(a, "{s}{s}{s}", .{ stage.string, if (index.len > 0) " " else "", index });
            if (std.mem.eql(u8, stage.string, "COLLSCAN")) s.wrong = true;
            if (std.mem.eql(u8, stage.string, "IXSCAN")) {
                s.ixscans += 1;
                if (!std.mem.eql(u8, index, "scan")) s.wrong = true;
            }
        };
        var it = doc.iterator();
        while (try it.next()) |element| switch (element.value) {
            .document, .array => |inner| try s.walk(a, inner),
            else => {},
        };
    }
};
