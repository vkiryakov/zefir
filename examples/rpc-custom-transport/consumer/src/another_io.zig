//! A safe build of the mailbox checks rule 2 of `rpc.ClientTransport`: a
//! call on another `std.Io` than the client's `connect` panics, naming the
//! rule. build.zig runs this program and checks the message on stderr and
//! the exit code 3 of the panic handler below, which exits instead of
//! aborting.

const std = @import("std");
const core = @import("zefir-core");
const rpc = @import("zefir-rpc");
const mailbox = @import("rpc-mailbox");

pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var broker: mailbox.Broker = .init(init.gpa, .{});
    var client_side: mailbox.Client = try .init(&broker, .{});
    try client_side.connect(io);

    // The same functions behind another table: not the io of connect.
    var vtable = io.vtable.*;
    const other: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const request: rpc.transport.Request = .{
        .route = .{ .service = "users", .version = 1, .method = "getUser" },
        .request_id = @splat(1),
        .codec = "json",
        .ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), .fromSeconds(1))),
        .metadata = &.{},
        .body = "{}",
    };
    _ = client_side.clientTransport().call(other, &request, .{ .allocator = init.gpa, .max_response_bytes = 1024 }) catch {};
    std.debug.print("no panic\n", .{});
    std.process.exit(0);
}
