//! Debug build: an engine that breaks the rules of `rpc.transport.Reply` on
//! `rpc.testing.MemoryTransport` gets a panic that names the rule. build.zig
//! runs this program once per case, the first argument, and checks the
//! panic message on stderr and the exit code 3 of the panic handler below.
const std = @import("std");
const core = @import("core");
const rpc = @import("rpc");

/// Prints the panic message and exits with code 3 instead of aborting.
pub const panic = std.debug.FullPanic(exitOnPanic);

fn exitOnPanic(message: []const u8, _: ?usize) noreturn {
    std.debug.print("panic: {s}\n", .{message});
    std.process.exit(3);
}

const route: rpc.Route = .{ .service = "users", .version = 1, .method = "getUser" };

/// An engine that admits every call and hands its reply to the program.
const Engine = struct {
    service_value: rpc.transport.Dispatcher.Service = .{
        .routes = &.{route},
        .max_inflight = 8,
        .max_request_bytes = 64,
        .max_metadata_entries = 64,
        .max_metadata_bytes = 16 * 1024,
    },
    buffer: [64]u8 = undefined,
    len: usize = 0,
    reply: rpc.transport.Reply = undefined,
    started: std.Io.Event = .unset,

    const vtable: rpc.transport.Dispatcher.VTable = .{ .service = service, .admit = admit, .fail = fail, .routeStats = routeStats };
    const incoming_vtable: rpc.transport.Incoming.VTable = .{ .body = body, .start = start, .abandon = abandon, .cancel = cancel };

    fn dispatcher(e: *Engine) rpc.transport.Dispatcher {
        return .{ .ptr = e, .vtable = &vtable };
    }

    fn service(ptr: *anyopaque) *const rpc.transport.Dispatcher.Service {
        const e: *Engine = @ptrCast(@alignCast(ptr));
        return &e.service_value;
    }

    fn admit(ptr: *anyopaque, io: std.Io, head: *const rpc.transport.RequestHead, body_len: usize) rpc.transport.Dispatcher.Admission {
        _ = io;
        _ = head;
        const e: *Engine = @ptrCast(@alignCast(ptr));
        e.len = body_len;
        return .{ .accepted = .{ .ptr = e, .vtable = &incoming_vtable } };
    }

    fn fail(_: *anyopaque, _: std.Io, _: rpc.transport.Dispatcher.FatalError, _: ?*const rpc.transport.Diagnostics) void {}

    fn routeStats(ptr: *anyopaque, route_index: usize) rpc.transport.Dispatcher.RouteStats {
        _ = ptr;
        _ = route_index;
        return .{ .requests = 0, .errors = 0, .processing_time = .zero };
    }

    fn body(ptr: *anyopaque) []u8 {
        const e: *Engine = @ptrCast(@alignCast(ptr));
        return e.buffer[0..e.len];
    }

    fn start(ptr: *anyopaque, io: std.Io, reply: rpc.transport.Reply) ?rpc.Failure {
        const e: *Engine = @ptrCast(@alignCast(ptr));
        e.reply = reply;
        e.started.set(io);
        return null;
    }

    fn abandon(ptr: *anyopaque, io: std.Io) void {
        _ = ptr;
        _ = io;
    }

    fn cancel(ptr: *anyopaque, io: std.Io) void {
        _ = ptr;
        _ = io;
    }
};

fn callOnce(client: rpc.ClientTransport, io: std.Io, gpa: std.mem.Allocator, budget: std.Io.Duration) rpc.ClientTransport.CallError!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const request: rpc.transport.Request = .{
        .route = route,
        .request_id = @splat(1),
        .codec = "json",
        .ctx = core.Context.root.withDeadline(.after(std.Io.Clock.awake.now(io), budget)),
        .metadata = &.{},
        .body = "{}",
    };
    _ = try client.call(io, &request, .{ .allocator = arena.allocator(), .max_response_bytes = 1024 });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.NoCase;
    const case = args[1];

    var memory: rpc.testing.MemoryTransport = try .init(init.gpa, .{});
    var engine: Engine = .{};
    try memory.serverTransport().start(io, engine.dispatcher());

    if (std.mem.eql(u8, case, "release_twice")) {
        // The client still waits, so the call is alive for the second release.
        var client = try io.concurrent(callOnce, .{ memory.clientTransport(), io, init.gpa, .fromSeconds(5) });
        _ = &client;
        try engine.started.wait(io);
        engine.reply.release(io, .completed);
        engine.reply.release(io, .completed);
    } else if (std.mem.eql(u8, case, "send_twice")) {
        var client = try io.concurrent(callOnce, .{ memory.clientTransport(), io, init.gpa, .fromSeconds(5) });
        try engine.started.wait(io);
        try engine.reply.send(io, &.{ .status = .ok });
        try client.await(io);
        try engine.reply.send(io, &.{ .status = .ok });
    } else if (std.mem.eql(u8, case, "deinit_in_use")) {
        // The client gives up at its deadline; the engine never releases.
        if (callOnce(memory.clientTransport(), io, init.gpa, .fromMilliseconds(20))) |_| {
            return error.UnexpectedResponse;
        } else |err| if (err != error.Timeout) return err;
        memory.deinit(io);
    } else {
        return error.UnknownCase;
    }
    std.debug.print("no panic: {s}\n", .{case});
    std.process.exit(0);
}
