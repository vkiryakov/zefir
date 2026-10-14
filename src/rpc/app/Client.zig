//! `rpc.Client`: the client of an application. It calls the methods of
//! contracts over a transport; requests and responses are the contracts'
//! types, sent as JSON.
//!
//! ```zig
//! var client = try rpc.Client.init(gpa, .{
//!     .transport = bus.clientTransport(), // rpc_nats.Transport; in tests the memory transport
//!     .credentials = .{ .bearer = config.users_token.expose() }, // for every call that brings none
//!     // .middleware = .{ clientMetrics, &breaker },  // around every call, in order
//!     // .default_timeout = std.Io.Duration.fromSeconds(3),
//! });
//! defer client.deinit();
//!
//! var r = try client.call(io, ctx, api.UserApi.getUser, .{ .id = 42 }, .{ .timeout = .fromMilliseconds(500) });
//! defer r.deinit();
//! switch (r.outcome) {
//!     .ok => |user| std.log.info("{s}", .{user.name}), // user: api.User
//!     .failure => |f| std.log.err("{s} ({s})", .{ f.message, f.app_code }),
//! }
//! ```
//!
//! A client has no lifecycle: `init` does no I/O, then come calls, then
//! `deinit`. The transport connects and reconnects, not the client. One
//! client calls any contracts on its transport; separate clients are for
//! services with other credentials or middleware.
//!
//! The path of a call:
//!
//! 1. The request is checked against its `field_rules`. A request against
//!    them is not sent: the outcome is a failure `invalid_argument` /
//!    `rpc.invalid_request` with all its violations, and `sent` is false.
//! 2. It is encoded as JSON. A NaN or infinite float, or a string that is
//!    not UTF-8, is not sent either: the same failure, with a message that
//!    says which.
//! 3. The engine, `rpc.RawClient`, sends it: the deadline, a request id, a
//!    span of the caller's trace, the credentials, the client's middleware,
//!    the transport's call.
//! 4. A success is decoded as the method's response type and checked
//!    against its rules; a response that fails either is
//!    `error.InvalidResponse`: the server and the client disagree about the
//!    contract. A failure of the server comes as `.failure`, with the
//!    violations from its body.
//!
//! A failure of the server is a value, not an error. The errors of `call`
//! are local; `CallError` says which of them are safe to retry.

const std = @import("std");
const core = @import("core");
const v = @import("validator");
const model = @import("../model.zig");
const rules = @import("../rules.zig");
const transport = @import("../transport.zig");
const RawClient = @import("../engine/RawClient.zig");
const ClientMiddleware = @import("../middleware.zig").ClientMiddleware;
const Credentials = @import("../credentials.zig").Credentials;
const json = @import("json.zig");
const violations = @import("violations.zig");
const contract = @import("contract.zig");
const client_options = @import("client_options.zig");

const Client = @This();

/// The engine that sends the calls; `init` builds it from the options.
engine: RawClient,

/// A decoded response may take this many times `max_response_bytes` of
/// memory: the memory of a value follows its type, not the size of its
/// JSON, so a small body may ask for much more.
pub const decode_budget_factor = 8;
/// The least memory a decoded response may take, whatever
/// `max_response_bytes` is.
pub const min_decode_budget = 64 * 1024;

/// The errors of `call`: those of `rpc.RawClient`, and `InvalidResponse`.
/// A failure of the server is not among them: it comes in the outcome.
///
/// | Error | Means | Retry |
/// |---|---|---|
/// | `Unavailable` | not sent, or surely not run: no link, the server drains, no server at all (NATS no responders), an open circuit breaker | safe |
/// | `DeadlineExceeded`, `Cancelled` | the deadline or a cancelation; if the request went out, the outcome is unknown | only an idempotent call |
/// | `ConnectionLost` | the link broke after sending; the outcome is unknown | only an idempotent call |
/// | `AccessDenied` | the broker did not allow sending (NATS permissions) | after a change of settings |
/// | `TooManyPendingRequests` | `max_pending` calls in flight; not sent | later |
/// | `RequestTooLarge` | larger than the transport carries; not sent | no |
/// | `ResponseTooLarge` | the response is over the client's limits and was dropped, but the server ran the call | only an idempotent call |
/// | `InvalidResponse` | the response does not decode as the method's type or breaks its `field_rules`: the versions of a DTO diverged | no |
/// | `ProtocolViolation`, `UnsupportedProtocol`, `TransportFailed` | a failure of the protocol or the transport; details in `CallOptions.diagnostics` | only an idempotent call |
/// | `MiddlewareFailed` | middleware of the client returned an error outside this set; if the request went out, the outcome is unknown | only an idempotent call |
/// | `ClientClosed`, `OutOfMemory` | — | — |
pub const CallError = RawClient.CallError || error{
    /// The response does not decode as the method's response type, or it
    /// breaks the type's `field_rules`: the server and the client disagree
    /// about the contract. The call ran.
    InvalidResponse,
};

pub const CallOptions = struct {
    /// The deadline is the earlier of the caller's and now plus this. Null:
    /// the client's `default_timeout`.
    timeout: ?std.Io.Duration = null,
    /// The application's metadata, borrowed until `call` returns. Reserved
    /// keys (authorization, traceparent, tracestate, zefir-correlation-id)
    /// and `zefir-*` keys are the engine's: a call with them is not sent.
    metadata: []const model.Metadata.Entry = &.{},
    /// Null: the client's credentials. `.none`: this call is anonymous.
    /// Others, such as the token of an end user, are borrowed until `call`
    /// returns.
    credentials: ?Credentials = null,
    /// Details of an error of the transport, and of
    /// `error.InvalidResponse`: what in the response is wrong and where,
    /// never a value of it. For logs.
    diagnostics: ?*transport.Diagnostics = null,
};

/// The outcome of one call of a method whose response type is `Resp`. It
/// owns the memory of the response: exactly one `deinit`, after which the
/// response and its slices are gone. Do not copy it as a second owner.
pub fn Result(comptime Resp: type) type {
    return struct {
        const Self = @This();

        /// The response, or a failure: the server's, or the client's own
        /// for a request it did not send (`sent` is false then).
        outcome: Outcome,
        /// The id the request went out with, for logs.
        request_id: [16]u8,
        /// Whether the request went to the transport. False when the client
        /// refused to send it: a request against its rules or one JSON
        /// cannot carry, invalid metadata, route or credentials; the failure
        /// says which.
        sent: bool,
        /// The server refused the call at admission and guarantees that it
        /// did not run: a retry is safe.
        refused: bool,
        /// The entries that `metadata()` reads.
        response_metadata: []const model.Metadata.Entry,
        /// Holds the response; `deinit` frees it.
        arena: std.heap.ArenaAllocator,

        pub const Outcome = union(enum) {
            ok: Resp,
            failure: model.Failure,
        };

        /// The metadata of the response: `get(key)`, `getAll(key)`,
        /// `iterator()`.
        pub fn metadata(result: *const Self) model.Metadata.View {
            return .{ .entries = result.response_metadata };
        }

        pub fn deinit(result: *Self) void {
            result.arena.deinit();
            result.* = undefined;
        }
    };
}

/// Builds a client from `options`, a struct literal:
///
/// - `.transport`: the client side of a transport, `rpc.ClientTransport`;
///   its owner keeps it until after the client's `deinit`;
/// - `.credentials` (optional): those of every call that brings none of
///   its own, such as `.{ .bearer = token }`,
///   `.{ .basic = .{ .user = "billing", .password = secret } }`,
///   `.{ .provider = oauth.credentialsProvider() }` (asked before every
///   call) or `.none`, the default. `init` copies them and `deinit` wipes
///   the copy; a provider is borrowed and must outlive the client;
/// - `.middleware` (optional): the links around every call, in order:
///   functions of type `rpc.ClientMiddlewareFn` and pointers to objects
///   with `run`, such as `.{ clientMetrics, &breaker }`. The objects are
///   borrowed and serve all calls at once;
/// - `.default_timeout` (optional): the deadline of a call without a
///   timeout of its own, 3 seconds by default;
/// - `.max_pending` (optional): calls in flight at once, 1024 by default;
///   one more gets `error.TooManyPendingRequests`;
/// - `.max_response_bytes` (optional): the largest response body, 1 MiB by
///   default. A larger one is `error.ResponseTooLarge`, and so is a
///   response that takes more than `decode_budget_factor` times as much
///   memory once decoded (at least `min_decode_budget`).
///
/// Options are `anytype`, so a value inside them has no type to take a
/// declaration literal from: write `std.Io.Duration.fromSeconds(3)`, not
/// `.fromSeconds(3)`.
///
/// No I/O: memory only for the copies of the credentials and of the list of
/// middleware.
pub fn init(gpa: std.mem.Allocator, options: anytype) error{OutOfMemory}!Client {
    const O = @TypeOf(options);
    comptime check(O);
    var engine_options: RawClient.Options = .{ .transport = options.transport };
    if (@hasField(O, "credentials")) {
        if (@FieldType(O, "credentials") == @TypeOf(.enum_literal)) comptime checkLiteral(options.credentials);
        engine_options.credentials = client_options.credentialsOf(options.credentials);
    }
    const Links = if (@hasField(O, "middleware")) @FieldType(O, "middleware") else @TypeOf(.{});
    // The engine copies the list.
    var links: [@typeInfo(Links).@"struct".field_names.len]ClientMiddleware = undefined;
    if (@hasField(O, "middleware")) engine_options.middleware = client_options.linksOf(options.middleware, &links);
    if (@hasField(O, "default_timeout")) engine_options.default_timeout = options.default_timeout;
    if (@hasField(O, "max_pending")) engine_options.max_pending = options.max_pending;
    if (@hasField(O, "max_response_bytes")) engine_options.max_response_bytes = options.max_response_bytes;
    return .{ .engine = try .init(gpa, engine_options) };
}

fn check(comptime O: type) void {
    if (client_options.optionsProblem(O)) |message| @compileError(message);
}

fn checkLiteral(comptime literal: @TypeOf(.enum_literal)) void {
    if (client_options.literalProblem(literal)) |message| @compileError(message);
}

/// Wipes the copy of the credentials and frees what `init` took. No call
/// may be in flight; results stay valid until their own `deinit`.
pub fn deinit(client: *Client) void {
    client.engine.deinit();
    client.* = undefined;
}

/// Calls `method`, a method of a contract such as `api.UserApi.getUser`,
/// with `request` and waits for the outcome. From any number of tasks at
/// once. `ctx` is the caller's context: its deadline, cancelation and
/// trace; in a handler, `ctx.operation()`, so that the nested call keeps
/// the rest of the deadline and goes on in the server's span. `request` and
/// the slices of `options` are borrowed until `call` returns.
///
/// `error.Cancelled` also comes when the caller's task is canceled during
/// the call; the cancelation stays for the task's next cancelation point.
pub fn call(
    client: *Client,
    io: std.Io,
    ctx: core.Context,
    comptime method: anytype,
    request: RequestOf(@TypeOf(method)),
    options: CallOptions,
) CallError!Result(ResponseOf(@TypeOf(method))) {
    const M = @TypeOf(method);
    const Resp = M.Response;
    var path_buf: [rules.max_field_bytes]u8 = undefined;
    if (v.check(&request, &path_buf) != null) return client.refuseRequest(io, M.Request, Resp, &request);
    const body = client.encodeRequest(io, M.Request, &request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NonFinite => return notSent(io, Resp, non_finite_request, .init(client.engine.gpa)),
        error.InvalidUtf8 => return notSent(io, Resp, not_utf8_request, .init(client.engine.gpa)),
    };
    defer client.freeRequest(io, body);
    var raw = try client.engine.call(io, ctx, M.route, body, .{
        .timeout = options.timeout,
        .metadata = options.metadata,
        .credentials = options.credentials,
        .diagnostics = options.diagnostics,
    });
    errdefer freeArena(io, &raw.arena);
    // What the response decodes into lives with it, in the arena of the
    // call, within the client's budget.
    var budget: Budget = .{ .child = raw.arena.allocator(), .limit = client.decodeBudget() };
    const outcome: Result(Resp).Outcome = switch (raw.response.status) {
        .ok => .{ .ok = try decodeResponse(M, io, &budget, raw.response.body, options.diagnostics) },
        .failure => |reason| failure: {
            var failure = reason;
            if (raw.response.body.len > 0) try readViolations(io, &budget, raw.response.body, &failure);
            break :failure .{ .failure = failure };
        },
    };
    return .{
        .outcome = outcome,
        .request_id = raw.request_id,
        .sent = raw.sent,
        .refused = raw.response.refused,
        .response_metadata = raw.response.metadata,
        .arena = raw.arena,
    };
}

/// The request type of `M`, the type of a method of a contract; another
/// type stops the build.
fn RequestOf(comptime M: type) type {
    comptime checkMethod(M);
    return M.Request;
}

/// The response type of `M`, the type of a method of a contract.
fn ResponseOf(comptime M: type) type {
    comptime checkMethod(M);
    return M.Response;
}

fn checkMethod(comptime M: type) void {
    const is_method = switch (@typeInfo(M)) {
        .@"struct" => @hasDecl(M, "is_rpc_method"),
        else => false,
    };
    if (is_method) return;
    const expected = "rpc.Client.call: the method must be a method of a contract, such as UserApi.getUser; got ";
    if (contract.isContract(M)) @compileError(expected ++ "the contract " ++ contract.InfoOf(M).label ++ " itself");
    @compileError(expected ++ @typeName(M));
}

/// A request with a NaN or infinite float, which JSON has no numbers for.
const non_finite_request: model.Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "A float of the request is NaN or infinite" };
/// A request with a string that is not UTF-8.
const not_utf8_request: model.Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_request", .message = "A string of the request is not UTF-8" };

/// The outcome of a request against its rules, which is not sent: all its
/// violations, as the server reports those of a request it got.
fn refuseRequest(client: *Client, io: std.Io, comptime Req: type, comptime Resp: type, request: *const Req) error{OutOfMemory}!Result(Resp) {
    // A Debug allocator may take a cancelable lock.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var arena: std.heap.ArenaAllocator = .init(client.engine.gpa);
    errdefer arena.deinit();
    const report = try v.checkAll(arena.allocator(), request);
    const list = try violations.fromReport(arena.allocator(), report);
    return notSent(io, Resp, .{
        .code = .invalid_argument,
        .app_code = "rpc.invalid_request",
        .message = "Invalid request",
        .field = if (list.len > 0) list[0].field else null,
        .violations = list,
        .violations_truncated = report.truncated,
    }, arena);
}

/// The outcome of a call the client does not send; `arena` holds what the
/// failure points to.
fn notSent(io: std.Io, comptime Resp: type, failure: model.Failure, arena: std.heap.ArenaAllocator) Result(Resp) {
    var request_id: [16]u8 = undefined;
    io.random(&request_id);
    return .{
        .outcome = .{ .failure = failure },
        .request_id = request_id,
        .sent = false,
        .refused = false,
        .response_metadata = &.{},
        .arena = arena,
    };
}

/// `request` as JSON, in memory of the client's allocator.
fn encodeRequest(client: *Client, io: std.Io, comptime Req: type, request: *const Req) error{ OutOfMemory, NonFinite, InvalidUtf8 }![]u8 {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var out: std.Io.Writer.Allocating = .init(client.engine.gpa);
    defer out.deinit();
    json.encode(Req, request, &out.writer) catch |err| return switch (err) {
        // The only way an allocating writer fails.
        error.WriteFailed => error.OutOfMemory,
        error.NonFinite => error.NonFinite,
        error.InvalidUtf8 => error.InvalidUtf8,
    };
    return out.toOwnedSlice();
}

fn freeRequest(client: *Client, io: std.Io, bytes: []u8) void {
    // The caller's cancelation, which the engine may have re-armed, stays.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    client.engine.gpa.free(bytes);
}

/// The memory a decoded response may take.
fn decodeBudget(client: *const Client) usize {
    return @max(client.engine.max_response_bytes *| decode_budget_factor, min_decode_budget);
}

/// The response of `M` in `body`, decoded within `budget` and checked
/// against its rules; `error.InvalidResponse` when either fails, with the
/// details in `diagnostics`.
fn decodeResponse(comptime M: type, io: std.Io, budget: *Budget, body: []const u8, diagnostics: ?*transport.Diagnostics) CallError!M.Response {
    const Resp = M.Response;
    const where = M.contract.label ++ "." ++ M.name;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var problem: json.Problem = .{};
    const value = json.decode(Resp, budget.allocator(), body, .{}, &problem) catch |err| switch (err) {
        error.Invalid => {
            if (diagnostics) |d| {
                if (problem.field) |field| {
                    d.set(.receive, null, where ++ ": the response does not decode: {s} at {s}", .{ problem.message, field });
                } else d.set(.receive, null, where ++ ": the response does not decode: {s}", .{problem.message});
            }
            return error.InvalidResponse;
        },
        error.OutOfMemory => return budget.outOfMemory(),
    };
    if (Resp != void) {
        var path_buf: [rules.max_field_bytes]u8 = undefined;
        if (v.check(&value, &path_buf)) |violation| {
            // The path, a code and a static message: no value.
            if (diagnostics) |d| {
                if (violation.field) |field| {
                    d.set(.receive, null, where ++ ": the response breaks its rules at {s}: {s} ({s})", .{ field, violation.message, violation.code });
                } else d.set(.receive, null, where ++ ": the response breaks its rules: {s} ({s})", .{ violation.message, violation.code });
            }
            return error.InvalidResponse;
        }
    }
    return value;
}

/// The body of a failure with violations, as `rpc.Server` writes it.
const ViolationsBody = struct {
    violations: []const model.Violation,
    truncated: bool = false,
};

/// The violations in `body`, the body of `failure`, into `failure`: at most
/// 100, with paths as a failure carries them. A body that is not a list of
/// violations, such as the text of a service that is not zefir, is left
/// aside: the failure stays what it is.
fn readViolations(io: std.Io, budget: *Budget, body: []const u8, failure: *model.Failure) error{ OutOfMemory, ResponseTooLarge }!void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    var problem: json.Problem = .{};
    const parsed = json.decode(ViolationsBody, budget.allocator(), body, .{}, &problem) catch |err| switch (err) {
        error.Invalid => return,
        error.OutOfMemory => return budget.outOfMemory(),
    };
    const kept = parsed.violations[0..@min(parsed.violations.len, violations.max_violations)];
    const list = budget.allocator().alloc(model.Violation, kept.len) catch return budget.outOfMemory();
    for (kept, list) |item, *violation| violation.* = .{ .field = violations.fieldOf(item.field), .code = item.code, .message = item.message };
    failure.violations = list;
    failure.violations_truncated = parsed.truncated or parsed.violations.len > kept.len;
}

/// An allocator that passes allocations on to `child`, the arena of a
/// call, up to `limit` bytes in all, and remembers when it refused one.
/// Frees give nothing back: the arena keeps what it handed out until the
/// end.
const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    /// It refused an allocation over the limit.
    exceeded: bool = false,

    fn allocator(b: *Budget) std.mem.Allocator {
        return .{ .ptr = b, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// `ResponseTooLarge` when the budget refused memory, else the
    /// allocator under it did: `OutOfMemory`.
    fn outOfMemory(b: *const Budget) error{ OutOfMemory, ResponseTooLarge } {
        return if (b.exceeded) error.ResponseTooLarge else error.OutOfMemory;
    }

    fn take(b: *Budget, n: usize) bool {
        if (n > b.limit - b.used) {
            b.exceeded = true;
            return false;
        }
        b.used += n;
        return true;
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ptr));
        if (!b.take(len)) return null;
        return b.child.rawAlloc(len, alignment, ret_addr) orelse {
            b.used -= len;
            return null;
        };
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const b: *Budget = @ptrCast(@alignCast(ptr));
        const more = new_len -| memory.len;
        if (!b.take(more)) return false;
        if (b.child.rawResize(memory, alignment, new_len, ret_addr)) return true;
        b.used -= more;
        return false;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ptr));
        const more = new_len -| memory.len;
        if (!b.take(more)) return null;
        return b.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            b.used -= more;
            return null;
        };
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const b: *Budget = @ptrCast(@alignCast(ptr));
        b.child.rawFree(memory, alignment, ret_addr);
    }
};

/// Frees an arena with the caller's cancelation held: a Debug allocator may
/// take a cancelable lock.
fn freeArena(io: std.Io, arena: *std.heap.ArenaAllocator) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    arena.deinit();
}

const testing = std.testing;

test "a budget refuses what passes its limit and says so" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var budget: Budget = .{ .child = arena.allocator(), .limit = 100 };
    const a = budget.allocator();
    _ = try a.alloc(u8, 60);
    try testing.expect(!budget.exceeded);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 41));
    try testing.expect(budget.exceeded);
    try testing.expectEqual(error.ResponseTooLarge, budget.outOfMemory());
    // Frees give nothing back: the arena keeps the bytes.
    const last = try a.alloc(u8, 40);
    a.free(last);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
}

test "a budget over an allocator that fails reports OutOfMemory" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var budget: Budget = .{ .child = failing.allocator(), .limit = 1 << 20 };
    try testing.expectError(error.OutOfMemory, budget.allocator().alloc(u8, 10));
    try testing.expect(!budget.exceeded);
    try testing.expectEqual(error.OutOfMemory, budget.outOfMemory());
    try testing.expectEqual(@as(usize, 0), budget.used);
}

test {
    _ = @import("client_options.zig");
    _ = @import("client_tests.zig");
}
