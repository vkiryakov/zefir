//! The middleware of the users service: code around its calls. Each link
//! runs its part before `next.run()` on the way in and its part after it
//! on the way out, and ends the call early by returning an error.

const std = @import("std");
const log = @import("log");
const rpc = @import("rpc");
const Store = @import("Store.zig");

/// A function, built at compile time for one permission: the call goes on
/// only when the caller's identity holds it.
pub fn requirePermission(comptime permission: []const u8) rpc.MiddlewareFn {
    return struct {
        fn run(ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
            const identity = ctx.identity() orelse return error.Unauthenticated;
            if (!identity.hasPermission(permission)) return error.PermissionDenied;
            return next.run();
        }
    }.run;
}

/// An object with a dependency, the store: at most `per_minute` calls a
/// minute from each caller.
pub const RateLimiter = struct {
    store: *Store,
    per_minute: u32,

    pub fn run(self: *RateLimiter, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        const caller = if (ctx.identity()) |identity| identity.subject else "anonymous";
        const key = try std.fmt.allocPrint(ctx.allocator(), "rate:{s}", .{caller});
        // The store is waited on through ctx.io(), within the call's deadline.
        const count = self.store.incrWithExpire(ctx.io(), key, .fromSeconds(60)) catch |err| switch (err) {
            // Never swallow a cancelation: the deadline could not stop the call.
            error.Canceled => return err,
            // The store is down: let the call through (fail-open).
            else => return next.run(),
        };
        // The calls left this minute, in the metadata of the response, which
        // a failure carries too; the client reads it with result.metadata().
        const remaining = try std.fmt.allocPrint(ctx.allocator(), "{d}", .{self.per_minute -| count});
        try ctx.setResponseMetadata("ratelimit-remaining", remaining);
        if (count > self.per_minute) {
            return ctx.fail(.{ .code = .resource_exhausted, .app_code = "rate.limited", .message = "Too many requests" });
        }
        return next.run();
    }
};

/// An object with a dependency, the logger: a record of every call that
/// succeeded, and of who made it.
pub const Audit = struct {
    logger: log.Logger,

    pub fn run(self: *Audit, ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
        try next.run();
        // A success here is not final yet: the deadline or a stop may still
        // fail the call.
        const caller = if (ctx.identity()) |identity| identity.subject else "anonymous";
        self.logger.info("Call audited", .{ .method = ctx.route().method, .by = caller });
    }
};
