//! Debug build: two tasks that call one cursor at once panic: a cursor
//! serves one task at a time. The first `next` waits at a gate of the fake
//! driver while the second one starts, so that they overlap. build.zig runs
//! this program and checks the panic message on stderr and the exit code 3
//! of the panic handler below.
const std = @import("std");
const odm = @import("odm");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

const Note = struct {
    id: []const u8,
    text: []const u8 = "",

    pub const odm_schema: odm.Schema(Note) = .{ .collection = "notes", .id = .id };
};

fn nextNote(cursor: *odm.Cursor(Note), io: std.Io) void {
    var buffer: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    _ = cursor.next(io, .root, fixed.allocator()) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var fake: odm.testing.FakeDriver = .init(init.gpa);
    defer fake.deinit();
    var registry: odm.Registry = .init(init.gpa, io, fake.driver(), .{});
    defer registry.deinit(io);
    try registry.registerConnection(io, "shared-1", .{ .uri = "fake://shared" });
    try registry.connect(io, .root, "shared-1");
    try registry.provisionTenant(io, .root, .{ .tenant = "acme", .connection = .{ .existing = "shared-1" }, .database = "acme", .version = 1 });
    var session = try registry.tenant(io, "acme");
    defer session.deinit(io);
    var cursor = try session.collection(Note).find(io, .root, .{}, .{});
    defer cursor.deinit(io);

    // From now on the gate holds the next of the cursor.
    var gate: odm.testing.FakeDriver.Gate = .{};
    try fake.plan("fake://shared", .{ .gate = &gate });
    var first = try io.concurrent(nextNote, .{ &cursor, io });
    defer first.cancel(io);
    defer gate.open(io);
    try gate.waitFor(io, 1);
    // The mistake: a second task calls the cursor meanwhile.
    var second = try io.concurrent(nextNote, .{ &cursor, io });
    defer second.cancel(io);
    try gate.waitFor(io, 2);
}
