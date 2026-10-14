//! The failures of the engine itself, with static strings, and how an error
//! of a handler becomes a failure. Internal to the module.

const std = @import("std");
const model = @import("model.zig");
const Failure = model.Failure;

/// The failure an error of a handler or middleware becomes, once the chain
/// of middleware has unwound, in this order:
///
/// 1. `error.RpcFailure`: the failure recorded with `ctx.fail`, as it is
///    (`internal` when none was recorded).
/// 2. `map_error`: the `.errors` table of the contract.
/// 3. The framework's names: `Canceled` (of `std.Io`) and `Cancelled` →
///    `cancelled`, `DeadlineExceeded`, `InvalidArgument`, `Unauthenticated`,
///    `PermissionDenied`, `ResourceExhausted` and `OutOfMemory` →
///    `resource_exhausted`, `Unavailable`, `Internal`; the app code is
///    "rpc.<code>".
/// 4. Any other error → `internal`. Its name does not leave the server.
pub fn fromError(err: anyerror, recorded: ?Failure, map_error: ?*const fn (err: anyerror) ?Failure) Failure {
    if (err == error.RpcFailure) return recorded orelse internal;
    if (map_error) |map| if (map(err)) |failure| return failure;
    return switch (err) {
        error.Canceled, error.Cancelled => cancelled,
        error.DeadlineExceeded => deadline_exceeded,
        error.InvalidArgument => invalid_argument,
        error.Unauthenticated => unauthenticated,
        error.PermissionDenied => permission_denied,
        error.ResourceExhausted, error.OutOfMemory => resource_exhausted,
        error.Unavailable => unavailable,
        error.Internal => internal,
        else => internal,
    };
}

pub const cancelled: Failure = .{ .code = .cancelled, .app_code = "rpc.cancelled", .message = "Cancelled" };
pub const invalid_argument: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Invalid argument" };
pub const unauthenticated: Failure = .{ .code = .unauthenticated, .app_code = "rpc.unauthenticated", .message = "Unauthenticated" };
pub const permission_denied: Failure = .{ .code = .permission_denied, .app_code = "rpc.permission_denied", .message = "Permission denied" };
pub const resource_exhausted: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Resource exhausted" };
pub const unavailable: Failure = .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Unavailable" };
pub const internal: Failure = .{ .code = .internal, .app_code = "rpc.internal", .message = "Internal error" };

/// No method serves the route.
pub const unknown_method: Failure = .{ .code = .unimplemented, .app_code = "rpc.unknown_method", .message = "Unknown method" };
/// The body is not in a codec the server speaks ("json" in v1).
pub const unsupported_codec: Failure = .{ .code = .unimplemented, .app_code = "rpc.unsupported_codec", .message = "Unsupported codec" };
/// A metadata key or value against the rules, a repeated reserved key, a
/// `zefir-*` key the engine does not know.
pub const invalid_metadata: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_metadata", .message = "Invalid metadata" };
/// More metadata than `max_metadata_entries` or `max_metadata_bytes`.
pub const metadata_too_large: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Metadata too large" };
/// A negative budget from the transport.
pub const invalid_timeout: Failure = .{ .code = .invalid_argument, .app_code = "rpc.invalid_argument", .message = "Invalid timeout" };
/// No budget left, or the deadline passed.
pub const deadline_exceeded: Failure = .{ .code = .deadline_exceeded, .app_code = "rpc.deadline_exceeded", .message = "Deadline exceeded" };
/// No place for one more call.
pub const overloaded: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Server overloaded" };
/// A body over `max_request_bytes`.
pub const request_too_large: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Request too large" };
/// Over the memory of one call or of all calls.
pub const out_of_memory: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Out of memory" };
/// No task for the call.
pub const no_task: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "No task for the call" };
/// The server stops and the call did not start.
pub const stopping: Failure = .{ .code = .unavailable, .app_code = "rpc.unavailable", .message = "Server is stopping" };
/// The server stopped a call that had started.
pub const stopped: Failure = .{ .code = .cancelled, .app_code = "rpc.cancelled", .message = "Server stopped the call" };
/// A response body over `max_response_bytes`, or over what the transport
/// carries.
pub const response_too_large: Failure = .{ .code = .resource_exhausted, .app_code = "rpc.resource_exhausted", .message = "Response too large" };

const testing = std.testing;

fn expectFailure(expected: Failure, actual: Failure) !void {
    try testing.expectEqual(expected.code, actual.code);
    try testing.expectEqualStrings(expected.app_code, actual.app_code);
    try testing.expectEqualStrings(expected.message, actual.message);
}

test "the framework's error names become their failures" {
    const cases = [_]struct { anyerror, Failure }{
        .{ error.Canceled, cancelled },
        .{ error.Cancelled, cancelled },
        .{ error.DeadlineExceeded, deadline_exceeded },
        .{ error.InvalidArgument, invalid_argument },
        .{ error.Unauthenticated, unauthenticated },
        .{ error.PermissionDenied, permission_denied },
        .{ error.ResourceExhausted, resource_exhausted },
        .{ error.OutOfMemory, resource_exhausted },
        .{ error.Unavailable, unavailable },
        .{ error.Internal, internal },
    };
    for (cases) |case| try expectFailure(case[1], fromError(case[0], null, null));
    try testing.expectEqualStrings("rpc.deadline_exceeded", fromError(error.DeadlineExceeded, null, null).app_code);
}

test "any other error is internal, and its name does not leave the server" {
    const failure = fromError(error.DatabaseConnectionRefused, null, null);
    try expectFailure(internal, failure);
    try testing.expect(std.mem.find(u8, failure.message, "Database") == null);
}

fn mapUsers(err: anyerror) ?Failure {
    return switch (err) {
        error.UserNotFound => .{ .code = .not_found, .app_code = "users.not_found", .message = "User not found" },
        // A contract may give a framework name its own failure.
        error.Unavailable => .{ .code = .unavailable, .app_code = "users.maintenance", .message = "Down for maintenance" },
        else => null,
    };
}

test "a recorded failure comes first, then the contract's table, then the framework's names" {
    const recorded: Failure = .{ .code = .failed_precondition, .app_code = "users.locked", .message = "Locked", .field = "id" };
    const exact = fromError(error.RpcFailure, recorded, mapUsers);
    try expectFailure(recorded, exact);
    try testing.expectEqualStrings("id", exact.field.?);
    // RpcFailure without a recorded failure is a bug of the caller.
    try expectFailure(internal, fromError(error.RpcFailure, null, mapUsers));

    try testing.expectEqualStrings("users.not_found", fromError(error.UserNotFound, null, mapUsers).app_code);
    try testing.expectEqualStrings("users.maintenance", fromError(error.Unavailable, null, mapUsers).app_code);
    // Not in the table: the framework's names, then internal.
    try expectFailure(cancelled, fromError(error.Canceled, recorded, mapUsers));
    try expectFailure(internal, fromError(error.Overflow, recorded, mapUsers));
}
