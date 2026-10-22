//! What the tests of the registry and of collections share: the result of
//! a call made in a task of its own, a wait on the clock for a condition,
//! and a registry with one tenant on a fake driver.

const std = @import("std");
const Io = std.Io;
const bson = @import("mongo-bson");
const odm = @import("../root.zig");
const FakeDriver = odm.testing.FakeDriver;

/// A registry on a fake driver, with the connection "shared-1" of
/// fake://shared and the tenant "acme" on the database "acme". It stays
/// where it is once `init` ran; give its sessions and cursors back before
/// its `deinit`.
pub const Shop = struct {
    fake: FakeDriver,
    registry: odm.Registry,
    /// The length of the journal after `init`.
    mark: usize,

    pub fn init(shop: *Shop, io: Io, options: odm.Registry.Options) !void {
        shop.fake = .init(std.testing.allocator);
        errdefer shop.fake.deinit();
        shop.registry = .init(std.testing.allocator, io, shop.fake.driver(), options);
        errdefer shop.registry.deinit(io);
        try shop.registry.registerConnection(io, "shared-1", .{ .uri = "fake://shared" });
        try shop.registry.connect(io, .root, "shared-1");
        try shop.registry.provisionTenant(io, .root, .{ .tenant = "acme", .connection = .{ .existing = "shared-1" }, .database = "acme", .version = 1 });
        shop.mark = shop.fake.journal(io).len;
    }

    pub fn deinit(shop: *Shop, io: Io) void {
        shop.registry.deinit(io);
        shop.fake.deinit();
    }

    /// The calls that went out since `init`, or since the last `forget`.
    pub fn sent(shop: *Shop, io: Io) []const FakeDriver.Request {
        return shop.fake.journal(io)[shop.mark..];
    }

    /// From now on `sent` holds only the calls to come.
    pub fn forget(shop: *Shop, io: Io) void {
        shop.mark = shop.fake.journal(io).len;
    }
};

/// Whether the document `got` is, byte for byte, the one that `bson.encode`
/// writes for `expected`, a literal spelled without types.
pub fn expectDocument(expected: anytype, got: bson.RawDocument) !void {
    const want = try bson.encode(std.testing.allocator, expected, .{});
    defer want.deinit();
    if (!std.mem.eql(u8, want.bytes, got.bytes)) {
        std.debug.print("expected {f}\n   found {f}\n", .{ want.raw(), got });
        return error.TestExpectedEqual;
    }
}

/// The errors of the calls of the registry, `shutdown` with them.
pub const CallError = odm.Error || odm.ShutdownError;

/// The result of one call of the registry in a task of its own.
pub const Outcome = struct {
    result: CallError!void = {},
    done: std.atomic.Value(bool) = .init(false),

    pub fn set(o: *Outcome, result: CallError!void) void {
        o.result = result;
        o.done.store(true, .release);
    }

    fn isDone(o: *Outcome, io: Io) bool {
        _ = io;
        return o.done.load(.acquire);
    }

    /// The result, once the call returned; error.Timeout after 30 s.
    pub fn wait(o: *Outcome, io: Io) !CallError!void {
        try eventually(io, o, isDone);
        return o.result;
    }
};

/// Until `holds(arg, io)`, looking every millisecond; error.Timeout after
/// 30 s on the .awake clock, so that a call that never returns fails the
/// test. Under ThreadSanitizer on a loaded machine, the drain behind the
/// 22 tasks of the concurrency test took up to 9 s.
pub fn eventually(io: Io, arg: anytype, comptime holds: fn (@TypeOf(arg), Io) bool) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(30));
    while (!holds(arg, io)) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) {
            std.debug.print("the registry did not get there in 30 s\n", .{});
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}
