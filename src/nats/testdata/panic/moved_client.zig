//! Debug build: a client copied after `connect()` panics on its first
//! method call, since its tasks still point to the old place. build.zig runs
//! this program and checks the panic message on stderr and the exit code 3
//! of the panic handler below.
const std = @import("std");
const Io = std.Io;
const nats = @import("nats");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

/// The server's side of the handshake, then reading until the client goes.
fn serve(io: Io, listener: *Io.net.Server) !void {
    const stream = try listener.accept(io);
    defer stream.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("INFO {\"server_id\":\"moved\",\"version\":\"2.15.0\",\"proto\":1,\"headers\":true,\"max_payload\":1048576}\r\n");
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    _ = try reader.interface.takeDelimiterInclusive('\n'); // CONNECT
    _ = try reader.interface.takeDelimiterInclusive('\n'); // PING
    try writer.interface.writeAll("PONG\r\n");
    try writer.interface.flush();
    while (true) _ = reader.interface.discard(.unlimited) catch return;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const loopback: Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var listener = try loopback.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var server = try io.concurrent(serve, .{ io, &listener });
    defer server.cancel(io) catch {};

    var url: [64]u8 = undefined;
    var client: nats.Client = try .init(init.gpa, io, .{
        .servers = &.{try std.fmt.bufPrint(&url, "nats://127.0.0.1:{d}", .{listener.socket.address.getPort()})},
    });
    defer client.deinit();
    try client.connect();

    // The mistake: a copy of the connected client.
    var moved = client;
    moved.publish("orders.created", "1001") catch {};
}
