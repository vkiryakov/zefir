//! Debug build: a connect that fails while a removal of its connection
//! waits for its turn. Once the connect ends its turn, the removal may free
//! the record of the connection at once, so the warning of the failed
//! connect must not take the id from that record. The log function below
//! holds the warning until the removal has returned, and the registry's
//! allocator keeps what it frees, a string overwritten with 'X': a warning
//! that read the freed record names "XXXXXXXX" instead of "shared-1", and
//! the program exits with 1. build.zig runs it and checks the exit code 0;
//! a panic exits with 3.
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

pub const std_options: std.Options = .{ .logFn = holdWarnings };

/// The io of main, for the log function.
var main_io: Io = undefined;
/// Set once the removal has returned.
var removed: Io.Event = .unset;
/// The warning of odm, as the log function wrote it.
var line_buffer: [256]u8 = undefined;
var line: []const u8 = "";

/// Holds a warning of odm until the removal has returned, as a slow log
/// would, then writes it to `line`.
fn holdWarnings(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (scope != .odm) return std.log.defaultLog(level, scope, format, args);
    removed.waitUncancelable(main_io);
    line = std.fmt.bufPrint(&line_buffer, format, args) catch "the warning does not fit the buffer";
}

/// An allocator that gives nothing back until its `deinit`, so that a use
/// after free reads memory that is still there: a freed string, of
/// alignment 1, becomes 'X' bytes; a freed struct keeps its bytes.
const Quarantine = struct {
    arena: std.heap.ArenaAllocator,

    fn allocator(q: *Quarantine) std.mem.Allocator {
        return .{ .ptr = q, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const q: *Quarantine = @ptrCast(@alignCast(ptr));
        return q.arena.allocator().rawAlloc(len, alignment, ret_addr);
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        if (alignment == .@"1") @memset(memory, 'X');
    }
};

/// A call in a task of its own, and its result once it returned.
const Call = struct {
    result: odm.Error!void = {},
    done: std.atomic.Value(bool) = .init(false),

    fn connect(call: *Call, registry: *odm.Registry, io: Io) void {
        call.result = registry.connect(io, .root, "shared-1");
        call.done.store(true, .release);
    }

    fn remove(call: *Call, registry: *odm.Registry, io: Io) void {
        call.result = registry.removeConnection(io, "shared-1");
        call.done.store(true, .release);
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

fn connecting(registry: *odm.Registry, io: Io) bool {
    const s = registry.connectionStats(io, "shared-1") catch return false;
    return s.state == .connecting;
}

fn isDone(call: *Call, _: Io) bool {
    return call.done.load(.acquire);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    main_io = io;
    var quarantine: Quarantine = .{ .arena = .init(init.gpa) };
    defer quarantine.arena.deinit();
    var fake: odm.testing.FakeDriver = .init(init.gpa);
    defer fake.deinit();
    var registry: odm.Registry = .init(quarantine.allocator(), io, fake.driver(), .{});
    defer registry.deinit(io);
    // The server is not there: the connect fails, after a while.
    try fake.plan("fake://down", .{ .connects = &.{error.Unavailable}, .connect_delay = .fromMilliseconds(100) });
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://down" });

    var connect: Call = .{};
    var connect_task = try io.concurrent(Call.connect, .{ &connect, &registry, io });
    try waitUntil(io, &registry, connecting, "the connect");
    // The removal waits for the turn that the connect holds.
    var remove: Call = .{};
    var remove_task = try io.concurrent(Call.remove, .{ &remove, &registry, io });
    // It returns once the failed connect has ended its turn, while the
    // warning of the connect waits in the log.
    try waitUntil(io, &remove, isDone, "the return of removeConnection");
    remove_task.await(io);
    try remove.result;
    removed.set(io);
    try waitUntil(io, &connect, isDone, "the return of connect");
    connect_task.await(io);
    if (connect.result) |_| {
        std.debug.print("the connect succeeded; the plan fails it\n", .{});
        std.process.exit(1);
    } else |err| if (err != error.Unavailable) {
        std.debug.print("the connect failed with {t}, not Unavailable\n", .{err});
        std.process.exit(1);
    }

    const expected = "connection shared-1: connect failed: Unavailable: the plan of the fake fails this connect with Unavailable";
    if (!std.mem.eql(u8, line, expected)) {
        std.debug.print("the warning of the failed connect is\n  {s}\nnot\n  {s}\n", .{ line, expected });
        std.process.exit(1);
    }
}
