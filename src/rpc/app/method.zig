//! The engine's handler of one method of a contract: it turns the bytes of
//! a request into the method's request type, checks it against its
//! `field_rules`, calls the method of the application's handler, checks
//! the response against its rules and turns it back into bytes. Internal
//! to the module; `rpc.Server` builds one for each method it serves.
//!
//! A stage that fails ends the call with an exact failure, named by the
//! stage and not by the Zig error (rpc 1.6, §5.9 of the specification):
//!
//! - a body that does not decode: `invalid_argument` / `rpc.invalid_request`,
//!   with what is wrong and where;
//! - a request against its rules: `invalid_argument` /
//!   `rpc.invalid_request`, with its violations, also in the body of the
//!   failure: at most 100, and as many as `max_response_bytes` holds;
//! - a response against its rules, or one that does not encode:
//!   `internal` / `rpc.invalid_response`, the details only in the server's
//!   log;
//! - memory or size over the limits: `resource_exhausted` /
//!   `rpc.resource_exhausted`.
//!
//! The errors of the method itself go on as they are: the contract's table
//! and the framework's names map them once the chain of middleware has
//! unwound. The violations of a failure that the method sets with
//! `ctx.fail` go out in the body of the failure, as those of a request.

const std = @import("std");
const v = @import("validator");
const model = @import("../model.zig");
const rules = @import("../rules.zig");
const failures = @import("../failures.zig");
const json = @import("json.zig");
const violations = @import("violations.zig");
const engine_context = @import("../engine/Context.zig");
const Context = engine_context.Context;

const log = std.log.scoped(.rpc);

/// A response the server's own contract does not allow.
pub const invalid_response: model.Failure = .{ .code = .internal, .app_code = "rpc.invalid_response", .message = "Invalid response" };

/// The engine's handler of `M`, a method of a contract (the type of
/// `UserApi.getUser`), on a handler of type `T`: `Handler.ptr` is the
/// handler, a `*T`.
pub fn Wrapper(comptime T: type, comptime M: type) type {
    return struct {
        pub fn handle(ptr: *anyopaque, ctx: *Context, body: []const u8) anyerror![]const u8 {
            const handler: *T = @ptrCast(@alignCast(ptr));
            const io = ctx.io();
            const request = request: {
                // The stages allocate in the call's arena, and a Debug
                // allocator may take a cancelable lock: it would swallow a
                // cancelation of the handler's task.
                const protection = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(protection);
                break :request try decodeRequest(M.Request, ctx, body);
            };
            // The deadline, the client or the stop may have ended the call
            // meanwhile: then the method does not run.
            try io.checkCancel();
            const response = @field(T, M.name)(handler, ctx, request) catch |err| {
                const failed: anyerror = err;
                if (failed != error.RpcFailure) return err;
                const protection = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(protection);
                return failWithOwnViolations(ctx);
            };
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            return encodeResponse(M.Response, ctx, &response);
        }
    };
}

/// After a method returned `error.RpcFailure`: the violations of the
/// failure it set with `ctx.fail` go out as the body of the failure, like
/// those of a request against its rules. A code or a message that JSON
/// cannot carry fails the call with `internal` / `rpc.invalid_response`.
fn failWithOwnViolations(ctx: *Context) error{RpcFailure} {
    const call = engine_context.callOf(ctx);
    // Without ctx.fail the call fails with internal.
    const reason = call.recorded orelse return error.RpcFailure;
    if (reason.violations.len == 0 or call.failure_body.len > 0) return error.RpcFailure;
    const list = violations.fromFailure(ctx.allocator(), reason.violations) catch |err| switch (err) {
        error.OutOfMemory => return ctx.fail(failures.out_of_memory),
        error.InvalidUtf8 => {
            const route = ctx.route();
            log.warn("{s}.v{d}.{s} failed with a violation whose code or message is not UTF-8", .{ route.service, route.version, route.method });
            return ctx.fail(invalid_response);
        },
    };
    var failure = reason;
    failure.violations = list;
    failure.violations_truncated = reason.violations_truncated or reason.violations.len > list.len;
    return failWithViolations(ctx, failure);
}

/// The request in `body`, decoded in the call's arena within the server's
/// limits and checked against its rules. Its strings may point into
/// `body`.
fn decodeRequest(comptime Req: type, ctx: *Context, body: []const u8) error{RpcFailure}!Req {
    const limits = engine_context.callOf(ctx).limits;
    var problem: json.Problem = .{};
    const request = json.decode(Req, ctx.allocator(), body, .{
        .max_depth = limits.max_json_depth,
        .max_items = limits.max_container_items,
    }, &problem) catch |err| return switch (err) {
        error.Invalid => ctx.fail(.{
            .code = .invalid_argument,
            .app_code = "rpc.invalid_request",
            .message = problem.message,
            .field = problem.field,
        }),
        error.OutOfMemory => ctx.fail(failures.out_of_memory),
    };
    try checkRequest(Req, ctx, &request);
    return request;
}

/// Fails the call with every violation of `request`, if it has any: in the
/// failure for middleware, and as the body of the failure for the client.
fn checkRequest(comptime Req: type, ctx: *Context, request: *const Req) error{RpcFailure}!void {
    // The first violation costs no memory; a request that keeps its rules
    // allocates nothing here.
    var path_buf: [rules.max_field_bytes]u8 = undefined;
    if (v.check(request, &path_buf) == null) return;
    // The report and the body live in the call's arena, freed with it.
    const arena = ctx.allocator();
    const report = v.checkAll(arena, request) catch return ctx.fail(failures.out_of_memory);
    const list = violations.fromReport(arena, report) catch return ctx.fail(failures.out_of_memory);
    return failWithViolations(ctx, .{
        .code = .invalid_argument,
        .app_code = "rpc.invalid_request",
        .message = "Invalid request",
        .field = if (list.len > 0) list[0].field else null,
        .violations = list,
        .violations_truncated = report.truncated,
    });
}

/// Fails the call with `reason`, its violations as the body of the
/// failure: the first that fit `max_response_bytes`, at most 100, with
/// `"truncated":true` when some are left out. Middleware sees the
/// violations that were sent; the failure itself always fits.
fn failWithViolations(ctx: *Context, reason: model.Failure) error{RpcFailure} {
    const max_bytes = engine_context.callOf(ctx).limits.max_response_bytes;
    const kept = violations.fit(reason.violations, reason.violations_truncated, max_bytes);
    var failure = reason;
    failure.violations = reason.violations[0..kept.count];
    failure.violations_truncated = kept.truncated;
    const body = violations.encode(ctx.allocator(), failure.violations, failure.violations_truncated) catch return ctx.fail(failures.out_of_memory);
    return engine_context.failWithBody(ctx, failure, body);
}

/// `response`, checked against its rules, as JSON in the call's arena. The
/// size is counted first, so that the bytes are allocated once and a
/// response over `max_response_bytes` is refused before it takes any
/// memory.
fn encodeResponse(comptime Resp: type, ctx: *Context, response: *const Resp) error{RpcFailure}![]const u8 {
    if (Resp != void) {
        var path_buf: [rules.max_field_bytes]u8 = undefined;
        if (v.check(response, &path_buf)) |violation| {
            const route = ctx.route();
            // The violation holds no value: the path, a code and a static
            // message.
            log.warn("{s}.v{d}.{s} returned a response against its rules: {s}: {s} ({s})", .{
                route.service,
                route.version,
                route.method,
                violation.field orelse "the response",
                violation.message,
                violation.code,
            });
            return ctx.fail(invalid_response);
        }
    }
    const limits = engine_context.callOf(ctx).limits;
    var buffer: [256]u8 = undefined;
    var counter: Counter = .init(&buffer, limits.max_response_bytes);
    json.encode(Resp, response, &counter.writer) catch |err| switch (err) {
        error.WriteFailed => return ctx.fail(failures.response_too_large),
        error.NonFinite, error.InvalidUtf8 => {
            const route = ctx.route();
            log.warn("{s}.v{d}.{s} returned a response that JSON cannot carry: {s}", .{
                route.service,
                route.version,
                route.method,
                if (err == error.NonFinite) "a float that is NaN or infinite" else "a string that is not UTF-8",
            });
            return ctx.fail(invalid_response);
        },
    };
    const size = counter.total();
    if (size > limits.max_response_bytes) return ctx.fail(failures.response_too_large);
    const bytes = ctx.allocator().alloc(u8, size) catch return ctx.fail(failures.out_of_memory);
    var writer: std.Io.Writer = .fixed(bytes);
    // The same value encodes to the same bytes, which fit exactly.
    json.encode(Resp, response, &writer) catch return ctx.fail(invalid_response);
    if (writer.end != size) return ctx.fail(invalid_response);
    return bytes;
}

/// A writer that counts what is written to it and fails once the count
/// passes `limit`: the size of an encoding, without keeping its bytes.
const Counter = struct {
    count: usize = 0,
    limit: usize,
    writer: std.Io.Writer,

    fn init(buffer: []u8, limit: usize) Counter {
        return .{ .limit = limit, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    /// What was written, the buffered bytes included.
    fn total(c: *const Counter) usize {
        return c.count +| c.writer.end;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const c: *Counter = @alignCast(@fieldParentPtr("writer", w));
        var written: usize = data[data.len - 1].len *| splat;
        for (data[0 .. data.len - 1]) |bytes| written +|= bytes.len;
        c.count +|= w.end +| written;
        w.end = 0;
        if (c.count > c.limit) return error.WriteFailed;
        return written;
    }
};

const testing = std.testing;

test "a counter counts what passes its buffer, and fails once a drain passes its limit" {
    var buffer: [4]u8 = undefined;
    var counter: Counter = .init(&buffer, 10);
    try counter.writer.writeAll("abc");
    try testing.expectEqual(@as(usize, 3), counter.total());
    try counter.writer.writeAll("defgh");
    try counter.writer.splatByteAll('x', 2);
    try testing.expectEqual(@as(usize, 10), counter.total());
    // The buffer may hold bytes past the limit until it drains: the caller
    // compares `total` with the limit at the end.
    try counter.writer.writeAll("y");
    try testing.expectEqual(@as(usize, 11), counter.total());
    try testing.expectError(error.WriteFailed, counter.writer.writeAll("zzzz"));

    var exact: Counter = .init(&buffer, 3);
    try exact.writer.writeAll("abc");
    try testing.expectEqual(@as(usize, 3), exact.total());
}
