//! An RPC-style handler: the context goes down to the repository by value,
//! next to the other parameters, and every layer checks it before work.

const std = @import("std");
const core = @import("core");

const User = struct { id: u64, name: []const u8 };

const Repository = struct {
    users: []const User,

    fn find(repo: Repository, ctx: core.Context, io: std.Io, id: u64) !User {
        try ctx.check(std.Io.Clock.awake.now(io));
        for (repo.users) |user| {
            if (user.id == id) return user;
        }
        return error.UserNotFound;
    }
};

fn getUser(ctx: core.Context, io: std.Io, repo: Repository, id: u64) !User {
    try ctx.check(std.Io.Clock.awake.now(io));
    return repo.find(ctx, io, id);
}

/// How a transport classifies the handler's errors.
fn codeFor(err: anyerror) core.ErrorCode {
    return switch (err) {
        error.Cancelled => .cancelled,
        error.DeadlineExceeded => .deadline_exceeded,
        error.UserNotFound => .not_found,
        else => .internal,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const repo: Repository = .{ .users = &.{.{ .id = 42, .name = "Ada" }} };

    // The call scope owns the token; the context only points to it.
    var token: core.CancellationToken = .init;
    const now = std.Io.Clock.awake.now(io);
    var span: [8]u8 = undefined;
    var trace: [16]u8 = undefined;
    io.random(&span);
    io.random(&trace);
    const ctx = core.Context.root
        .withTrace(.{
            .trace_id = core.TraceId.fromBytes(trace) catch return error.ZeroTraceId,
            .span_id = core.SpanId.fromBytes(span) catch return error.ZeroSpanId,
            .flags = .{ .sampled = true },
            .state = .empty,
        })
        .withDeadline(.after(now, .fromMilliseconds(500)))
        .withCancellation(&token);

    const user = try getUser(ctx, io, repo, 42);
    try out.print("trace {f}: user {d} is {s}\n", .{ ctx.trace.?.trace_id, user.id, user.name });

    if (getUser(ctx, io, repo, 7)) |_| return error.ExpectedNotFound else |err| {
        try out.print("user 7: {t}\n", .{codeFor(err)});
        if (codeFor(err) != .not_found) return error.UnexpectedCode;
    }

    token.cancel();
    if (getUser(ctx, io, repo, 42)) |_| return error.ExpectedCancellation else |err| {
        try out.print("after cancel: {t}\n", .{codeFor(err)});
        if (codeFor(err) != .cancelled) return error.UnexpectedCode;
    }
}
