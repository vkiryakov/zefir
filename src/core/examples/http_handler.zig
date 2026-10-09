//! An HTTP-style handler: the server gives every request a context with a
//! deadline and a cancellation token, and the handler checks it before work.

const std = @import("std");
const core = @import("core");

const Request = struct { path: []const u8 };
const Response = struct { status: u16, body: []const u8 };

fn handleRequest(ctx: core.Context, io: std.Io, request: Request) core.ContextError!Response {
    try ctx.check(std.Io.Clock.awake.now(io));
    return .{ .status = 200, .body = request.path };
}

/// What the server answers when the handler fails.
fn statusFor(err: core.ContextError) u16 {
    return switch (core.ErrorCode.fromContextError(err)) {
        .cancelled => 499,
        .deadline_exceeded => 504,
        else => 500,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // The request scope owns the token; the context only points to it.
    var token: core.CancellationToken = .init;
    const now = std.Io.Clock.awake.now(io);
    const ctx = core.Context.root
        .withDeadline(.after(now, .fromSeconds(2)))
        .withCancellation(&token);

    const ok = try handleRequest(ctx, io, .{ .path = "/users/42" });
    try out.print("{d} {s}\n", .{ ok.status, ok.body });
    if (ok.status != 200) return error.UnexpectedStatus;

    // The client disconnected: the server cancels the request.
    token.cancel();
    if (handleRequest(ctx, io, .{ .path = "/users/42" })) |_| {
        return error.ExpectedCancellation;
    } else |err| {
        try out.print("{d} after {t}\n", .{ statusFor(err), err });
        if (err != error.Cancelled) return error.UnexpectedError;
    }

    // A request whose deadline has passed is refused the same way.
    const late = core.Context.root.withDeadline(.after(now, .zero));
    if (handleRequest(late, io, .{ .path = "/users/42" })) |_| {
        return error.ExpectedDeadlineExceeded;
    } else |err| {
        try out.print("{d} after {t}\n", .{ statusFor(err), err });
        if (err != error.DeadlineExceeded) return error.UnexpectedError;
    }
}
