//! `rpc.Context`: the context of one call on the server.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const rules = @import("../rules.zig");
const failures = @import("../failures.zig");
const Peer = @import("../transport.zig").Peer;
const Info = @import("../transport.zig").Info;
const ServerTransport = @import("../ServerTransport.zig");
const IdentityView = @import("../auth.zig").IdentityView;
const Credentials = @import("../credentials.zig").Credentials;

/// The context of one call on the server. The engine creates it for each
/// call; handlers and middleware get a borrowed pointer and must not keep it
/// after they return or hand it to background tasks.
///
/// ```zig
/// fn getUser(ctx: *rpc.Context) anyerror![]const u8 {
///     const op = ctx.operation(); // the deadline, the token and the trace
///     try op.check(std.Io.Clock.awake.now(ctx.io()));
///     const tenant = ctx.metadata().get("x-tenant") orelse
///         return ctx.fail(.{ .code = .invalid_argument, .app_code = "users.no_tenant", .message = "No tenant" });
///     try ctx.setResponseMetadata("x-cache", "miss");
///     return std.fmt.allocPrint(ctx.allocator(), "{{\"tenant\":\"{s}\"}}", .{tenant});
/// }
/// ```
pub const Context = opaque {
    /// The `std.Io` the server runs on: every wait of the handler goes
    /// through it.
    pub fn io(ctx: *Context) std.Io {
        return state(ctx).io;
    }

    /// The `core.Context` of the call: its deadline, its own cancellation
    /// token and the server's span of the caller's trace. Pass it to
    /// repositories and to nested calls: a nested call's deadline only
    /// shortens, and its trace goes on from this span. The engine cancels
    /// the token when the deadline passes, the client gives up or the
    /// server stops, and cancels the handler's task too.
    pub fn operation(ctx: *Context) core.Context {
        return state(ctx).operation;
    }

    /// The arena of the call, freed after the response is sent. Parallel
    /// tasks of the handler must not use it.
    pub fn allocator(ctx: *Context) std.mem.Allocator {
        return state(ctx).arena;
    }

    /// The service, version and method of the call.
    pub fn route(ctx: *Context) model.Route {
        return state(ctx).route;
    }

    /// 16 bytes for logs and tracing; not an idempotency key.
    pub fn requestId(ctx: *Context) [16]u8 {
        return state(ctx).request_id;
    }

    /// The request's metadata, to read: without the reserved keys
    /// (authorization, traceparent, tracestate, zefir-correlation-id).
    pub fn metadata(ctx: *Context) model.Metadata.View {
        return .{ .entries = state(ctx).metadata };
    }

    /// Who sent the call, as the transport knows it: for logs, never for
    /// authorization.
    pub fn peer(ctx: *Context) Peer {
        return state(ctx).peer;
    }

    /// What the transport can do: for logs, never for authorization.
    pub fn transport(ctx: *Context) Info {
        return state(ctx).server_transport.info();
    }

    /// Who calls, as the server's authenticator found; null for an
    /// anonymous call. Its strings live in the arena of the call or are
    /// constant.
    pub fn identity(ctx: *Context) ?IdentityView {
        return state(ctx).identity;
    }

    /// The request's body in bytes, as the client encoded it: for
    /// middleware that checks or logs it before anything decodes it. Never
    /// change it.
    pub fn requestBody(ctx: *Context) []const u8 {
        return state(ctx).request_body;
    }

    /// For middleware, after its `next.run()`: the body of the successful
    /// response in bytes. Null before `next.run()` and when it failed.
    /// Never change it.
    pub fn responseBody(ctx: *Context) ?[]const u8 {
        return state(ctx).response_body;
    }

    pub const SetMetadataError = error{
        /// A key or value against the metadata rules, or a reserved or
        /// `zefir-*` key: those are the engine's.
        InvalidMetadata,
        /// Over `max_metadata_entries` or `max_metadata_bytes` of the
        /// server.
        ResourceExhausted,
        OutOfMemory,
    };

    /// Adds a pair to the metadata of the response, success or failure;
    /// copied into the arena. The rules of request metadata apply; the
    /// same key may repeat.
    pub fn setResponseMetadata(ctx: *Context, key: []const u8, value: []const u8) SetMetadataError!void {
        const c = state(ctx);
        if (!rules.isValidKey(key) or !rules.isValidValue(value)) return error.InvalidMetadata;
        if (rules.isReserved(key) or std.mem.startsWith(u8, key, rules.engine_prefix)) return error.InvalidMetadata;
        const bytes = c.response_metadata_bytes + 3 + key.len + value.len;
        if (c.response_metadata.items.len + 1 > c.metadata_limits.max_entries or bytes > c.metadata_limits.max_bytes)
            return error.ResourceExhausted;
        const entry: model.Metadata.Entry = .{ .key = try c.arena.dupe(u8, key), .value = try c.arena.dupe(u8, value) };
        try c.response_metadata.append(c.arena, entry);
        c.response_metadata_bytes = bytes;
    }

    /// Ends the call with exactly this failure: `return ctx.fail(.{ .code,
    /// .app_code, .message })`. Middleware sees `error.RpcFailure` and the
    /// failure in `failure()`. Its strings may point into the arena, the
    /// request or literals.
    pub fn fail(ctx: *Context, reason: model.Failure) error{RpcFailure} {
        return failWithBody(ctx, reason, "");
    }

    /// The failure set with `fail`, if any.
    pub fn failure(ctx: *Context) ?model.Failure {
        return state(ctx).recorded;
    }

    /// The failure the engine sends for `err`, for logs of middleware:
    /// the recorded failure for `error.RpcFailure`, then the contract's
    /// table, then the framework's names, else `internal`.
    pub fn mapError(ctx: *Context, err: anyerror) model.Failure {
        const c = state(ctx);
        return failures.fromError(err, c.recorded, c.map_error);
    }
};

/// `ctx.fail` with a body for the failure: the JSON violations of
/// `rpc.Server`. Internal to the module.
pub fn failWithBody(ctx: *Context, reason: model.Failure, body: []const u8) error{RpcFailure} {
    const c = state(ctx);
    c.recorded = reason;
    c.failure_body = body;
    return error.RpcFailure;
}

fn state(ctx: *Context) *CallContext {
    return @ptrCast(@alignCast(ctx));
}

/// The call behind `ctx`. Internal to the module.
pub fn callOf(ctx: *Context) *CallContext {
    return state(ctx);
}

/// What `rpc.Context` reads and writes: one per call, inside the engine's
/// call. Internal to the module.
pub const CallContext = struct {
    io: std.Io,
    /// The deadline of the call, its own token and the server's span.
    operation: core.Context,
    /// The arena of the call.
    arena: std.mem.Allocator,
    route: model.Route,
    request_id: [16]u8,
    /// The request's metadata without the reserved keys.
    metadata: []const model.Metadata.Entry,
    peer: Peer,
    server_transport: ServerTransport,
    map_error: ?*const fn (err: anyerror) ?model.Failure,
    /// The limits of the response's metadata: those of a request.
    metadata_limits: rules.MetadataLimits,
    /// The reserved values of the request, for the engine. The call wipes
    /// `authorization` before it frees it.
    authorization: ?[]u8 = null,
    correlation_id: ?[]const u8 = null,
    /// `authorization` parsed for the authenticator; the call wipes what
    /// was decoded into the arena.
    credentials: Credentials = .none,
    /// Set once the authenticator returned an identity.
    identity: ?IdentityView = null,
    /// The body the transport filled in.
    request_body: []const u8 = "",
    /// The handler's body, while the middleware that looks at it has seen
    /// its `next.run()` succeed.
    response_body: ?[]const u8 = null,
    /// The metadata of the response, in the arena.
    response_metadata: std.ArrayList(model.Metadata.Entry) = .empty,
    /// Its size, as `rpc.transport.metadataBytes` counts it.
    response_metadata_bytes: usize = 2,
    /// The failure set with `fail`.
    recorded: ?model.Failure = null,
    /// The body of the recorded failure (the violations of `rpc.Server`).
    failure_body: []const u8 = "",
};
