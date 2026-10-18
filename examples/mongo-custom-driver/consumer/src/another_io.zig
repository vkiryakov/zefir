//! A safe build of minidriver checks rule 2 of `mongo.Client`: a call on
//! another `std.Io` than the one of `init` panics, naming the rule.
//! build.zig runs this program and checks the message on stderr and the
//! exit code 3 of the panic handler below, which exits instead of aborting.

const std = @import("std");
const mongo = @import("zefir-mongo");
const minidriver = @import("mongo-minidriver");

pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // No server: the check comes before any I/O.
    var driver: minidriver.Client = try .init(init.gpa, io, .{ .uri = "mongodb://127.0.0.1:27017" });
    // The same functions behind another table: not the io of init.
    var vtable = io.vtable.*;
    const other: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const ping: mongo.Command = .{ .database = "admin", .body = mongo.bson.literal(.{ .ping = 1 }) };
    if (driver.client().runCommand(other, .of(.root), ping, .{ .allocator = init.gpa })) |reply| reply.deinit() else |_| {}
    std.debug.print("no panic\n", .{});
    std.process.exit(0);
}
