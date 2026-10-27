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

/// A new span id: 8 random bytes, drawn again in the rare case that all of
/// them are zero.
fn newSpanId(io: std.Io) core.SpanId {
    while (true) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        return core.SpanId.fromBytes(bytes) catch continue;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const repo: Repository = .{ .users = &.{.{ .id = 42, .name = "Ada" }} };

    // What the call brought: the trace of the caller, and the budget it has
    // left for the call.
    const caller = try core.w3c.parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    const budget: std.Io.Duration = .fromMilliseconds(500);

    // The call scope owns the token; the context only points to it. The
    // handler's span is a child of the caller's, in the same trace.
    var token: core.CancellationToken = .init;
    const ctx = core.Context.root
        .withTrace(caller.child(newSpanId(io)))
        .withDeadline(.after(std.Io.Clock.awake.now(io), budget))
        .withCancellation(&token);

    const user = try getUser(ctx, io, repo, 42);
    try out.print("trace {f}: user {d} is {s}\n", .{ caller.trace_id, user.id, user.name });

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
