//! The service on the network: zio runs it, `http.native` serves it on
//! port 8080, and SIGTERM stops it gracefully.

const std = @import("std");
const zio = @import("zio");
const http = @import("zefir").http;
const Service = @import("Service.zig");
const TodoRepository = @import("TodoRepository.zig");

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    const repo: TodoRepository = .{ .todos = &.{.{ .id = 1, .title = "Buy milk", .done = false }} };

    var native: http.native.Backend = try .init(init.gpa, .{ .port = 8080 });
    defer native.deinit();

    var service: Service = .{ .todos = .{ .repo = &repo } };
    try service.start(init.gpa, io, native.backend());
    defer service.deinit(init.gpa, io);

    // SIGTERM begins a graceful stop; wait returns once it is over.
    var on_terminate = try io.concurrent(stopOnSignal, .{ io, &service.server });
    defer on_terminate.cancel(io) catch {};
    try service.server.wait(io);
}

fn stopOnSignal(io: std.Io, server: *http.Server) !void {
    var signal = try zio.Signal.init(.terminate);
    defer signal.deinit();
    try signal.wait();
    server.requestStop(io);
}
