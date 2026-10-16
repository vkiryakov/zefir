//! `rpc.RawClient`: the client engine. It sends a call through a client
//! transport with a deadline, a request id, a span of the caller's trace
//! and the credentials of the call, and turns the errors of the transport
//! into its own, the same way on every transport. Bodies are bytes here:
//! `rpc.Client` adds JSON and validation on top, so applications use
//! `rpc.Client`, and tests of transports use the engine.
//!
//! ```zig
//! var client: rpc.RawClient = try .init(gpa, .{ .transport = memory.clientTransport() });
//! defer client.deinit();
//! const route: rpc.Route = .{ .service = "greeter", .version = 1, .method = "greet" };
//! var result = try client.call(io, ctx, route, "world", .{ .timeout = .fromMilliseconds(500) });
//! defer result.deinit();
//! switch (result.response.status) {
//!     .ok => std.log.info("{s}", .{result.response.body}),
//!     .failure => |failure| std.log.err("{s}: {s}", .{ failure.app_code, failure.message }),
//! }
//! ```
//!
//! The path of a call: the deadline is the earlier of the caller's and now
//! plus the timeout, and a canceled or expired context sends nothing; a
//! place among `max_pending`; a request id; a span of the caller's trace in
//! `traceparent`; the credentials in `authorization`, a provider asked right
//! before sending; the transport's call; the context checked once more, so
//! that a response at the deadline does not become a success after the
//! fact.

const std = @import("std");
const core = @import("core");
const model = @import("../model.zig");
const transport = @import("../transport.zig");
const rules = @import("../rules.zig");
const failures = @import("../failures.zig");
const credentials = @import("../credentials.zig");
const ClientTransport = @import("../ClientTransport.zig");
const Credentials = credentials.Credentials;
const Info = transport.Info;
const ClientMiddleware = @import("../middleware.zig").ClientMiddleware;

const RawClient = @This();

const log = std.log.scoped(.rpc);

gpa: std.mem.Allocator,
client_transport: ClientTransport,
/// The client's own copy of `Options.credentials`; `deinit` wipes it.
default_credentials: Credentials,
/// The client's own copy of `Options.middleware`.
middleware: []const ClientMiddleware,
default_timeout: std.Io.Duration,
max_pending: u32,
max_response_bytes: usize,
/// Calls in flight now.
pending: std.atomic.Value(u32) = .init(0),

pub const Options = struct {
    /// The client side of a transport. Its owner creates it before the
    /// client and frees it after the client's `deinit`.
    transport: ClientTransport,
    /// The credentials of every call that brings none of its own. `init`
    /// copies them, `deinit` wipes the copy. A `.provider` is borrowed, not
    /// copied: its object must outlive the client, and it serves all calls
    /// at once.
    credentials: Credentials = .none,
    /// The links around every call, outermost first. `init` copies the
    /// list; the objects are borrowed and must outlive the client.
    middleware: []const ClientMiddleware = &.{},
    /// The deadline of a call without a timeout of its own: now plus this,
    /// unless the caller's context ends earlier.
    default_timeout: std.Io.Duration = .fromSeconds(3),
    /// Calls in flight at once; one more gets
    /// `error.TooManyPendingRequests` and is not sent.
    max_pending: u32 = 1024,
    /// The largest response body; a larger one is `error.ResponseTooLarge`.
    max_response_bytes: usize = 1 << 20,
};

/// No I/O; allocates only the copies of the credentials and of the list of
/// middleware.
pub fn init(gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!RawClient {
    const default_credentials = try credentials.dupe(gpa, options.credentials);
    errdefer credentials.wipe(gpa, default_credentials);
    return .{
        .gpa = gpa,
        .client_transport = options.transport,
        .default_credentials = default_credentials,
        .middleware = try gpa.dupe(ClientMiddleware, options.middleware),
        .default_timeout = options.default_timeout,
        .max_pending = options.max_pending,
        .max_response_bytes = options.max_response_bytes,
    };
}

/// Wipes the copy of the credentials and frees what `init` took. No call
/// may be in flight.
pub fn deinit(client: *RawClient) void {
    credentials.wipe(client.gpa, client.default_credentials);
    client.gpa.free(client.middleware);
    client.* = undefined;
}

/// What middleware of the client sees of one outgoing call. The engine
/// creates it for each call; a link gets a borrowed pointer and must not
/// keep it after it returns.
///
/// ```zig
/// fn tagCalls(ctx: *rpc.ClientContext, next: *rpc.ClientNext) anyerror!void {
///     try ctx.addMetadata("x-caller", "billing");
///     const started = std.Io.Clock.awake.now(ctx.io());
///     defer {
///         const took = started.durationTo(std.Io.Clock.awake.now(ctx.io()));
///         const failed = if (ctx.response()) |response| response.status == .failure else true;
///         std.log.info("{s} took {d} ms, failed: {}", .{ ctx.route().method, took.toMilliseconds(), failed });
///     }
///     return next.run();
/// }
/// ```
pub const ClientContext = opaque {
    /// The service, version and method of the call.
    pub fn route(ctx: *ClientContext) model.Route {
        return outgoingOf(ctx).route;
    }

    /// The caller's context with the deadline of the call and its span.
    pub fn operation(ctx: *ClientContext) core.Context {
        return outgoingOf(ctx).operation;
    }

    /// The caller's `std.Io`: every wait of a link goes through it.
    pub fn io(ctx: *ClientContext) std.Io {
        return outgoingOf(ctx).io;
    }

    /// The arena of the call: freed with its `Result`, or when the call
    /// fails.
    pub fn allocator(ctx: *ClientContext) std.mem.Allocator {
        return outgoingOf(ctx).arena;
    }

    /// The id the request goes out with, for logs.
    pub fn requestId(ctx: *ClientContext) [16]u8 {
        return outgoingOf(ctx).request_id;
    }

    /// What the client's transport can do: for logs.
    pub fn transport(ctx: *ClientContext) Info {
        return outgoingOf(ctx).client.client_transport.info();
    }

    /// Before `next.run()`: adds a pair to the request's metadata, after
    /// the application's; copied into the arena. Reserved and `zefir-*`
    /// keys are the engine's: `error.InvalidMetadata`, as are a key or a
    /// value against the rules.
    pub fn addMetadata(ctx: *ClientContext, key: []const u8, value: []const u8) error{ InvalidMetadata, OutOfMemory }!void {
        const o = outgoingOf(ctx);
        if (rules.checkUserMetadata(&.{.{ .key = key, .value = value }}) != null) return error.InvalidMetadata;
        // A Debug allocator may take a cancelable lock.
        const protection = o.io.swapCancelProtection(.blocked);
        defer _ = o.io.swapCancelProtection(protection);
        const entry: model.Metadata.Entry = .{ .key = try o.arena.dupe(u8, key), .value = try o.arena.dupe(u8, value) };
        try o.added.append(o.arena, entry);
    }

    /// Before `next.run()`: the credentials of this call instead of those it
    /// had, such as a fresh token. Borrowed until `next.run()` returns; a
    /// provider is asked right before sending. A secret the link copies into
    /// `allocator()` for this is freed with the call, not wiped: a provider
    /// is the way to credentials the engine wipes.
    pub fn setCredentials(ctx: *ClientContext, chosen: Credentials) void {
        outgoingOf(ctx).credentials = chosen;
    }

    /// After `next.run()` of this link has returned success: the server's
    /// response, a failure included. Null before it, and when it failed.
    /// Credentials that cannot travel, such as a token with a line break,
    /// are refused at the end of the chain, where the engine sends: the
    /// response is then the engine's `invalid_argument` ("Invalid
    /// authorization value"), and `sent()` is false. Under `rpc.Client` it
    /// is the response before the client decodes it: a success here may
    /// still end the call with `InvalidResponse` or `ResponseTooLarge`.
    pub fn response(ctx: *ClientContext) ?*const model.Response {
        const o = outgoingOf(ctx);
        if (!o.response_visible) return null;
        return if (o.response) |*r| r else null;
    }

    /// After `next.run()` of this link has returned success: whether the
    /// request went out, so that `response()` is the server's. False when
    /// the engine refused to send it, and while `response()` is null.
    pub fn sent(ctx: *ClientContext) bool {
        const o = outgoingOf(ctx);
        return o.response_visible and o.sent;
    }
};

fn outgoingOf(ctx: *ClientContext) *Outgoing {
    return @ptrCast(@alignCast(ctx));
}

/// The rest of the client's chain behind one link: `rpc.ClientNext`.
pub const ClientNext = opaque {
    /// Runs the links after this one, then the transport's call, and
    /// returns their outcome in the names of `CallError`. Exactly once per
    /// link. It may run in a task of the link's own, such as one the link
    /// cancels at a time limit of its own: canceling that task ends the
    /// attempt with `Cancelled`, and the link decides what to return.
    pub fn run(next: *ClientNext) anyerror!void {
        const link: *Outgoing.Link = @ptrCast(@alignCast(next));
        return link.runNext();
    }
};

pub const CallOptions = struct {
    /// The deadline is the earlier of the caller's and now plus this. Null:
    /// `Options.default_timeout`.
    timeout: ?std.Io.Duration = null,
    /// The application's metadata, borrowed until `call` returns. Reserved
    /// keys (authorization, traceparent, tracestate, zefir-correlation-id)
    /// and `zefir-*` keys are the engine's.
    metadata: []const model.Metadata.Entry = &.{},
    /// Null: the client's credentials. `.none`: this call is anonymous.
    /// Others, such as the token of an end user, are borrowed until `call`
    /// returns.
    credentials: ?Credentials = null,
    /// Details of an error of the transport, for logs.
    diagnostics: ?*transport.Diagnostics = null,
};

/// The response of one call. It owns the response's memory: exactly one
/// `deinit`, after which its slices are gone. Do not copy it as a second
/// owner.
pub const Result = struct {
    /// Success with a body, or the server's failure; `response.refused`: the
    /// server refused the call at admission and did not run it.
    response: model.Response,
    /// The id the request went out with, for logs.
    request_id: [16]u8,
    /// Whether the request went to the transport. False when the engine
    /// refused to send it: invalid metadata, route or credentials; the
    /// failure in `response` says which.
    sent: bool = true,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(result: *Result) void {
        result.arena.deinit();
        result.* = undefined;
    }
};

/// The errors of `call`: those of the transport (`rpc.ClientTransport`) in
/// the names of rpc 1.6, and the engine's own. A failure of the server is
/// not an error: it comes in `Result.response`.
pub const CallError = error{
    /// Not sent, or the server surely did not start the call: safe to retry.
    Unavailable,
    /// The transport or broker did not allow sending; not sent.
    AccessDenied,
    /// The link broke after sending; the call may have run.
    ConnectionLost,
    /// The caller's context was canceled, or the caller's task; the call may
    /// have run if it was sent.
    Cancelled,
    /// The deadline passed; the call may have run if it was sent.
    DeadlineExceeded,
    /// `max_pending` of the client or the transport's own limit; not sent.
    TooManyPendingRequests,
    /// Larger than the transport or the other side accepts; not sent.
    RequestTooLarge,
    /// The response is over the limits and was dropped; the call ran.
    ResponseTooLarge,
    /// The other side broke the protocol; the call may have run.
    ProtocolViolation,
    /// No protocol version or codec in common; not sent.
    UnsupportedProtocol,
    /// The owner closed the transport; not sent.
    ClientClosed,
    /// Any other error of the transport; details in `CallOptions.diagnostics`.
    TransportFailed,
    /// Middleware of the client returned an error outside this set.
    MiddlewareFailed,
    OutOfMemory,
};

/// Sends one call and waits for its response. From any number of tasks at
/// once. `ctx` is the caller's: its deadline, token and trace; in a handler,
/// `ctx.operation()`, so that a nested call keeps the rest of the deadline
/// and goes on in the server's span. A call whose context is canceled or
/// has expired is not sent. `request` and the slices of `options` are
/// borrowed until `call` returns.
///
/// A deadline that has passed ends the call with `error.DeadlineExceeded`,
/// even when the token is canceled too: a server cancels the token of a
/// call at its deadline, and a nested call made with that context then
/// ends as one that ran out of time. `error.Cancelled` also comes when the
/// caller's task is canceled during the call: the cancelation stays for
/// the task's next cancelation point, so `io.checkCancel()` still sees it.
pub fn call(client: *RawClient, io: std.Io, ctx: core.Context, route: model.Route, request: []const u8, options: CallOptions) CallError!Result {
    const started = now(io);
    var operation = ctx.withDeadline(.after(started, options.timeout orelse client.default_timeout));
    try checkContext(operation, started);
    if (!client.takePending()) return error.TooManyPendingRequests;
    defer _ = client.pending.fetchSub(1, .release);

    var request_id: [16]u8 = undefined;
    io.random(&request_id);
    // The call is a span of the caller's trace.
    if (operation.trace) |parent| operation = operation.withTrace(parent.child(newSpanId(io)));

    var arena: std.heap.ArenaAllocator = .init(client.gpa);
    errdefer freeArena(io, &arena);
    rules.validateRoute(route) catch return notSent(arena, request_id, failures.invalid_route);
    if (rules.checkUserMetadata(options.metadata) != null) return notSent(arena, request_id, failures.invalid_metadata);

    var outgoing: Outgoing = .{
        .client = client,
        .io = io,
        .operation = operation,
        .arena = arena.allocator(),
        .route = route,
        .request_id = request_id,
        .request = request,
        .metadata = options.metadata,
        .credentials = options.credentials orelse client.default_credentials,
        .diagnostics = options.diagnostics,
    };
    try outgoing.runLayer(0);
    return .{ .response = outgoing.response.?, .request_id = request_id, .sent = outgoing.sent, .arena = arena };
}

/// The caller's context at `at`: `DeadlineExceeded` once its deadline has
/// passed, else `Cancelled` when its token is canceled. Unlike
/// `core.Context.check`, the deadline comes first: a timeout is a
/// deadline, not a cancelation.
fn checkContext(operation: core.Context, at: std.Io.Timestamp) CallError!void {
    if (operation.isExpired(at)) return error.DeadlineExceeded;
    if (operation.isCancelled()) return error.Cancelled;
}

/// A call the engine refused to send.
fn notSent(arena: std.heap.ArenaAllocator, request_id: [16]u8, failure: model.Failure) Result {
    return .{ .response = .{ .status = .{ .failure = failure } }, .request_id = request_id, .sent = false, .arena = arena };
}

fn takePending(client: *RawClient) bool {
    var current = client.pending.load(.monotonic);
    while (true) {
        if (current >= client.max_pending) return false;
        current = client.pending.cmpxchgWeak(current, current + 1, .acquire, .monotonic) orelse return true;
    }
}

/// One call on its way: what the engine sends, and what came back.
const Outgoing = struct {
    client: *RawClient,
    io: std.Io,
    /// The caller's context with the deadline of the call and its span.
    operation: core.Context,
    /// The arena of the call: the `Result` owns it.
    arena: std.mem.Allocator,
    route: model.Route,
    request_id: [16]u8,
    request: []const u8,
    /// The application's metadata, checked.
    metadata: []const model.Metadata.Entry,
    /// What middleware added, in the arena.
    added: std.ArrayList(model.Metadata.Entry) = .empty,
    credentials: Credentials,
    diagnostics: ?*transport.Diagnostics,
    response: ?model.Response = null,
    sent: bool = false,
    /// `response` is what the running link's `next.run()` returned.
    response_visible: bool = false,
    /// A link called `next.run()` twice: the call fails with
    /// `MiddlewareFailed`.
    violation: bool = false,

    /// Runs link `index` and all inside it; the transport's call past the
    /// last link. Errors come in the names of `CallError`.
    fn runLayer(o: *Outgoing, index: usize) CallError!void {
        const links = o.client.middleware;
        if (index == links.len) return o.send();
        var link: Link = .{ .outgoing = o, .index = index };
        const result = links[index].run(links[index].ptr, @ptrCast(o), @ptrCast(&link));
        // A second next.run() decides, whatever the links did with it.
        if (o.violation) return error.MiddlewareFailed;
        // An error the link returns is the outcome.
        result catch |err| return o.linkError(err);
        if (!link.called) {
            o.warn("returned success without calling next.run()");
            return error.MiddlewareFailed;
        }
        // An error from inside that the link swallowed stays the outcome.
        if (link.inner) |err| return err;
    }

    const Link = struct {
        outgoing: *Outgoing,
        index: usize,
        called: bool = false,
        /// What `next.run()` returned, when it failed.
        inner: ?CallError = null,

        fn runNext(link: *Link) CallError!void {
            const o = link.outgoing;
            if (link.called) {
                o.violation = true;
                o.warn("called next.run() twice");
                return error.MiddlewareFailed;
            }
            link.called = true;
            o.response_visible = false;
            o.runLayer(link.index + 1) catch |err| {
                link.inner = err;
                o.response_visible = false;
                return err;
            };
            o.response_visible = true;
        }
    };

    /// An error a link returned, in the names of `CallError`: a `Canceled`
    /// the link met at a cancelation point of its task is re-armed, an
    /// error outside the set is `MiddlewareFailed`.
    fn linkError(o: *Outgoing, err: anyerror) CallError {
        if (err == error.Canceled) return o.canceled();
        inline for (@typeInfo(CallError).error_set.error_names.?) |name| {
            if (err == @field(CallError, name)) return @field(CallError, name);
        }
        return error.MiddlewareFailed;
    }

    fn warn(o: *Outgoing, comptime what: []const u8) void {
        // The log may take a cancelable lock; a cancelation of the caller stays.
        const protection = o.io.swapCancelProtection(.blocked);
        defer _ = o.io.swapCancelProtection(protection);
        log.warn("client middleware of {s}.v{d}.{s} " ++ what ++ "; the call fails with MiddlewareFailed", .{ o.route.service, o.route.version, o.route.method });
    }

    /// Asks a provider for the credentials, encodes them, sends the request
    /// and takes the response. The credentials of the call live in an arena
    /// that is wiped once the transport is done with the request.
    fn send(o: *Outgoing) CallError!void {
        const io = o.io;
        // A context canceled or expired while the links ran: nothing goes
        // out, and no provider is asked.
        try checkContext(o.operation, now(io));
        var wiping: credentials.Wiping = .{ .gpa = o.client.gpa };
        var secrets: std.heap.ArenaAllocator = .init(wiping.allocator());
        defer freeArena(io, &secrets);
        const chosen = try o.askProvider(secrets.allocator());
        // Credentials the server would read as something else stay here.
        if (!credentials.readsBack(chosen)) return o.refuseAuthorization();
        const authorization = authorization: {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            break :authorization try credentials.encode(secrets.allocator(), chosen);
        };
        if (authorization) |value| if (!rules.isValidValue(value)) return o.refuseAuthorization();
        const request: transport.Request = .{
            .route = o.route,
            .request_id = o.request_id,
            .codec = "json",
            .ctx = o.operation,
            .metadata = try o.requestMetadata(authorization),
            .body = o.request,
        };
        // Once more right before sending: the provider may have taken a
        // while.
        try checkContext(o.operation, now(io));
        const response = o.client.client_transport.call(io, &request, .{
            .allocator = o.arena,
            .max_response_bytes = o.client.max_response_bytes,
            .diagnostics = o.diagnostics,
        }) catch |err| return o.transportError(err);
        // A success at the deadline is not a success after the fact. A
        // failure of the server stays what it is: a refusal still promises
        // that the call did not run.
        if (response.status == .ok) try checkContext(o.operation, now(io));
        o.response = response;
        o.sent = true;
    }

    /// Ends the call without sending it: its credentials cannot travel.
    fn refuseAuthorization(o: *Outgoing) void {
        o.response = .{ .status = .{ .failure = failures.invalid_authorization } };
    }

    /// The credentials of the call; a provider is asked now.
    fn askProvider(o: *Outgoing, secrets: std.mem.Allocator) CallError!Credentials {
        const provider = switch (o.credentials) {
            .provider => |provider| provider,
            else => |chosen| return chosen,
        };
        const got = provider.get(provider.ptr, o.io, o.operation, secrets) catch |err| switch (err) {
            error.Unavailable => return error.Unavailable,
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return o.canceled(),
        };
        if (got == .provider) @panic("rpc.RawClient: a CredentialsProvider returned .provider; return the credentials of the call");
        return got;
    }

    /// The engine's keys first (the span of the call, the credentials), then
    /// the application's, then those of middleware; in the arena of the call.
    fn requestMetadata(o: *Outgoing, authorization: ?[]const u8) error{OutOfMemory}![]const model.Metadata.Entry {
        const protection = o.io.swapCancelProtection(.blocked);
        defer _ = o.io.swapCancelProtection(protection);
        var list: std.ArrayList(model.Metadata.Entry) = try .initCapacity(o.arena, 3 + o.metadata.len + o.added.items.len);
        if (o.operation.trace) |trace| {
            const buffer = try o.arena.create([core.w3c.traceparent_len]u8);
            list.appendAssumeCapacity(.{ .key = core.w3c.traceparent_header, .value = core.w3c.formatTraceparent(trace, buffer) });
            // A tracestate that metadata cannot carry, such as one with a
            // tab between its members, stays behind.
            if (!trace.state.isEmpty() and rules.isValidValue(trace.state.header))
                list.appendAssumeCapacity(.{ .key = core.w3c.tracestate_header, .value = trace.state.header });
        }
        if (authorization) |value| list.appendAssumeCapacity(.{ .key = "authorization", .value = value });
        list.appendSliceAssumeCapacity(o.metadata);
        list.appendSliceAssumeCapacity(o.added.items);
        return list.items;
    }

    /// An error of the transport in the names of `CallError`.
    fn transportError(o: *Outgoing, err: ClientTransport.CallError) CallError {
        return switch (err) {
            error.Timeout => error.DeadlineExceeded,
            error.Canceled => o.canceled(),
            error.Closed => error.ClientClosed,
            error.Unexpected => error.TransportFailed,
            error.Unavailable => error.Unavailable,
            error.AccessDenied => error.AccessDenied,
            error.ConnectionLost => error.ConnectionLost,
            error.TooManyPendingRequests => error.TooManyPendingRequests,
            error.RequestTooLarge => error.RequestTooLarge,
            error.ResponseTooLarge => error.ResponseTooLarge,
            error.ProtocolViolation => error.ProtocolViolation,
            error.UnsupportedProtocol => error.UnsupportedProtocol,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// The caller's task was canceled at a cancelation point: the
    /// cancelation is re-armed for the task's next one, and the call ends
    /// with `DeadlineExceeded` when its deadline has passed, else
    /// `Cancelled`.
    fn canceled(o: *Outgoing) CallError {
        o.io.recancel();
        checkContext(o.operation, now(o.io)) catch |err| return err;
        return error.Cancelled;
    }
};

/// Frees an arena of the engine with the caller's cancelation held: a
/// Debug allocator may take a cancelable lock.
fn freeArena(io: std.Io, arena: *std.heap.ArenaAllocator) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    arena.deinit();
}

fn newSpanId(io: std.Io) core.SpanId {
    while (true) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        // All zero is not a span id; draw again.
        return core.SpanId.fromBytes(bytes) catch continue;
    }
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

test {
    _ = @import("client_tests.zig");
}
