//! The engine's handler of one method of a contract: it turns the bytes of
//! a request into the method's request type, calls the method of the
//! application's handler and turns its response back into bytes. Internal
//! to the module; `rpc.Server` builds one for each method it serves.
//!
//! A stage that fails ends the call with an exact failure, named by the
//! stage and not by the Zig error (rpc 1.6, §5.9 of the specification):
//!
//! - a body that does not decode: `invalid_argument` / `rpc.invalid_request`,
//!   with what is wrong and where;
//! - a response that does not encode: `internal` / `rpc.invalid_response`,
//!   the details only in the server's log;
//! - memory or size over the limits: `resource_exhausted` /
//!   `rpc.resource_exhausted`.
//!
//! The errors of the method itself go on as they are: the contract's table
//! and the framework's names map them once the chain of middleware has
//! unwound.

const std = @import("std");
const model = @import("../model.zig");
const failures = @import("../failures.zig");
const json = @import("json.zig");
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
            const request = try decodeRequest(M.Request, ctx, body);
            const response = try @field(T, M.name)(handler, ctx, request);
            return encodeResponse(M.Response, ctx, &response);
        }
    };
}

/// The request in `body`, decoded in the call's arena within the server's
/// limits. Its strings may point into `body`.
fn decodeRequest(comptime Req: type, ctx: *Context, body: []const u8) error{RpcFailure}!Req {
    const limits = engine_context.callOf(ctx).limits;
    var problem: json.Problem = .{};
    return json.decode(Req, ctx.allocator(), body, .{
        .max_depth = limits.max_json_depth,
        .max_items = limits.max_container_items,
    }, &problem) catch |err| switch (err) {
        error.Invalid => ctx.fail(.{
            .code = .invalid_argument,
            .app_code = "rpc.invalid_request",
            .message = problem.message,
            .field = problem.field,
        }),
        error.OutOfMemory => ctx.fail(failures.out_of_memory),
    };
}

/// `response` as JSON in the call's arena. The size is counted first, so
/// that the bytes are allocated once and a response over
/// `max_response_bytes` is refused before it takes any memory.
fn encodeResponse(comptime Resp: type, ctx: *Context, response: *const Resp) error{RpcFailure}![]const u8 {
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
