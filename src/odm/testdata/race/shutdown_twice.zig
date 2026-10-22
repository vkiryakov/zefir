//! Debug build: two shutdowns, and a deinit right after the second one
//! returns. The first shutdown waits for the lease of a generation that a
//! drain closed by force before it, and frees that generation once the
//! lease is back; the second one waits for the first and returns its
//! result. Once the second returns, its caller may deinit the registry, so
//! the first must have freed the generation, the last use of the registry,
//! before it lets the second go.
//!
//! The driver is the fake's, whose client of that generation checks, as the
//! registry frees it, that the second shutdown cannot return yet; when it
//! can, the program exits with 1 before the registry goes on. The second
//! task deinits the registry only after that check, so that a run of the
//! mistake never reads freed memory. build.zig runs the program and checks
//! the exit code 0; a panic exits with 3.
const std = @import("std");
const Io = std.Io;
const odm = @import("odm");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

/// The forced close of the drain logs a warning, which this program does
/// not need.
pub const std_options: std.Options = .{ .log_level = .err };

var main_io: Io = undefined;
var registry: odm.Registry = undefined;
/// The client of the first generation, which the drain closes by force.
var first_client: ?*anyopaque = null;
/// The table of the fake's clients, and the same with `deinit` hooked.
var fake_table: *const odm.Client.VTable = undefined;
var hooked_table: odm.Client.VTable = undefined;
/// Set once the client of the first generation was freed while the second
/// shutdown still waited.
var checked: Io.Event = .unset;

/// The fake's driver, whose clients come with `hookedDeinit`.
const Driver = struct {
    fake: *odm.testing.FakeDriver,

    pub const name = "fake with a hook";

    pub fn open(d: *Driver, io: Io, config: *const odm.ConnectionConfig) odm.Driver.OpenError!odm.Client {
        const client = try d.fake.open(io, config);
        if (first_client == null) first_client = client.ptr;
        fake_table = client.vtable;
        hooked_table = client.vtable.*;
        hooked_table.deinit = hookedDeinit;
        return .{ .ptr = client.ptr, .vtable = &hooked_table };
    }
};

/// The registry frees a client: that of the first generation comes before
/// the shutdown is done, never after.
fn hookedDeinit(ptr: *anyopaque) void {
    if (ptr == first_client) {
        // The second task deinits the registry only after `checked`: the
        // registry is still whole here.
        if (registry.shut.isSet()) {
            std.debug.print("the first shutdown frees a generation after it let the second one return: the caller of the second may deinit the registry now, and the first would read freed memory\n", .{});
            std.process.exit(1);
        }
        checked.set(main_io);
    }
    fake_table.deinit(ptr);
}

/// The result of a shutdown in a task of its own.
const Stop = struct {
    result: odm.ShutdownError!void = {},
    done: std.atomic.Value(bool) = .init(false),

    fn first(stop: *Stop, io: Io) void {
        stop.result = registry.shutdown(io, .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake }));
        stop.done.store(true, .release);
    }

    /// The second shutdown, and the deinit of the registry once it
    /// returned, as the caller of a shutdown may do.
    fn second(stop: *Stop, io: Io) void {
        stop.result = registry.shutdown(io, .now(io, .awake));
        checked.waitUncancelable(io);
        registry.deinit(io);
        stop.done.store(true, .release);
    }
};

/// Until `holds(arg, io)`, or exits with 1 after 30 s.
fn waitUntil(io: Io, arg: anytype, comptime holds: fn (@TypeOf(arg), Io) bool, comptime what: []const u8) !void {
    const give_up = Io.Clock.awake.now(io).addDuration(.fromSeconds(30));
    while (!holds(arg, io)) {
        if (Io.Clock.awake.now(io).nanoseconds >= give_up.nanoseconds) {
            std.debug.print("{s} did not come in 30 s\n", .{what});
            std.process.exit(1);
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn stopping(r: *odm.Registry, io: Io) bool {
    _ = r.connectionStats(io, "shared-1") catch |err| return err == error.ShuttingDown;
    return false;
}

fn isDone(stop: *Stop, _: Io) bool {
    return stop.done.load(.acquire);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    main_io = io;
    var fake: odm.testing.FakeDriver = .init(init.gpa);
    defer fake.deinit();
    var driver: Driver = .{ .fake = &fake };
    registry = .init(init.gpa, io, odm.Driver.init(&driver), .{ .drain_timeout = .fromMilliseconds(50) });
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://shared" });
    try registry.connect(io, .root, "shared-1");
    try registry.provisionTenant(io, .root, .{ .tenant = "acme", .connection = .{ .existing = "shared-1" }, .database = "acme", .version = 1 });

    // The session holds the first generation past the drain of the
    // replacement, which closes it by force.
    var session = try registry.tenant(io, "acme");
    try registry.replaceConnection(io, .root, "shared-1", .{ .uri = "fake://next" });

    var first: Stop = .{};
    var first_task = try io.concurrent(Stop.first, .{ &first, io });
    // The first shutdown has taken the generations; the second waits for it.
    try waitUntil(io, &registry, stopping, "the shutdown");
    var second: Stop = .{};
    var second_task = try io.concurrent(Stop.second, .{ &second, io });
    // The lease comes back while the first one waits for it, which frees
    // the generation then.
    session.deinit(io);
    try waitUntil(io, &first, isDone, "the return of the first shutdown");
    first_task.await(io);
    try waitUntil(io, &second, isDone, "the return of the second shutdown and its deinit");
    second_task.await(io);

    first.result catch |err| {
        std.debug.print("the first shutdown is {t}; its lease came back before the deadline\n", .{err});
        std.process.exit(1);
    };
    second.result catch |err| {
        std.debug.print("the second shutdown is {t}, not the result of the first\n", .{err});
        std.process.exit(1);
    };
    const counts = fake.counts(io);
    if (counts.opened != 2 or counts.closed != 2 or counts.freed != 2) {
        std.debug.print("the fake opened {d} clients, closed {d} and freed {d}, not 2 each\n", .{ counts.opened, counts.closed, counts.freed });
        std.process.exit(1);
    }
}
