// Application code (src/middleware.zig of the example app): zefir-http ships none of these.
//! The middleware of the example app, one of each kind zefir-http takes: a
//! function, functions as after phases, a set, an object with a
//! dependency, and an object that calls two services at once. The
//! authentication is in auth.zig, CORS in cors.zig.

const std = @import("std");
const http = @import("http");
const log = @import("log");
const auth = @import("auth.zig");
const Billing = @import("Billing.zig");
const TodoRepository = @import("TodoRepository.zig");

/// A function: a `run` phase alone. The id of the request goes back to the
/// client, which can quote it when it reports a problem.
pub fn requestId(ctx: *http.Context) !http.MiddlewareResult {
    try ctx.response.setHeader("x-request-id", ctx.requestId());
    return .next;
}

/// A function as an after phase, listed as `http.onResponse(securityHeaders)`:
/// it runs right before the head of every response goes out, the answers
/// to errors too.
pub fn securityHeaders(ctx: *http.Context) !void {
    try ctx.response.setHeader("x-content-type-options", "nosniff");
}

/// Listed as `http.onResponse(noCache)` in `protected`: a cache keeps no
/// response that needs a user.
pub fn noCache(ctx: *http.Context) !void {
    try ctx.response.setHeader("cache-control", "no-store");
}

/// A set: a tuple of middleware, unfolded in place wherever it is listed.
/// The controllers that need a user list it.
pub const protected = .{ auth.requireUser, http.onResponse(noCache) };

/// An object with an `onFinish` phase alone: a record for each request
/// once it has ended, answered, refused or cut. It is listed by its
/// address, `&access_log`, and borrowed by the server.
pub const AccessLog = struct {
    logger: log.Logger,

    pub fn onFinish(self: *AccessLog, ctx: *http.Context, outcome: http.Outcome) !void {
        self.logger.info("Request", .{
            .method = @tagName(ctx.request.method),
            .path = ctx.request.path,
            .status = outcome.status,
            .user = if (ctx.locals.get(auth.CurrentUser)) |user| user.id else "-",
            .err = if (outcome.err) |err| @errorName(err) else "-",
            .request = ctx.requestId(),
            .duration_ms = outcome.duration.toMilliseconds(),
        });
    }
};

/// How many todos a user has, as `PlanLookup` puts it into `ctx.locals`.
pub const Usage = struct { todos: u32 };

/// An object that does I/O: the plan of the user from the billing service
/// and the count of their todos from the repository, both at once, into
/// `ctx.locals` for the handler. The route of POST /v1/todos lists it as
/// `.plans`, a field of its controller.
pub const PlanLookup = struct {
    billing: *Billing,
    repo: *TodoRepository,

    pub fn run(self: *PlanLookup, ctx: *http.Context) !http.MiddlewareResult {
        // An anonymous request has no plan; requireUser has refused it before.
        const user = ctx.locals.get(auth.CurrentUser) orelse return .next;
        const io = ctx.io();
        // Two calls at once: the request waits for the longer one, not for both.
        var plan = io.async(Billing.planOf, .{ self.billing, ctx.operation(), io, user.id });
        defer if (plan.cancel(io)) |_| {} else |_| {};
        var usage = io.async(TodoRepository.count, .{ self.repo, ctx.operation(), io, user.id });
        defer if (usage.cancel(io)) |_| {} else |_| {};
        try ctx.locals.put(Billing.Plan, try plan.await(io));
        try ctx.locals.put(Usage, .{ .todos = try usage.await(io) });
        return .next;
    }
};
