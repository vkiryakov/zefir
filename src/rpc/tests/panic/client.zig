//! Debug build: an application that breaks the rules of `rpc.RawClient`
//! gets a panic that names the rule. build.zig runs this program once per
//! case, the first argument, and checks the panic message on stderr and the
//! exit code 3 of the panic handler below.
const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");

/// Prints the panic message and exits with code 3 instead of aborting, so
/// the run ends the same way on every OS and no crash reporter or core dump
/// is involved.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

/// A provider that answers with a provider: credentials it never gives.
fn getProvider(ptr: *anyopaque, _: std.Io, _: core.Context, _: std.mem.Allocator) (error{ Unavailable, OutOfMemory } || std.Io.Cancelable)!rpc.Credentials {
    return .{ .provider = .{ .ptr = ptr, .get = getProvider } };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.NoCase;
    const case = args[1];

    var memory: rpc.testing.MemoryTransport = try .init(init.gpa, .{});
    var state: u8 = 0;
    var client: rpc.RawClient = try .init(init.gpa, .{ .transport = memory.clientTransport() });
    const route: rpc.Route = .{ .service = "users", .version = 1, .method = "getUser" };
    if (std.mem.eql(u8, case, "provider_returns_provider")) {
        var result = try client.call(io, .root, route, "", .{ .credentials = .{ .provider = .{ .ptr = &state, .get = getProvider } } });
        result.deinit();
    } else {
        return error.UnknownCase;
    }
    client.deinit();
    memory.deinit(io);
    std.debug.print("no panic: {s}\n", .{case});
    std.process.exit(0);
}
