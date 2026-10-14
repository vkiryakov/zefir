//! Middleware: code around every call, the same on every transport. On the
//! server it runs in the handler's task after authentication: the code
//! before `next.run()` sees the request, the code after sees the outcome.
//! On the client it runs in the caller's task around the transport's call.
//!
//! A link is a function without state or an object with dependencies of
//! its own:
//!
//! ```zig
//! pub fn requirePermission(comptime permission: []const u8) rpc.MiddlewareFn {
//!     return struct {
//!         fn run(ctx: *rpc.Context, next: *rpc.Next) anyerror!void {
//!             const identity = ctx.identity() orelse return error.Unauthenticated;
//!             if (!identity.hasPermission(permission)) return error.PermissionDenied;
//!             return next.run();
//!         }
//!     }.run;
//! }
//!
//! var server: rpc.RawServer = try .init(gpa, .{
//!     .transport = bus.serverTransport(),
//!     .methods = &.{.{
//!         .route = delete_user,
//!         .handler = users.deleteHandler(),
//!         .middleware = &.{.of(requirePermission("users.delete"))},
//!     }},
//!     .middleware = &.{ .of(logCalls), .of(&limiter) }, // every method
//! });
//! ```
//!
//! The rules of the chain:
//!
//! 1. Each link calls `next.run()` exactly once. A second call returns
//!    `error.Internal` and fails the call with `internal` whatever the links
//!    do next: `catch` does not hide it. Returning success without calling
//!    `next.run()` is `Internal` too; returning an error without it is fine.
//! 2. `next.run()` returns the outcome of the links inside and the handler:
//!    the error of the call, also one swallowed deeper, or success.
//! 3. An error swallowed by a link stays the outcome: it does not become a
//!    success. An error a link returns is the outcome, also after a success
//!    inside, which is not undone.
//! 4. The error becomes a failure once, after the chain has unwound: the
//!    failure of `ctx.fail`, then the contract's table, then the
//!    framework's names, else `internal`. A link sees the real Zig error.
//! 5. A success a link sees is not final: the deadline, the client's cancel
//!    or the stop may still win, and a response over the limits becomes
//!    `resource_exhausted`.
//! 6. Middleware waits only through `std.Io`, and returns `error.Canceled`
//!    as it is: the deadline cancels it like the handler.

const std = @import("std");
const engine_context = @import("engine/Context.zig");
const Context = engine_context.Context;
const Handler = @import("engine/RawServer.zig").Handler;
const RawClient = @import("engine/RawClient.zig");
const ClientContext = RawClient.ClientContext;

const log = std.log.scoped(.rpc);

/// One link of the server's chain. `ptr` is null for a function without
/// state, the object for middleware with state. Build it with `of`.
pub const Middleware = struct {
    ptr: ?*anyopaque = null,
    run: *const fn (ptr: ?*anyopaque, ctx: *Context, next: *Next) anyerror!void,

    /// The link of `item`: a function of type `rpc.MiddlewareFn`, or a
    /// pointer to an object with
    /// `pub fn run(self: *@This(), ctx: *rpc.Context, next: *rpc.Next) anyerror!void`.
    /// The object is borrowed: it must outlive the server. Anything else
    /// stops the build with a message that names what to write.
    pub fn of(item: anytype) Middleware {
        return linkOf(Middleware, Context, Next, "rpc.Middleware.of", "fn (ctx: *rpc.Context, next: *rpc.Next) anyerror!void", item);
    }
};

/// A middleware function without state.
pub const MiddlewareFn = fn (ctx: *Context, next: *Next) anyerror!void;

/// The rest of the chain behind one link.
pub const Next = opaque {
    /// Runs the links after this one, then the handler, and returns their
    /// outcome. Exactly once per link.
    pub fn run(next: *Next) anyerror!void {
        const link: *Chain.Link = @ptrCast(@alignCast(next));
        return link.runNext();
    }
};

/// One link of the client's chain, around the transport's call in the
/// caller's task. `ptr` is null for a function without state, the object
/// for middleware with state. Build it with `of`.
///
/// The rules are those of the server: `next.run()` exactly once, a second
/// call fails the call with `MiddlewareFailed` whatever the links do next,
/// and an error swallowed by a link stays the outcome. Returning an error
/// without `next.run()` is fine, as a circuit breaker does; success without
/// it is `MiddlewareFailed`. `next.run()` returns errors in the names of
/// `rpc.RawClient.CallError`; a link may replace the outcome with one of
/// them, and any other error becomes `MiddlewareFailed`.
pub const ClientMiddleware = struct {
    ptr: ?*anyopaque = null,
    run: *const fn (ptr: ?*anyopaque, ctx: *ClientContext, next: *ClientNext) anyerror!void,

    /// The link of `item`: a function of type `rpc.ClientMiddlewareFn`, or
    /// a pointer to an object with
    /// `pub fn run(self: *@This(), ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void`.
    /// The object is borrowed: it must outlive the client. Anything else
    /// stops the build with a message that names what to write.
    pub fn of(item: anytype) ClientMiddleware {
        return linkOf(ClientMiddleware, ClientContext, ClientNext, "rpc.ClientMiddleware.of", "fn (ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void", item);
    }
};

/// A middleware function of the client, without state.
pub const ClientMiddlewareFn = fn (ctx: *ClientContext, next: *ClientNext) anyerror!void;

/// The rest of the client's chain behind one link.
pub const ClientNext = opaque {
    /// Runs the links after this one, then the transport's call, and
    /// returns their outcome. Exactly once per link.
    pub fn run(next: *ClientNext) anyerror!void {
        return RawClient.runNext(next);
    }
};

/// The link of a function or an object; `where` and `function` name them in
/// the messages of the build. Internal to the module.
pub fn linkOf(
    comptime Link: type,
    comptime Ctx: type,
    comptime NextT: type,
    comptime where: []const u8,
    comptime function: []const u8,
    item: anytype,
) Link {
    const Item = @TypeOf(item);
    comptime checkItem(Ctx, NextT, where, function, Item);
    if (@typeInfo(Item) == .@"fn") return .{ .run = struct {
        fn run(_: ?*anyopaque, ctx: *Ctx, next: *NextT) anyerror!void {
            return item(ctx, next);
        }
    }.run };
    const T = @typeInfo(Item).pointer.child;
    return .{ .ptr = item, .run = struct {
        fn run(ptr: ?*anyopaque, ctx: *Ctx, next: *NextT) anyerror!void {
            const self: *T = @ptrCast(@alignCast(ptr.?));
            return self.run(ctx, next);
        }
    }.run };
}

/// Stops the build unless `Item` is a function of the link's type or a
/// pointer to a mutable object with the method `run`.
fn checkItem(comptime Ctx: type, comptime NextT: type, comptime where: []const u8, comptime function: []const u8, comptime Item: type) void {
    const method = "pub fn run(self: *@This(), " ++ function["fn (".len..];
    const expected = where ++ ": expected " ++ function ++ ", or a pointer to a type with " ++ method ++ "; got " ++ @typeName(Item);
    switch (@typeInfo(Item)) {
        .@"fn" => if (Item != fn (*Ctx, *NextT) anyerror!void) @compileError(expected),
        .pointer => |pointer| {
            if (pointer.size != .one) @compileError(expected);
            const T = pointer.child;
            switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => {},
                else => @compileError(expected),
            }
            if (pointer.attrs.@"const") @compileError(where ++ ": the middleware must be mutable, declared with var; got " ++ @typeName(Item));
            if (!@hasDecl(T, "run")) @compileError(where ++ ": " ++ @typeName(T) ++ " has no method run; expected " ++ method);
            if (@TypeOf(T.run) != fn (*T, *Ctx, *NextT) anyerror!void)
                @compileError(where ++ ": " ++ @typeName(T) ++ ".run has another signature; expected " ++ method);
        },
        else => @compileError(expected),
    }
}

/// One run of the server's chain for a call: the links of the server, then
/// those of the method, then the handler. Internal to the module.
pub const Chain = struct {
    context: *Context,
    server_links: []const Middleware,
    method_links: []const Middleware,
    handler: Handler,
    request: []const u8,
    /// What the handler returned.
    body: ?[]const u8 = null,
    /// A link called `next.run()` twice: the call fails with `Internal`.
    violation: bool = false,

    /// The body of a success, or the error the call ends with.
    pub fn run(chain: *Chain) anyerror![]const u8 {
        try chain.layer(0);
        return chain.body.?;
    }

    /// Runs link `index` and all inside it; the handler past the last link.
    fn layer(chain: *Chain, index: usize) anyerror!void {
        const count = chain.server_links.len + chain.method_links.len;
        if (index == count) {
            chain.body = try chain.handler.handle(chain.handler.ptr, chain.context, chain.request);
            return;
        }
        const link_of = if (index < chain.server_links.len) chain.server_links[index] else chain.method_links[index - chain.server_links.len];
        var link: Link = .{ .chain = chain, .index = index };
        const result = link_of.run(link_of.ptr, chain.context, @ptrCast(&link));
        // A second next.run() decides, whatever the links did with it.
        if (chain.violation) return error.Internal;
        // An error the link returns is the outcome.
        try result;
        if (!link.called) {
            chain.warn("returned success without calling next.run()");
            return error.Internal;
        }
        // An error from inside that the link swallowed stays the outcome.
        if (link.inner) |err| return err;
    }

    fn warn(chain: *Chain, comptime what: []const u8) void {
        const call = engine_context.callOf(chain.context);
        // The log may take a cancelable lock; a cancelation of the task stays.
        const protection = call.io.swapCancelProtection(.blocked);
        defer _ = call.io.swapCancelProtection(protection);
        const r = call.route;
        log.warn("middleware of {s}.v{d}.{s} " ++ what ++ "; the call fails with internal", .{ r.service, r.version, r.method });
    }

    const Link = struct {
        chain: *Chain,
        index: usize,
        called: bool = false,
        /// What `next.run()` returned, when it failed.
        inner: ?anyerror = null,

        fn runNext(link: *Link) anyerror!void {
            const chain = link.chain;
            if (link.called) {
                chain.violation = true;
                chain.warn("called next.run() twice");
                return error.Internal;
            }
            link.called = true;
            const call = engine_context.callOf(chain.context);
            call.response_body = null;
            chain.layer(link.index + 1) catch |err| {
                link.inner = err;
                call.response_body = null;
                return err;
            };
            call.response_body = chain.body;
        }
    };
};

const testing = std.testing;

fn refuse(_: *Context, _: *Next) anyerror!void {
    return error.Refused;
}

fn inferred(_: *Context, _: *Next) !void {}

const Counter = struct {
    runs: u32 = 0,

    pub fn run(c: *Counter, _: *Context, _: *Next) anyerror!void {
        c.runs += 1;
    }
};

test "of builds a link from a function and from an object" {
    const function: Middleware = .of(refuse);
    try testing.expectEqual(@as(?*anyopaque, null), function.ptr);
    try testing.expectError(error.Refused, function.run(function.ptr, undefined, undefined));

    var counter: Counter = .{};
    const object: Middleware = .of(&counter);
    try object.run(object.ptr, undefined, undefined);
    try object.run(object.ptr, undefined, undefined);
    try testing.expectEqual(@as(u32, 2), counter.runs);
    try testing.expectEqual(@as(?*anyopaque, &counter), object.ptr);
    // A function with an inferred error set is not a MiddlewareFn.
    try testing.expect(@TypeOf(inferred) != MiddlewareFn);
}
